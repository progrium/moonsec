//! `zig build test-linux-host`: the Linux host's injector on real uinput devices, read
//! back from their /dev/input/event* nodes the way a compositor reads them.
//!
//! Needs write access to /dev/uinput and read access to /dev/input/event* (CI's
//! linux.yml sets both up). Without them each test is skipped, unless
//! MOONSEC_REQUIRE names `uinput`: then it fails. The cloud containers have no
//! /dev/uinput, so these run on a GitHub ubuntu-24.04 runner or a Linux machine.
const std = @import("std");
const host = @import("host_linux");
const ui = @import("linux_uinput");

const input = host.input;
const testing = std.testing;

fn required(what: []const u8) bool {
    const v = std.c.getenv("MOONSEC_REQUIRE") orelse return false;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(v), ',');
    while (it.next()) |t| if (std.mem.eql(u8, t, what)) return true;
    return false;
}

fn skip(what: []const u8, why: []const u8) error{ SkipZigTest, TestUnexpectedResult } {
    if (required(what)) {
        std.debug.print("{s} required but unavailable: {s}\n", .{ what, why });
        return error.TestUnexpectedResult;
    }
    std.debug.print("no {s} ({s}): skipping\n", .{ what, why });
    return error.SkipZigTest;
}

/// Every non-SYN event read from `r` within `ms`, until `want` of them arrived.
fn collect(r: ui.Reader, want: usize, ms: u32, out: []ui.Event) []ui.Event {
    var n: usize = 0;
    var waited: u32 = 0;
    var buf: [64]ui.Event = undefined;
    while (n < want and waited < ms) {
        const got = r.read(&buf);
        if (got.len == 0) {
            ui.sleepMs(2);
            waited += 2;
            continue;
        }
        for (got) |e| {
            if (e.type == ui.EV_SYN or e.type == ui.EV_MSC or n == out.len) continue;
            out[n] = e;
            n += 1;
        }
    }
    return out[0..n];
}

fn expectEvent(e: ui.Event, t: u16, code: u16, value: i32) !void {
    testing.expectEqual(t, e.type) catch |err| {
        std.debug.print("event: type {d} code {d} value {d}\n", .{ e.type, e.code, e.value });
        return err;
    };
    try testing.expectEqual(code, e.code);
    try testing.expectEqual(value, e.value);
}

fn reader(d: ui.Device) ?ui.Reader {
    return ui.Reader.open(d.node orelse return null, 3000);
}

test "uinput: keyboard and mouse actions arrive on their event nodes" {
    var j = input.Injector.init(input.Opener.uinput) catch |e| return skip("uinput", @errorName(e));
    defer j.deinit();
    const kb = reader(j.keyboard) orelse return skip("uinput", "cannot read the keyboard's event node");
    defer kb.close();
    const mouse = reader(j.mouse) orelse return skip("uinput", "cannot read the mouse's event node");
    defer mouse.close();

    try j.inject(.{ .key = .{ .code = 0x04, .down = true, .time = 0 } });
    try j.inject(.{ .key = .{ .code = 0x04, .down = false, .time = 0 } });
    try j.inject(.{ .key = .{ .code = 0xE0, .down = true, .time = 0 } }); // left ctrl
    try j.inject(.{ .key = .{ .code = 0xE0, .down = false, .time = 0 } });
    var buf: [32]ui.Event = undefined;
    const keys = collect(kb, 4, 1000, &buf);
    try testing.expectEqual(@as(usize, 4), keys.len);
    try expectEvent(keys[0], ui.EV_KEY, ui.KEY_A, 1);
    try expectEvent(keys[1], ui.EV_KEY, ui.KEY_A, 0);
    try expectEvent(keys[2], ui.EV_KEY, 29, 1);
    try expectEvent(keys[3], ui.EV_KEY, 29, 0);

    try j.inject(.{ .motion = .{ .dx = 5, .dy = -4 } });
    try j.inject(.{ .button = .{ .code = 2, .down = true, .time = 0 } });
    try j.inject(.{ .button = .{ .code = 2, .down = false, .time = 0 } });
    try j.inject(.{ .scroll = .{ .dx = 0, .dy = -120, .time = 0 } });
    const m = collect(mouse, 6, 1000, &buf);
    try testing.expectEqual(@as(usize, 6), m.len);
    try expectEvent(m[0], ui.EV_REL, ui.REL_X, 5);
    try expectEvent(m[1], ui.EV_REL, ui.REL_Y, -4);
    try expectEvent(m[2], ui.EV_KEY, ui.BTN_RIGHT, 1);
    try expectEvent(m[3], ui.EV_KEY, ui.BTN_RIGHT, 0);
    try expectEvent(m[4], ui.EV_REL, ui.REL_WHEEL_HI_RES, -120);
    try expectEvent(m[5], ui.EV_REL, ui.REL_WHEEL, -1);
}

