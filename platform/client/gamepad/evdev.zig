//! Linux gamepads through evdev (/dev/input/event*).
//!
//! A device counts as a gamepad when it has a gamepad button (BTN_SOUTH, the
//! first of the BTN_GAMEPAD range) and at least one absolute axis. That takes
//! in xpad, hid-playstation, hid-nintendo and the like, and leaves out the
//! separate motion-sensor and touchpad nodes those drivers also create.
//!
//! Codes follow the kernel's gamepad spec (Documentation/input/gamepad.rst):
//! BTN_SOUTH/EAST/NORTH/WEST are the face buttons by position; sticks are
//! ABS_X/Y and ABS_RX/RY; analog triggers ABS_Z/RZ (or ABS_BRAKE/GAS, or
//! ABS_HAT2Y/HAT2X); the d-pad is ABS_HAT0X/Y or BTN_DPAD_*. Where a pad has
//! only digital triggers (BTN_TL2/TR2) they read as fully pressed.
//! xpad reports X and Y as BTN_X/BTN_Y, which are BTN_NORTH/BTN_WEST by
//! number; Microsoft pads (vendor 0x045e) get those two swapped back.
//!
//! The source watches /dev/input with inotify, so pads plugged in later show
//! up (IN_ATTRIB catches udev applying permissions after the node appears).
//! Event times come from the kernel on CLOCK_MONOTONIC (EVIOCSCLOCKID), the
//! platform clock. A SYN_DROPPED resyncs the whole state with EVIOCGKEY and
//! EVIOCGABS.
//!
//! Desktop sessions get read access to gamepads through udev's uaccess tag.
//!
//! The mapping (`Mapper`) builds and is tested on every OS; `Source` needs Linux.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("platform");
const pads = @import("pads.zig");

const Gamepad = pads.Gamepad;
const B = pads.Button;

// ---------------------------------------------------------------------------
// Codes (linux/input-event-codes.h)

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_ABS: u16 = 0x03;
pub const SYN_REPORT: u16 = 0;
pub const SYN_DROPPED: u16 = 3;

pub const BTN_SOUTH: u16 = 0x130;
pub const BTN_EAST: u16 = 0x131;
pub const BTN_C: u16 = 0x132;
pub const BTN_NORTH: u16 = 0x133;
pub const BTN_WEST: u16 = 0x134;
pub const BTN_Z: u16 = 0x135;
pub const BTN_TL: u16 = 0x136;
pub const BTN_TR: u16 = 0x137;
pub const BTN_TL2: u16 = 0x138;
pub const BTN_TR2: u16 = 0x139;
pub const BTN_SELECT: u16 = 0x13a;
pub const BTN_START: u16 = 0x13b;
pub const BTN_MODE: u16 = 0x13c;
pub const BTN_THUMBL: u16 = 0x13d;
pub const BTN_THUMBR: u16 = 0x13e;
pub const BTN_DPAD_UP: u16 = 0x220;
pub const BTN_DPAD_DOWN: u16 = 0x221;
pub const BTN_DPAD_LEFT: u16 = 0x222;
pub const BTN_DPAD_RIGHT: u16 = 0x223;
pub const KEY_MAX: u16 = 0x2ff;

pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_Z: u16 = 0x02;
pub const ABS_RX: u16 = 0x03;
pub const ABS_RY: u16 = 0x04;
pub const ABS_RZ: u16 = 0x05;
pub const ABS_GAS: u16 = 0x09;
pub const ABS_BRAKE: u16 = 0x0a;
pub const ABS_HAT0X: u16 = 0x10;
pub const ABS_HAT0Y: u16 = 0x11;
pub const ABS_HAT2X: u16 = 0x14;
pub const ABS_HAT2Y: u16 = 0x15;
pub const ABS_MAX: u16 = 0x3f;

pub const vendor_microsoft: u16 = 0x045e;

/// struct input_absinfo.
pub const AbsInfo = extern struct {
    value: i32 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32 = 0,
};

