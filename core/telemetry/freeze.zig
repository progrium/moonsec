//! Freeze detector for the Phase 2 gate ("one hour without a freeze") and the soak.
//!
//! Feed it every present with the presented content's identity (the frame id, or the
//! frame number read back from the test pattern). A freeze is a stretch longer than
//! `threshold_us` without new content on screen: either nothing was presented, or what
//! was presented repeated old content (a stuck decoder, a repeated capture). It also keeps
//! counts of shorter stalls, since a stream that hitches every few seconds is not healthy
//! even if it never crosses the threshold.
//!
//! Sans-I/O: times are microseconds on any monotonic clock.
const std = @import("std");

pub const Micros = i64;

pub const Config = struct {
    /// A gap without new content longer than this is a freeze.
    threshold_us: Micros = 200_000,
    /// Gaps longer than these are counted as stalls (not freezes).
    stall_us: [2]Micros = .{ 50_000, 100_000 },
};

pub const Freeze = struct {
    /// When the last new content was shown before the freeze.
    start_us: Micros,
    duration_us: Micros,
};

pub const Stats = struct {
    presents: u64 = 0,
    /// Presents that showed content already shown (same id) or older content.
    repeats: u64 = 0,
    freezes: u64 = 0,
    frozen_us: Micros = 0,
    longest_gap_us: Micros = 0,
    /// Gaps longer than `stall_us[0]` and `stall_us[1]`.
    stalls: [2]u64 = .{ 0, 0 },
};

pub const Detector = struct {
    pub const keep = 16;

    cfg: Config,
    stats: Stats = .{},
    last_new_us: ?Micros = null,
    last_id: ?u64 = null,
    /// The most recent freezes, oldest first.
    recent: [keep]Freeze = undefined,
    recent_len: usize = 0,

    pub fn init(cfg: Config) Detector {
        return .{ .cfg = cfg };
    }

    /// A frame reached the screen at `now_us` showing content `id` (ids increase with
    /// newer content; they may skip).
    pub fn onPresent(d: *Detector, now_us: Micros, id: u64) void {
        d.stats.presents += 1;
        if (d.last_id) |l| if (id <= l) {
            d.stats.repeats += 1;
            return;
        };
        d.closeGap(now_us);
        d.last_id = id;
        d.last_new_us = now_us;
    }

    /// End of the run: a trailing stretch without new content counts too.
    pub fn finish(d: *Detector, now_us: Micros) void {
        d.closeGap(now_us);
        d.last_new_us = now_us;
    }

    /// Time since new content was last shown (0 before the first present).
    pub fn currentGap(d: *const Detector, now_us: Micros) Micros {
        return if (d.last_new_us) |t| now_us - t else 0;
    }

    fn closeGap(d: *Detector, now_us: Micros) void {
        const t = d.last_new_us orelse return;
        const gap = now_us - t;
        d.stats.longest_gap_us = @max(d.stats.longest_gap_us, gap);
        for (d.cfg.stall_us, 0..) |s, i| {
            if (gap > s) d.stats.stalls[i] += 1;
        }
        if (gap > d.cfg.threshold_us) {
            d.stats.freezes += 1;
            d.stats.frozen_us += gap;
            if (d.recent_len == keep) {
                std.mem.copyForwards(Freeze, d.recent[0 .. keep - 1], d.recent[1..keep]);
                d.recent_len -= 1;
            }
            d.recent[d.recent_len] = .{ .start_us = t, .duration_us = gap };
            d.recent_len += 1;
        }
    }

    pub fn recentFreezes(d: *const Detector) []const Freeze {
        return d.recent[0..d.recent_len];
    }
};

const testing = std.testing;

test "steady presents never freeze" {
    var d = Detector.init(.{});
    var t: Micros = 0;
    for (0..1000) |i| {
        d.onPresent(t, i);
        t += 16_667;
    }
    d.finish(t);
    try testing.expectEqual(@as(u64, 0), d.stats.freezes);
    try testing.expectEqual(@as(u64, 0), d.stats.stalls[0]);
    try testing.expect(d.stats.longest_gap_us <= 16_667);
}

test "a gap and a stuck picture both count" {
    var d = Detector.init(.{ .threshold_us = 100_000 });
    d.onPresent(0, 1);
    d.onPresent(16_000, 2);
    d.onPresent(200_000, 3); // 184 ms with nothing on screen
    // Repeats of frame 3 for 150 ms, then new content.
    d.onPresent(250_000, 3);
    d.onPresent(300_000, 3);
    d.onPresent(351_000, 4);
    d.onPresent(360_000, 5);
    d.finish(380_000);
    try testing.expectEqual(@as(u64, 2), d.stats.freezes);
    try testing.expectEqual(@as(u64, 2), d.stats.repeats);
    try testing.expectEqual(@as(Micros, 184_000), d.stats.longest_gap_us);
    try testing.expectEqual(@as(Micros, 184_000 + 151_000), d.stats.frozen_us);
    try testing.expectEqual(@as(u64, 2), d.stats.stalls[1]);
    const r = d.recentFreezes();
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqual(@as(Micros, 200_000), r[1].start_us);
}

test "trailing freeze is counted at finish" {
    var d = Detector.init(.{});
    d.onPresent(0, 0);
    try testing.expectEqual(@as(Micros, 500_000), d.currentGap(500_000));
    d.finish(500_000);
    try testing.expectEqual(@as(u64, 1), d.stats.freezes);
}
