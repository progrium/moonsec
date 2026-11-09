//! NSEvent records to platform input events.
//!
//! The Objective-C side (macc_window.m) copies the fields it needs out of each
//! keyboard, mouse and scroll NSEvent the client view receives into a
//! `macc_event` and queues it. This file is the pure part: macOS virtual key
//! codes to USB HID usages, modifier-flag changes to key downs and ups,
//! fractional mouse and trackpad deltas to whole counts. It builds and is
//! tested on every OS.
//!
//! Virtual key codes (kVK_*), not characters: they name the physical key
//! whatever the keyboard layout, which is what the host's injector and HID
//! usages both want.

const std = @import("std");
const api = @import("platform");

pub const What = api.InputEvent.What;

/// `macc_event.kind` values (macc.h).
pub const Kind = enum(u32) {
    key_down = 1,
    key_up = 2,
    flags_changed = 3,
    mouse_down = 4,
    mouse_up = 5,
    mouse_move = 6,
    scroll = 7,
    quit = 8,
    _,
};

/// The fields of one NSEvent the mapping needs (mirrors `macc_event`).
pub const Record = struct {
    kind: Kind,
    /// NSEvent.keyCode (key and flags-changed events).
    key_code: u16 = 0,
    /// NSEvent.modifierFlags, device-dependent bits included.
    modifier_flags: u64 = 0,
    /// NSEvent.isARepeat (key down).
    repeat: bool = false,
    /// NSEvent.buttonNumber (0 left, 1 right, 2 middle, 3 back, 4 forward).
    button: u16 = 0,
    /// Mouse: NSEvent.deltaX/Y. Scroll: NSEvent.scrollingDeltaX/Y.
    dx: f64 = 0,
    dy: f64 = 0,
    /// Scroll: hasPreciseScrollingDeltas (trackpad, Magic Mouse: points, not lines).
    precise: bool = false,
    /// Scroll: isDirectionInvertedFromDevice ("natural" scrolling on).
    inverted: bool = false,
};