/// struct input_id.
pub const InputId = extern struct {
    bustype: u16 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    version: u16 = 0,
};

/// struct input_event on 64-bit Linux (time is a struct timeval).
pub const RawEvent = extern struct {
    sec: isize = 0,
    usec: isize = 0,
    type: u16,
    code: u16,
    value: i32,
};

// ---------------------------------------------------------------------------
// Mapping

/// Which analog axis feeds each part of the pad, chosen from the device's
/// capabilities, and the ranges they report.
pub const Mapper = struct {
    abs: [ABS_MAX + 1]AbsInfo = .{AbsInfo{}} ** (ABS_MAX + 1),
    has_abs: std.StaticBitSet(ABS_MAX + 1) = .initEmpty(),
    lt_axis: ?u16 = null,
    rt_axis: ?u16 = null,
    swap_xy: bool = false,

    /// Current values; `snapshot` turns them into a Gamepad.
    buttons: u32 = 0,
    /// Buttons held from BTN_DPAD_*, kept apart from the hat so either can
    /// release without clearing the other.
    dpad_buttons: u32 = 0,
    digital_lt: bool = false,
    digital_rt: bool = false,

    /// Set up from the device's absolute axes (index = ABS code) and id.
    pub fn init(abs_bits: std.StaticBitSet(ABS_MAX + 1), infos: *const [ABS_MAX + 1]AbsInfo, id: InputId) Mapper {
        var m: Mapper = .{ .has_abs = abs_bits, .abs = infos.*, .swap_xy = id.vendor == vendor_microsoft };
        const pairs = [_][2]u16{ .{ ABS_Z, ABS_RZ }, .{ ABS_BRAKE, ABS_GAS }, .{ ABS_HAT2Y, ABS_HAT2X } };
        for (pairs) |p| {
            if (m.lt_axis == null and abs_bits.isSet(p[0])) m.lt_axis = p[0];
            if (m.rt_axis == null and abs_bits.isSet(p[1])) m.rt_axis = p[1];
        }
        return m;
    }

    /// The `Gamepad.Button` bit for a key code, or null for keys we ignore.
    pub fn buttonBit(m: *const Mapper, code: u16) ?u32 {
        return switch (code) {
            BTN_SOUTH => B.a,
            BTN_EAST => B.b,
            BTN_NORTH => if (m.swap_xy) B.x else B.y,
            BTN_WEST => if (m.swap_xy) B.y else B.x,
            BTN_TL => B.left_shoulder,
            BTN_TR => B.right_shoulder,
            BTN_SELECT => B.back,
            BTN_START => B.start,
            BTN_MODE => B.guide,
            BTN_THUMBL => B.left_thumb,
            BTN_THUMBR => B.right_thumb,
            BTN_DPAD_UP => B.dpad_up,
            BTN_DPAD_DOWN => B.dpad_down,
            BTN_DPAD_LEFT => B.dpad_left,
            BTN_DPAD_RIGHT => B.dpad_right,
            else => null,
        };
    }

    pub fn key(m: *Mapper, code: u16, down: bool) void {
        switch (code) {
            BTN_TL2 => m.digital_lt = down,
            BTN_TR2 => m.digital_rt = down,
            BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT => {
                const bit = m.buttonBit(code).?;
                if (down) m.dpad_buttons |= bit else m.dpad_buttons &= ~bit;
            },
            else => {
                const bit = m.buttonBit(code) orelse return;
                if (down) m.buttons |= bit else m.buttons &= ~bit;
            },
        }
    }

    pub fn axis(m: *Mapper, code: u16, value: i32) void {
        if (code > ABS_MAX) return;
        m.abs[code].value = value;
    }

    fn stickOf(m: *const Mapper, code: u16, invert: bool) i16 {
        if (!m.has_abs.isSet(code)) return 0;
        const a = m.abs[code];
        return pads.stick(a.value, a.minimum, a.maximum, invert);
    }

    fn triggerOf(m: *const Mapper, code: ?u16, digital: bool) u16 {
        // With an analog axis, the digital BTN_TL2/TR2 some drivers also send
        // (hid-playstation, past a threshold) is ignored.
        if (code) |c| return pads.trigger(m.abs[c].value, m.abs[c].minimum, m.abs[c].maximum);
        return if (digital) 65535 else 0;
    }

    fn hatBits(m: *const Mapper) u32 {
        var bits: u32 = 0;
        if (m.has_abs.isSet(ABS_HAT0X)) {
            const x = m.abs[ABS_HAT0X].value;
            if (x < 0) bits |= B.dpad_left;
            if (x > 0) bits |= B.dpad_right;
        }
        if (m.has_abs.isSet(ABS_HAT0Y)) {
            const y = m.abs[ABS_HAT0Y].value;
            if (y < 0) bits |= B.dpad_up;
            if (y > 0) bits |= B.dpad_down;
        }
        return bits;
    }

    pub fn snapshot(m: *const Mapper) Gamepad {
        return .{
            .buttons = m.buttons | m.dpad_buttons | m.hatBits(),
            .lx = m.stickOf(ABS_X, false),
            .ly = m.stickOf(ABS_Y, true),
            .rx = m.stickOf(ABS_RX, false),
            .ry = m.stickOf(ABS_RY, true),
            .lt = m.triggerOf(m.lt_axis, m.digital_lt),
            .rt = m.triggerOf(m.rt_axis, m.digital_rt),
        };
    }
};

