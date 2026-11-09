//! Text conversions for the clipboard backends: UTF-16 with CRLF (Windows) <-> UTF-8 with LF
//! (the wire, spec/control-v0.md).
const std = @import("std");

/// UTF-16 (CRLF) to UTF-8 (LF). Unpaired surrogates become U+FFFD.
pub fn fromWide(gpa: std.mem.Allocator, wide: []const u16) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, wide.len);
    var i: usize = 0;
    while (i < wide.len) : (i += 1) {
        var cp: u21 = wide[i];
        if (cp == '\r' and i + 1 < wide.len and wide[i + 1] == '\n') continue;
        if (cp >= 0xd800 and cp <= 0xdbff and i + 1 < wide.len and wide[i + 1] >= 0xdc00 and wide[i + 1] <= 0xdfff) {
            cp = 0x10000 + ((cp - 0xd800) << 10) + (wide[i + 1] - 0xdc00);
            i += 1;
        } else if (cp >= 0xd800 and cp <= 0xdfff) cp = 0xfffd;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch unreachable;
        try out.appendSlice(gpa, enc[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// UTF-8 (LF) to NUL-terminated UTF-16 (CRLF). Invalid UTF-8 becomes U+FFFD.
pub fn toWide(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u16)) error{OutOfMemory}!void {
    try out.ensureTotalCapacity(gpa, text.len + 1);
    var i: usize = 0;
    var prev_cr = false;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp: u21 = if (i + len <= text.len) std.unicode.utf8Decode(text[i .. i + len]) catch 0xfffd else 0xfffd;
        i += if (i + len <= text.len) len else 1;
        if (cp == '\n' and !prev_cr) try out.append(gpa, '\r');
        prev_cr = cp == '\r';
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try out.append(gpa, @intCast(0xd800 + (v >> 10)));
            try out.append(gpa, @intCast(0xdc00 + (v & 0x3ff)));
        } else try out.append(gpa, @intCast(cp));
    }
    try out.append(gpa, 0);
}

test "UTF-8 <-> UTF-16 with line breaks" {
    const gpa = std.testing.allocator;
    var w: std.ArrayList(u16) = .empty;
    defer w.deinit(gpa);
    try toWide(gpa, "a\nb\r\nç😀", &w);
    try std.testing.expectEqualSlices(u16, &.{ 'a', '\r', '\n', 'b', '\r', '\n', 0xe7, 0xd83d, 0xde00, 0 }, w.items);
    const back = try fromWide(gpa, w.items[0 .. w.items.len - 1]);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("a\nb\nç😀", back);
    const lone = try fromWide(gpa, &.{ 'x', 0xd800, 'y' });
    defer gpa.free(lone);
    try std.testing.expectEqualStrings("x\u{fffd}y", lone);
}
