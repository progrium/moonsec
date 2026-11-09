//! A virtual keyboard and mouse through /dev/uinput, for tests and the end-to-end run:
//! it types keys into evdev the way a real keyboard does, so the client's evdev source
//! is exercised from the kernel up. Needs write access to /dev/uinput.
const std = @import("std");
const evdev = @import("evdev.zig");
const linux = std.os.linux;

fn ioc(dir: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, 'U') << 8) | nr;
}
const ui_dev_create = ioc(0, 1, 0);
const ui_dev_destroy = ioc(0, 2, 0);
const ui_dev_setup = ioc(1, 3, @sizeOf(Setup));
const ui_set_evbit = ioc(1, 100, @sizeOf(c_int));
const ui_set_keybit = ioc(1, 101, @sizeOf(c_int));
const ui_set_relbit = ioc(1, 102, @sizeOf(c_int));
fn uiGetSysname(len: u32) u32 {
    return ioc(2, 44, len);
}

const Setup = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [80]u8,
    ff_effects_max: u32,
};

pub const Error = error{ NoUinput, SetupFailed, NoEventNode };

pub const Device = struct {
    fd: i32,
    /// /dev/input/eventN of the new device.
    node: u8,

    /// Creates a keyboard (every KEY_* up to KEY_MICMUTE) with a mouse (REL_X/Y, wheels,
    /// five buttons), then waits up to 3 s for its event node to be openable (udev may
    /// still be setting its permissions).
    pub fn create(name: []const u8) Error!Device {
        const rc = linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.NoUinput;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        try set(fd, ui_set_evbit, evdev.EV_KEY);
        try set(fd, ui_set_evbit, evdev.EV_REL);
        var k: c_int = 1;
        while (k < 249) : (k += 1) try set(fd, ui_set_keybit, k);
        for ([_]c_int{ evdev.BTN_LEFT, evdev.BTN_RIGHT, evdev.BTN_MIDDLE, evdev.BTN_SIDE, evdev.BTN_EXTRA }) |b| try set(fd, ui_set_keybit, b);
        for ([_]c_int{ evdev.REL_X, evdev.REL_Y, evdev.REL_WHEEL, evdev.REL_HWHEEL }) |r| try set(fd, ui_set_relbit, r);
        var s: Setup = std.mem.zeroes(Setup);
        s.bustype = 0x06; // BUS_VIRTUAL
        s.vendor = 0x6d73;
        s.product = 0x0001;
        s.version = 1;
        @memcpy(s.name[0..@min(name.len, s.name.len - 1)], name[0..@min(name.len, s.name.len - 1)]);
        if (linux.errno(linux.ioctl(fd, ui_dev_setup, @intFromPtr(&s))) != .SUCCESS) return error.SetupFailed;
        if (linux.errno(linux.ioctl(fd, ui_dev_create, 0)) != .SUCCESS) return error.SetupFailed;
        errdefer _ = linux.ioctl(fd, ui_dev_destroy, 0);

        // inputN -> /sys/devices/virtual/input/inputN/eventM -> /dev/input/eventM.
        var sys: [64]u8 = @splat(0);
        if (linux.errno(linux.ioctl(fd, uiGetSysname(sys.len), @intFromPtr(&sys))) != .SUCCESS) return error.SetupFailed;
        const sysname = std.mem.sliceTo(&sys, 0);
        var tries: u32 = 0;
        while (tries < 300) : (tries += 1) {
            if (findEventNode(sysname)) |node| {
                var path_buf: [32]u8 = undefined;
                const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{node}) catch unreachable;
                const r = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
                if (linux.errno(r) == .SUCCESS) {
                    _ = linux.close(@intCast(r));
                    return .{ .fd = fd, .node = node };
                }
            }
            sleepMs(10);
        }
        return error.NoEventNode;
    }

    fn set(fd: i32, req: u32, v: c_int) Error!void {
        if (linux.errno(linux.ioctl(fd, req, @as(usize, @intCast(v)))) != .SUCCESS) return error.SetupFailed;
    }

    fn findEventNode(sysname: []const u8) ?u8 {
        var node: u8 = 0;
        while (node < evdev.max_nodes) : (node += 1) {
            var buf: [96]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "/sys/devices/virtual/input/{s}/event{d}", .{ sysname, node }) catch return null;
            const r = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(r) == .SUCCESS) {
                _ = linux.close(@intCast(r));
                return node;
            }
        }
        return null;
    }

    fn emit(d: Device, t: u16, code: u16, value: i32) void {
        const e: evdev.RawEvent = .{ .sec = 0, .usec = 0, .type = t, .code = code, .value = value };
        _ = linux.write(d.fd, @ptrCast(&e), @sizeOf(evdev.RawEvent));
    }

    fn syn(d: Device) void {
        d.emit(evdev.EV_SYN, evdev.SYN_REPORT, 0);
    }

    /// A key (KEY_* code) press or release, as its own report.
    pub fn key(d: Device, code: u16, down: bool) void {
        d.emit(evdev.EV_KEY, code, @intFromBool(down));
        d.syn();
    }

    /// Relative motion, as its own report.
    pub fn move(d: Device, dx: i32, dy: i32) void {
        if (dx != 0) d.emit(evdev.EV_REL, evdev.REL_X, dx);
        if (dy != 0) d.emit(evdev.EV_REL, evdev.REL_Y, dy);
        d.syn();
    }

    pub fn destroy(d: Device) void {
        _ = linux.ioctl(d.fd, ui_dev_destroy, 0);
        _ = linux.close(d.fd);
    }
};

/// The Linux KEY_* code for a HID usage (the inverse of `evdev.hidUsage`), 0 if none.
pub fn keyCode(usage: u16) u16 {
    var k: u16 = 1;
    while (k < 256) : (k += 1) if (evdev.hidUsage(k) == usage) return k;
    return 0;
}

pub fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

test "keyCode inverts hidUsage for the letters" {
    for (0..26) |i| {
        const usage: u16 = @intCast(4 + i);
        try std.testing.expectEqual(usage, evdev.hidUsage(keyCode(usage)));
    }
}
