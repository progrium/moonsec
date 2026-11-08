//! Six-digit pairing PINs (spec/pairing-v0.md, "PIN").
const std = @import("std");

pub const len = 6;
pub const Pin = [len]u8;

/// A uniformly random PIN from caller-supplied random bytes (rejection sampling; the core
/// has no RNG). Returns null in the rare case all four candidates are rejected; draw again.
pub fn fromRandom(random: *const [16]u8) ?Pin {
    const limit: u32 = std.math.maxInt(u32) - std.math.maxInt(u32) % 1_000_000;
    var i: usize = 0;
    while (i < 16) : (i += 4) {
        const v = std.mem.readInt(u32, random[i..][0..4], .little);
        if (v >= limit) continue;
        var pin: Pin = undefined;
        var x = v % 1_000_000;
        var k: usize = len;
        while (k > 0) {
            k -= 1;
            pin[k] = '0' + @as(u8, @intCast(x % 10));
            x /= 10;
        }
        return pin;
    }
    return null;
}

/// Accepts what a person types: digits with optional spaces or dashes ("123 456", "123-456").
pub fn parse(text: []const u8) ?Pin {
    var pin: Pin = undefined;
    var n: usize = 0;
    for (text) |c| switch (c) {
        '0'...'9' => {
            if (n == len) return null;
            pin[n] = c;
            n += 1;
        },
        ' ', '-', '\t', '\r', '\n' => {},
        else => return null,
    };
    return if (n == len) pin else null;
}

/// "123 456", the way the host shows it.
pub fn display(pin: *const Pin) [len + 1]u8 {
    return (pin[0..3] ++ " " ++ pin[3..6]).*;
}

test "PINs are six digits and parse back from typed forms" {
    var r: [16]u8 = undefined;
    std.mem.writeInt(u32, r[0..4], 123_456 + 1_000_000 * 7, .little);
    const p = fromRandom(&r).?;
    try std.testing.expectEqualStrings("123456", &p);
    try std.testing.expectEqualStrings("123 456", &display(&p));
    try std.testing.expectEqual(p, parse("123 456").?);
    try std.testing.expectEqual(p, parse(" 123-456\n").?);
    try std.testing.expect(parse("12345") == null);
    try std.testing.expect(parse("1234567") == null);
    try std.testing.expect(parse("12a456") == null);
    // Leading zeros are kept.
    std.mem.writeInt(u32, r[0..4], 42, .little);
    try std.testing.expectEqualStrings("000042", &fromRandom(&r).?);
    // A rejected first draw falls through to the next word.
    std.mem.writeInt(u32, r[0..4], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, r[4..8], 999_999, .little);
    try std.testing.expectEqualStrings("999999", &fromRandom(&r).?);
    @memset(&r, 0xff);
    try std.testing.expect(fromRandom(&r) == null);
}
