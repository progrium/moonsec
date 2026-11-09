//! Linux input plumbing shared by the host and the client ("linux_uinput"): event codes
//! from input-event-codes.h, the KEY_* <-> USB HID usage table, and virtual devices
//! through /dev/uinput.
//!
//! The host injects into these devices (platform/host/linux); the client's tests type on
//! them so its evdev source is exercised from the kernel up (platform/client/linux).
//! Creating a device needs write access to /dev/uinput: see platform/host/linux/README.md
//! for the udev rule.
const std = @import("std");
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// input-event-codes.h

pub const EV_SYN = 0x00;
pub const EV_KEY = 0x01;
pub const EV_REL = 0x02;
pub const EV_ABS = 0x03;
pub const EV_MSC = 0x04;
pub const SYN_REPORT = 0;
pub const SYN_DROPPED = 3;

pub const REL_X = 0x00;
pub const REL_Y = 0x01;
pub const REL_HWHEEL = 0x06;
pub const REL_WHEEL = 0x08;
pub const REL_WHEEL_HI_RES = 0x0b;
pub const REL_HWHEEL_HI_RES = 0x0c;
pub const REL_MAX = 0x0f;

pub const ABS_X = 0x00;
pub const ABS_Y = 0x01;
pub const ABS_Z = 0x02;
pub const ABS_RX = 0x03;
pub const ABS_RY = 0x04;
pub const ABS_RZ = 0x05;
pub const ABS_HAT0X = 0x10;
pub const ABS_HAT0Y = 0x11;

pub const INPUT_PROP_POINTER = 0x00;
pub const INPUT_PROP_DIRECT = 0x01;

pub const KEY_A = 30;
pub const KEY_SPACE = 57;
pub const KEY_MAX = 0x2ff;

pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_MIDDLE = 0x112;
pub const BTN_SIDE = 0x113;
pub const BTN_EXTRA = 0x114;
pub const BTN_FORWARD = 0x115;
pub const BTN_BACK = 0x116;
pub const BTN_TASK = 0x117;

pub const BTN_SOUTH = 0x130;
pub const BTN_EAST = 0x131;
pub const BTN_NORTH = 0x133;
pub const BTN_WEST = 0x134;
pub const BTN_TL = 0x136;
pub const BTN_TR = 0x137;
pub const BTN_SELECT = 0x13a;
pub const BTN_START = 0x13b;
pub const BTN_MODE = 0x13c;
pub const BTN_THUMBL = 0x13d;
pub const BTN_THUMBR = 0x13e;

pub const BUS_USB = 0x03;
pub const BUS_VIRTUAL = 0x06;

/// `struct input_event` on 64-bit Linux.
pub const Event = extern struct {
    sec: isize = 0,
    usec: isize = 0,
    type: u16,
    code: u16,
    value: i32,
};

// ---------------------------------------------------------------------------
// Keys

/// Linux KEY_* code to USB HID keyboard usage (page 7); 0 when there is none.
pub fn hidUsage(code: u16) u16 {
    if (code < key_table.len) return key_table[code];
    if (code >= 183 and code <= 194) return 0x68 + (code - 183); // F13..F24
    return 0;
}

/// USB HID keyboard usage to Linux KEY_* code (the inverse of `hidUsage`); 0 when none.
pub fn keyCode(usage: u16) u16 {
    return if (usage < hid_table.len) hid_table[usage] else 0;
}

