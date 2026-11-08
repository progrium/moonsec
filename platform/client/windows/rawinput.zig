//! Raw Input records to core input calls.
//!
//! The C side (rawinput.c) registers for keyboard and mouse Raw Input on the
//! client window and hands over the RAWKEYBOARD / RAWMOUSE fields it reads
//! from each WM_INPUT unchanged. This file is the pure part: scan codes to
//! USB HID usages, button flags to button events, and calls on
//! `core.input.Sender`. It builds and is tested on every OS.
//!
//! Scan codes, not virtual keys: they name the physical key whatever the
//! keyboard layout, which is what the host's SendInput (KEYEVENTF_SCANCODE)
//! and HID usages both want.

const std = @import("std");
const api = @import("platform");

pub const What = api.InputEvent.What;

/// RAWKEYBOARD.Flags bits.
pub const ri_key_break: u16 = 0x01;
pub const ri_key_e0: u16 = 0x02;
pub const ri_key_e1: u16 = 0x04;

/// RAWMOUSE.usFlags bits.
pub const mouse_move_absolute: u16 = 0x01;
pub const mouse_virtual_desktop: u16 = 0x02;

/// RAWMOUSE.usButtonFlags bits.
pub const ri_mouse_wheel: u16 = 0x0400;
pub const ri_mouse_hwheel: u16 = 0x0800;

/// Fields of a RAWKEYBOARD the mapping needs.
pub const RawKeyboard = extern struct {
    make_code: u16,
    flags: u16,
};

/// Fields of a RAWMOUSE the mapping needs.
pub const RawMouse = extern struct {
    flags: u16,
    button_flags: u16,
    /// Wheel delta (signed, 120 per notch) when a wheel flag is set.
    button_data: u16,
    last_x: i32,
    last_y: i32,
};

