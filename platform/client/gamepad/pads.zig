//! What every client gamepad backend shares: pad slots and value scaling.
//!
//! A backend sees devices under its own ids (an XInput user index, an evdev
//! device, a GCController). Each time it reads one it calls `Slots.update`
//! with the device's id and full state, or null when the device went away.
//! `Slots` gives each device one of the `core.input.max_pads` slots for as
//! long as it stays connected, drops states that did not change, and queues
//! `api.InputEvent.pad` events for the backend's `poll` to hand out.
//!
//! Pure; builds and is tested on every OS.

const std = @import("std");
const api = @import("platform");
const core = @import("core");

pub const Gamepad = core.input.Gamepad;
pub const Button = Gamepad.Button;
pub const max_pads = core.input.max_pads;

pub const Slots = struct {
    ids: [max_pads]?u64 = .{null} ** max_pads,
    last: [max_pads]Gamepad = .{Gamepad{}} ** max_pads,
    queue: [queue_len]api.InputEvent = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Events held between polls. When full, a new snapshot replaces the
    /// newest queued one for the same slot: snapshots are idempotent, so only
    /// presses shorter than the poll gap can be lost, never a final state.
    pub const queue_len = 64;

    /// Record a device's state; null means it disconnected. A device seen for
    /// the first time takes the lowest free slot; with every slot taken it is
    /// ignored until one frees up.
    pub fn update(s: *Slots, id: u64, state: ?Gamepad, time_us: api.Micros) void {
        const slot = if (s.slotOf(id)) |slot| blk: {
            if (state) |st| {
                if (std.meta.eql(s.last[slot], st)) return;
                s.last[slot] = st;
            } else {
                s.ids[slot] = null;
                s.last[slot] = .{};
            }
            break :blk slot;
        } else blk: {
            const st = state orelse return;
            const free = std.mem.indexOfScalar(?u64, &s.ids, null) orelse return;
            s.ids[free] = id;
            s.last[free] = st;
            break :blk free;
        };
        s.push(.{ .time_us = time_us, .what = .{ .pad = .{ .index = @intCast(slot), .state = state } } });
    }

    pub fn slotOf(s: *const Slots, id: u64) ?usize {
        for (s.ids, 0..) |maybe, i| if (maybe == id) return i;
        return null;
    }

    /// Disconnect every device still connected (the backend is closing).
    pub fn disconnectAll(s: *Slots, time_us: api.Micros) void {
        for (s.ids) |maybe| if (maybe) |id| s.update(id, null, time_us);
    }

    pub fn connected(s: *const Slots) usize {
        var n: usize = 0;
        for (s.ids) |maybe| n += @intFromBool(maybe != null);
        return n;
    }

    pub fn pending(s: *const Slots) usize {
        return s.len;
    }

    /// Move queued events into `out`, oldest first; returns how many.
    pub fn drain(s: *Slots, out: []api.InputEvent) usize {
        const n = @min(out.len, s.len);
        for (out[0..n]) |*o| {
            o.* = s.queue[s.head];
            s.head = (s.head + 1) % queue_len;
        }
        s.len -= n;
        return n;
    }

    fn push(s: *Slots, e: api.InputEvent) void {
        if (s.len == queue_len) {
            // Full: overwrite the newest event for this slot, if any.
            const idx = e.what.pad.index;
            var k = s.len;
            while (k > 0) {
                k -= 1;
                const at = (s.head + k) % queue_len;
                if (s.queue[at].what.pad.index == idx) {
                    s.queue[at] = e;
                    return;
                }
            }
            // No event for this slot is queued (cannot happen with fewer
            // slots than queue entries, but stay safe): drop the oldest.
            s.head = (s.head + 1) % queue_len;
            s.len -= 1;
        }
        s.queue[(s.head + s.len) % queue_len] = e;
        s.len += 1;
    }
};

// ---------------------------------------------------------------------------
// Scaling