const key_table = blk: {
    var t = [_]u16{0} ** 128;
    const pairs = [_][2]u16{
        .{ 1, 0x29 }, // ESC
        .{ 2, 0x1E }, .{ 3, 0x1F }, .{ 4, 0x20 }, .{ 5, 0x21 }, .{ 6, 0x22 }, .{ 7, 0x23 }, .{ 8, 0x24 }, .{ 9, 0x25 }, .{ 10, 0x26 }, .{ 11, 0x27 }, // 1..0
        .{ 12, 0x2D }, .{ 13, 0x2E }, .{ 14, 0x2A }, .{ 15, 0x2B }, // - = BACKSPACE TAB
        .{ 16, 0x14 }, .{ 17, 0x1A }, .{ 18, 0x08 }, .{ 19, 0x15 }, .{ 20, 0x17 }, .{ 21, 0x1C }, .{ 22, 0x18 }, .{ 23, 0x0C }, .{ 24, 0x12 }, .{ 25, 0x13 }, // Q..P
        .{ 26, 0x2F }, .{ 27, 0x30 }, .{ 28, 0x28 }, .{ 29, 0xE0 }, // [ ] ENTER LCTRL
        .{ 30, 0x04 }, .{ 31, 0x16 }, .{ 32, 0x07 }, .{ 33, 0x09 }, .{ 34, 0x0A }, .{ 35, 0x0B }, .{ 36, 0x0D }, .{ 37, 0x0E }, .{ 38, 0x0F }, // A..L
        .{ 39, 0x33 }, .{ 40, 0x34 }, .{ 41, 0x35 }, .{ 42, 0xE1 }, .{ 43, 0x31 }, // ; ' ` LSHIFT backslash
        .{ 44, 0x1D }, .{ 45, 0x1B }, .{ 46, 0x06 }, .{ 47, 0x19 }, .{ 48, 0x05 }, .{ 49, 0x11 }, .{ 50, 0x10 }, // Z..M
        .{ 51, 0x36 }, .{ 52, 0x37 }, .{ 53, 0x38 }, .{ 54, 0xE5 }, .{ 55, 0x55 }, .{ 56, 0xE2 }, .{ 57, 0x2C }, .{ 58, 0x39 }, // , . / RSHIFT KP* LALT SPACE CAPS
        .{ 59, 0x3A }, .{ 60, 0x3B }, .{ 61, 0x3C }, .{ 62, 0x3D }, .{ 63, 0x3E }, .{ 64, 0x3F }, .{ 65, 0x40 }, .{ 66, 0x41 }, .{ 67, 0x42 }, .{ 68, 0x43 }, // F1..F10
        .{ 69, 0x53 }, .{ 70, 0x47 }, // NUMLOCK SCROLLLOCK
        .{ 71, 0x5F }, .{ 72, 0x60 }, .{ 73, 0x61 }, .{ 74, 0x56 }, .{ 75, 0x5C }, .{ 76, 0x5D }, .{ 77, 0x5E }, .{ 78, 0x57 }, // KP7 KP8 KP9 KP- KP4 KP5 KP6 KP+
        .{ 79, 0x59 }, .{ 80, 0x5A }, .{ 81, 0x5B }, .{ 82, 0x62 }, .{ 83, 0x63 }, // KP1 KP2 KP3 KP0 KP.
        .{ 85, 0x94 }, .{ 86, 0x64 }, .{ 87, 0x44 }, .{ 88, 0x45 }, // ZENKAKUHANKAKU 102ND F11 F12
        .{ 89, 0x87 }, .{ 90, 0x92 }, .{ 91, 0x93 }, .{ 92, 0x8A }, .{ 93, 0x88 }, .{ 94, 0x8B }, .{ 95, 0x8C }, // RO KATAKANA HIRAGANA HENKAN KATAKANAHIRAGANA MUHENKAN KPJPCOMMA
        .{ 96, 0x58 }, .{ 97, 0xE4 }, .{ 98, 0x54 }, .{ 99, 0x46 }, .{ 100, 0xE6 }, // KPENTER RCTRL KP/ SYSRQ RALT
        .{ 102, 0x4A }, .{ 103, 0x52 }, .{ 104, 0x4B }, .{ 105, 0x50 }, .{ 106, 0x4F }, .{ 107, 0x4D }, .{ 108, 0x51 }, .{ 109, 0x4E }, .{ 110, 0x49 }, .{ 111, 0x4C }, // HOME UP PGUP LEFT RIGHT END DOWN PGDN INS DEL
        .{ 113, 0x7F }, .{ 114, 0x81 }, .{ 115, 0x80 }, .{ 116, 0x66 }, .{ 117, 0x67 }, .{ 119, 0x48 }, // MUTE VOL- VOL+ POWER KP= PAUSE
        .{ 121, 0x85 }, .{ 122, 0x90 }, .{ 123, 0x91 }, .{ 124, 0x89 }, .{ 125, 0xE3 }, .{ 126, 0xE7 }, .{ 127, 0x65 }, // KPCOMMA HANGEUL HANJA YEN LMETA RMETA COMPOSE
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

const hid_table = blk: {
    @setEvalBranchQuota(10_000);
    var t = [_]u16{0} ** 256;
    var k: u16 = 1;
    while (k < 256) : (k += 1) {
        const u = hidUsage(k);
        if (u != 0 and t[u] == 0) t[u] = k;
    }
    break :blk t;
};

/// Highest KEY_* code `keyCode` returns, so a keyboard device can declare them all.
pub const max_keyboard_key = 248;

// ---------------------------------------------------------------------------
// uinput.h

fn ioc(dir: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, 'U') << 8) | nr;
}
const ui_dev_create = ioc(0, 1, 0);
const ui_dev_destroy = ioc(0, 2, 0);
const ui_dev_setup = ioc(1, 3, @sizeOf(Setup));
const ui_abs_setup = ioc(1, 4, @sizeOf(AbsSetup));
const ui_set_evbit = ioc(1, 100, @sizeOf(c_int));
const ui_set_keybit = ioc(1, 101, @sizeOf(c_int));
const ui_set_relbit = ioc(1, 102, @sizeOf(c_int));
const ui_set_absbit = ioc(1, 103, @sizeOf(c_int));
const ui_set_propbit = ioc(1, 110, @sizeOf(c_int));
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