// ---------------------------------------------------------------------------
// ioctls (linux/input.h)

fn ioc(dir: u32, typ: u8, nr: u8, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, typ) << 8) | nr;
}
const ioc_write: u32 = 1;
const ioc_read: u32 = 2;

pub fn EVIOCGID() u32 {
    return ioc(ioc_read, 'E', 0x02, @sizeOf(InputId));
}
pub fn EVIOCGNAME(len: u32) u32 {
    return ioc(ioc_read, 'E', 0x06, len);
}
pub fn EVIOCGKEY(len: u32) u32 {
    return ioc(ioc_read, 'E', 0x18, len);
}
pub fn EVIOCGBIT(ev: u8, len: u32) u32 {
    return ioc(ioc_read, 'E', 0x20 + ev, len);
}
pub fn EVIOCGABS(abs: u8) u32 {
    return ioc(ioc_read, 'E', 0x40 + abs, @sizeOf(AbsInfo));
}
pub fn EVIOCSCLOCKID() u32 {
    return ioc(ioc_write, 'E', 0xa0, @sizeOf(c_int));
}

fn bitSet(bytes: []const u8, bit: usize) bool {
    return bit / 8 < bytes.len and (bytes[bit / 8] >> @intCast(bit % 8)) & 1 != 0;
}

// ---------------------------------------------------------------------------
// Source

pub const Options = struct {
    /// Directory to watch; tests may point it elsewhere.
    dir: [:0]const u8 = "/dev/input",
    /// Only take devices whose name contains this (tests use it to see only
    /// their virtual pad).
    name_filter: ?[]const u8 = null,
};

pub const max_devices = 8;

pub const Source = if (builtin.os.tag == .linux) LinuxSource else struct {
    pub fn open(_: api.Clock, _: Options) api.Error!@This() {
        return error.Unsupported;
    }
    pub fn poll(_: *@This(), _: []api.InputEvent) api.Error!usize {
        return 0;
    }
    pub fn close(_: *@This()) void {}
};

