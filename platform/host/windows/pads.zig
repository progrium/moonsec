//! Virtual gamepads on the Windows host, behind a small backend interface so the driver
//! route (docs/virtual-gamepad.md) can change without touching the injector.
//!
//! `Pads` turns the receiver's pad actions (connect, snapshot, disconnect) into plug,
//! update and unplug calls on a `Backend`. It holds no OS state, so it is tested anywhere;
//! the ViGEmBus backend is in host.zig and pad_vigem.c.
const std = @import("std");
const core = @import("core");

pub const Gamepad = core.input.Gamepad;
pub const Micros = core.input.Micros;
pub const max_pads = core.input.max_pads;

pub const Error = error{
    /// No driver (ViGEmBus not installed or not running). Retried after `retry_after`.
    Unavailable,
    /// The driver refused the request (device gone, bus reset, out of slots).
    Failed,
};

/// One virtual controller per slot (0..max_pads-1).
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Plug a controller into `slot`. May wait for PnP to bring the device up
        /// (ViGEmBus: tens of milliseconds); only called on connect.
        plug: *const fn (ptr: *anyopaque, slot: u8) Error!void,
        /// Submit a full state snapshot for a plugged slot.
        update: *const fn (ptr: *anyopaque, slot: u8, state: Gamepad) Error!void,
        /// Unplug `slot`; a no-op when it isn't plugged.
        unplug: *const fn (ptr: *anyopaque, slot: u8) void,
    };

    pub fn plug(b: Backend, slot: u8) Error!void {
        return b.vtable.plug(b.ptr, slot);
    }
    pub fn update(b: Backend, slot: u8, state: Gamepad) Error!void {
        return b.vtable.update(b.ptr, slot, state);
    }
    pub fn unplug(b: Backend, slot: u8) void {
        b.vtable.unplug(b.ptr, slot);
    }
};

/// Turns a value with `plug`, `update` and `unplug` methods into a `Backend`.
pub fn bind(comptime T: type, p: *T) Backend {
    const S = struct {
        fn plug(ptr: *anyopaque, slot: u8) Error!void {
            return @as(*T, @ptrCast(@alignCast(ptr))).plug(slot);
        }
        fn update(ptr: *anyopaque, slot: u8, state: Gamepad) Error!void {
            return @as(*T, @ptrCast(@alignCast(ptr))).update(slot, state);
        }
        fn unplug(ptr: *anyopaque, slot: u8) void {
            @as(*T, @ptrCast(@alignCast(ptr))).unplug(slot);
        }
        const vtable: Backend.VTable = .{ .plug = plug, .update = update, .unplug = unplug };
    };
    return .{ .ptr = p, .vtable = &S.vtable };
}

/// The Xbox 360 report a ViGEmBus (or any XUSB) target takes; XINPUT_GAMEPAD's layout.
pub const XusbReport = extern struct {
    buttons: u16,
    lt: u8,
    rt: u8,
    lx: i16,
    ly: i16,
    rx: i16,
    ry: i16,
};

/// `core.input.Gamepad` to an XUSB report. Clients put buttons in XInput order
/// (XINPUT_GAMEPAD_*: d-pad 0x1-0x8, start 0x10, back 0x20, thumbs 0x40/0x80, shoulders
/// 0x100/0x200, guide 0x400, A B X Y 0x1000-0x8000); bits above 15 have no XUSB button
/// and are dropped. Triggers are 16-bit on the wire and 8-bit in XInput.
pub fn toXusb(g: Gamepad) XusbReport {
    return .{
        .buttons = @truncate(g.buttons & 0xF7FF), // 0x800 is unassigned in XUSB
        .lt = @intCast(g.lt >> 8),
        .rt = @intCast(g.rt >> 8),
        .lx = g.lx,
        .ly = g.ly,
        .rx = g.rx,
        .ry = g.ry,
    };
}

pub const Stats = struct {
    plugs: u32 = 0,
    unplugs: u32 = 0,
    updates: u64 = 0,
    /// Pad actions dropped because no backend was available.
    dropped: u64 = 0,
    failures: u32 = 0,
};