test "uinput: absolute positions on the tablet, over the output's pixels" {
    var j = input.Injector.init(input.Opener.uinput) catch |e| return skip("uinput", @errorName(e));
    defer j.deinit();
    j.setOutput(.{ .width = 800, .height = 600 });
    // The first position creates the tablet; read the ones after it.
    try j.inject(.{ .abs = .{ .x = 0, .y = 0 } });
    const t = reader(j.tablet.?) orelse return skip("uinput", "cannot read the tablet's event node");
    defer t.close();
    try j.inject(.{ .abs = .{ .x = 65535, .y = 32768 } });
    var buf: [8]ui.Event = undefined;
    const ev = collect(t, 2, 1000, &buf);
    try testing.expectEqual(@as(usize, 2), ev.len);
    try expectEvent(ev[0], ui.EV_ABS, ui.ABS_X, 799);
    try expectEvent(ev[1], ui.EV_ABS, ui.ABS_Y, 300);
}

test "uinput: a gamepad appears on connect, reports the Xbox 360 layout, goes on disconnect" {
    var j = input.Injector.init(input.Opener.uinput) catch |e| return skip("uinput", @errorName(e));
    defer j.deinit();
    try j.inject(.{ .pad = .{ .index = 0, .connected = true, .state = .{} } });
    const node = j.pads[0].?.node orelse return skip("uinput", "the pad has no event node");
    const r = ui.Reader.open(node, 3000) orelse return skip("uinput", "cannot read the pad's event node");
    defer r.close();
    const B = input.PadButton;
    try j.inject(.{ .pad = .{ .index = 0, .connected = true, .state = .{ .buttons = B.a | B.dpad_left, .lx = -20000, .ly = 20000, .rt = 65535 } } });
    var buf: [16]ui.Event = undefined;
    // Only changes are reported: A, LX, LY, RZ, HAT0X.
    const ev = collect(r, 5, 1000, &buf);
    try testing.expectEqual(@as(usize, 5), ev.len);
    try expectEvent(ev[0], ui.EV_KEY, ui.BTN_SOUTH, 1);
    try expectEvent(ev[1], ui.EV_ABS, ui.ABS_X, -20000);
    try expectEvent(ev[2], ui.EV_ABS, ui.ABS_Y, -20000);
    try expectEvent(ev[3], ui.EV_ABS, ui.ABS_RZ, input.trigger_max);
    try expectEvent(ev[4], ui.EV_ABS, ui.ABS_HAT0X, -1);

    try j.inject(.{ .pad = .{ .index = 0, .connected = false, .state = .{} } });
    try testing.expectEqual(@as(?ui.Device, null), j.pads[0]);
    // The node goes away with the device.
    var gone = false;
    var waited: u32 = 0;
    while (!gone and waited < 2000) : (waited += 10) {
        var p: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&p, "/dev/input/event{d}", .{node}) catch unreachable;
        const rc = std.os.linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) gone = true else {
            _ = std.os.linux.close(@intCast(rc));
            ui.sleepMs(10);
        }
    }
    try testing.expect(gone);
}