/// A raw axis value in `min..max` to -32768..32767, centered at the midpoint.
/// `invert` flips the direction (evdev Y axes grow downwards; ours grow up).
pub fn stick(value: i32, min: i32, max: i32, invert: bool) i16 {
    if (max <= min) return 0;
    const lo: i64 = min;
    const hi: i64 = max;
    const v: i64 = std.math.clamp(@as(i64, value), lo, hi);
    // Map to 0..65535 then shift, so both ends reach the extremes exactly.
    var u: i64 = @divFloor((v - lo) * 65535 + @divFloor(hi - lo, 2), hi - lo);
    if (invert) u = 65535 - u;
    return @intCast(u - 32768);
}

/// A raw trigger value in `min..max` to 0..65535.
pub fn trigger(value: i32, min: i32, max: i32) u16 {
    if (max <= min) return 0;
    const lo: i64 = min;
    const hi: i64 = max;
    const v: i64 = std.math.clamp(@as(i64, value), lo, hi);
    return @intCast(@divFloor((v - lo) * 65535 + @divFloor(hi - lo, 2), hi - lo));
}

/// A float stick in -1..1 (GameController) to -32768..32767.
pub fn stickF(v: f32) i16 {
    if (!(v == v)) return 0; // NaN
    const c = std.math.clamp(v, -1.0, 1.0);
    const scaled = if (c < 0) c * 32768.0 else c * 32767.0;
    return @intFromFloat(@round(scaled));
}

/// A float trigger in 0..1 (GameController) to 0..65535.
pub fn triggerF(v: f32) u16 {
    if (!(v == v)) return 0;
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 65535.0));
}

/// An 8-bit trigger (XInput) to 0..65535.
pub fn trigger8(v: u8) u16 {
    return @as(u16, v) * 257;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectPad(e: api.InputEvent, index: u8, state: ?Gamepad) !void {
    try testing.expectEqual(index, e.what.pad.index);
    try testing.expectEqual(state, e.what.pad.state);
}

test "slots: first device takes slot 0 and reports even at rest" {
    var s: Slots = .{};
    s.update(77, .{}, 10);
    var out: [8]api.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 1), s.drain(&out));
    try expectPad(out[0], 0, Gamepad{});
    try testing.expectEqual(@as(api.Micros, 10), out[0].time_us);
}

test "slots: unchanged states are dropped, changes are queued in order" {
    var s: Slots = .{};
    s.update(1, .{}, 0);
    s.update(1, .{}, 1);
    s.update(1, .{ .buttons = Button.a }, 2);
    s.update(1, .{ .buttons = Button.a }, 3);
    s.update(1, .{ .buttons = Button.a, .lx = 100 }, 4);
    var out: [8]api.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 3), s.drain(&out));
    try expectPad(out[0], 0, Gamepad{});
    try expectPad(out[1], 0, Gamepad{ .buttons = Button.a });
    try expectPad(out[2], 0, Gamepad{ .buttons = Button.a, .lx = 100 });
}

test "slots: devices keep their slot; freed slots are reused lowest first" {
    var s: Slots = .{};
    s.update(10, .{}, 0);
    s.update(20, .{}, 0);
    s.update(30, .{}, 0);
    s.update(20, null, 1);
    s.update(40, .{ .buttons = Button.y }, 2);
    s.update(30, .{ .buttons = Button.b }, 3);
    var out: [16]api.InputEvent = undefined;
    const n = s.drain(&out);
    try testing.expectEqual(@as(usize, 6), n);
    try expectPad(out[3], 1, null);
    try expectPad(out[4], 1, Gamepad{ .buttons = Button.y });
    try expectPad(out[5], 2, Gamepad{ .buttons = Button.b });
    try testing.expectEqual(@as(usize, 3), s.connected());
}

