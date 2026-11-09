//! Keyboard and mouse from evdev (/dev/input/event*), for the Linux client.
//!
//! The pure part (`Translator`) turns `input_event` records into the platform's
//! `InputEvent`s and is tested in `zig build test`; `Devices` opens and reads the device
//! nodes. Gamepads are not read here: platform/client/gamepad has its own evdev source.
//!
//!   keys      Linux KEY_* codes to USB HID usages (page 7); autorepeat is dropped.
//!   buttons   BTN_LEFT/RIGHT/MIDDLE/SIDE/EXTRA (and BACK/FORWARD) to 1, 2, 3, 4, 5.
//!   motion    REL_X/REL_Y summed per SYN_REPORT, one `move_rel` per report.
//!   wheels    REL_WHEEL_HI_RES/REL_HWHEEL_HI_RES (120 per notch) when the device has
//!             them, else REL_WHEEL/REL_HWHEEL x 120. Positive is away from the user / right.
//!
//! Within one report, motion comes first, then keys and buttons in order, then scroll,
//! as the Windows Raw Input translation does. SYN_DROPPED discards up to the next report.
//! Timestamps are CLOCK_MONOTONIC (EVIOCSCLOCKID), the bundle's clock.
//!
//! Reading evdev needs read access to the device nodes (the `input` group on most
//! distributions). The devices are not grabbed unless asked: the compositor sees the
//! same keys, which is what a windowed client wants.
const std = @import("std");
const api = @import("platform");
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// input-event-codes.h

pub const EV_SYN = 0x00;
pub const EV_KEY = 0x01;
pub const EV_REL = 0x02;
pub const SYN_REPORT = 0;
pub const SYN_DROPPED = 3;
pub const REL_X = 0x00;
pub const REL_Y = 0x01;
pub const REL_HWHEEL = 0x06;
pub const REL_WHEEL = 0x08;
pub const REL_WHEEL_HI_RES = 0x0b;
pub const REL_HWHEEL_HI_RES = 0x0c;
pub const KEY_A = 30;
pub const KEY_SPACE = 57;
pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_MIDDLE = 0x112;
pub const BTN_SIDE = 0x113;
pub const BTN_EXTRA = 0x114;
pub const BTN_FORWARD = 0x115;
pub const BTN_BACK = 0x116;
/// A gamepad's south face button: such nodes belong to the gamepad source.
pub const BTN_SOUTH = 0x130;
pub const KEY_MAX = 0x2ff;
pub const REL_MAX = 0x0f;

/// `struct input_event` on 64-bit Linux.
pub const RawEvent = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,

    pub fn timeUs(e: RawEvent) api.Micros {
        return @as(api.Micros, e.sec) * 1_000_000 + e.usec;
    }
};

