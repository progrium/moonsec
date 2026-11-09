//! The evdev source against a real kernel device: a virtual pad made with
//! uinput, found through inotify, read and unplugged.
//!
//! Needs write access to /dev/uinput and read access to the event node it
//! creates (CI: `modprobe uinput` plus a udev rule, see .github/workflows/
//! gamepad.yml). Skips without them, unless built with -Duinput=required,
//! in which case missing access fails the test.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("platform");
const options = @import("gamepad_options");
const evdev = @import("evdev.zig");
const pads = @import("pads.zig");

const linux = std.os.linux;
const testing = std.testing;
const B = pads.Button;

// linux/uinput.h
const UinputSetup = extern struct {
    id: evdev.InputId,
    name: [80]u8,
    ff_effects_max: u32,
};
const UinputAbsSetup = extern struct {
    code: u16,
    _pad: u16 = 0,
    absinfo: evdev.AbsInfo,
};

fn ioc(dir: u32, nr: u8, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, 'U') << 8) | nr;
}
const UI_DEV_CREATE = ioc(0, 1, 0);
const UI_DEV_DESTROY = ioc(0, 2, 0);
const UI_DEV_SETUP = ioc(1, 3, @sizeOf(UinputSetup));
const UI_ABS_SETUP = ioc(1, 4, @sizeOf(UinputAbsSetup));
const UI_SET_EVBIT = ioc(1, 100, @sizeOf(c_int));
const UI_SET_KEYBIT = ioc(1, 101, @sizeOf(c_int));
const UI_SET_ABSBIT = ioc(1, 103, @sizeOf(c_int));

fn check(rc: usize) !void {
    if (linux.errno(rc) != .SUCCESS) return error.Ioctl;
}

const VirtualPad = struct {
    fd: i32,

    fn create(name: []const u8, vendor: u16) !VirtualPad {
        const rc = linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.NoUinput;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        try check(linux.ioctl(fd, UI_SET_EVBIT, evdev.EV_KEY));
        try check(linux.ioctl(fd, UI_SET_EVBIT, evdev.EV_ABS));
        const keys = [_]u16{
            evdev.BTN_SOUTH,  evdev.BTN_EAST,   evdev.BTN_NORTH, evdev.BTN_WEST, evdev.BTN_TL,
            evdev.BTN_TR,     evdev.BTN_SELECT, evdev.BTN_START, evdev.BTN_MODE, evdev.BTN_THUMBL,
            evdev.BTN_THUMBR,
        };
        for (keys) |k| try check(linux.ioctl(fd, UI_SET_KEYBIT, k));
        const axes = [_]struct { u16, i32, i32 }{
            .{ evdev.ABS_X, -32768, 32767 },  .{ evdev.ABS_Y, -32768, 32767 },
            .{ evdev.ABS_RX, -32768, 32767 }, .{ evdev.ABS_RY, -32768, 32767 },
            .{ evdev.ABS_Z, 0, 255 },         .{ evdev.ABS_RZ, 0, 255 },
            .{ evdev.ABS_HAT0X, -1, 1 },      .{ evdev.ABS_HAT0Y, -1, 1 },
        };
        for (axes) |a| {
            try check(linux.ioctl(fd, UI_SET_ABSBIT, a[0]));
            var s: UinputAbsSetup = .{ .code = a[0], .absinfo = .{ .minimum = a[1], .maximum = a[2] } };
            try check(linux.ioctl(fd, UI_ABS_SETUP, @intFromPtr(&s)));
        }
        var setup: UinputSetup = .{ .id = .{ .bustype = 0x03, .vendor = vendor, .product = 0x1234, .version = 1 }, .name = .{0} ** 80, .ff_effects_max = 0 };
        @memcpy(setup.name[0..name.len], name);
        try check(linux.ioctl(fd, UI_DEV_SETUP, @intFromPtr(&setup)));
        try check(linux.ioctl(fd, UI_DEV_CREATE, 0));
        return .{ .fd = fd };
    }

    fn emit(p: VirtualPad, typ: u16, code: u16, value: i32) !void {
        const e: evdev.RawEvent = .{ .type = typ, .code = code, .value = value };
        const rc = linux.write(p.fd, @ptrCast(&e), @sizeOf(evdev.RawEvent));
        if (linux.errno(rc) != .SUCCESS) return error.Write;
    }

    fn sync(p: VirtualPad) !void {
        try p.emit(evdev.EV_SYN, evdev.SYN_REPORT, 0);
    }

    fn destroy(p: VirtualPad) void {
        _ = linux.ioctl(p.fd, UI_DEV_DESTROY, 0);
        _ = linux.close(p.fd);
    }
};

fn monoNow(_: ?*anyopaque) api.Micros {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(api.Micros, ts.sec) * std.time.us_per_s + @divTrunc(ts.nsec, 1000);
}

fn sleepMs(ms: u32) void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
}

/// Polls until a pad event satisfying `pred` arrives, for up to 3 s.
fn waitFor(s: *evdev.Source, ctx: anytype, comptime pred: fn (@TypeOf(ctx), api.InputEvent) bool) !api.InputEvent {
    var out: [32]api.InputEvent = undefined;
    var tries: usize = 0;
    while (tries < 300) : (tries += 1) {
        const n = try s.poll(&out);
        for (out[0..n]) |e| if (pred(ctx, e)) return e;
        sleepMs(10);
    }
    return error.Timeout;
}

fn skipOrFail(why: []const u8) !void {
    if (options.require_uinput) {
        std.debug.print("uinput required but unavailable: {s}\n", .{why});
        return error.UinputUnavailable;
    }
    return error.SkipZigTest;
}

