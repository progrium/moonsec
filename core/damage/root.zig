//! Capture damage: which parts of the screen changed in each captured frame, on a fixed
//! grid of square cells (docs/design.md, "Damage tracking"; the lossless-tiles design).
//!
//! Capture backends report damage as rectangles in frame pixels (`Rect`, passed on
//! `api.CapturedFrame.damage`): null means "unknown, treat everything as changed", an
//! empty slice means "nothing changed". `Grid` folds those into per-cell state that every
//! consumer reads the same way:
//!   - lossless tiles (core/refine) use 64-pixel cells,
//!   - regional QP refinement (core/qpmap) uses 16-pixel blocks (a macroblock).
//! Each consumer keeps its own Grid at its own cell size and its own policy state; the
//! Grid only knows what changed when.
//!
//! Per cell it keeps `since`, the frame id of the last frame that damaged it (so the cell
//! has looked the same from `since` on), and a 64-frame history bitmask (bit 0 = the latest
//! applied frame) for the "low motion counts as still" rule.
//!
//! Sans-I/O. `init` allocates once; `apply` and every query are allocation-free. Builds for
//! wasm32 (the web client uses the same cell geometry to apply damage messages).
const std = @import("std");

/// A rectangle in frame pixels. Zero width or height covers nothing.
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn empty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }

    /// `r` cut to a `width` x `height` frame.
    pub fn clip(r: Rect, width: u32, height: u32) Rect {
        if (r.x >= width or r.y >= height) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{ .x = r.x, .y = r.y, .w = @min(r.w, width - r.x), .h = @min(r.h, height - r.y) };
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        if (a.empty() or b.empty()) return false;
        return a.x < b.x +| b.w and b.x < a.x +| a.w and a.y < b.y +| b.h and b.y < a.y +| a.h;
    }

    /// The smallest rectangle holding both (an empty one counts as nothing).
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.empty()) return b;
        if (b.empty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x +| a.w, b.x +| b.w);
        const y1 = @max(a.y +| a.h, b.y +| b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// How many frames of history each cell keeps.
pub const history_frames = 64;

/// "No frame yet": `since` of a cell that was never applied.
pub const never: u64 = std.math.maxInt(u64);

pub const Grid = struct {
    width: u32,
    height: u32,
    /// Cell edge in pixels; the right and bottom cells may be smaller.
    cell: u32,
    cols: u32,
    rows: u32,
    /// Per cell: the frame id of the last frame that damaged it (`never` before the first).
    since: []u64,
    /// Per cell: bit i set = the frame `last_frame - i` damaged it.
    history: []u64,
    /// The last frame id passed to `apply` (`never` before the first).
    last_frame: u64 = never,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, cell: u32) !Grid {
        std.debug.assert(cell > 0);
        const cols = std.math.divCeil(u32, width, cell) catch unreachable;
        const rows = std.math.divCeil(u32, height, cell) catch unreachable;
        const n = @as(usize, cols) * rows;
        const since = try allocator.alloc(u64, n);
        errdefer allocator.free(since);
        const history = try allocator.alloc(u64, n);
        @memset(since, never);
        @memset(history, 0);
        return .{ .width = width, .height = height, .cell = cell, .cols = cols, .rows = rows, .since = since, .history = history, .allocator = allocator };
    }

    pub fn deinit(g: *Grid) void {
        g.allocator.free(g.since);
        g.allocator.free(g.history);
        g.* = undefined;
    }

    /// Starts over at a new frame size (a mode change, a new display): every cell reads as
    /// never applied.
    pub fn resize(g: *Grid, width: u32, height: u32) !void {
        const fresh = try Grid.init(g.allocator, width, height, g.cell);
        g.deinit();
        g.* = fresh;
    }

    pub fn cells(g: *const Grid) u32 {
        return g.cols * g.rows;
    }

    /// The pixels cell `i` covers.
    pub fn cellRect(g: *const Grid, i: u32) Rect {
        const cx = i % g.cols;
        const cy = i / g.cols;
        const x = cx * g.cell;
        const y = cy * g.cell;
        return .{ .x = x, .y = y, .w = @min(g.cell, g.width - x), .h = @min(g.cell, g.height - y) };
    }

    /// The cell holding pixel (x, y), or null outside the frame.
    pub fn cellAt(g: *const Grid, x: u32, y: u32) ?u32 {
        if (x >= g.width or y >= g.height) return null;
        return (y / g.cell) * g.cols + x / g.cell;
    }

    /// Folds frame `frame_id`'s damage in. Frame ids increase; a skipped id counts as a
    /// frame with no damage. A repeated or older id only adds its damage to the latest
    /// frame's (it can't rewrite history). null damage marks every cell.
    pub fn apply(g: *Grid, frame_id: u64, damage: ?[]const Rect) void {
        if (g.last_frame == never or frame_id > g.last_frame) {
            const shift: u64 = if (g.last_frame == never) history_frames else frame_id - g.last_frame;
            if (shift >= history_frames) {
                @memset(g.history, 0);
            } else {
                const s: u6 = @intCast(shift);
                for (g.history) |*h| h.* <<= s;
            }
            g.last_frame = frame_id;
        }
        const id = g.last_frame;
        const rects = damage orelse {
            for (g.since, g.history) |*s, *h| {
                s.* = id;
                h.* |= 1;
            }
            return;
        };
        for (rects) |raw| {
            const r = raw.clip(g.width, g.height);
            if (r.empty()) continue;
            const c0 = r.x / g.cell;
            const c1 = (r.x + r.w - 1) / g.cell;
            const r0 = r.y / g.cell;
            const r1 = (r.y + r.h - 1) / g.cell;
            var cy = r0;
            while (cy <= r1) : (cy += 1) {
                var cx = c0;
                while (cx <= c1) : (cx += 1) {
                    const i = cy * g.cols + cx;
                    g.since[i] = id;
                    g.history[i] |= 1;
                }
            }
        }
    }

    /// Marks every cell changed at the latest frame (an unknown change, a resize upstream).
    pub fn invalidateAll(g: *Grid) void {
        g.apply(if (g.last_frame == never) 0 else g.last_frame, null);
    }

    /// Whether frame `frame_id` damaged cell `i`. Frames older than the history or newer
    /// than the latest read as false; use `since` for older questions.
    pub fn changedIn(g: *const Grid, i: u32, frame_id: u64) bool {
        if (g.last_frame == never or frame_id > g.last_frame) return false;
        const back = g.last_frame - frame_id;
        if (back >= history_frames) return g.since[i] == frame_id;
        return (g.history[i] >> @intCast(back)) & 1 != 0;
    }

    /// Whether cell `i` changed in any frame after `after` up to the latest. Exact for any
    /// `after`: it reads `since`.
    pub fn changedSince(g: *const Grid, i: u32, after: u64) bool {
        const s = g.since[i];
        return s != never and s > after;
    }

    /// Frames since cell `i` last changed, at frame `now` (0 = changed in `now`).
    /// A cell never damaged is treated as changed at the first applied frame.
    pub fn stillFrames(g: *const Grid, i: u32, now: u64) u64 {
        const s = g.since[i];
        if (s == never) return now;
        return now -| s;
    }

    /// Cell `i` has not changed for at least `after` frames at frame `now`.
    pub fn stillFor(g: *const Grid, i: u32, now: u64, after: u64) bool {
        return g.stillFrames(i, now) >= after;
    }

    /// How many of the last `window` frames (at most `history_frames`) damaged cell `i`.
    pub fn changesIn(g: *const Grid, i: u32, window: u32) u32 {
        const w = @min(window, history_frames);
        if (w == 0) return 0;
        const mask: u64 = if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
        return @popCount(g.history[i] & mask);
    }

    /// The "low motion counts as still" rule: cell `i` changed in at most a quarter of the
    /// last `window` frames (a blinking caret, a ticking clock).
    pub fn lowMotion(g: *const Grid, i: u32, window: u32) bool {
        const w = @min(window, history_frames);
        return g.changesIn(i, w) * 4 <= w;
    }
};