// kVK_* virtual key code to HID usage (keyboard page 0x07). 0: unmapped.
const keymap: [128]u8 = blk: {
    var t = [_]u8{0} ** 128;
    const pairs = [_][2]u8{
        .{ 0x00, 0x04 }, .{ 0x01, 0x16 }, .{ 0x02, 0x07 }, .{ 0x03, 0x09 }, .{ 0x04, 0x0B }, // A S D F H
        .{ 0x05, 0x0A }, .{ 0x06, 0x1D }, .{ 0x07, 0x1B }, .{ 0x08, 0x06 }, .{ 0x09, 0x19 }, // G Z X C V
        .{ 0x0A, 0x64 }, .{ 0x0B, 0x05 }, .{ 0x0C, 0x14 }, .{ 0x0D, 0x1A }, .{ 0x0E, 0x08 }, // ISO § B Q W E
        .{ 0x0F, 0x15 }, .{ 0x10, 0x1C }, .{ 0x11, 0x17 }, // R Y T
        .{ 0x12, 0x1E }, .{ 0x13, 0x1F }, .{ 0x14, 0x20 }, .{ 0x15, 0x21 }, .{ 0x16, 0x23 }, // 1 2 3 4 6
        .{ 0x17, 0x22 }, .{ 0x18, 0x2E }, .{ 0x19, 0x26 }, .{ 0x1A, 0x24 }, .{ 0x1B, 0x2D }, // 5 = 9 7 -
        .{ 0x1C, 0x25 }, .{ 0x1D, 0x27 }, .{ 0x1E, 0x30 }, .{ 0x1F, 0x12 }, .{ 0x20, 0x18 }, // 8 0 ] O U
        .{ 0x21, 0x2F }, .{ 0x22, 0x0C }, .{ 0x23, 0x13 }, .{ 0x24, 0x28 }, .{ 0x25, 0x0F }, // [ I P Return L
        .{ 0x26, 0x0D }, .{ 0x27, 0x34 }, .{ 0x28, 0x0E }, .{ 0x29, 0x33 }, .{ 0x2A, 0x31 }, // J ' K ; \
        .{ 0x2B, 0x36 }, .{ 0x2C, 0x38 }, .{ 0x2D, 0x11 }, .{ 0x2E, 0x10 }, .{ 0x2F, 0x37 }, // , / N M .
        .{ 0x30, 0x2B }, .{ 0x31, 0x2C }, .{ 0x32, 0x35 }, .{ 0x33, 0x2A }, .{ 0x35, 0x29 }, // Tab Space ` Delete Esc
        .{ 0x36, 0xE7 }, .{ 0x37, 0xE3 }, .{ 0x38, 0xE1 }, .{ 0x39, 0x39 }, .{ 0x3A, 0xE2 }, // RCmd Cmd Shift Caps Opt
        .{ 0x3B, 0xE0 }, .{ 0x3C, 0xE5 }, .{ 0x3D, 0xE6 }, .{ 0x3E, 0xE4 }, // Ctrl RShift ROpt RCtrl
        .{ 0x40, 0x6C }, .{ 0x41, 0x63 }, .{ 0x43, 0x55 }, .{ 0x45, 0x57 }, .{ 0x47, 0x53 }, // F17 KP. KP* KP+ Clear
        .{ 0x48, 0x80 }, .{ 0x49, 0x81 }, .{ 0x4A, 0x7F }, // VolUp VolDown Mute
        .{ 0x4B, 0x54 }, .{ 0x4C, 0x58 }, .{ 0x4E, 0x56 }, .{ 0x4F, 0x6D }, .{ 0x50, 0x6E }, // KP/ KPEnter KP- F18 F19
        .{ 0x51, 0x67 }, .{ 0x52, 0x62 }, .{ 0x53, 0x59 }, .{ 0x54, 0x5A }, .{ 0x55, 0x5B }, // KP= KP0 KP1 KP2 KP3
        .{ 0x56, 0x5C }, .{ 0x57, 0x5D }, .{ 0x58, 0x5E }, .{ 0x59, 0x5F }, .{ 0x5A, 0x6F }, // KP4 KP5 KP6 KP7 F20
        .{ 0x5B, 0x60 }, .{ 0x5C, 0x61 }, .{ 0x5D, 0x89 }, .{ 0x5E, 0x87 }, .{ 0x5F, 0x85 }, // KP8 KP9 Yen _ KP,
        .{ 0x60, 0x3E }, .{ 0x61, 0x3F }, .{ 0x62, 0x40 }, .{ 0x63, 0x3C }, .{ 0x64, 0x41 }, // F5 F6 F7 F3 F8
        .{ 0x65, 0x42 }, .{ 0x66, 0x91 }, .{ 0x67, 0x44 }, .{ 0x68, 0x90 }, .{ 0x69, 0x68 }, // F9 Eisu F11 Kana F13
        .{ 0x6A, 0x6B }, .{ 0x6B, 0x69 }, .{ 0x6D, 0x43 }, .{ 0x6E, 0x65 }, .{ 0x6F, 0x45 }, // F16 F14 F10 Menu F12
        .{ 0x71, 0x6A }, .{ 0x72, 0x49 }, .{ 0x73, 0x4A }, .{ 0x74, 0x4B }, .{ 0x75, 0x4C }, // F15 Help/Ins Home PgUp Del
        .{ 0x76, 0x3D }, .{ 0x77, 0x4D }, .{ 0x78, 0x3B }, .{ 0x79, 0x4E }, .{ 0x7A, 0x3A }, // F4 End F2 PgDn F1
        .{ 0x7B, 0x50 }, .{ 0x7C, 0x4F }, .{ 0x7D, 0x51 }, .{ 0x7E, 0x52 }, // Left Right Down Up
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

/// The HID usage for a virtual key code, or null when it has none (Fn, unknown).
pub fn usage(key_code: u16) ?u16 {
    if (key_code >= keymap.len) return null;
    const u = keymap[key_code];
    return if (u == 0) null else u;
}

/// NSEventModifierFlags, device-independent.
pub const flag_caps_lock: u64 = 1 << 16;
pub const flag_shift: u64 = 1 << 17;
pub const flag_control: u64 = 1 << 18;
pub const flag_option: u64 = 1 << 19;
pub const flag_command: u64 = 1 << 20;

/// Device-dependent left/right bits (IOLLEvent.h NX_DEVICE*KEYMASK) in the low word.
const device_mask: u64 = 0x20FF;

/// Which flag bits say a modifier key is held: (key code, device-independent
/// bit, device-dependent bit for that side).
const modifiers = [_]struct { u16, u64, u64 }{
    .{ 0x3B, flag_control, 0x0001 }, // Control
    .{ 0x38, flag_shift, 0x0002 }, // Shift
    .{ 0x3C, flag_shift, 0x0004 }, // Right Shift
    .{ 0x37, flag_command, 0x0008 }, // Command
    .{ 0x36, flag_command, 0x0010 }, // Right Command
    .{ 0x3A, flag_option, 0x0020 }, // Option
    .{ 0x3D, flag_option, 0x0040 }, // Right Option
    .{ 0x3E, flag_control, 0x2000 }, // Right Control
};

const caps_lock_code: u16 = 0x39;

/// State across events: which modifier keys are down (flags-changed events
/// say only what the flags are now) and the fractions of motion and scroll
/// not sent yet.
pub const State = struct {
    /// Modifier keys held, by index into `modifiers`.
    held: u8 = 0,
    rem_x: f64 = 0,
    rem_y: f64 = 0,
    scroll_rem_x: f64 = 0,
    scroll_rem_y: f64 = 0,

    /// Whether a flags-changed event for modifier `i` means it went down. With
    /// device-dependent bits present (real keyboards) they say it; synthetic
    /// events often carry only the device-independent bit, so then a set bit
    /// is a press of whichever side is not held yet, a clear one a release.
    fn modifierDown(s: *const State, i: usize, flags: u64) bool {
        const m = modifiers[i];
        if (flags & m[1] == 0) return false;
        if (flags & device_mask != 0) return flags & m[2] != 0;
        return s.held & (@as(u8, 1) << @intCast(i)) == 0;
    }
};

/// Most events one record can produce (Caps Lock: down and up).
pub const max_events = 2;

/// Wheel units per line of scroll (one notch), as on Windows.
pub const units_per_line = 120;
/// Points of precise (trackpad) scroll that make one line.
pub const points_per_line = 10.0;

/// The events for one record, in order, written to `out`; returns how many.
///
/// Keys: key repeats are dropped (the host's OS repeats a held key itself).
/// Caps Lock reports a flags change on each press and nothing on release, so
/// each change goes out as a down then an up, which toggles the host's lock.
///
/// Motion: NSEvent deltas are points and may be fractional (high-resolution
/// mice and trackpads); fractions carry over to the next event so slow motion
/// isn't lost. Positive dy is down, as with Raw Input.
///
/// Scroll: 120 per line, positive away from the user (dy) or to the right
/// (dx), the Windows wheel convention. NSEvent's deltas are positive for up
/// and left with natural scrolling off, and flipped with it on, so they are
/// turned back to the device's direction first.
pub fn translate(s: *State, r: Record, out: *[max_events]What) usize {
    switch (r.kind) {
        .key_down, .key_up => {
            if (r.kind == .key_down and r.repeat) return 0;
            const u = usage(r.key_code) orelse return 0;
            out[0] = .{ .key = .{ .code = u, .down = r.kind == .key_down } };
            return 1;
        },
        .flags_changed => {
            const u = usage(r.key_code) orelse return 0;
            if (r.key_code == caps_lock_code) {
                out[0] = .{ .key = .{ .code = u, .down = true } };
                out[1] = .{ .key = .{ .code = u, .down = false } };
                return 2;
            }
            for (modifiers, 0..) |m, i| {
                if (m[0] != r.key_code) continue;
                const bit = @as(u8, 1) << @intCast(i);
                const down = s.modifierDown(i, r.modifier_flags);
                const was = s.held & bit != 0;
                if (down == was) return 0;
                if (down) s.held |= bit else s.held &= ~bit;
                out[0] = .{ .key = .{ .code = u, .down = down } };
                return 1;
            }
            return 0;
        },
        .mouse_down, .mouse_up => {
            if (r.button > 31) return 0;
            out[0] = .{ .button = .{ .code = r.button + 1, .down = r.kind == .mouse_down } };
            return 1;
        },
        .mouse_move => {
            const dx = take(&s.rem_x, r.dx);
            const dy = take(&s.rem_y, r.dy);
            if (dx == 0 and dy == 0) return 0;
            out[0] = .{ .move_rel = .{ .dx = dx, .dy = dy } };
            return 1;
        },
        .scroll => {
            // Lines (or points) toward the device's own "up" and "left".
            var lx = r.dx;
            var ly = r.dy;
            if (r.inverted) {
                lx = -lx;
                ly = -ly;
            }
            if (r.precise) {
                lx /= points_per_line;
                ly /= points_per_line;
            }
            // Up is away from the user: positive. Left is negative.
            const dx = take(&s.scroll_rem_x, -lx * units_per_line);
            const dy = take(&s.scroll_rem_y, ly * units_per_line);
            if (dx == 0 and dy == 0) return 0;
            out[0] = .{ .scroll = .{ .dx = dx, .dy = dy } };
            return 1;
        },
        .quit => {
            out[0] = .quit;
            return 1;
        },
        _ => return 0,
    }
}

/// Adds `v` to the carried fraction `rem` and takes the whole part out.
fn take(rem: *f64, v: f64) i32 {
    if (!std.math.isFinite(v)) return 0;
    const total = rem.* + v;
    const whole = std.math.clamp(@trunc(total), -1e6, 1e6);
    rem.* = total - whole;
    return @intFromFloat(whole);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn one(s: *State, r: Record) ?What {
    var out: [max_events]What = undefined;
    const n = translate(s, r, &out);
    return if (n == 0) null else out[0];
}

test "letters, digits and navigation keys map to HID usages" {
    var s: State = .{};
    try testing.expectEqual(What{ .key = .{ .code = 0x04, .down = true } }, one(&s, .{ .kind = .key_down, .key_code = 0x00 }).?); // A
    try testing.expectEqual(What{ .key = .{ .code = 0x04, .down = false } }, one(&s, .{ .kind = .key_up, .key_code = 0x00 }).?);
    try testing.expectEqual(@as(u16, 0x1D), one(&s, .{ .kind = .key_down, .key_code = 0x06 }).?.key.code); // Z
    try testing.expectEqual(@as(u16, 0x27), one(&s, .{ .kind = .key_down, .key_code = 0x1D }).?.key.code); // 0
    try testing.expectEqual(@as(u16, 0x28), one(&s, .{ .kind = .key_down, .key_code = 0x24 }).?.key.code); // Return
    try testing.expectEqual(@as(u16, 0x58), one(&s, .{ .kind = .key_down, .key_code = 0x4C }).?.key.code); // KP Enter
    try testing.expectEqual(@as(u16, 0x2A), one(&s, .{ .kind = .key_down, .key_code = 0x33 }).?.key.code); // Delete = Backspace
    try testing.expectEqual(@as(u16, 0x4C), one(&s, .{ .kind = .key_down, .key_code = 0x75 }).?.key.code); // Forward Delete
    try testing.expectEqual(@as(u16, 0x52), one(&s, .{ .kind = .key_down, .key_code = 0x7E }).?.key.code); // Up
    try testing.expectEqual(@as(u16, 0x45), one(&s, .{ .kind = .key_down, .key_code = 0x6F }).?.key.code); // F12
}

test "every letter and digit is mapped once" {
    var seen = [_]bool{false} ** 256;
    for (keymap) |u| {
        if (u >= 0x04 and u <= 0x27) {
            try testing.expect(!seen[u]);
            seen[u] = true;
        }
    }
    for (0x04..0x28) |u| try testing.expect(seen[u]);
}

test "repeats, Fn and unknown codes are dropped" {
    var s: State = .{};
    try testing.expect(one(&s, .{ .kind = .key_down, .key_code = 0x00, .repeat = true }) == null);
    try testing.expect(one(&s, .{ .kind = .flags_changed, .key_code = 0x3F, .modifier_flags = 1 << 23 }) == null); // Fn
    try testing.expect(one(&s, .{ .kind = .key_down, .key_code = 0x7F }) == null);
    try testing.expect(one(&s, .{ .kind = .key_down, .key_code = 500 }) == null);
}

test "modifiers from flags changes, left and right apart" {
    var s: State = .{};
    // Left Shift down, Right Shift down, Left up, Right up (device bits as a real keyboard sends).
    try testing.expectEqual(What{ .key = .{ .code = 0xE1, .down = true } }, one(&s, .{ .kind = .flags_changed, .key_code = 0x38, .modifier_flags = flag_shift | 0x0002 | 0x100 }).?);
    try testing.expectEqual(What{ .key = .{ .code = 0xE5, .down = true } }, one(&s, .{ .kind = .flags_changed, .key_code = 0x3C, .modifier_flags = flag_shift | 0x0006 | 0x100 }).?);
    try testing.expectEqual(What{ .key = .{ .code = 0xE1, .down = false } }, one(&s, .{ .kind = .flags_changed, .key_code = 0x38, .modifier_flags = flag_shift | 0x0004 | 0x100 }).?);
    try testing.expectEqual(What{ .key = .{ .code = 0xE5, .down = false } }, one(&s, .{ .kind = .flags_changed, .key_code = 0x3C, .modifier_flags = 0x100 }).?);
    // Command, Option, Control.
    try testing.expectEqual(What{ .key = .{ .code = 0xE3, .down = true } }, one(&s, .{ .kind = .flags_changed, .key_code = 0x37, .modifier_flags = flag_command | 0x0008 }).?);
    try testing.expectEqual(What{ .key = .{ .code = 0xE6, .down = true } }, one(&s, .{ .kind = .flags_changed, .key_code = 0x3D, .modifier_flags = flag_command | flag_option | 0x0048 }).?);
    try testing.expectEqual(What{ .key = .{ .code = 0xE4, .down = true } }, one(&s, .{ .kind = .flags_changed, .key_code = 0x3E, .modifier_flags = flag_control | 0x2048 | flag_command | flag_option }).?);
    // The same state again is no change.
    try testing.expect(one(&s, .{ .kind = .flags_changed, .key_code = 0x3E, .modifier_flags = flag_control | 0x2048 | flag_command | flag_option }) == null);
}

test "modifiers without device bits (synthetic events)" {
    var s: State = .{};
    try testing.expect(one(&s, .{ .kind = .flags_changed, .key_code = 0x3B, .modifier_flags = flag_control }).?.key.down);
    try testing.expect(!one(&s, .{ .kind = .flags_changed, .key_code = 0x3B, .modifier_flags = 0 }).?.key.down);
}

test "Caps Lock: each change is a press and release" {
    var s: State = .{};
    var out: [max_events]What = undefined;
    try testing.expectEqual(@as(usize, 2), translate(&s, .{ .kind = .flags_changed, .key_code = 0x39, .modifier_flags = flag_caps_lock }, &out));
    try testing.expectEqual(What{ .key = .{ .code = 0x39, .down = true } }, out[0]);
    try testing.expectEqual(What{ .key = .{ .code = 0x39, .down = false } }, out[1]);
    try testing.expectEqual(@as(usize, 2), translate(&s, .{ .kind = .flags_changed, .key_code = 0x39, .modifier_flags = 0 }, &out));
}

test "mouse buttons are 1-based" {
    var s: State = .{};
    try testing.expectEqual(What{ .button = .{ .code = 1, .down = true } }, one(&s, .{ .kind = .mouse_down, .button = 0 }).?);
    try testing.expectEqual(What{ .button = .{ .code = 2, .down = false } }, one(&s, .{ .kind = .mouse_up, .button = 1 }).?);
    try testing.expectEqual(@as(u16, 4), one(&s, .{ .kind = .mouse_down, .button = 3 }).?.button.code); // back
}

test "fractional motion carries over" {
    var s: State = .{};
    try testing.expect(one(&s, .{ .kind = .mouse_move, .dx = 0.4, .dy = -0.4 }) == null);
    try testing.expectEqual(What{ .move_rel = .{ .dx = 1, .dy = -1 } }, one(&s, .{ .kind = .mouse_move, .dx = 0.7, .dy = -0.7 }).?);
    try testing.expectEqual(What{ .move_rel = .{ .dx = 5, .dy = 3 } }, one(&s, .{ .kind = .mouse_move, .dx = 4.9, .dy = 3.1 }).?);
    try testing.expect(one(&s, .{ .kind = .mouse_move, .dx = std.math.nan(f64), .dy = 0 }) == null);
}

test "scroll: lines and points to wheel units, device direction" {
    var s: State = .{};
    // A wheel notch up (away from the user), natural scrolling off.
    try testing.expectEqual(What{ .scroll = .{ .dx = 0, .dy = 120 } }, one(&s, .{ .kind = .scroll, .dy = 1 }).?);
    // The same notch with natural scrolling on: NSEvent reports it flipped.
    try testing.expectEqual(What{ .scroll = .{ .dx = 0, .dy = 120 } }, one(&s, .{ .kind = .scroll, .dy = -1, .inverted = true }).?);
    // Scrolling right: NSEvent dx is negative.
    try testing.expectEqual(What{ .scroll = .{ .dx = 120, .dy = 0 } }, one(&s, .{ .kind = .scroll, .dx = -1 }).?);
    // Trackpad: 5 points is half a line; two of them make one.
    try testing.expectEqual(What{ .scroll = .{ .dx = 0, .dy = -60 } }, one(&s, .{ .kind = .scroll, .dy = -5, .precise = true }).?);
    try testing.expectEqual(What{ .scroll = .{ .dx = 0, .dy = 1 } }, one(&s, .{ .kind = .scroll, .dy = 0.1, .precise = true }).?);
    try testing.expect(one(&s, .{ .kind = .scroll }) == null);
}

test "quit" {
    var s: State = .{};
    try testing.expectEqual(What.quit, one(&s, .{ .kind = .quit }).?);
}