/// Linux KEY_* code to USB HID keyboard usage; 0 when there is none.
pub fn hidUsage(code: u16) u16 {
    if (code < key_table.len) return key_table[code];
    if (code >= 183 and code <= 194) return 0x68 + (code - 183); // F13..F24
    return 0;
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

/// BTN_* to the platform's 1-based mouse button; 0 when it is not a mouse button.
pub fn mouseButton(code: u16) u16 {
    return switch (code) {
        BTN_LEFT => 1,
        BTN_RIGHT => 2,
        BTN_MIDDLE => 3,
        BTN_SIDE, BTN_BACK => 4,
        BTN_EXTRA, BTN_FORWARD => 5,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Translation

/// Most events one report can produce before it is flushed early.
pub const max_report = 32;

/// One device's report assembler.
pub const Translator = struct {
    /// The device reports high-resolution wheels: ignore the notch events.
    hi_res_wheel: bool = false,
    dx: i32 = 0,
    dy: i32 = 0,
    sx: i32 = 0,
    sy: i32 = 0,
    keys: [max_report]api.InputEvent.What = undefined,
    n_keys: usize = 0,
    dropping: bool = false,

    /// Feeds one record; on SYN_REPORT (or a full buffer) writes the report's events to
    /// `out` and returns how many. `out` must hold `max_report + 3`.
    pub fn feed(t: *Translator, e: RawEvent, out: []api.InputEvent) usize {
        std.debug.assert(out.len >= max_report + 3);
        if (e.type == EV_SYN) {
            if (e.code == SYN_DROPPED) {
                t.reset();
                t.dropping = true;
                return 0;
            }
            if (e.code != SYN_REPORT) return 0;
            if (t.dropping) {
                t.dropping = false;
                t.reset();
                return 0;
            }
            return t.flush(e.timeUs(), out);
        }
        if (t.dropping) return 0;
        switch (e.type) {
            EV_KEY => {
                if (e.value == 2) return 0; // autorepeat: the host repeats on its own
                const down = e.value != 0;
                const what: api.InputEvent.What = if (mouseButton(e.code) != 0)
                    .{ .button = .{ .code = mouseButton(e.code), .down = down } }
                else if (hidUsage(e.code) != 0)
                    .{ .key = .{ .code = hidUsage(e.code), .down = down } }
                else
                    return 0;
                t.keys[t.n_keys] = what;
                t.n_keys += 1;
                if (t.n_keys == max_report) return t.flush(e.timeUs(), out);
            },
            EV_REL => switch (e.code) {
                REL_X => t.dx +|= e.value,
                REL_Y => t.dy +|= e.value,
                REL_WHEEL => if (!t.hi_res_wheel) {
                    t.sy +|= e.value *| 120;
                },
                REL_HWHEEL => if (!t.hi_res_wheel) {
                    t.sx +|= e.value *| 120;
                },
                REL_WHEEL_HI_RES => if (t.hi_res_wheel) {
                    t.sy +|= e.value;
                },
                REL_HWHEEL_HI_RES => if (t.hi_res_wheel) {
                    t.sx +|= e.value;
                },
                else => {},
            },
            else => {},
        }
        return 0;
    }

    fn flush(t: *Translator, time: api.Micros, out: []api.InputEvent) usize {
        var n: usize = 0;
        if (t.dx != 0 or t.dy != 0) {
            out[n] = .{ .time_us = time, .what = .{ .move_rel = .{ .dx = t.dx, .dy = t.dy } } };
            n += 1;
        }
        for (t.keys[0..t.n_keys]) |w| {
            out[n] = .{ .time_us = time, .what = w };
            n += 1;
        }
        if (t.sx != 0 or t.sy != 0) {
            out[n] = .{ .time_us = time, .what = .{ .scroll = .{ .dx = t.sx, .dy = t.sy } } };
            n += 1;
        }
        t.reset();
        return n;
    }

    fn reset(t: *Translator) void {
        t.dx = 0;
        t.dy = 0;
        t.sx = 0;
        t.sy = 0;
        t.n_keys = 0;
    }
};

/// Keys and buttons currently held, so focus loss can release them.
pub const Held = struct {
    keys: std.StaticBitSet(256) = .initEmpty(),
    buttons: u8 = 0,

    pub fn note(h: *Held, w: api.InputEvent.What) void {
        switch (w) {
            .key => |k| if (k.code < 256) h.keys.setValue(k.code, k.down),
            .button => |b| if (b.code >= 1 and b.code <= 8) {
                const bit = @as(u8, 1) << @intCast(b.code - 1);
                if (b.down) h.buttons |= bit else h.buttons &= ~bit;
            },
            else => {},
        }
    }

    /// Release events for everything held, into `out`; returns how many (and forgets them).
    pub fn releaseAll(h: *Held, time: api.Micros, out: []api.InputEvent) usize {
        var n: usize = 0;
        var it = h.keys.iterator(.{});
        while (it.next()) |code| {
            if (n == out.len) break;
            out[n] = .{ .time_us = time, .what = .{ .key = .{ .code = @intCast(code), .down = false } } };
            h.keys.unset(code);
            n += 1;
        }
        for (0..8) |i| {
            const bit = @as(u8, 1) << @intCast(i);
            if (h.buttons & bit == 0 or n == out.len) continue;
            out[n] = .{ .time_us = time, .what = .{ .button = .{ .code = @intCast(i + 1), .down = false } } };
            h.buttons &= ~bit;
            n += 1;
        }
        return n;
    }

    pub fn any(h: *const Held) bool {
        return h.keys.count() > 0 or h.buttons != 0;
    }
};

// ---------------------------------------------------------------------------
// Devices

fn ioc(dir: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, 'E') << 8) | nr;
}
const ioc_read = 2;
const ioc_write = 1;

fn eviocgbit(ev: u32, len: u32) u32 {
    return ioc(ioc_read, 0x20 + ev, len);
}
fn eviocgname(len: u32) u32 {
    return ioc(ioc_read, 0x06, len);
}
const eviocsclockid = ioc(ioc_write, 0xa0, @sizeOf(c_int));
const eviocgrab = ioc(ioc_write, 0x90, @sizeOf(c_int));

fn testBit(bits: []const u8, bit: usize) bool {
    return bit / 8 < bits.len and bits[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
}

pub const Kind = packed struct(u8) {
    keyboard: bool = false,
    mouse: bool = false,
    _r: u6 = 0,

    pub fn any(k: Kind) bool {
        return k.keyboard or k.mouse;
    }
};

/// What the bits say a device is: a keyboard has letter keys and space, a mouse has
/// relative X/Y and a left button. Gamepads, touchpads and tablets are neither.
pub fn classify(ev_bits: []const u8, key_bits: []const u8, rel_bits: []const u8) Kind {
    var k: Kind = .{};
    // Gamepads (BTN_SOUTH) are read by platform/client/gamepad, not here.
    if (testBit(key_bits, BTN_SOUTH)) return k;
    if (testBit(ev_bits, EV_KEY) and testBit(key_bits, KEY_A) and testBit(key_bits, KEY_SPACE)) k.keyboard = true;
    if (testBit(ev_bits, EV_REL) and testBit(rel_bits, REL_X) and testBit(rel_bits, REL_Y) and testBit(key_bits, BTN_LEFT)) k.mouse = true;
    return k;
}

pub const max_devices = 32;
/// /dev/input/event0..N are probed.
pub const max_nodes = 64;

const Device = struct {
    fd: i32,
    node: u8,
    kind: Kind,
    tr: Translator,
    name: [64]u8,
    name_len: usize,
};

fn sysOk(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

/// The open keyboards and mice. Not thread-safe; one poller.
pub const Devices = struct {
    devs: [max_devices]Device = undefined,
    n: usize = 0,
    grab: bool = false,
    /// Nodes that were looked at and are not ours (no access, other kinds), by bit.
    skip: u64 = 0,
    /// Nodes we could not open for lack of permission (for the log).
    denied: u64 = 0,
    logged_denied: bool = false,

    /// Opens every keyboard and mouse node not open yet. Returns how many were added.
    pub fn scan(d: *Devices) usize {
        var added: usize = 0;
        var node: u8 = 0;
        while (node < max_nodes) : (node += 1) {
            const bit = @as(u64, 1) << @intCast(node);
            if (d.skip & bit != 0 or d.isOpen(node) or d.n == max_devices) continue;
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{node}) catch unreachable;
            const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .ACCES, .PERM => {
                    d.denied |= bit;
                    continue;
                },
                else => continue, // no such node (yet)
            }
            const fd: i32 = @intCast(rc);
            var ev_bits: [4]u8 = @splat(0);
            var key_bits: [(KEY_MAX + 8) / 8]u8 = @splat(0);
            var rel_bits: [(REL_MAX + 8) / 8]u8 = @splat(0);
            _ = linux.ioctl(fd, eviocgbit(0, ev_bits.len), @intFromPtr(&ev_bits));
            _ = linux.ioctl(fd, eviocgbit(EV_KEY, key_bits.len), @intFromPtr(&key_bits));
            _ = linux.ioctl(fd, eviocgbit(EV_REL, rel_bits.len), @intFromPtr(&rel_bits));
            const kind = classify(&ev_bits, &key_bits, &rel_bits);
            if (!kind.any()) {
                _ = linux.close(fd);
                d.skip |= bit;
                continue;
            }
            var clk: c_int = @intFromEnum(linux.CLOCK.MONOTONIC);
            if (!sysOk(linux.ioctl(fd, eviocsclockid, @intFromPtr(&clk)))) {
                // Without it the timestamps are wall-clock time: not ours to use.
                std.log.scoped(.client_linux).warn("event{d}: EVIOCSCLOCKID failed; skipping", .{node});
                _ = linux.close(fd);
                d.skip |= bit;
                continue;
            }
            var dev: Device = .{ .fd = fd, .node = node, .kind = kind, .tr = .{ .hi_res_wheel = testBit(&rel_bits, REL_WHEEL_HI_RES) }, .name = undefined, .name_len = 0 };
            const nrc = linux.ioctl(fd, eviocgname(dev.name.len), @intFromPtr(&dev.name));
            if (sysOk(nrc)) dev.name_len = std.mem.indexOfScalar(u8, &dev.name, 0) orelse @min(nrc, dev.name.len);
            d.denied &= ~bit;
            d.devs[d.n] = dev;
            d.n += 1;
            if (d.grab) d.setGrab(d.n - 1, true);
            std.log.scoped(.client_linux).info("evdev: event{d} \"{s}\"{s}{s}", .{ node, dev.name[0..dev.name_len], if (kind.keyboard) " keyboard" else "", if (kind.mouse) " mouse" else "" });
            added += 1;
        }
        if (d.n == 0 and d.denied != 0 and !d.logged_denied) {
            std.log.scoped(.client_linux).warn("evdev: no access to /dev/input/event* (add the user to the `input` group); no local input", .{});
            d.logged_denied = true;
        }
        return added;
    }

    fn isOpen(d: *const Devices, node: u8) bool {
        for (d.devs[0..d.n]) |dev| if (dev.node == node) return true;
        return false;
    }

    fn setGrab(d: *Devices, i: usize, on: bool) void {
        var v: c_int = @intFromBool(on);
        _ = linux.ioctl(d.devs[i].fd, eviocgrab, if (on) @intFromPtr(&v) else 0);
    }

    pub fn setGrabAll(d: *Devices, on: bool) void {
        if (d.grab == on) return;
        d.grab = on;
        for (0..d.n) |i| d.setGrab(i, on);
    }

    /// Reads every device until it would block, writing events to `out` (oldest first
    /// per device). Stops early when `out` has less than a report's worth of room;
    /// the rest stays in the kernel's buffer for the next call. Devices that went away
    /// are closed.
    pub fn read(d: *Devices, out: []api.InputEvent) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < d.n) {
            const dev = &d.devs[i];
            var raw: [16]RawEvent = undefined;
            var gone = false;
            while (out.len - n >= max_report + 3) {
                const rc = linux.read(dev.fd, @ptrCast(&raw), @sizeOf(@TypeOf(raw)));
                switch (linux.errno(rc)) {
                    .SUCCESS => {},
                    .AGAIN, .INTR => break,
                    else => { // ENODEV: unplugged
                        gone = true;
                        break;
                    },
                }
                if (rc == 0) break;
                const k = rc / @sizeOf(RawEvent);
                for (raw[0..k]) |e| n += dev.tr.feed(e, out[n..]);
                if (k < raw.len) break;
            }
            if (gone) {
                std.log.scoped(.client_linux).info("evdev: event{d} removed", .{dev.node});
                _ = linux.close(dev.fd);
                d.devs[i] = d.devs[d.n - 1];
                d.n -= 1;
                continue;
            }
            i += 1;
        }
        return n;
    }

    pub fn deinit(d: *Devices) void {
        for (d.devs[0..d.n]) |dev| _ = linux.close(dev.fd);
        d.n = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn rawEv(t: u16, code: u16, value: i32, us: isize) RawEvent {
    return .{ .sec = 0, .usec = us, .type = t, .code = code, .value = value };
}

test "letters, digits and modifiers map to HID usages" {
    try testing.expectEqual(@as(u16, 0x04), hidUsage(KEY_A));
    try testing.expectEqual(@as(u16, 0x1D), hidUsage(44)); // Z
    try testing.expectEqual(@as(u16, 0x27), hidUsage(11)); // 0
    try testing.expectEqual(@as(u16, 0xE0), hidUsage(29)); // left ctrl
    try testing.expectEqual(@as(u16, 0xE7), hidUsage(126)); // right meta
    try testing.expectEqual(@as(u16, 0x52), hidUsage(103)); // up
    try testing.expectEqual(@as(u16, 0x73), hidUsage(194)); // F24
    try testing.expectEqual(@as(u16, 0), hidUsage(0));
    try testing.expectEqual(@as(u16, 0), hidUsage(BTN_LEFT));
    // Every letter: KEY_* order is QWERTY rows, HID is alphabetical.
    const qwerty = "qwertyuiopasdfghjklzxcvbnm";
    const codes = [_]u16{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 38, 44, 45, 46, 47, 48, 49, 50 };
    for (qwerty, codes) |ch, code| try testing.expectEqual(@as(u16, 4 + ch - 'a'), hidUsage(code));
}

test "a report: motion first, then keys and buttons, then scroll" {
    var t: Translator = .{};
    var out: [max_report + 3]api.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_KEY, BTN_LEFT, 1, 10), &out));
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_REL, REL_X, 5, 10), &out));
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_REL, REL_Y, -3, 10), &out));
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_REL, REL_X, 2, 10), &out));
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_REL, REL_WHEEL, -1, 10), &out));
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_KEY, KEY_A, 1, 10), &out));
    const n = t.feed(rawEv(EV_SYN, SYN_REPORT, 0, 1234), &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(i32, 7), out[0].what.move_rel.dx);
    try testing.expectEqual(@as(i32, -3), out[0].what.move_rel.dy);
    try testing.expect(out[1].what.button.code == 1 and out[1].what.button.down);
    try testing.expect(out[2].what.key.code == 0x04 and out[2].what.key.down);
    try testing.expectEqual(@as(i32, -120), out[3].what.scroll.dy);
    try testing.expectEqual(@as(api.Micros, 1234), out[3].time_us);
    // Empty report: nothing.
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_SYN, SYN_REPORT, 0, 2000), &out));
}

