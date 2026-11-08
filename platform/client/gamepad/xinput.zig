//! Windows gamepads through XInput.
//!
//! XInput covers Xbox 360, Xbox One and Series pads and anything that speaks
//! their protocol, which is also what the Windows host's virtual pad will be.
//! Its layout is the one `core.input.Gamepad` uses, so the mapping is direct.
//! The DLL is loaded at run time (xinput1_4.dll, Windows 8 and later, falling
//! back to xinput9_1_0.dll); without it `Source` reports no pads.
//! XInputGetStateEx (ordinal 100 of xinput1_4) adds the guide button when
//! present.
//!
//! GameInput would add non-XInput pads (DualSense, Switch Pro) on Windows 10+,
//! but it ships as a redistributable and has no mingw headers; those pads can
//! come later through it or through Steam Input's XInput emulation.
//!
//! The mapping part builds and is tested on every OS; `Source` needs Windows.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("platform");
const pads = @import("pads.zig");

const Gamepad = pads.Gamepad;

/// XINPUT_GAMEPAD.
pub const XGamepad = extern struct {
    buttons: u16 = 0,
    left_trigger: u8 = 0,
    right_trigger: u8 = 0,
    thumb_lx: i16 = 0,
    thumb_ly: i16 = 0,
    thumb_rx: i16 = 0,
    thumb_ry: i16 = 0,
};

/// XINPUT_STATE.
pub const XState = extern struct {
    packet: u32 = 0,
    pad: XGamepad = .{},
};

/// XInput's wButtons bits are `Gamepad.Button`'s; 0x0400 is the guide button
/// from XInputGetStateEx and 0x0800 is unused.
pub fn toGamepad(x: XGamepad) Gamepad {
    return .{
        .buttons = x.buttons & 0xF7FF,
        .lx = x.thumb_lx,
        .ly = x.thumb_ly,
        .rx = x.thumb_rx,
        .ry = x.thumb_ry,
        .lt = pads.trigger8(x.left_trigger),
        .rt = pads.trigger8(x.right_trigger),
    };
}

pub const user_count = 4;
const error_success: u32 = 0;

/// How often to look again at a user index with nothing plugged in. XInput
/// documents that querying an empty slot is slow, so do it rarely.
pub const recheck_us: api.Micros = 500_000;

/// WINAPI on Windows; elsewhere (tests with a fake XInput) the C convention.
const winapi: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;
const GetStateFn = *const fn (user: u32, state: *XState) callconv(winapi) u32;

const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
} else struct {};