const AbsInfo = extern struct {
    value: i32 = 0,
    minimum: i32,
    maximum: i32,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32 = 0,
};

const AbsSetup = extern struct {
    code: u16,
    absinfo: AbsInfo,
};

comptime {
    std.debug.assert(@sizeOf(Setup) == 92);
    std.debug.assert(@sizeOf(AbsSetup) == 28);
    std.debug.assert(@sizeOf(Event) == 24);
}

pub const Error = error{
    /// No /dev/uinput: the uinput module is not loaded (`modprobe uinput`), or this is a
    /// container without it.
    NoUinput,
    /// /dev/uinput exists but this user may not write it (see the udev rule).
    AccessDenied,
    SetupFailed,
    /// The device was created but its /dev/input/eventN did not appear or open in time.
    NoEventNode,
};

/// One absolute axis of a device.
pub const Axis = struct {
    code: u16,
    min: i32,
    max: i32,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32 = 0,
};

/// Vendor id of every moonsec device (the bytes "ms").
pub const vendor_moonsec = 0x6d73;
/// Products 0x0100..0x01ff are the host's injection devices (platform/host/linux).
/// A client on the same machine must not read them back, or its input would echo.
pub fn isHostDevice(vendor: u16, product: u16) bool {
    return vendor == vendor_moonsec and product & 0xff00 == 0x0100;
}

/// What a device reports. Codes not listed here are dropped by the kernel when written.
pub const Spec = struct {
    name: []const u8,
    bustype: u16 = BUS_VIRTUAL,
    vendor: u16 = vendor_moonsec,
    product: u16 = 0x0001,
    version: u16 = 1,
    /// KEY_* codes 1..`key_range` (a keyboard), then `keys`.
    key_range: u16 = 0,
    keys: []const u16 = &.{},
    rels: []const u16 = &.{},
    abs: []const Axis = &.{},
    props: []const u16 = &.{},
    /// Wait up to 3 s for /dev/input/eventN to be openable for reading (udev may still be
    /// setting its permissions): for tests that read the device back.
    wait_readable: bool = false,
};