test "autorepeat dropped, unknown keys ignored, release maps" {
    var t: Translator = .{};
    var out: [max_report + 3]api.InputEvent = undefined;
    _ = t.feed(rawEv(EV_KEY, KEY_A, 2, 0), &out);
    _ = t.feed(rawEv(EV_KEY, 0x2fe, 1, 0), &out);
    _ = t.feed(rawEv(EV_KEY, BTN_SIDE, 0, 0), &out);
    const n = t.feed(rawEv(EV_SYN, SYN_REPORT, 0, 0), &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(out[0].what.button.code == 4 and !out[0].what.button.down);
}

test "high-resolution wheels win when the device has them" {
    var t: Translator = .{ .hi_res_wheel = true };
    var out: [max_report + 3]api.InputEvent = undefined;
    _ = t.feed(rawEv(EV_REL, REL_WHEEL, 1, 0), &out);
    _ = t.feed(rawEv(EV_REL, REL_WHEEL_HI_RES, 60, 0), &out);
    _ = t.feed(rawEv(EV_REL, REL_HWHEEL_HI_RES, -120, 0), &out);
    const n = t.feed(rawEv(EV_SYN, SYN_REPORT, 0, 0), &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i32, 60), out[0].what.scroll.dy);
    try testing.expectEqual(@as(i32, -120), out[0].what.scroll.dx);
}

