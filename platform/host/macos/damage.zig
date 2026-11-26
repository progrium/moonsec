//! ScreenCaptureKit's dirty rectangles (SCStreamFrameInfoDirtyRects, in points of the
//! captured display) as frame damage in pixels (`api.CapturedFrame.damage`). Plain Zig, no
//! SDK, so `zig build test` checks it on any host.
const std = @import("std");
const core = @import("core");

pub const Rect = core.damage.Rect;

/// A CGRect: origin x, y and size w, h, in points (top-left origin, as SCK gives them).
pub const PointRect = struct { x: f64, y: f64, w: f64, h: f64 };

/// The display's `src_w` x `src_h` points fill the `width` x `height` frame (SCK scales
/// to fit; at the display's own pixel size the factor is its backing scale). Each rect
/// is scaled and rounded outwards, cut to the frame, into `out`; once `out` is full the
/// last one grows to cover the rest. Null (unknown) when the source size is unknown, when
/// its aspect differs from the frame's (letterboxed: the content does not fill it), or
/// when a rect reaches past the source (then they are not in its points after all).
pub fn fromPoints(rects: []const PointRect, src_w: f64, src_h: f64, width: u32, height: u32, out: []Rect) ?[]const Rect {
    if (!(src_w > 0 and src_h > 0) or width == 0 or height == 0 or out.len == 0) return null;
    const sx = @as(f64, @floatFromInt(width)) / src_w;
    const sy = @as(f64, @floatFromInt(height)) / src_h;
    if (@abs(sx - sy) > 0.01 * @max(sx, sy)) return null;
    const fw: f64 = @floatFromInt(width);
    const fh: f64 = @floatFromInt(height);
    var n: usize = 0;
    for (rects) |r| {
        if (!std.math.isFinite(r.x) or !std.math.isFinite(r.y) or !std.math.isFinite(r.w) or !std.math.isFinite(r.h)) return null;
        if (r.x + r.w > src_w + 1 or r.y + r.h > src_h + 1) return null;
        const x0 = std.math.clamp(@floor(r.x * sx), 0, fw);
        const y0 = std.math.clamp(@floor(r.y * sy), 0, fh);
        const x1 = std.math.clamp(@ceil((r.x + r.w) * sx), 0, fw);
        const y1 = std.math.clamp(@ceil((r.y + r.h) * sy), 0, fh);
        if (x1 <= x0 or y1 <= y0) continue;
        const px: Rect = .{
            .x = @intFromFloat(x0),
            .y = @intFromFloat(y0),
            .w = @as(u32, @intFromFloat(x1)) - @as(u32, @intFromFloat(x0)),
            .h = @as(u32, @intFromFloat(y1)) - @as(u32, @intFromFloat(y0)),
        };
        if (n < out.len) {
            out[n] = px;
            n += 1;
        } else out[n - 1] = out[n - 1].unite(px);
    }
    return out[0..n];
}

const testing = std.testing;

test "points scale by the backing factor and round outwards" {
    var buf: [4]Rect = undefined;
    // A 1512x982-point Retina display at its 3024x1964 pixels.
    const got = fromPoints(&.{
        .{ .x = 10, .y = 20, .w = 30, .h = 40 },
        .{ .x = 0.25, .y = 0.5, .w = 1, .h = 1 },
        .{ .x = 1500, .y = 980, .w = 12.5, .h = 2.5 },
        .{ .x = -2, .y = 0, .w = 4, .h = 0 },
    }, 1512, 982, 3024, 1964, &buf).?;
    try testing.expectEqualSlices(Rect, &.{
        .{ .x = 20, .y = 40, .w = 60, .h = 80 },
        .{ .x = 0, .y = 1, .w = 3, .h = 2 },
        .{ .x = 3000, .y = 1960, .w = 24, .h = 4 },
    }, got);
    // Rects past the display's points are not points: unknown, not misplaced.
    try testing.expect(fromPoints(&.{.{ .x = 2000, .y = 0, .w = 10, .h = 10 }}, 1512, 982, 3024, 1964, &buf) == null);
    // An idle frame: nothing changed.
    try testing.expectEqual(@as(usize, 0), fromPoints(&.{}, 1512, 982, 3024, 1964, &buf).?.len);
}

test "a downscaled stream, overflow, and the unknown cases" {
    var buf: [2]Rect = undefined;
    // 1920x1080 points streamed at 1280x720 (the rate ladder's resize).
    const got = fromPoints(&.{
        .{ .x = 0, .y = 0, .w = 3, .h = 3 },
        .{ .x = 300, .y = 300, .w = 3, .h = 3 },
        .{ .x = 600, .y = 150, .w = 3, .h = 3 },
    }, 1920, 1080, 1280, 720, &buf).?;
    try testing.expectEqualSlices(Rect, &.{ .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .{ .x = 200, .y = 100, .w = 202, .h = 102 } }, got);
    // No source size (a window), or letterboxed.
    try testing.expect(fromPoints(&.{}, 0, 0, 1280, 720, &buf) == null);
    try testing.expect(fromPoints(&.{}, 1920, 1200, 1280, 720, &buf) == null);
}