// Set-1 make code (no prefix) to HID usage (keyboard page 0x07). 0: unmapped.
const plain: [128]u8 = blk: {
    var t = [_]u8{0} ** 128;
    const pairs = [_][2]u8{
        .{ 0x01, 0x29 }, // Escape
        .{ 0x02, 0x1E }, .{ 0x03, 0x1F }, .{ 0x04, 0x20 }, .{ 0x05, 0x21 }, .{ 0x06, 0x22 }, // 1-5
        .{ 0x07, 0x23 }, .{ 0x08, 0x24 }, .{ 0x09, 0x25 }, .{ 0x0A, 0x26 }, .{ 0x0B, 0x27 }, // 6-0
        .{ 0x0C, 0x2D }, .{ 0x0D, 0x2E }, .{ 0x0E, 0x2A }, .{ 0x0F, 0x2B }, // - = Backspace Tab
        .{ 0x10, 0x14 }, .{ 0x11, 0x1A }, .{ 0x12, 0x08 }, .{ 0x13, 0x15 }, .{ 0x14, 0x17 }, // Q W E R T
        .{ 0x15, 0x1C }, .{ 0x16, 0x18 }, .{ 0x17, 0x0C }, .{ 0x18, 0x12 }, .{ 0x19, 0x13 }, // Y U I O P
        .{ 0x1A, 0x2F }, .{ 0x1B, 0x30 }, .{ 0x1C, 0x28 }, .{ 0x1D, 0xE0 }, // [ ] Enter LCtrl
        .{ 0x1E, 0x04 }, .{ 0x1F, 0x16 }, .{ 0x20, 0x07 }, .{ 0x21, 0x09 }, .{ 0x22, 0x0A }, // A S D F G
        .{ 0x23, 0x0B }, .{ 0x24, 0x0D }, .{ 0x25, 0x0E }, .{ 0x26, 0x0F }, // H J K L
        .{ 0x27, 0x33 }, .{ 0x28, 0x34 }, .{ 0x29, 0x35 }, .{ 0x2A, 0xE1 }, .{ 0x2B, 0x31 }, // ; ' ` LShift \
        .{ 0x2C, 0x1D }, .{ 0x2D, 0x1B }, .{ 0x2E, 0x06 }, .{ 0x2F, 0x19 }, .{ 0x30, 0x05 }, // Z X C V B
        .{ 0x31, 0x11 }, .{ 0x32, 0x10 }, .{ 0x33, 0x36 }, .{ 0x34, 0x37 }, .{ 0x35, 0x38 }, // N M , . /
        .{ 0x36, 0xE5 }, .{ 0x37, 0x55 }, .{ 0x38, 0xE2 }, .{ 0x39, 0x2C }, .{ 0x3A, 0x39 }, // RShift KP* LAlt Space Caps
        .{ 0x3B, 0x3A }, .{ 0x3C, 0x3B }, .{ 0x3D, 0x3C }, .{ 0x3E, 0x3D }, .{ 0x3F, 0x3E }, // F1-F5
        .{ 0x40, 0x3F }, .{ 0x41, 0x40 }, .{ 0x42, 0x41 }, .{ 0x43, 0x42 }, .{ 0x44, 0x43 }, // F6-F10
        .{ 0x45, 0x53 }, .{ 0x46, 0x47 }, // NumLock ScrollLock
        .{ 0x47, 0x5F }, .{ 0x48, 0x60 }, .{ 0x49, 0x61 }, .{ 0x4A, 0x56 }, // KP7 KP8 KP9 KP-
        .{ 0x4B, 0x5C }, .{ 0x4C, 0x5D }, .{ 0x4D, 0x5E }, .{ 0x4E, 0x57 }, // KP4 KP5 KP6 KP+
        .{ 0x4F, 0x59 }, .{ 0x50, 0x5A }, .{ 0x51, 0x5B }, .{ 0x52, 0x62 }, .{ 0x53, 0x63 }, // KP1 KP2 KP3 KP0 KP.
        .{ 0x56, 0x64 }, .{ 0x57, 0x44 }, .{ 0x58, 0x45 }, .{ 0x59, 0x67 }, // ISO \ F11 F12 KP=
        .{ 0x64, 0x68 }, .{ 0x65, 0x69 }, .{ 0x66, 0x6A }, .{ 0x67, 0x6B }, .{ 0x68, 0x6C }, // F13-F17
        .{ 0x69, 0x6D }, .{ 0x6A, 0x6E }, .{ 0x6B, 0x6F }, .{ 0x6C, 0x70 }, .{ 0x6D, 0x71 }, // F18-F22
        .{ 0x6E, 0x72 }, .{ 0x76, 0x73 }, // F23 F24
        .{ 0x70, 0x88 }, .{ 0x73, 0x87 }, .{ 0x79, 0x8A }, .{ 0x7B, 0x8B }, .{ 0x7D, 0x89 }, .{ 0x7E, 0x85 }, // JIS, KP,
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

// E0-prefixed make code to HID usage.
const extended: [128]u8 = blk: {
    var t = [_]u8{0} ** 128;
    const pairs = [_][2]u8{
        .{ 0x1C, 0x58 }, .{ 0x1D, 0xE4 }, .{ 0x35, 0x54 }, .{ 0x37, 0x46 }, .{ 0x38, 0xE6 }, // KPEnter RCtrl KP/ PrtSc RAlt
        .{ 0x45, 0x53 }, // NumLock (some keyboards send it extended)
        .{ 0x47, 0x4A }, .{ 0x48, 0x52 }, .{ 0x49, 0x4B }, .{ 0x4B, 0x50 }, .{ 0x4D, 0x4F }, // Home Up PgUp Left Right
        .{ 0x4F, 0x4D }, .{ 0x50, 0x51 }, .{ 0x51, 0x4E }, .{ 0x52, 0x49 }, .{ 0x53, 0x4C }, // End Down PgDn Ins Del
        .{ 0x5B, 0xE3 }, .{ 0x5C, 0xE7 }, .{ 0x5D, 0x65 }, // LGui RGui Menu
        .{ 0x5E, 0x66 }, // Power
        .{ 0x20, 0x7F }, .{ 0x2E, 0x81 }, .{ 0x30, 0x80 }, // Mute VolDown VolUp
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

pub const usage_pause: u16 = 0x48;

/// Keyboard state across records: Pause arrives as two records
/// (E1 1D, then 45) and the second must not read as NumLock.
pub const Keyboard = struct {
    swallow_numlock: bool = false,

    pub const Key = struct { usage: u16, down: bool };

    /// The HID usage and direction for one record, or null for records that
    /// carry no key of their own (the fake shifts Windows wraps around
    /// navigation keys, the tail of Pause, overruns and unmapped codes).
    pub fn map(k: *Keyboard, r: RawKeyboard) ?Key {
        const down = r.flags & ri_key_break == 0;
        const code = r.make_code;
        if (code == 0 or code >= 0x80) return null; // 0xFF: overrun
        if (r.flags & ri_key_e1 != 0) {
            if (code == 0x1D) {
                k.swallow_numlock = true;
                return .{ .usage = usage_pause, .down = down };
            }
            return null;
        }
        if (r.flags & ri_key_e0 != 0) {
            // E0 2A / E0 36: fake shift around Insert/Home/arrows etc.
            if (code == 0x2A or code == 0x36) return null;
            const u = extended[code];
            return if (u == 0) null else .{ .usage = u, .down = down };
        }
        if (code == 0x45 and k.swallow_numlock) {
            k.swallow_numlock = false;
            return null;
        }
        const u = plain[code];
        return if (u == 0) null else .{ .usage = u, .down = down };
    }
};

/// Mouse button bit pairs in usButtonFlags: (down, up) for buttons 1..5
/// (left, right, middle, back, forward).
const button_bits = [_][2]u16{
    .{ 0x0001, 0x0002 },
    .{ 0x0004, 0x0008 },
    .{ 0x0010, 0x0020 },
    .{ 0x0040, 0x0080 },
    .{ 0x0100, 0x0200 },
};

/// The event for one keyboard record, or null when it carries no key.
pub fn keyboardEvent(k: *Keyboard, r: RawKeyboard) ?What {
    const key = k.map(r) orelse return null;
    return .{ .key = .{ .code = key.usage, .down = key.down } };
}

/// Most events one mouse record can produce: a move, five buttons down and
/// up, two wheels.
pub const max_mouse_events = 1 + 2 * button_bits.len + 2;

/// The events for one mouse record, in order, written to `out`; returns how many.
///
/// Relative motion goes out as `move_rel` (mice report counts, unaccelerated,
/// which is what games want). Absolute devices (pens, RDP, VMs) report
/// 0..65535 across the screen or virtual desktop and go out as `move_abs`;
/// mapping virtual-desktop coordinates to the streamed display is the
/// caller's job. Wheel data is signed, 120 per notch, positive away from the
/// user (vertical) or to the right (horizontal), passed through as is.
///
/// Motion comes before buttons so a click lands after the move that came
/// with it in the same record.
pub fn mouseEvents(r: RawMouse, out: *[max_mouse_events]What) usize {
    var n: usize = 0;
    if (r.flags & mouse_move_absolute != 0) {
        out[n] = .{ .move_abs = .{ .x = clampAbs(r.last_x), .y = clampAbs(r.last_y) } };
        n += 1;
    } else if (r.last_x != 0 or r.last_y != 0) {
        out[n] = .{ .move_rel = .{ .dx = r.last_x, .dy = r.last_y } };
        n += 1;
    }
    for (button_bits, 1..) |bits, b| {
        if (r.button_flags & bits[0] != 0) {
            out[n] = .{ .button = .{ .code = @intCast(b), .down = true } };
            n += 1;
        }
        if (r.button_flags & bits[1] != 0) {
            out[n] = .{ .button = .{ .code = @intCast(b), .down = false } };
            n += 1;
        }
    }
    const delta: i32 = @as(i16, @bitCast(r.button_data));
    if (r.button_flags & ri_mouse_wheel != 0) {
        out[n] = .{ .scroll = .{ .dx = 0, .dy = delta } };
        n += 1;
    }
    if (r.button_flags & ri_mouse_hwheel != 0) {
        out[n] = .{ .scroll = .{ .dx = delta, .dy = 0 } };
        n += 1;
    }
    return n;
}

fn clampAbs(v: i32) u16 {
    return @intCast(std.math.clamp(v, 0, 65535));
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn press(k: *Keyboard, code: u16, flags: u16) ?Keyboard.Key {
    return k.map(.{ .make_code = code, .flags = flags });
}

test "letters, modifiers and extended keys map to HID usages" {
    var k: Keyboard = .{};
    try testing.expectEqual(Keyboard.Key{ .usage = 0x04, .down = true }, press(&k, 0x1E, 0).?); // A
    try testing.expectEqual(Keyboard.Key{ .usage = 0x04, .down = false }, press(&k, 0x1E, ri_key_break).?);
    try testing.expectEqual(@as(u16, 0xE0), press(&k, 0x1D, 0).?.usage); // LCtrl
    try testing.expectEqual(@as(u16, 0xE4), press(&k, 0x1D, ri_key_e0).?.usage); // RCtrl
    try testing.expectEqual(@as(u16, 0x58), press(&k, 0x1C, ri_key_e0).?.usage); // KP Enter
    try testing.expectEqual(@as(u16, 0x28), press(&k, 0x1C, 0).?.usage); // Enter
    try testing.expectEqual(@as(u16, 0x52), press(&k, 0x48, ri_key_e0).?.usage); // Up
    try testing.expectEqual(@as(u16, 0x60), press(&k, 0x48, 0).?.usage); // KP8
    try testing.expectEqual(@as(u16, 0x45), press(&k, 0x58, 0).?.usage); // F12
    try testing.expectEqual(@as(u16, 0xE3), press(&k, 0x5B, ri_key_e0).?.usage); // LWin
}

test "every plain letter and digit is mapped once" {
    var seen = [_]bool{false} ** 256;
    for (plain) |u| {
        if (u == 0) continue;
        if (u >= 0x04 and u <= 0x27) {
            try testing.expect(!seen[u]);
            seen[u] = true;
        }
    }
    for (0x04..0x28) |u| try testing.expect(seen[u]);
}

test "fake shifts and overruns are dropped" {
    var k: Keyboard = .{};
    try testing.expect(press(&k, 0x2A, ri_key_e0) == null);
    try testing.expect(press(&k, 0x36, ri_key_e0 | ri_key_break) == null);
    try testing.expect(press(&k, 0xFF, 0) == null);
    try testing.expect(press(&k, 0, 0) == null);
}

test "Pause is one key, and its NumLock tail is swallowed" {
    var k: Keyboard = .{};
    try testing.expectEqual(Keyboard.Key{ .usage = usage_pause, .down = true }, press(&k, 0x1D, ri_key_e1).?);
    try testing.expect(press(&k, 0x45, 0) == null);
    // A real NumLock afterwards still works.
    try testing.expectEqual(@as(u16, 0x53), press(&k, 0x45, 0).?.usage);
}

test "mouse: motion, then buttons, then wheel" {
    var out: [max_mouse_events]What = undefined;
    var n = mouseEvents(.{ .flags = 0, .button_flags = 0x0001 | 0x0002 | ri_mouse_wheel, .button_data = @bitCast(@as(i16, -120)), .last_x = 5, .last_y = -3 }, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(i32, 5), out[0].move_rel.dx);
    try testing.expectEqual(@as(i32, -3), out[0].move_rel.dy);
    try testing.expect(out[1].button.code == 1 and out[1].button.down);
    try testing.expect(out[2].button.code == 1 and !out[2].button.down);
    try testing.expectEqual(@as(i32, -120), out[3].scroll.dy);

    n = mouseEvents(.{ .flags = 0, .button_flags = ri_mouse_hwheel, .button_data = 240, .last_x = 0, .last_y = 0 }, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i32, 240), out[0].scroll.dx);

    // No motion and no buttons: nothing.
    try testing.expectEqual(@as(usize, 0), mouseEvents(.{ .flags = 0, .button_flags = 0, .button_data = 0, .last_x = 0, .last_y = 0 }, &out));
}

test "mouse: absolute devices clamp to 0..65535" {
    var out: [max_mouse_events]What = undefined;
    const n = mouseEvents(.{ .flags = mouse_move_absolute, .button_flags = 0x0040, .button_data = 0, .last_x = 70000, .last_y = -1 }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 65535), out[0].move_abs.x);
    try testing.expectEqual(@as(u16, 0), out[0].move_abs.y);
    try testing.expectEqual(@as(u16, 4), out[1].button.code); // back
}

test "every button flag produces its event" {
    var out: [max_mouse_events]What = undefined;
    const n = mouseEvents(.{ .flags = 0, .button_flags = 0x03FF | ri_mouse_wheel | ri_mouse_hwheel, .button_data = 120, .last_x = 1, .last_y = 1 }, &out);
    try testing.expectEqual(@as(usize, max_mouse_events), n);
}

test "keyboardEvent" {
    var k: Keyboard = .{};
    try testing.expectEqual(@as(u16, 0x04), keyboardEvent(&k, .{ .make_code = 0x1E, .flags = 0 }).?.key.code);
    try testing.expect(keyboardEvent(&k, .{ .make_code = 0x2A, .flags = ri_key_e0 }) == null);
}