test "SYN_DROPPED discards up to the next report" {
    var t: Translator = .{};
    var out: [max_report + 3]api.InputEvent = undefined;
    _ = t.feed(rawEv(EV_KEY, KEY_A, 1, 0), &out);
    _ = t.feed(rawEv(EV_SYN, SYN_DROPPED, 0, 0), &out);
    _ = t.feed(rawEv(EV_KEY, KEY_SPACE, 1, 0), &out);
    try testing.expectEqual(@as(usize, 0), t.feed(rawEv(EV_SYN, SYN_REPORT, 0, 0), &out));
    _ = t.feed(rawEv(EV_KEY, KEY_SPACE, 0, 0), &out);
    try testing.expectEqual(@as(usize, 1), t.feed(rawEv(EV_SYN, SYN_REPORT, 0, 0), &out));
    try testing.expect(out[0].what.key.code == 0x2C and !out[0].what.key.down);
}

test "a full report flushes early" {
    var t: Translator = .{};
    var out: [max_report + 3]api.InputEvent = undefined;
    var total: usize = 0;
    for (0..max_report + 4) |i| total += t.feed(rawEv(EV_KEY, KEY_A, @intCast(i % 2), 0), &out);
    total += t.feed(rawEv(EV_SYN, SYN_REPORT, 0, 0), &out);
    try testing.expectEqual(@as(usize, max_report + 4), total);
}