fn runPad(vendor: u16, north_bit: u32) !void {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "moonsec test pad {d}-{x}", .{ linux.getpid(), vendor });

    var src = try evdev.Source.open(.{ .nowFn = monoNow }, .{ .name_filter = name });
    defer src.close();
    // Nothing yet.
    var out: [8]api.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 0), try src.poll(&out));

    const pad = VirtualPad.create(name, vendor) catch |e| return skipOrFail(@errorName(e));
    var destroyed = false;
    defer if (!destroyed) pad.destroy();
    // /dev/input existed when the source opened, so hotplug is on.
    try testing.expect(src.inotify >= 0);

    // Hotplug: the new node shows up through inotify, at rest.
    const t0 = monoNow(null);
    const connected = waitFor(&src, {}, struct {
        fn f(_: void, e: api.InputEvent) bool {
            return e.what.pad.state != null;
        }
    }.f) catch return skipOrFail("the virtual pad's event node never became readable");
    try testing.expectEqual(@as(u8, 0), connected.what.pad.index);
    const rest = connected.what.pad.state.?;
    try testing.expectEqual(@as(u32, 0), rest.buttons);
    try testing.expectEqual(@as(u16, 0), rest.lt);
    try testing.expect(connected.time_us >= t0);

    // One report: A held, left stick up, right trigger full, d-pad right.
    try pad.emit(evdev.EV_KEY, evdev.BTN_SOUTH, 1);
    try pad.emit(evdev.EV_ABS, evdev.ABS_Y, -32768);
    try pad.emit(evdev.EV_ABS, evdev.ABS_RZ, 255);
    try pad.emit(evdev.EV_ABS, evdev.ABS_HAT0X, 1);
    const sent = monoNow(null);
    try pad.sync();
    const e1 = try waitFor(&src, {}, struct {
        fn f(_: void, e: api.InputEvent) bool {
            const st = e.what.pad.state orelse return false;
            return st.buttons & B.a != 0;
        }
    }.f);
    const g1 = e1.what.pad.state.?;
    try testing.expectEqual(B.a | B.dpad_right, g1.buttons);
    try testing.expectEqual(@as(i16, 32767), g1.ly);
    try testing.expectEqual(@as(u16, 65535), g1.rt);
    // The kernel's timestamp, on the monotonic clock, close to when we sent it.
    try testing.expect(@abs(e1.time_us - sent) < 1_000_000);

    // Release A, press the top face button.
    try pad.emit(evdev.EV_KEY, evdev.BTN_SOUTH, 0);
    try pad.emit(evdev.EV_KEY, evdev.BTN_NORTH, 1);
    try pad.sync();
    const e2 = try waitFor(&src, north_bit, struct {
        fn f(bit: u32, e: api.InputEvent) bool {
            const st = e.what.pad.state orelse return false;
            return st.buttons & bit != 0;
        }
    }.f);
    try testing.expectEqual(north_bit | B.dpad_right, e2.what.pad.state.?.buttons);

    // Unplug.
    pad.destroy();
    destroyed = true;
    const gone = try waitFor(&src, {}, struct {
        fn f(_: void, e: api.InputEvent) bool {
            return e.what.pad.state == null;
        }
    }.f);
    try testing.expectEqual(@as(u8, 0), gone.what.pad.index);
    try testing.expectEqual(@as(usize, 0), src.deviceCount());
}

test "uinput: virtual pad plugs in, reports and unplugs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try runPad(0x1209, B.y);
}

test "uinput: Microsoft pads swap NORTH/WEST back to xpad's X/Y" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try runPad(evdev.vendor_microsoft, B.x);
}

test "uinput: a pad already plugged in is found at open, and the state it has" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "moonsec test pad {d}-early", .{linux.getpid()});
    const pad = VirtualPad.create(name, 0x1209) catch |e| return skipOrFail(@errorName(e));
    defer pad.destroy();
    try pad.emit(evdev.EV_KEY, evdev.BTN_START, 1);
    try pad.sync();

    var src = try evdev.Source.open(.{ .nowFn = monoNow }, .{ .name_filter = name });
    defer src.close();
    const e = waitFor(&src, {}, struct {
        fn f(_: void, ev: api.InputEvent) bool {
            const st = ev.what.pad.state orelse return false;
            return st.buttons & B.start != 0;
        }
    }.f) catch return skipOrFail("the virtual pad's event node never became readable");
    try testing.expectEqual(B.start, e.what.pad.state.?.buttons);
}

test "uinput: the Linux host's virtual pad is skipped unless asked for" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Named the way platform/host/linux/input.zig names its pads, plus our pid so the
    // filter below sees only this one.
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "moonsec pad {d} (Xbox 360 layout)", .{linux.getpid()});
    try testing.expect(evdev.isHostPad(name));
    const pad = VirtualPad.create(name, 0x045e) catch |e| return skipOrFail(@errorName(e));
    defer pad.destroy();

    // Opt out of the skip first, so we know the node is readable before trusting a zero.
    var seen = try evdev.Source.open(.{ .nowFn = monoNow }, .{ .name_filter = name, .skip_host_pads = false });
    defer seen.close();
    _ = waitFor(&seen, {}, struct {
        fn f(_: void, e: api.InputEvent) bool {
            return e.what.pad.state != null;
        }
    }.f) catch return skipOrFail("the virtual pad's event node never became readable");
    try testing.expectEqual(@as(usize, 1), seen.deviceCount());

    var src = try evdev.Source.open(.{ .nowFn = monoNow }, .{ .name_filter = name });
    defer src.close();
    var out: [8]api.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 0), try src.poll(&out));
    try testing.expectEqual(@as(usize, 0), src.deviceCount());
}