pub const Device = struct {
    fd: i32,
    /// /dev/input/eventN of the device, when it was found.
    node: ?u8 = null,

    pub fn create(spec: Spec) Error!Device {
        const rc = linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .ACCES, .PERM, .ROFS => return error.AccessDenied,
            else => return error.NoUinput,
        }
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        if (spec.key_range > 0 or spec.keys.len > 0) try set(fd, ui_set_evbit, EV_KEY);
        if (spec.rels.len > 0) try set(fd, ui_set_evbit, EV_REL);
        if (spec.abs.len > 0) try set(fd, ui_set_evbit, EV_ABS);
        var k: u16 = 1;
        while (k <= spec.key_range) : (k += 1) try set(fd, ui_set_keybit, k);
        for (spec.keys) |c| try set(fd, ui_set_keybit, c);
        for (spec.rels) |c| try set(fd, ui_set_relbit, c);
        for (spec.props) |c| try set(fd, ui_set_propbit, c);
        for (spec.abs) |a| {
            try set(fd, ui_set_absbit, a.code);
            const s: AbsSetup = .{ .code = a.code, .absinfo = .{ .minimum = a.min, .maximum = a.max, .fuzz = a.fuzz, .flat = a.flat, .resolution = a.resolution } };
            if (linux.errno(linux.ioctl(fd, ui_abs_setup, @intFromPtr(&s))) != .SUCCESS) return error.SetupFailed;
        }
        var s: Setup = std.mem.zeroes(Setup);
        s.bustype = spec.bustype;
        s.vendor = spec.vendor;
        s.product = spec.product;
        s.version = spec.version;
        const n = @min(spec.name.len, s.name.len - 1);
        @memcpy(s.name[0..n], spec.name[0..n]);
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
                if (!spec.wait_readable) return .{ .fd = fd, .node = node };
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
        if (!spec.wait_readable) return .{ .fd = fd };
        return error.NoEventNode;
    }

    fn set(fd: i32, req: u32, v: u16) Error!void {
        if (linux.errno(linux.ioctl(fd, req, v)) != .SUCCESS) return error.SetupFailed;
    }

    fn findEventNode(sysname: []const u8) ?u8 {
        var node: u8 = 0;
        while (node < max_nodes) : (node += 1) {
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

    /// Writes `events` in one call (the kernel takes a batch). False when the write failed
    /// or was short.
    pub fn write(d: Device, events: []const Event) bool {
        if (events.len == 0) return true;
        const bytes = std.mem.sliceAsBytes(events);
        const rc = linux.write(d.fd, bytes.ptr, bytes.len);
        return linux.errno(rc) == .SUCCESS and rc == bytes.len;
    }

    /// A key (KEY_* code) press or release, as its own report.
    pub fn key(d: Device, code: u16, down: bool) void {
        _ = d.write(&.{ .{ .type = EV_KEY, .code = code, .value = @intFromBool(down) }, syn });
    }

    /// Relative motion, as its own report.
    pub fn move(d: Device, dx: i32, dy: i32) void {
        _ = d.write(&.{ .{ .type = EV_REL, .code = REL_X, .value = dx }, .{ .type = EV_REL, .code = REL_Y, .value = dy }, syn });
    }

    pub fn destroy(d: Device) void {
        _ = linux.ioctl(d.fd, ui_dev_destroy, 0);
        _ = linux.close(d.fd);
    }
};

/// Reads a device's events back from /dev/input/eventN (tests and the end-to-end check
/// read what was injected, as the compositor would).
pub const Reader = struct {
    fd: i32,

    /// Opens the node, retrying for up to `wait_ms` while udev sets its permissions.
    pub fn open(node: u8, wait_ms: u32) ?Reader {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{node}) catch unreachable;
        var waited: u32 = 0;
        while (true) : (waited += 10) {
            const r = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
            if (linux.errno(r) == .SUCCESS) return .{ .fd = @intCast(r) };
            if (waited >= wait_ms) return null;
            sleepMs(10);
        }
    }

    /// Events available now (none when there are none); never blocks.
    pub fn read(r: Reader, out: []Event) []Event {
        const bytes = std.mem.sliceAsBytes(out);
        const rc = linux.read(r.fd, bytes.ptr, bytes.len);
        if (linux.errno(rc) != .SUCCESS) return out[0..0];
        return out[0 .. rc / @sizeOf(Event)];
    }

    pub fn close(r: Reader) void {
        _ = linux.close(r.fd);
    }
};

pub const syn: Event = .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 };

/// Event nodes searched (/dev/input/event0..63).
pub const max_nodes = 64;

pub fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

test "keyCode inverts hidUsage" {
    for (0..26) |i| {
        const usage: u16 = @intCast(4 + i);
        try std.testing.expectEqual(usage, hidUsage(keyCode(usage)));
    }
    var k: u16 = 1;
    while (k < 256) : (k += 1) {
        const u = hidUsage(k);
        if (u != 0) try std.testing.expectEqual(u, hidUsage(keyCode(u)));
        try std.testing.expect(keyCode(u) <= max_keyboard_key);
    }
    try std.testing.expectEqual(@as(u16, KEY_A), keyCode(0x04));
    try std.testing.expectEqual(@as(u16, 194), keyCode(0x73)); // F24
    try std.testing.expectEqual(@as(u16, 0), keyCode(0));
    try std.testing.expectEqual(@as(u16, 0), keyCode(0x300));
}

test "the host's devices are told apart from other moonsec devices" {
    try std.testing.expect(isHostDevice(vendor_moonsec, 0x0101));
    try std.testing.expect(isHostDevice(vendor_moonsec, 0x01ff));
    try std.testing.expect(!isHostDevice(vendor_moonsec, 0x0001)); // the client's test typist
    try std.testing.expect(!isHostDevice(0x045e, 0x0101));
}