test "held keys and buttons are released on focus loss" {
    var h: Held = .{};
    h.note(.{ .key = .{ .code = 0x04, .down = true } });
    h.note(.{ .key = .{ .code = 0xE1, .down = true } });
    h.note(.{ .key = .{ .code = 0x04, .down = false } });
    h.note(.{ .button = .{ .code = 2, .down = true } });
    try testing.expect(h.any());
    var out: [8]api.InputEvent = undefined;
    const n = h.releaseAll(77, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(out[0].what.key.code == 0xE1 and !out[0].what.key.down);
    try testing.expect(out[1].what.button.code == 2 and !out[1].what.button.down);
    try testing.expect(!h.any());
}

test "classify by capability bits" {
    var ev_bits: [4]u8 = @splat(0);
    var key_bits: [(KEY_MAX + 8) / 8]u8 = @splat(0);
    var rel_bits: [(REL_MAX + 8) / 8]u8 = @splat(0);
    try testing.expect(!classify(&ev_bits, &key_bits, &rel_bits).any());
    ev_bits[0] = (1 << EV_KEY) | (1 << EV_REL);
    key_bits[KEY_A / 8] |= 1 << (KEY_A % 8);
    key_bits[KEY_SPACE / 8] |= 1 << (KEY_SPACE % 8);
    try testing.expect(classify(&ev_bits, &key_bits, &rel_bits).keyboard);
    try testing.expect(!classify(&ev_bits, &key_bits, &rel_bits).mouse);
    rel_bits[0] = 0b11;
    key_bits[BTN_LEFT / 8] |= 1 << (BTN_LEFT % 8);
    try testing.expect(classify(&ev_bits, &key_bits, &rel_bits).mouse);
    key_bits[BTN_SOUTH / 8] |= 1 << (BTN_SOUTH % 8);
    try testing.expect(!classify(&ev_bits, &key_bits, &rel_bits).any());
}
