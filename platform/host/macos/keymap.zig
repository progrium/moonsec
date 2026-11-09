//! USB HID keyboard usages (page 7, what `core.input` carries) to macOS virtual key
//! codes (`kVK_*` in HIToolbox/Events.h). Virtual key codes name physical positions on
//! an ANSI keyboard, like HID usages, so the map is layout-independent: the host's
//! keyboard layout turns them into characters. Pure Zig, tested on every OS.
const std = @import("std");

/// The virtual key code for a HID usage, or null when macOS has no key for it.
pub fn toKeyCode(usage: u16) ?u16 {
    if (usage >= table.len) return null;
    const k = table[usage];
    return if (k == none) null else k;
}

const none: u16 = 0xFFFF;

const table: [256]u16 = blk: {
    var t: [256]u16 = @splat(none);
    // Letters a..z (0x04..0x1D).
    const letters = [26]u16{
        0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // a..m
        0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // n..z
    };
    for (letters, 0..) |k, i| t[0x04 + i] = k;
    // 1..9, 0 (0x1E..0x27).
    const digits = [10]u16{ 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D };
    for (digits, 0..) |k, i| t[0x1E + i] = k;
    t[0x28] = 0x24; // Return
    t[0x29] = 0x35; // Escape
    t[0x2A] = 0x33; // Backspace (kVK_Delete)
    t[0x2B] = 0x30; // Tab
    t[0x2C] = 0x31; // Space
    t[0x2D] = 0x1B; // -
    t[0x2E] = 0x18; // =
    t[0x2F] = 0x21; // [
    t[0x30] = 0x1E; // ]
    t[0x31] = 0x2A; // backslash
    t[0x32] = 0x2A; // non-US # (same position as backslash on ISO boards)
    t[0x33] = 0x29; // ;
    t[0x34] = 0x27; // '
    t[0x35] = 0x32; // `
    t[0x36] = 0x2B; // ,
    t[0x37] = 0x2F; // .
    t[0x38] = 0x2C; // /
    t[0x39] = 0x39; // Caps Lock
    // F1..F12 (0x3A..0x45).
    const fkeys = [12]u16{ 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F };
    for (fkeys, 0..) |k, i| t[0x3A + i] = k;
    // Print Screen, Scroll Lock and Pause sit where F13..F15 are on Apple keyboards.
    t[0x46] = 0x69;
    t[0x47] = 0x6B;
    t[0x48] = 0x71;
    t[0x49] = 0x72; // Insert -> Help
    t[0x4A] = 0x73; // Home
    t[0x4B] = 0x74; // Page Up
    t[0x4C] = 0x75; // Delete Forward
    t[0x4D] = 0x77; // End
    t[0x4E] = 0x79; // Page Down
    t[0x4F] = 0x7C; // Right
    t[0x50] = 0x7B; // Left
    t[0x51] = 0x7D; // Down
    t[0x52] = 0x7E; // Up
    t[0x53] = 0x47; // Num Lock -> Keypad Clear
    t[0x54] = 0x4B; // KP /
    t[0x55] = 0x43; // KP *
    t[0x56] = 0x4E; // KP -
    t[0x57] = 0x45; // KP +
    t[0x58] = 0x4C; // KP Enter
    // KP 1..9, 0 (0x59..0x62).
    const kp = [10]u16{ 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, 0x52 };
    for (kp, 0..) |k, i| t[0x59 + i] = k;
    t[0x63] = 0x41; // KP .
    t[0x64] = 0x0A; // non-US backslash (kVK_ISO_Section)
    t[0x65] = 0x6E; // Application / context menu
    t[0x67] = 0x51; // KP =
    // F13..F20 (0x68..0x6F); macOS has no F21..F24.
    const fhigh = [8]u16{ 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A };
    for (fhigh, 0..) |k, i| t[0x68 + i] = k;
    t[0x75] = 0x72; // Help
    t[0x7F] = 0x4A; // Mute
    t[0x80] = 0x48; // Volume Up
    t[0x81] = 0x49; // Volume Down
    t[0x85] = 0x5F; // KP , (JIS)
    t[0x87] = 0x5E; // International1 (JIS underscore / Ro)
    t[0x89] = 0x5D; // International3 (JIS yen)
    t[0x90] = 0x68; // Lang1 (Kana)
    t[0x91] = 0x66; // Lang2 (Eisu)
    // Modifiers (0xE0..0xE7): left ctrl, shift, alt, gui; right ctrl, shift, alt, gui.
    const mods = [8]u16{ 0x3B, 0x38, 0x3A, 0x37, 0x3E, 0x3C, 0x3D, 0x36 };
    for (mods, 0..) |k, i| t[0xE0 + i] = k;
    break :blk t;
};

const testing = std.testing;

test "HID usages map to macOS virtual key codes" {
    try testing.expectEqual(@as(?u16, 0x00), toKeyCode(0x04)); // a
    try testing.expectEqual(@as(?u16, 0x06), toKeyCode(0x1D)); // z
    try testing.expectEqual(@as(?u16, 0x12), toKeyCode(0x1E)); // 1
    try testing.expectEqual(@as(?u16, 0x1D), toKeyCode(0x27)); // 0
    try testing.expectEqual(@as(?u16, 0x24), toKeyCode(0x28)); // return
    try testing.expectEqual(@as(?u16, 0x7E), toKeyCode(0x52)); // up
    try testing.expectEqual(@as(?u16, 0x7A), toKeyCode(0x3A)); // F1
    try testing.expectEqual(@as(?u16, 0x6F), toKeyCode(0x45)); // F12
    try testing.expectEqual(@as(?u16, 0x37), toKeyCode(0xE3)); // left GUI -> command
    try testing.expectEqual(@as(?u16, 0x3D), toKeyCode(0xE6)); // right alt -> right option
    try testing.expectEqual(@as(?u16, null), toKeyCode(0x01));
    try testing.expectEqual(@as(?u16, null), toKeyCode(0x70)); // F21
    try testing.expectEqual(@as(?u16, null), toKeyCode(0x1234));
}

test "letters, digits and modifiers each get their own key" {
    var seen = std.StaticBitSet(128).initEmpty();
    var u: u16 = 0x04;
    while (u <= 0x27) : (u += 1) {
        const k = toKeyCode(u).?;
        try testing.expect(!seen.isSet(k));
        seen.set(k);
    }
    u = 0xE0;
    while (u <= 0xE7) : (u += 1) {
        const k = toKeyCode(u).?;
        try testing.expect(!seen.isSet(k));
        seen.set(k);
    }
}
