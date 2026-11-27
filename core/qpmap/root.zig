//! Regional refine (design "Lossless tiles and idle refinement for sharp remote text",
//! stage 2): per-block QP offsets that sharpen the still parts of a screen inside the
//! normal stream, so a ticking clock or a video in one corner doesn't keep the text next
//! to it soft. The idea is Selkies' paint-over ledger, fitted to our single encode with
//! LTRs: one encoder, one map per frame, no encoder per stripe.
//!
//! The `Ledger` keeps one entry per encoder block (16×16 macroblocks for H.264, the
//! encoder's CTB for HEVC: the block size comes from the encoder, so there is no
//! aggregation) and reads stillness from a `core.damage.Grid` over the same blocks:
//!
//!   - Damage resets a block to coarse.
//!   - A block that has been still for `refine_after` frames, or that changed in at most a
//!     quarter of its last 4 × `refine_after` frames (low motion: a blinking caret), is a
//!     candidate. Candidates get `steps[0]`, then `steps[1]`, ... on successive coded
//!     frames: each is a QP offset (negative = finer) on top of the rate controller's QP.
//!     A block that has been coded at every step is clean and gets no offset, so it codes
//!     as a skip against its sharp reference.
//!   - At most 1/`pace` of the blocks get an offset per frame (Selkies' 1/64), taken in
//!     raster order from a cursor that rotates, so every block gets its turn.
//!   - A frame the encoder dropped, or one coded while the rate controller was cutting
//!     (`Outcome.constrained`), doesn't advance anything: those blocks are redone later.
//!     A keyframe or a refresh against an older LTR (`reset`) makes every block coarse.
//!
//! The host calls `observe` for every captured frame (repeats with empty damage), `plan`
//! before each encode, and `commit` with what happened to that frame. Whole-screen
//! stillness is stage 1's job (core/still): the host doesn't plan a map on its refine
//! frames. Sans-I/O; allocates only in `init`.
const std = @import("std");
const damage = @import("../damage/root.zig");

pub const Rect = damage.Rect;

pub const max_steps = 4;

pub const Config = struct {
    /// Frames a block must be still before it is refined (150 ms at 60 fps).
    refine_after: u32 = 9,
    /// Also refine blocks that changed in at most a quarter of their last
    /// 4 × `refine_after` frames (capped at 63).
    low_motion: bool = true,
    /// QP offsets of the refine steps, coarse to fine, on the H.264/HEVC QP scale.
    steps: [max_steps]i8 = .{ -6, -12, 0, 0 },
    n_steps: u8 = 2,
    /// At most 1/`pace` of the blocks get an offset per frame (at least one).
    pace: u32 = 64,
    /// Most horizontal runs of offset blocks in one map; 0 = no limit. For encoders that
    /// take rectangles rather than a per-block map (VAAPI ROI): each run is one rectangle.
    max_regions: u32 = 0,
};

/// One frame's map, valid until the next `plan` or `commit`.
pub const Map = struct {
    block: u32,
    cols: u32,
    rows: u32,
    /// cols × rows offsets in raster order.
    offsets: []const i8,
};

pub const Outcome = enum {
    /// Coded with the map.
    coded,
    /// The encoder dropped the frame.
    dropped,
    /// Coded, but while the rate controller was cutting: the blocks may have come out
    /// coarse, so they are redone later.
    constrained,
    /// It came out a keyframe (an IDR, or the first frame): everything is coarse again.
    keyframe,
};