pub const Pads = struct {
    backend: ?Backend = null,
    plugged: [max_pads]bool = .{false} ** max_pads,
    /// Last state submitted per slot, so repeats of the same snapshot cost nothing.
    last: [max_pads]?Gamepad = .{null} ** max_pads,
    /// After `Unavailable`, plugs are not retried before this time.
    retry_at: ?Micros = null,
    /// Backoff after `Unavailable` (a missing driver), so a connected pad doesn't
    /// enumerate devices on every packet.
    retry_after: Micros = 5_000_000,
    stats: Stats = .{},
    /// The backend was unavailable and the caller hasn't been told yet.
    warn_unavailable: bool = false,

    /// Applies one `core.input.Action.pad`. `now` is host time, for the retry backoff.
    pub fn apply(p: *Pads, index: u8, connected: bool, state: Gamepad, now: Micros) Error!void {
        if (index >= max_pads) return;
        const b = p.backend orelse {
            p.stats.dropped += 1;
            return;
        };
        if (!connected) {
            if (p.plugged[index]) {
                b.unplug(index);
                p.stats.unplugs += 1;
            }
            p.plugged[index] = false;
            p.last[index] = null;
            return;
        }
        if (!p.plugged[index]) {
            if (p.retry_at) |t| if (now < t) {
                p.stats.dropped += 1;
                return;
            };
            b.plug(index) catch |e| {
                p.stats.failures += 1;
                p.stats.dropped += 1;
                if (e == error.Unavailable) {
                    if (p.retry_at == null) p.warn_unavailable = true;
                    p.retry_at = now + p.retry_after;
                }
                return e;
            };
            p.retry_at = null;
            p.plugged[index] = true;
            p.last[index] = null;
            p.stats.plugs += 1;
        }
        if (p.last[index]) |l| if (std.meta.eql(l, state)) return;
        b.update(index, state) catch |e| {
            // The device went away underneath us (bus restarted, removed in Device
            // Manager): plug again on the next snapshot.
            p.stats.failures += 1;
            b.unplug(index);
            p.plugged[index] = false;
            p.last[index] = null;
            return e;
        };
        p.last[index] = state;
        p.stats.updates += 1;
    }

    /// Unplugs every slot (session end).
    pub fn unplugAll(p: *Pads) void {
        const b = p.backend orelse return;
        for (&p.plugged, &p.last, 0..) |*pl, *l, i| {
            if (pl.*) {
                b.unplug(@intCast(i));
                p.stats.unplugs += 1;
            }
            pl.* = false;
            l.* = null;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const Fake = struct {
    available: bool = true,
    fail_update: bool = false,
    plugged: [max_pads]bool = .{false} ** max_pads,
    state: [max_pads]Gamepad = .{Gamepad{}} ** max_pads,
    plugs: u32 = 0,
    updates: u32 = 0,

    pub fn plug(f: *Fake, slot: u8) Error!void {
        if (!f.available) return error.Unavailable;
        if (f.plugged[slot]) return error.Failed;
        f.plugged[slot] = true;
        f.plugs += 1;
    }
    pub fn update(f: *Fake, slot: u8, s: Gamepad) Error!void {
        if (!f.plugged[slot] or f.fail_update) return error.Failed;
        f.state[slot] = s;
        f.updates += 1;
    }
    pub fn unplug(f: *Fake, slot: u8) void {
        f.plugged[slot] = false;
    }
};

test "connect plugs, snapshots update, repeats are free, disconnect unplugs" {
    var f: Fake = .{};
    var p: Pads = .{ .backend = bind(Fake, &f) };
    const s: Gamepad = .{ .buttons = 0x1000, .lx = -100, .rt = 0xFFFF };
    try p.apply(1, true, s, 0);
    try testing.expect(f.plugged[1]);
    try testing.expectEqual(s, f.state[1]);
    try p.apply(1, true, s, 10);
    try testing.expectEqual(@as(u32, 1), f.updates);
    try p.apply(1, true, .{ .buttons = 0 }, 20);
    try testing.expectEqual(@as(u32, 2), f.updates);
    try p.apply(1, false, .{}, 30);
    try testing.expect(!f.plugged[1]);
    try p.apply(1, false, .{}, 40); // already gone
    try testing.expectEqual(@as(u32, 1), p.stats.unplugs);
    try p.apply(9, true, s, 50); // out of range: ignored
}

test "missing driver backs off, then plugs once it appears" {
    var f: Fake = .{ .available = false };
    var p: Pads = .{ .backend = bind(Fake, &f), .retry_after = 1000 };
    try testing.expectError(error.Unavailable, p.apply(0, true, .{}, 0));
    try testing.expect(p.warn_unavailable);
    p.warn_unavailable = false;
    f.available = true;
    try p.apply(0, true, .{}, 500); // inside the backoff: dropped quietly
    try testing.expect(!f.plugged[0]);
    try p.apply(0, true, .{}, 1000);
    try testing.expect(f.plugged[0]);
    try testing.expect(!p.warn_unavailable);
    try testing.expectEqual(@as(u64, 2), p.stats.dropped);
}

test "a failed update replugs on the next snapshot" {
    var f: Fake = .{};
    var p: Pads = .{ .backend = bind(Fake, &f) };
    try p.apply(0, true, .{ .buttons = 1 }, 0);
    f.fail_update = true;
    try testing.expectError(error.Failed, p.apply(0, true, .{ .buttons = 2 }, 1));
    try testing.expect(!f.plugged[0]);
    f.fail_update = false;
    try p.apply(0, true, .{ .buttons = 2 }, 2);
    try testing.expectEqual(@as(u32, 2), f.plugs);
    try testing.expectEqual(@as(u32, 2), f.state[0].buttons);
}

test "no backend drops pads" {
    var p: Pads = .{};
    try p.apply(0, true, .{}, 0);
    try testing.expectEqual(@as(u64, 1), p.stats.dropped);
}

test "unplugAll" {
    var f: Fake = .{};
    var p: Pads = .{ .backend = bind(Fake, &f) };
    try p.apply(0, true, .{}, 0);
    try p.apply(3, true, .{}, 0);
    p.unplugAll();
    try testing.expect(!f.plugged[0] and !f.plugged[3]);
    try testing.expectEqual(@as(u32, 2), p.stats.unplugs);
}

test "XUSB report mapping" {
    const r = toXusb(.{ .buttons = 0x1_F00F, .lx = -32768, .ly = 32767, .rx = 1, .ry = -1, .lt = 0xFFFF, .rt = 0x00FF });
    try testing.expectEqual(@as(u16, 0xF00F), r.buttons);
    try testing.expectEqual(@as(u8, 0xFF), r.lt);
    try testing.expectEqual(@as(u8, 0), r.rt);
    try testing.expectEqual(@as(i16, -32768), r.lx);
    try testing.expectEqual(@as(i16, -1), r.ry);
    try testing.expectEqual(@as(u16, 0x0400), toXusb(.{ .buttons = 0x0C00 }).buttons); // guide kept, 0x800 dropped
    try testing.expectEqual(@as(usize, 12), @sizeOf(XusbReport));
}