pub const Source = struct {
    clock: api.Clock,
    get_state: ?GetStateFn = null,
    /// Which DLL `get_state` came from, for logs and tests.
    dll: []const u8 = "",
    slots: pads.Slots = .{},
    connected: [user_count]bool = .{false} ** user_count,
    packet: [user_count]u32 = .{0} ** user_count,
    next_check: [user_count]api.Micros = .{0} ** user_count,

    /// Loads XInput. Never fails: without XInput the source reports no pads.
    pub fn open(clock: api.Clock) Source {
        var s: Source = .{ .clock = clock };
        if (builtin.os.tag != .windows) return s;
        const names = [_][:0]const u8{ "xinput1_4.dll", "xinput9_1_0.dll" };
        for (names) |name| {
            const m = win.LoadLibraryA(name) orelse continue;
            // Ordinal 100: XInputGetStateEx (reports the guide button).
            const ex: ?*const anyopaque = if (std.mem.eql(u8, name, "xinput1_4.dll"))
                win.GetProcAddress(m, @ptrFromInt(100))
            else
                null;
            const f = ex orelse win.GetProcAddress(m, "XInputGetState") orelse continue;
            s.get_state = @ptrCast(@alignCast(f));
            s.dll = name;
            break;
        }
        return s;
    }

    pub fn available(s: *const Source) bool {
        return s.get_state != null;
    }

    /// Reads every connected pad (and, every `recheck_us`, the empty slots)
    /// and copies pad events into `out`. Never blocks.
    pub fn poll(s: *Source, out: []api.InputEvent) api.Error!usize {
        if (s.get_state) |get| {
            const now = s.clock.now();
            for (0..user_count) |u| {
                if (!s.connected[u] and now < s.next_check[u]) continue;
                var st: XState = .{};
                const rc = get(@intCast(u), &st);
                if (rc != error_success) {
                    if (s.connected[u]) s.slots.update(u, null, now);
                    s.connected[u] = false;
                    s.next_check[u] = now + recheck_us;
                    continue;
                }
                if (s.connected[u] and st.packet == s.packet[u]) continue;
                s.connected[u] = true;
                s.packet[u] = st.packet;
                s.slots.update(u, toGamepad(st.pad), now);
            }
        }
        return s.slots.drain(out);
    }

    pub fn close(s: *Source) void {
        s.slots.disconnectAll(s.clock.now());
        s.get_state = null;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const B = pads.Button;

test "xinput: layout maps straight through" {
    const g = toGamepad(.{
        .buttons = 0x1000 | 0x0001 | 0x0010 | 0x0200 | 0x8000 | 0x0400 | 0x0800,
        .left_trigger = 255,
        .right_trigger = 128,
        .thumb_lx = -32768,
        .thumb_ly = 32767,
        .thumb_rx = 5,
        .thumb_ry = -5,
    });
    try testing.expectEqual(B.a | B.dpad_up | B.start | B.right_shoulder | B.y | B.guide, g.buttons);
    try testing.expectEqual(@as(u16, 65535), g.lt);
    try testing.expectEqual(@as(u16, 128 * 257), g.rt);
    try testing.expectEqual(@as(i16, -32768), g.lx);
    try testing.expectEqual(@as(i16, 32767), g.ly);
    try testing.expectEqual(@as(i16, 5), g.rx);
    try testing.expectEqual(@as(i16, -5), g.ry);
}

test "xinput: struct layout matches the SDK" {
    try testing.expectEqual(@as(usize, 12), @sizeOf(XGamepad));
    try testing.expectEqual(@as(usize, 16), @sizeOf(XState));
    try testing.expectEqual(@as(usize, 4), @offsetOf(XState, "pad"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(XGamepad, "thumb_lx"));
}

var fake_now: api.Micros = 0;
var fake_states: [user_count]?XState = .{null} ** user_count;
var fake_calls: usize = 0;

fn fakeNow(_: ?*anyopaque) api.Micros {
    return fake_now;
}

fn fakeGetState(user: u32, state: *XState) callconv(winapi) u32 {
    fake_calls += 1;
    if (fake_states[user]) |st| {
        state.* = st;
        return 0;
    }
    return 1167; // ERROR_DEVICE_NOT_CONNECTED
}

test "xinput: source with a fake XInput" {
    fake_now = 1000;
    fake_states = .{null} ** user_count;
    fake_calls = 0;
    var s: Source = .{ .clock = .{ .nowFn = fakeNow }, .get_state = &fakeGetState };
    var out: [8]api.InputEvent = undefined;

    try testing.expectEqual(@as(usize, 0), try s.poll(&out));
    try testing.expectEqual(@as(usize, 4), fake_calls);
    // Empty slots are not asked again until recheck_us passes.
    fake_now += 1000;
    try testing.expectEqual(@as(usize, 0), try s.poll(&out));
    try testing.expectEqual(@as(usize, 4), fake_calls);

    // A pad plugs into user index 2; seen at the next recheck, in slot 0.
    fake_states[2] = .{ .packet = 1, .pad = .{ .buttons = 0x1000 } };
    fake_now += recheck_us;
    try testing.expectEqual(@as(usize, 1), try s.poll(&out));
    try testing.expectEqual(@as(u8, 0), out[0].what.pad.index);
    try testing.expectEqual(B.a, out[0].what.pad.state.?.buttons);
    try testing.expectEqual(fake_now, out[0].time_us);

    // Same packet number: nothing new. A connected pad is read every poll.
    fake_calls = 0;
    fake_now += 1;
    try testing.expectEqual(@as(usize, 0), try s.poll(&out));
    try testing.expectEqual(@as(usize, 1), fake_calls);

    fake_states[2] = .{ .packet = 2, .pad = .{ .buttons = 0, .right_trigger = 255 } };
    try testing.expectEqual(@as(usize, 1), try s.poll(&out));
    try testing.expectEqual(@as(u16, 65535), out[0].what.pad.state.?.rt);

    fake_states[2] = null;
    try testing.expectEqual(@as(usize, 1), try s.poll(&out));
    try testing.expectEqual(@as(?Gamepad, null), out[0].what.pad.state);
}

test "xinput: open never fails" {
    var s = Source.open(.{ .nowFn = fakeNow });
    if (builtin.os.tag != .windows) try testing.expect(!s.available());
    var out: [8]api.InputEvent = undefined;
    _ = try s.poll(&out);
    s.close();
}