const LinuxSource = struct {
    const linux = std.os.linux;

    clock: api.Clock,
    opts: Options,
    inotify: i32 = -1,
    devices: [max_devices]?Device = .{null} ** max_devices,
    slots: pads.Slots = .{},
    next_id: u64 = 1,
    /// Rescan before the next read (startup, inotify said something changed,
    /// or there is no inotify and the rescan interval passed).
    rescan_due: bool = true,
    next_rescan: api.Micros = 0,

    /// Rescan interval when inotify is unavailable.
    const rescan_us: api.Micros = 1_000_000;

    const Device = struct {
        fd: i32,
        id: u64,
        /// "eventN", to skip nodes already open on a rescan.
        node: [16]u8,
        node_len: u8,
        mapper: Mapper,
        /// The state changed since the last SYN_REPORT.
        dirty: bool = false,
        /// Dropping events until the next SYN_REPORT after a SYN_DROPPED.
        dropping: bool = false,

        fn nodeName(d: *const Device) []const u8 {
            return d.node[0..d.node_len];
        }
    };

    pub fn open(clock: api.Clock, opts: Options) api.Error!LinuxSource {
        var s: LinuxSource = .{ .clock = clock, .opts = opts };
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) == .SUCCESS) {
            const fd: i32 = @intCast(rc);
            const w = linux.inotify_add_watch(fd, opts.dir, linux.IN.CREATE | linux.IN.ATTRIB | linux.IN.MOVED_TO);
            if (linux.errno(w) == .SUCCESS) s.inotify = fd else _ = linux.close(fd);
        }
        return s;
    }

    pub fn close(s: *LinuxSource) void {
        const now = s.clock.now();
        for (&s.devices) |*slot| if (slot.*) |*d| {
            _ = linux.close(d.fd);
            s.slots.update(d.id, null, now);
            slot.* = null;
        };
        if (s.inotify >= 0) _ = linux.close(s.inotify);
        s.inotify = -1;
    }

    pub fn deviceCount(s: *const LinuxSource) usize {
        var n: usize = 0;
        for (s.devices) |d| n += @intFromBool(d != null);
        return n;
    }

    pub fn poll(s: *LinuxSource, out: []api.InputEvent) api.Error!usize {
        s.checkHotplug();
        for (&s.devices) |*slot| {
            if (slot.*) |*d| {
                if (!s.readDevice(d)) {
                    _ = linux.close(d.fd);
                    s.slots.update(d.id, null, s.clock.now());
                    slot.* = null;
                }
            }
        }
        return s.slots.drain(out);
    }

    fn checkHotplug(s: *LinuxSource) void {
        if (s.inotify >= 0) {
            var buf: [1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
            while (true) {
                const rc = linux.read(s.inotify, &buf, buf.len);
                if (linux.errno(rc) != .SUCCESS or rc == 0) break;
                s.rescan_due = true;
            }
        } else if (s.clock.now() >= s.next_rescan) {
            s.rescan_due = true;
        }
        if (!s.rescan_due) return;
        s.rescan_due = false;
        s.next_rescan = s.clock.now() + rescan_us;
        s.scan();
    }

    fn scan(s: *LinuxSource) void {
        const dfd_rc = linux.open(s.opts.dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(dfd_rc) != .SUCCESS) return;
        const dfd: i32 = @intCast(dfd_rc);
        defer _ = linux.close(dfd);
        var buf: [4096]u8 align(8) = undefined;
        while (true) {
            const n = linux.getdents64(dfd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var off: usize = 0;
            while (off < n) {
                const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], builtin.cpu.arch.endian());
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + 19])), 0);
                off += reclen;
                if (!std.mem.startsWith(u8, name, "event") or name.len >= 16) continue;
                if (s.isOpen(name)) continue;
                s.tryOpen(dfd, name);
            }
        }
    }

    fn isOpen(s: *const LinuxSource, node: []const u8) bool {
        for (&s.devices) |*slot| if (slot.*) |*d| {
            if (std.mem.eql(u8, d.nodeName(), node)) return true;
        };
        return false;
    }

    fn tryOpen(s: *LinuxSource, dfd: i32, name: []const u8) void {
        const free = for (s.devices, 0..) |d, i| {
            if (d == null) break i;
        } else return;
        var z: [16:0]u8 = .{0} ** 16;
        @memcpy(z[0..name.len], name);
        const rc = linux.openat(dfd, &z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        const fd: i32 = @intCast(rc);
        const mapper = probe(fd, s.opts.name_filter) orelse {
            _ = linux.close(fd);
            return;
        };
        var d: Device = .{ .fd = fd, .id = s.next_id, .node = undefined, .node_len = @intCast(name.len), .mapper = mapper };
        @memcpy(d.node[0..name.len], name);
        s.next_id += 1;
        s.devices[free] = d;
        s.slots.update(d.id, d.mapper.snapshot(), s.clock.now());
    }

    /// Checks that `fd` is a gamepad (and passes the name filter), switches it
    /// to monotonic timestamps and reads its current state.
    fn probe(fd: i32, name_filter: ?[]const u8) ?Mapper {
        var ev_bits: [4]u8 = .{0} ** 4;
        if (linux.errno(linux.ioctl(fd, EVIOCGBIT(0, ev_bits.len), @intFromPtr(&ev_bits))) != .SUCCESS) return null;
        if (!bitSet(&ev_bits, EV_KEY) or !bitSet(&ev_bits, EV_ABS)) return null;
        var key_bits: [(KEY_MAX + 1) / 8]u8 = .{0} ** ((KEY_MAX + 1) / 8);
        if (linux.errno(linux.ioctl(fd, EVIOCGBIT(EV_KEY, key_bits.len), @intFromPtr(&key_bits))) != .SUCCESS) return null;
        if (!bitSet(&key_bits, BTN_SOUTH)) return null;
        var abs_bytes: [(ABS_MAX + 1) / 8]u8 = .{0} ** ((ABS_MAX + 1) / 8);
        if (linux.errno(linux.ioctl(fd, EVIOCGBIT(EV_ABS, abs_bytes.len), @intFromPtr(&abs_bytes))) != .SUCCESS) return null;

        if (name_filter) |f| {
            var name: [256]u8 = .{0} ** 256;
            const rc = linux.ioctl(fd, EVIOCGNAME(name.len), @intFromPtr(&name));
            if (linux.errno(rc) != .SUCCESS) return null;
            if (std.mem.indexOf(u8, std.mem.sliceTo(&name, 0), f) == null) return null;
        }

        var id: InputId = .{};
        _ = linux.ioctl(fd, EVIOCGID(), @intFromPtr(&id));

        var abs_bits: std.StaticBitSet(ABS_MAX + 1) = .initEmpty();
        var infos: [ABS_MAX + 1]AbsInfo = .{AbsInfo{}} ** (ABS_MAX + 1);
        for (0..ABS_MAX + 1) |a| {
            if (!bitSet(&abs_bytes, a)) continue;
            if (linux.errno(linux.ioctl(fd, EVIOCGABS(@intCast(a)), @intFromPtr(&infos[a]))) != .SUCCESS) continue;
            abs_bits.set(a);
        }
        if (abs_bits.count() == 0) return null;

        var clk: c_int = @intFromEnum(linux.CLOCK.MONOTONIC);
        _ = linux.ioctl(fd, EVIOCSCLOCKID(), @intFromPtr(&clk));

        var m = Mapper.init(abs_bits, &infos, id);
        syncKeys(fd, &m);
        return m;
    }

    /// Reads every key's current state into the mapper (open, SYN_DROPPED).
    fn syncKeys(fd: i32, m: *Mapper) void {
        var keys: [(KEY_MAX + 1) / 8]u8 = .{0} ** ((KEY_MAX + 1) / 8);
        if (linux.errno(linux.ioctl(fd, EVIOCGKEY(keys.len), @intFromPtr(&keys))) != .SUCCESS) return;
        const codes = [_]u16{
            BTN_SOUTH,      BTN_EAST,  BTN_NORTH, BTN_WEST,   BTN_TL,     BTN_TR,      BTN_TL2,       BTN_TR2,
            BTN_SELECT,     BTN_START, BTN_MODE,  BTN_THUMBL, BTN_THUMBR, BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT,
            BTN_DPAD_RIGHT,
        };
        for (codes) |c| m.key(c, bitSet(&keys, c));
    }

    fn resync(d: *Device) void {
        syncKeys(d.fd, &d.mapper);
        var it = d.mapper.has_abs.iterator(.{});
        while (it.next()) |a| {
            var info: AbsInfo = .{};
            if (linux.errno(linux.ioctl(d.fd, EVIOCGABS(@intCast(a)), @intFromPtr(&info))) == .SUCCESS)
                d.mapper.abs[a].value = info.value;
        }
    }

    /// Reads everything pending on the device. False when it is gone.
    fn readDevice(s: *LinuxSource, d: *Device) bool {
        var evs: [64]RawEvent = undefined;
        while (true) {
            const rc = linux.read(d.fd, @ptrCast(&evs), @sizeOf(@TypeOf(evs)));
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return true,
                .INTR => continue,
                else => return false, // ENODEV: unplugged
            }
            if (rc == 0) return false;
            const n = rc / @sizeOf(RawEvent);
            for (evs[0..n]) |e| s.apply(d, e);
            if (n < evs.len) return true;
        }
    }

    fn apply(s: *LinuxSource, d: *Device, e: RawEvent) void {
        switch (e.type) {
            EV_SYN => switch (e.code) {
                SYN_REPORT => {
                    if (d.dropping) {
                        d.dropping = false;
                        resync(d);
                        d.dirty = true;
                    }
                    if (d.dirty) {
                        d.dirty = false;
                        const t: api.Micros = @as(api.Micros, e.sec) * std.time.us_per_s + e.usec;
                        s.slots.update(d.id, d.mapper.snapshot(), t);
                    }
                },
                SYN_DROPPED => d.dropping = true,
                else => {},
            },
            EV_KEY => if (!d.dropping) {
                d.mapper.key(e.code, e.value != 0);
                d.dirty = true;
            },
            EV_ABS => if (!d.dropping) {
                d.mapper.axis(e.code, e.value);
                d.dirty = true;
            },
            else => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testMapper(axes: []const u16, vendor: u16) Mapper {
    var bits: std.StaticBitSet(ABS_MAX + 1) = .initEmpty();
    var infos: [ABS_MAX + 1]AbsInfo = .{AbsInfo{}} ** (ABS_MAX + 1);
    for (axes) |a| {
        bits.set(a);
        infos[a] = switch (a) {
            ABS_HAT0X, ABS_HAT0Y => .{ .minimum = -1, .maximum = 1 },
            ABS_Z, ABS_RZ => .{ .minimum = 0, .maximum = 1023 },
            ABS_BRAKE, ABS_GAS => .{ .minimum = 0, .maximum = 255 },
            else => .{ .minimum = -32768, .maximum = 32767 },
        };
    }
    return Mapper.init(bits, &infos, .{ .vendor = vendor });
}

test "evdev: Xbox-style pad (xpad)" {
    var m = testMapper(&.{ ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y }, vendor_microsoft);
    try testing.expectEqual(Gamepad{}, (blk: {
        var g = m.snapshot();
        // Sticks rest at 0 (range midpoint rounds to 0 or -1 depending on parity).
        try testing.expect(@abs(@as(i32, g.lx)) <= 1);
        g.lx = 0;
        g.ly = 0;
        g.rx = 0;
        g.ry = 0;
        break :blk g;
    }));
    m.key(BTN_SOUTH, true);
    m.key(BTN_NORTH, true); // xpad's BTN_X: the left button on a Microsoft pad
    m.key(BTN_MODE, true);
    m.axis(ABS_Y, -32768); // pushed up
    m.axis(ABS_RX, 32767);
    m.axis(ABS_Z, 1023);
    m.axis(ABS_HAT0X, -1);
    m.axis(ABS_HAT0Y, 1);
    const g = m.snapshot();
    try testing.expectEqual(B.a | B.x | B.guide | B.dpad_left | B.dpad_down, g.buttons);
    try testing.expectEqual(@as(i16, 32767), g.ly);
    try testing.expectEqual(@as(i16, 32767), g.rx);
    try testing.expectEqual(@as(u16, 65535), g.lt);
    try testing.expectEqual(@as(u16, 0), g.rt);

    m.key(BTN_SOUTH, false);
    m.axis(ABS_HAT0X, 0);
    try testing.expectEqual(B.x | B.guide | B.dpad_down, m.snapshot().buttons);
}

test "evdev: spec pad (hid-playstation) keeps NORTH as the top button" {
    var m = testMapper(&.{ ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ }, 0x054c);
    m.key(BTN_NORTH, true);
    try testing.expectEqual(B.y, m.snapshot().buttons);
    m.key(BTN_NORTH, false);
    m.key(BTN_WEST, true);
    try testing.expectEqual(B.x, m.snapshot().buttons);
}

test "evdev: d-pad buttons and digital triggers" {
    var m = testMapper(&.{ ABS_X, ABS_Y }, 0x057e);
    m.key(BTN_DPAD_UP, true);
    m.key(BTN_TL2, true);
    m.key(BTN_SELECT, true);
    m.key(BTN_START, true);
    m.key(0x2fe, true); // unknown: ignored
    var g = m.snapshot();
    try testing.expectEqual(B.dpad_up | B.back | B.start, g.buttons);
    try testing.expectEqual(@as(u16, 65535), g.lt);
    try testing.expectEqual(@as(u16, 0), g.rt);
    try testing.expectEqual(@as(i16, 0), g.rx); // no right stick
    m.key(BTN_DPAD_UP, false);
    m.key(BTN_TL2, false);
    g = m.snapshot();
    try testing.expectEqual(B.back | B.start, g.buttons);
    try testing.expectEqual(@as(u16, 0), g.lt);
}

test "evdev: trigger axes fall back to BRAKE/GAS" {
    var m = testMapper(&.{ ABS_X, ABS_Y, ABS_BRAKE, ABS_GAS }, 0);
    try testing.expectEqual(@as(?u16, ABS_BRAKE), m.lt_axis);
    try testing.expectEqual(@as(?u16, ABS_GAS), m.rt_axis);
    m.axis(ABS_GAS, 255);
    try testing.expectEqual(@as(u16, 65535), m.snapshot().rt);
    m.axis(0x3f + 1, 7); // out of range: ignored
}

test "evdev: ioctl numbers match linux/input.h" {
    try testing.expectEqual(@as(u32, 0x80084502), EVIOCGID());
    try testing.expectEqual(@as(u32, 0x81004506), EVIOCGNAME(256));
    try testing.expectEqual(@as(u32, 0x80604518), EVIOCGKEY(96));
    try testing.expectEqual(@as(u32, 0x80044520), EVIOCGBIT(0, 4));
    try testing.expectEqual(@as(u32, 0x80184540), EVIOCGABS(0));
    try testing.expectEqual(@as(u32, 0x400445a0), EVIOCSCLOCKID());
    if (@sizeOf(usize) == 8) try testing.expectEqual(@as(usize, 24), @sizeOf(RawEvent));
}

test "evdev: source on a directory with no pads" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var s = try Source.open(.{ .nowFn = struct {
        fn f(_: ?*anyopaque) api.Micros {
            return 0;
        }
    }.f }, .{ .dir = "/proc/self", .name_filter = "no such device" });
    defer s.close();
    var out: [8]api.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 0), try s.poll(&out));
    try testing.expectEqual(@as(usize, 0), s.deviceCount());
}

test "evdev: digital trigger bits do not override an analog axis" {
    var m = testMapper(&.{ ABS_X, ABS_Y, ABS_Z, ABS_RZ }, 0x054c);
    m.axis(ABS_Z, 512);
    m.key(BTN_TL2, true);
    try testing.expect(m.snapshot().lt < 40000);
}