pub const Ledger = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    grid: damage.Grid,
    /// Steps done per block: 0 = coarse, `n_steps` = clean.
    state: []u8,
    offsets: []i8,
    /// Blocks with an offset in the current plan.
    picked: []u32,
    n_picked: usize = 0,
    cursor: usize = 0,
    frame: u64 = 0,
    stats: Stats = .{},

    pub const Stats = struct {
        /// Frames planned with a map, and block offsets handed out.
        maps: u64 = 0,
        block_offsets: u64 = 0,
        /// Block steps that were coded (advanced), and maps not committed as coded.
        steps_coded: u64 = 0,
        maps_lost: u64 = 0,
        resets: u64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, block: u32, cfg: Config) !Ledger {
        std.debug.assert(block > 0 and cfg.n_steps > 0 and cfg.n_steps <= max_steps);
        var grid = try damage.Grid.init(gpa, width, height, block);
        errdefer grid.deinit();
        const n = grid.cols * grid.rows;
        const state = try gpa.alloc(u8, n);
        errdefer gpa.free(state);
        const offsets = try gpa.alloc(i8, n);
        errdefer gpa.free(offsets);
        const picked = try gpa.alloc(u32, n);
        @memset(state, 0);
        @memset(offsets, 0);
        return .{ .gpa = gpa, .cfg = cfg, .grid = grid, .state = state, .offsets = offsets, .picked = picked };
    }

    pub fn deinit(l: *Ledger) void {
        l.grid.deinit();
        l.gpa.free(l.state);
        l.gpa.free(l.offsets);
        l.gpa.free(l.picked);
    }

    pub fn blockSize(l: *const Ledger) u32 {
        return l.grid.cell;
    }

    pub fn len(l: *const Ledger) usize {
        return l.state.len;
    }

    /// The next captured frame's damage, in frame pixels: null is unknown (everything
    /// changed), empty is nothing (a repeat).
    pub fn observe(l: *Ledger, dmg: ?[]const Rect) void {
        l.frame += 1;
        l.grid.apply(l.frame, dmg);
        for (l.state, 0..) |*s, i| {
            if (l.grid.changedIn(@intCast(i), l.frame)) s.* = 0;
        }
    }

    fn eligible(l: *const Ledger, i: usize) bool {
        if (l.state[i] >= l.cfg.n_steps) return false;
        const c: u32 = @intCast(i);
        if (l.grid.stillFor(c, l.frame, l.cfg.refine_after)) return true;
        if (!l.cfg.low_motion) return false;
        // Low motion only counts once the block has a full window of history.
        const window = @min(4 * l.cfg.refine_after, 63);
        return l.frame >= window and l.grid.lowMotion(c, window);
    }

    fn clearPicks(l: *Ledger) void {
        for (l.picked[0..l.n_picked]) |i| l.offsets[i] = 0;
        l.n_picked = 0;
    }

    /// The map for the frame about to be encoded, or null when no block needs refining
    /// or `allow` is false (the rate controller is cutting, the path is stalled, stage 1
    /// is refining the whole screen, or the frame is forced).
    pub fn plan(l: *Ledger, allow: bool) ?Map {
        l.clearPicks();
        if (!allow) return null;
        const n = l.state.len;
        const budget = @max(1, n / @max(l.cfg.pace, 1));
        const cols = l.grid.cols;
        var runs: u32 = 0;
        var last: ?usize = null;
        var k: usize = 0;
        while (k < n and l.n_picked < budget) : (k += 1) {
            const i = (l.cursor + k) % n;
            if (!l.eligible(i)) continue;
            const off = l.cfg.steps[l.state[i]];
            const extends = if (last) |p| p + 1 == i and i % cols != 0 and l.offsets[p] == off else false;
            if (!extends) {
                if (l.cfg.max_regions != 0 and runs == l.cfg.max_regions) break;
                runs += 1;
            }
            l.offsets[i] = off;
            l.picked[l.n_picked] = @intCast(i);
            l.n_picked += 1;
            last = i;
        }
        if (l.n_picked == 0) return null;
        l.cursor = (last.? + 1) % n;
        l.stats.maps += 1;
        l.stats.block_offsets += l.n_picked;
        return .{ .block = l.grid.cell, .cols = cols, .rows = l.grid.rows, .offsets = l.offsets };
    }

    /// What happened to the frame `plan` was last called for.
    pub fn commit(l: *Ledger, outcome: Outcome) void {
        switch (outcome) {
            .coded => {
                for (l.picked[0..l.n_picked]) |i| l.state[i] += 1;
                l.stats.steps_coded += l.n_picked;
            },
            .dropped, .constrained => if (l.n_picked > 0) {
                l.stats.maps_lost += 1;
            },
            .keyframe => l.reset(),
        }
        l.clearPicks();
    }

    /// Every block coarse again: a keyframe, or a refresh against an LTR older than the
    /// refinement.
    pub fn reset(l: *Ledger) void {
        @memset(l.state, 0);
        l.stats.resets += 1;
    }

    pub fn isClean(l: *const Ledger, i: usize) bool {
        return l.state[i] >= l.cfg.n_steps;
    }

    pub fn cleanCount(l: *const Ledger) usize {
        var c: usize = 0;
        for (l.state) |s| c += @intFromBool(s >= l.cfg.n_steps);
        return c;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn blockIndex(l: *const Ledger, x: u32, y: u32) usize {
    return (y / l.grid.cell) * l.grid.cols + x / l.grid.cell;
}

test "still blocks next to a moving region refine and become clean; moving ones never" {
    // 256×128 at 16 px: 16×8 blocks. A "video" plays in the top-left 64×32 every frame.
    var l = try Ledger.init(testing.allocator, 256, 128, 16, .{ .pace = 8 });
    defer l.deinit();
    const video = [_]Rect{.{ .x = 0, .y = 0, .w = 64, .h = 32 }};
    var frames: u32 = 0;
    var first_map: ?u32 = null;
    while (frames < 200) : (frames += 1) {
        l.observe(if (frames == 0) null else &video);
        const m = l.plan(true) orelse {
            l.commit(.coded);
            continue;
        };
        if (first_map == null) first_map = frames;
        try testing.expectEqual(@as(u32, 16), m.cols);
        var nonzero: usize = 0;
        for (m.offsets, 0..) |o, i| {
            if (o == 0) continue;
            nonzero += 1;
            const x = (i % m.cols) * 16;
            const y = (i / m.cols) * 16;
            try testing.expect(!(x < 64 and y < 32)); // never inside the video
            try testing.expect(o == -6 or o == -12);
        }
        try testing.expect(nonzero <= 128 / 8); // the pace
        l.commit(.coded);
    }
    // The first frame is all damage, so nothing refines before refine_after frames of stillness.
    try testing.expectEqual(@as(?u32, 9), first_map);
    // 128 blocks, 8 of them video: the other 120 are clean.
    try testing.expectEqual(@as(usize, 120), l.cleanCount());
    // A clean screen asks for nothing.
    l.observe(&video);
    try testing.expectEqual(@as(?Map, null), l.plan(true));
}

test "damage makes a block coarse again; keyframes reset everything" {
    var l = try Ledger.init(testing.allocator, 64, 64, 16, .{ .pace = 1 });
    defer l.deinit();
    for (0..40) |_| {
        l.observe(&.{});
        _ = l.plan(true);
        l.commit(.coded);
    }
    try testing.expectEqual(@as(usize, 16), l.cleanCount());
    // A window moves over the top-right block.
    l.observe(&.{.{ .x = 50, .y = 3, .w = 4, .h = 4 }});
    try testing.expect(!l.isClean(blockIndex(&l, 50, 3)));
    try testing.expectEqual(@as(usize, 15), l.cleanCount());
    l.commit(.keyframe);
    try testing.expectEqual(@as(usize, 0), l.cleanCount());
    // Unknown damage is everything.
    for (0..40) |_| {
        l.observe(&.{});
        _ = l.plan(true);
        l.commit(.coded);
    }
    l.observe(null);
    try testing.expectEqual(@as(usize, 0), l.cleanCount());
}

test "dropped and constrained frames don't advance; disallowed frames get no map" {
    var l = try Ledger.init(testing.allocator, 32, 16, 16, .{ .pace = 1, .refine_after = 2 });
    defer l.deinit();
    for (0..3) |_| l.observe(&.{});
    try testing.expectEqual(@as(?Map, null), l.plan(false));
    _ = l.plan(true).?;
    l.commit(.dropped);
    _ = l.plan(true).?;
    l.commit(.constrained);
    try testing.expectEqual(@as(usize, 0), l.cleanCount());
    try testing.expectEqual(@as(u64, 2), l.stats.maps_lost);
    // Two steps per block, both blocks in each map (budget 2/1): two coded maps.
    for (0..2) |_| {
        l.observe(&.{});
        try testing.expect(l.plan(true) != null);
        l.commit(.coded);
    }
    try testing.expectEqual(@as(usize, 2), l.cleanCount());
    l.observe(&.{});
    try testing.expectEqual(@as(?Map, null), l.plan(true));
}

test "low motion: a blinking caret's block still refines" {
    var l = try Ledger.init(testing.allocator, 64, 16, 16, .{ .pace = 1, .refine_after = 8 });
    defer l.deinit();
    const caret = [_]Rect{.{ .x = 20, .y = 2, .w = 2, .h = 12 }}; // block 1
    var refined_caret = false;
    for (0..200) |f| {
        l.observe(if (f % 16 == 0) &caret else &.{});
        if (l.plan(true)) |m| {
            if (m.offsets[1] != 0) refined_caret = true;
        }
        l.commit(.coded);
    }
    try testing.expect(refined_caret);
    // Without the low-motion rule it refines only between blinks, once it's been still for 8.
    var strict = try Ledger.init(testing.allocator, 64, 16, 16, .{ .pace = 1, .refine_after = 8, .low_motion = false });
    defer strict.deinit();
    var busy = false;
    for (0..200) |f| {
        strict.observe(if (f % 4 == 0) &caret else &.{});
        if (strict.plan(true)) |m| {
            if (m.offsets[1] != 0) busy = true;
        }
        strict.commit(.coded);
    }
    try testing.expect(!busy);
}

test "max_regions bounds the runs of a map" {
    // 8×8 blocks, the middle column moving: every row splits into two runs.
    var l = try Ledger.init(testing.allocator, 128, 128, 16, .{ .pace = 1, .max_regions = 3 });
    defer l.deinit();
    const bar = [_]Rect{.{ .x = 64, .y = 0, .w = 16, .h = 128 }};
    for (0..9) |_| l.observe(&bar);
    l.cfg.pace = 1; // budget: all blocks
    const m = l.plan(true).?;
    var runs: u32 = 0;
    for (m.offsets, 0..) |o, i| {
        if (o == 0) continue;
        if (i % m.cols == 0 or m.offsets[i - 1] != o) runs += 1;
    }
    try testing.expectEqual(@as(u32, 3), runs);
}