test "rect clip and intersect" {
    const r = Rect{ .x = 10, .y = 10, .w = 100, .h = 100 };
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 40, .h = 90 }, r.clip(50, 100));
    try std.testing.expect(r.clip(5, 5).empty());
    try std.testing.expect(r.intersects(.{ .x = 109, .y = 109, .w = 1, .h = 1 }));
    try std.testing.expect(!r.intersects(.{ .x = 110, .y = 0, .w = 5, .h = 500 }));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 10, .w = 110, .h = 105 }, r.unite(.{ .x = 0, .y = 100, .w = 1, .h = 15 }));
}

test "grid geometry and partial edge cells" {
    var g = try Grid.init(std.testing.allocator, 1920, 1080, 64);
    defer g.deinit();
    try std.testing.expectEqual(@as(u32, 30), g.cols);
    try std.testing.expectEqual(@as(u32, 17), g.rows);
    try std.testing.expectEqual(@as(u32, 510), g.cells());
    const last = g.cellRect(509);
    try std.testing.expectEqual(Rect{ .x = 1856, .y = 1024, .w = 64, .h = 56 }, last);
    try std.testing.expectEqual(@as(?u32, 509), g.cellAt(1919, 1079));
    try std.testing.expectEqual(@as(?u32, null), g.cellAt(1920, 0));
}

