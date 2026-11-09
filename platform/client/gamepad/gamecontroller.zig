//! macOS gamepads through GameController.framework (gc.m).
//!
//! Every controller with an extended gamepad profile (Xbox, DualShock 4,
//! DualSense, Switch Pro, MFi) reports through one API; GameController
//! already names the face buttons by position, so the mapping is direct.
//! Each poll snapshots `GCController.controllers`; `pads.Slots` turns the
//! snapshots into connect, change and disconnect events.
//!
//! The mapping (`toGamepad`, `Snapshotter`) builds and is tested on every OS;
//! `Source` needs macOS and links GameController and Foundation.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("platform");
const pads = @import("pads.zig");

const Gamepad = pads.Gamepad;

/// `mgc_pad` in gc.h.
pub const MgcPad = extern struct {
    id: u64 = 0,
    buttons: u32 = 0,
    lx: f32 = 0,
    ly: f32 = 0,
    rx: f32 = 0,
    ry: f32 = 0,
    lt: f32 = 0,
    rt: f32 = 0,
};

pub fn toGamepad(p: MgcPad) Gamepad {
    return .{
        .buttons = p.buttons & 0xF7FF,
        .lx = pads.stickF(p.lx),
        .ly = pads.stickF(p.ly),
        .rx = pads.stickF(p.rx),
        .ry = pads.stickF(p.ry),
        .lt = pads.triggerF(p.lt),
        .rt = pads.triggerF(p.rt),
    };
}

/// Up to this many controllers are looked at per poll.
pub const max_seen = 8;

/// Turns one poll's list of controllers into slot updates, including
/// disconnects for the ones missing since the last poll.
pub const Snapshotter = struct {
    slots: pads.Slots = .{},
    prev: [max_seen]u64 = undefined,
    prev_n: usize = 0,

    pub fn apply(s: *Snapshotter, seen: []const MgcPad, now: api.Micros) void {
        for (s.prev[0..s.prev_n]) |id| {
            const still = for (seen) |p| {
                if (p.id == id) break true;
            } else false;
            if (!still) s.slots.update(id, null, now);
        }
        for (seen) |p| s.slots.update(p.id, toGamepad(p), now);
        s.prev_n = @min(seen.len, max_seen);
        for (seen[0..s.prev_n], 0..) |p, i| s.prev[i] = p.id;
    }
};

const c = struct {
    extern fn mgc_init() void;
    extern fn mgc_poll(out: [*]MgcPad, cap: usize) usize;
};

pub const Source = struct {
    clock: api.Clock,
    snap: Snapshotter = .{},

    pub fn open(clock: api.Clock) api.Error!Source {
        if (builtin.os.tag == .macos) c.mgc_init() else return error.Unsupported;
        return .{ .clock = clock };
    }

    pub fn poll(s: *Source, out: []api.InputEvent) api.Error!usize {
        if (builtin.os.tag == .macos) {
            var seen: [max_seen]MgcPad = undefined;
            const n = c.mgc_poll(&seen, seen.len);
            s.snap.apply(seen[0..n], s.clock.now());
        }
        return s.snap.slots.drain(out);
    }

    pub fn close(s: *Source) void {
        s.snap.slots.disconnectAll(s.clock.now());
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const B = pads.Button;

test "gamecontroller: floats and bits to a Gamepad" {
    const g = toGamepad(.{ .id = 1, .buttons = B.a | B.guide | B.dpad_left, .lx = -1, .ly = 1, .rx = 0.5, .ry = -0.25, .lt = 1, .rt = 0 });
    try testing.expectEqual(B.a | B.guide | B.dpad_left, g.buttons);
    try testing.expectEqual(@as(i16, -32768), g.lx);
    try testing.expectEqual(@as(i16, 32767), g.ly); // GameController's y is up positive, like ours
    try testing.expectEqual(@as(i16, 16384), g.rx);
    try testing.expectEqual(@as(i16, -8192), g.ry);
    try testing.expectEqual(@as(u16, 65535), g.lt);
    try testing.expectEqual(@as(u16, 0), g.rt);
}

test "gamecontroller: struct layout matches gc.h" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(MgcPad));
    try testing.expectEqual(@as(usize, 8), @offsetOf(MgcPad, "buttons"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(MgcPad, "lx"));
}

test "gamecontroller: snapshots become connects, changes and disconnects" {
    var s: Snapshotter = .{};
    var out: [16]api.InputEvent = undefined;

    s.apply(&.{ .{ .id = 0xA0 }, .{ .id = 0xB0, .buttons = B.b } }, 1);
    try testing.expectEqual(@as(usize, 2), s.slots.drain(&out));
    try testing.expectEqual(@as(u8, 1), out[1].what.pad.index);

    s.apply(&.{ .{ .id = 0xA0 }, .{ .id = 0xB0, .buttons = B.b } }, 2);
    try testing.expectEqual(@as(usize, 0), s.slots.drain(&out));

    // A unplugged, B pressed X.
    s.apply(&.{.{ .id = 0xB0, .buttons = B.x }}, 3);
    try testing.expectEqual(@as(usize, 2), s.slots.drain(&out));
    try testing.expectEqual(@as(u8, 0), out[0].what.pad.index);
    try testing.expectEqual(@as(?Gamepad, null), out[0].what.pad.state);
    try testing.expectEqual(B.x, out[1].what.pad.state.?.buttons);

    // A new controller takes the freed slot 0.
    s.apply(&.{ .{ .id = 0xB0, .buttons = B.x }, .{ .id = 0xC0 } }, 4);
    try testing.expectEqual(@as(usize, 1), s.slots.drain(&out));
    try testing.expectEqual(@as(u8, 0), out[0].what.pad.index);
}

test "gamecontroller: source opens and polls (macOS)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var s = try Source.open(.{ .nowFn = struct {
        fn f(_: ?*anyopaque) api.Micros {
            return 0;
        }
    }.f });
    defer s.close();
    var out: [8]api.InputEvent = undefined;
    // CI runners have no controllers; just make sure the framework answers.
    _ = try s.poll(&out);
}