test "slots: a fifth device waits for a free slot" {
    var s: Slots = .{};
    for (0..max_pads) |i| s.update(i, .{}, 0);
    s.update(99, .{ .buttons = Button.a }, 1);
    try testing.expectEqual(@as(?usize, null), s.slotOf(99));
    s.update(2, null, 2);
    s.update(99, .{ .buttons = Button.a }, 3);
    try testing.expectEqual(@as(?usize, 2), s.slotOf(99));
    // Disconnecting an unknown device does nothing.
    const before = s.pending();
    s.update(12345, null, 4);
    try testing.expectEqual(before, s.pending());
}

test "slots: a full queue keeps each slot's newest state" {
    var s: Slots = .{};
    s.update(1, .{}, 0);
    s.update(2, .{}, 0);
    var i: i16 = 1;
    while (i <= Slots.queue_len + 10) : (i += 1) s.update(1, .{ .lx = i }, i);
    s.update(2, .{ .rx = 5 }, 999);
    var out: [Slots.queue_len]api.InputEvent = undefined;
    const n = s.drain(&out);
    try testing.expectEqual(@as(usize, Slots.queue_len), n);
    var last1: ?Gamepad = null;
    var last2: ?Gamepad = null;
    for (out[0..n]) |e| {
        if (e.what.pad.index == 0) last1 = e.what.pad.state else last2 = e.what.pad.state;
    }
    try testing.expectEqual(@as(i16, Slots.queue_len + 10), last1.?.lx);
    try testing.expectEqual(@as(i16, 5), last2.?.rx);
}

test "slots: drain in pieces and disconnectAll" {
    var s: Slots = .{};
    s.update(1, .{}, 0);
    s.update(2, .{}, 0);
    s.disconnectAll(5);
    var out: [1]api.InputEvent = undefined;
    var seen: usize = 0;
    while (s.drain(&out) == 1) seen += 1;
    try testing.expectEqual(@as(usize, 4), seen);
    try testing.expectEqual(@as(usize, 0), s.connected());
}

test "scaling" {
    try testing.expectEqual(@as(i16, -32768), stick(-32768, -32768, 32767, false));
    try testing.expectEqual(@as(i16, 32767), stick(32767, -32768, 32767, false));
    try testing.expectEqual(@as(i16, 0), stick(0, -32768, 32767, false));
    try testing.expectEqual(@as(i16, -32768), stick(0, 0, 255, false));
    try testing.expectEqual(@as(i16, 32767), stick(255, 0, 255, false));
    try testing.expectEqual(@as(i16, 32767), stick(0, 0, 255, true));
    try testing.expectEqual(@as(i16, -32768), stick(400, 0, 255, true));
    try testing.expect(@abs(@as(i32, stick(128, 0, 255, false))) < 200);
    try testing.expectEqual(@as(i16, 0), stick(5, 3, 3, false));

    try testing.expectEqual(@as(u16, 0), trigger(0, 0, 1023));
    try testing.expectEqual(@as(u16, 65535), trigger(1023, 0, 1023));
    try testing.expectEqual(@as(u16, 65535), trigger(5000, 0, 255));
    try testing.expectEqual(@as(u16, 0), trigger(-5, 0, 255));

    try testing.expectEqual(@as(i16, -32768), stickF(-1.0));
    try testing.expectEqual(@as(i16, 32767), stickF(1.0));
    try testing.expectEqual(@as(i16, 32767), stickF(3.0));
    try testing.expectEqual(@as(i16, 0), stickF(0.0));
    try testing.expectEqual(@as(i16, 0), stickF(std.math.nan(f32)));
    try testing.expectEqual(@as(u16, 65535), triggerF(1.0));
    try testing.expectEqual(@as(u16, 0), triggerF(-0.5));
    try testing.expectEqual(@as(u16, 32768), triggerF(0.5));

    try testing.expectEqual(@as(u16, 0), trigger8(0));
    try testing.expectEqual(@as(u16, 65535), trigger8(255));
}