test "damage marks cells, history and since" {
    var g = try Grid.init(std.testing.allocator, 256, 128, 64);
    defer g.deinit();
    g.apply(1, null);
    for (0..g.cells()) |i| try std.testing.expectEqual(@as(u64, 1), g.since[i]);
    // A rect straddling cells 1 and 2 of the top row.
    g.apply(2, &.{.{ .x = 100, .y = 10, .w = 40, .h = 4 }});
    try std.testing.expectEqual(@as(u64, 2), g.since[1]);
    try std.testing.expectEqual(@as(u64, 2), g.since[2]);
    try std.testing.expectEqual(@as(u64, 1), g.since[0]);
    try std.testing.expect(g.changedIn(1, 2));
    try std.testing.expect(g.changedIn(1, 1));
    try std.testing.expect(!g.changedIn(0, 2));
    // Nothing changes for frames 3..10 (empty damage, and skipped ids).
    g.apply(3, &.{});
    g.apply(10, &.{});
    try std.testing.expect(g.stillFor(0, 10, 9));
    try std.testing.expect(!g.stillFor(1, 10, 9));
    try std.testing.expectEqual(@as(u64, 8), g.stillFrames(1, 10));
    try std.testing.expect(g.changedSince(1, 1));
    try std.testing.expect(!g.changedSince(1, 2));
    try std.testing.expect(!g.changedIn(1, 3));
    try std.testing.expect(g.changedIn(1, 2));
}

test "low motion: a caret blinking every 8th frame counts as still" {
    var g = try Grid.init(std.testing.allocator, 64, 64, 16);
    defer g.deinit();
    var f: u64 = 0;
    while (f < 64) : (f += 1) {
        const blink = f % 8 == 0;
        g.apply(f, if (blink) &.{.{ .x = 0, .y = 0, .w = 2, .h = 16 }} else &.{});
    }
    try std.testing.expectEqual(@as(u32, 8), g.changesIn(0, 64));
    try std.testing.expect(g.lowMotion(0, 64));
    try std.testing.expect(g.lowMotion(1, 64));
    // Busy: changing every other frame is not low motion.
    while (f < 128) : (f += 1) g.apply(f, if (f % 2 == 0) &.{.{ .x = 0, .y = 0, .w = 1, .h = 1 }} else &.{});
    try std.testing.expect(!g.lowMotion(0, 64));
}

test "history shifts out after 64 frames, since stays exact" {
    var g = try Grid.init(std.testing.allocator, 64, 64, 64);
    defer g.deinit();
    g.apply(5, &.{.{ .x = 0, .y = 0, .w = 1, .h = 1 }});
    g.apply(500, &.{});
    try std.testing.expectEqual(@as(u32, 0), g.changesIn(0, 64));
    try std.testing.expect(g.changedIn(0, 5));
    try std.testing.expect(!g.changedIn(0, 6));
    try std.testing.expectEqual(@as(u64, 495), g.stillFrames(0, 500));
}

test "resize starts over" {
    var g = try Grid.init(std.testing.allocator, 64, 64, 64);
    defer g.deinit();
    g.apply(1, null);
    try g.resize(200, 100);
    try std.testing.expectEqual(@as(u32, 4 * 2), g.cells());
    try std.testing.expectEqual(never, g.since[7]);
    try std.testing.expectEqual(never, g.last_frame);
}
