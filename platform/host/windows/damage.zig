//! Desktop Duplication's move and dirty rectangles as frame damage (`api.CapturedFrame.damage`).
//! Plain Zig with no Windows imports, so `zig build test` checks it on any host.
const std = @import("std");
const core = @import("core");

pub const Rect = core.damage.Rect;

/// DXGI_OUTDUPL_MOVE_RECT: SourcePoint x, y; DestinationRect left, top, right, bottom.
pub const MoveRect = [6]i32;
/// RECT: left, top, right, bottom.
pub const DirtyRect = [4]i32;

/// A fixed list of rectangles cut to a frame; once it is full, the last one grows to cover
/// the rest (more than changed, never less).
pub const List = struct {
    buf: []Rect,
    n: usize = 0,
    width: u32,
    height: u32,

    /// Adds the rectangle from (x0, y0) up to (x1, y1), exclusive, cut to the frame.
    pub fn addEdges(l: *List, x0: i64, y0: i64, x1: i64, y1: i64) void {
        const cx0: u32 = @intCast(std.math.clamp(x0, 0, l.width));
        const cy0: u32 = @intCast(std.math.clamp(y0, 0, l.height));
        const cx1: u32 = @intCast(std.math.clamp(x1, 0, l.width));
        const cy1: u32 = @intCast(std.math.clamp(y1, 0, l.height));
        if (cx1 <= cx0 or cy1 <= cy0 or l.buf.len == 0) return;
        const r: Rect = .{ .x = cx0, .y = cy0, .w = cx1 - cx0, .h = cy1 - cy0 };
        if (l.n < l.buf.len) {
            l.buf[l.n] = r;
            l.n += 1;
        } else l.buf[l.n - 1] = l.buf[l.n - 1].unite(r);
    }

    pub fn slice(l: *const List) []const Rect {
        return l.buf[0..l.n];
    }
};

/// The damage of one duplicated frame: each move counts at its source and its destination,
/// then the dirty rectangles; cut to the width x height desktop image, into `out`.
pub fn fromDxgi(moves: []const MoveRect, dirty: []const DirtyRect, width: u32, height: u32, out: []Rect) []const Rect {
    var l: List = .{ .buf = out, .width = width, .height = height };
    for (moves) |m| {
        const w = @as(i64, m[4]) - m[2];
        const h = @as(i64, m[5]) - m[3];
        l.addEdges(m[0], m[1], @as(i64, m[0]) + w, @as(i64, m[1]) + h);
        l.addEdges(m[2], m[3], m[4], m[5]);
    }
    for (dirty) |d| l.addEdges(d[0], d[1], d[2], d[3]);
    return l.slice();
}

const testing = std.testing;

test "moves damage source and destination; dirty rects follow; all cut to the image" {
    var buf: [8]Rect = undefined;
    const moves = [_]MoveRect{.{ 100, 50, 120, 60, 220, 110 }}; // 100x50 from (100,50) to (120,60)
    const dirty = [_]DirtyRect{ .{ 0, 0, 10, 10 }, .{ 1900, 1070, 1930, 1090 }, .{ 5, 5, 5, 9 }, .{ -4, -4, 2, 3 } };
    const got = fromDxgi(&moves, &dirty, 1920, 1080, &buf);
    try testing.expectEqualSlices(Rect, &.{
        .{ .x = 100, .y = 50, .w = 100, .h = 50 },
        .{ .x = 120, .y = 60, .w = 100, .h = 50 },
        .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .x = 1900, .y = 1070, .w = 20, .h = 10 },
        .{ .x = 0, .y = 0, .w = 2, .h = 3 },
    }, got);
    // Nothing presented that changed pixels: an empty list, not unknown.
    try testing.expectEqual(@as(usize, 0), fromDxgi(&.{}, &.{}, 1920, 1080, &buf).len);
}

test "more rectangles than fit grow the last one" {
    var buf: [2]Rect = undefined;
    const dirty = [_]DirtyRect{ .{ 0, 0, 1, 1 }, .{ 10, 10, 11, 11 }, .{ 20, 5, 30, 6 }, .{ 15, 40, 16, 41 } };
    const got = fromDxgi(&.{}, &dirty, 100, 100, &buf);
    try testing.expectEqualSlices(Rect, &.{ .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 10, .y = 5, .w = 20, .h = 36 } }, got);
}
