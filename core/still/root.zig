//! Idle refinement (docs/design.md, "Refine when idle"): when the screen stops changing,
//! re-encode the same picture as a few P-frames with falling QP caps, so a still desktop
//! sharpens over its first few hundred milliseconds of stillness instead of staying as
//! soft as its last frame. The last step is marked a long-term reference, so a later loss
//! refreshes against the sharp picture.
//!
//! Sans-I/O. The host's capture stage tells it about new content and recovery frames, and
//! asks it, when capture produced nothing new, whether a refine step is due:
//!
//!   onContent(now)        a new captured picture went to the encoder (not a repeat)
//!   onRecovery(now)       an IDR or LTR refresh went out: sharpness is gone, start over
//!   due(now, ok)          the next step (QP cap, last?) when one should be encoded now;
//!                         `ok` is the rate side's go-ahead (`HostSession.refineOk`)
//!   onRefined(now)        that step was encoded and sent
//!   wakeAt()              when a step can next be due, for the capture wait
//!
//! "Still" means capture had nothing new: every backend signals it (Desktop Duplication's
//! timeout, ScreenCaptureKit's idle status, PipeWire sending no buffer). Capture damage
//! (stages 2 and 3) is not needed here.
const std = @import("std");

const Micros = i64;

pub const max_steps = 4;

pub const Config = struct {
    /// Stillness before the first step (about 9 frames at 60 fps).
    refine_after_us: Micros = 150_000,
    /// The QP caps, coarse to fine, on the H.264/HEVC scale. Each step codes only the
    /// residual the previous one left, so the steps get smaller; spreading the drop over
    /// a few frames keeps each one within a few frame budgets. Not 0: QP 0 is lossless
    /// only in High 4:4:4 Predictive, which most hardware decoders refuse.
    steps: [max_steps]u8 = .{ 24, 16, 8, 0 },
    /// How many of `steps` are used.
    n_steps: u8 = 3,
    /// Least time between two steps: one frame interval.
    step_gap_us: Micros = 16_667,

    pub fn forFps(fps: u32) Config {
        return .{ .step_gap_us = @divTrunc(1_000_000, @as(Micros, @max(fps, 1))) };
    }

    pub fn stepList(c: *const Config) []const u8 {
        return c.steps[0..@min(c.n_steps, max_steps)];
    }
};

pub const Step = struct {
    /// Which step, from 0.
    index: u8,
    /// The QP cap for this frame (`api.EncodeParams.refine_qp`).
    qp: u8,
    /// The sequence's last step: mark it a long-term reference.
    last: bool,
};

pub const Stats = struct {
    /// Refine frames encoded, and sequences that ran to their last step.
    steps: u64 = 0,
    sequences: u64 = 0,
    /// Sequences cut short by new content, and restarts after a recovery frame.
    interrupted: u64 = 0,
    restarts: u64 = 0,
    /// Times a step was due but the rate side said no (`due` with `ok` false).
    held: u64 = 0,
};

pub const Still = struct {
    cfg: Config = .{},
    /// When the last new picture went to the encoder; null before the first.
    content_us: ?Micros = null,
    /// The next step to encode; `cfg.n_steps` when the picture is clean.
    step: u8 = 0,
    last_step_us: ?Micros = null,
    stats: Stats = .{},

    pub fn init(cfg: Config) Still {
        return .{ .cfg = cfg };
    }

    /// A new picture went to the encoder (normal rate control).
    pub fn onContent(s: *Still, now: Micros) void {
        if (s.step > 0 and s.step < s.cfg.n_steps) s.stats.interrupted += 1;
        s.content_us = now;
        s.step = 0;
        s.last_step_us = null;
    }

    /// An IDR or LTR refresh went out (a join, a broken decoder, a loss): the picture is
    /// at normal quality again, so refine it again if the screen stays still.
    pub fn onRecovery(s: *Still, now: Micros) void {
        _ = now;
        if (s.step > 0) s.stats.restarts += 1;
        s.step = 0;
        s.last_step_us = null;
    }

    /// The step to encode now, if one is due: the screen has been still long enough, the
    /// sequence is not finished, a frame interval has passed since the previous step, and
    /// `ok` (the rate controller is not draining a queue or cutting for overuse).
    pub fn due(s: *Still, now: Micros, ok: bool) ?Step {
        const t = s.wakeAt() orelse return null;
        if (now < t) return null;
        if (!ok) {
            s.stats.held += 1;
            return null;
        }
        const list = s.cfg.stepList();
        return .{ .index = s.step, .qp = list[s.step], .last = s.step + 1 == list.len };
    }

    /// The step `due` returned was encoded and sent.
    pub fn onRefined(s: *Still, now: Micros) void {
        std.debug.assert(s.step < s.cfg.n_steps);
        s.step += 1;
        s.last_step_us = now;
        s.stats.steps += 1;
        if (s.step == s.cfg.n_steps) s.stats.sequences += 1;
    }

    /// When the next step can be due (if `ok`), or null when none is pending (no picture
    /// yet, or the current one is already refined).
    pub fn wakeAt(s: *const Still) ?Micros {
        const c = s.content_us orelse return null;
        if (s.step >= s.cfg.stepList().len) return null;
        var t = c + s.cfg.refine_after_us;
        if (s.last_step_us) |l| t = @max(t, l + s.cfg.step_gap_us);
        return t;
    }

    /// When the screen last changed (host time), null before the first picture.
    pub fn stillSince(s: *const Still) ?Micros {
        return s.content_us;
    }

    /// How long the screen has been still; 0 before the first picture.
    pub fn stillFor(s: *const Still, now: Micros) Micros {
        const c = s.content_us orelse return 0;
        return @max(0, now - c);
    }

    /// A sequence is under way (some steps sent, more to come).
    pub fn refining(s: *const Still) bool {
        return s.step > 0 and s.step < s.cfg.stepList().len;
    }

    /// Every step went out since the last new picture or recovery frame.
    pub fn clean(s: *const Still) bool {
        return s.content_us != null and s.step >= s.cfg.stepList().len;
    }
};

const testing = std.testing;

test "steps start after refine_after, one frame apart, and the last is marked" {
    var s: Still = .init(.{});
    try testing.expectEqual(@as(?Step, null), s.due(0, true));
    s.onContent(1_000_000);
    try testing.expectEqual(@as(?Step, null), s.due(1_100_000, true));
    try testing.expectEqual(@as(?Micros, 1_150_000), s.wakeAt());
    const a = s.due(1_150_000, true).?;
    try testing.expectEqual(@as(u8, 24), a.qp);
    try testing.expect(!a.last);
    s.onRefined(1_150_000);
    try testing.expect(s.refining());
    try testing.expectEqual(@as(?Step, null), s.due(1_160_000, true));
    const b = s.due(1_166_667, true).?;
    try testing.expectEqual(@as(u8, 16), b.qp);
    s.onRefined(1_166_667);
    const c = s.due(1_200_000, true).?;
    try testing.expectEqual(@as(u8, 8), c.qp);
    try testing.expect(c.last);
    s.onRefined(1_200_000);
    try testing.expect(s.clean());
    try testing.expect(!s.refining());
    try testing.expectEqual(@as(?Step, null), s.due(5_000_000, true));
    try testing.expectEqual(@as(?Micros, null), s.wakeAt());
    try testing.expectEqual(@as(u64, 3), s.stats.steps);
    try testing.expectEqual(@as(u64, 1), s.stats.sequences);
    try testing.expectEqual(@as(Micros, 4_000_000), s.stillFor(5_000_000));
}

test "new content stops the sequence; a recovery frame restarts it" {
    var s: Still = .init(.{});
    s.onContent(0);
    _ = s.due(200_000, true).?;
    s.onRefined(200_000);
    s.onContent(210_000);
    try testing.expectEqual(@as(u64, 1), s.stats.interrupted);
    try testing.expectEqual(@as(?Step, null), s.due(300_000, true));
    try testing.expectEqual(@as(u8, 24), s.due(360_000, true).?.qp);
    // Run it to the end, then an IDR (a join): refine again, from the coarsest step.
    for (0..3) |i| {
        const now: Micros = 360_000 + @as(Micros, @intCast(i)) * 20_000;
        _ = s.due(now, true).?;
        s.onRefined(now);
    }
    try testing.expect(s.clean());
    s.onRecovery(500_000);
    try testing.expectEqual(@as(u64, 1), s.stats.restarts);
    // Still for long enough already: the first step is due at once.
    try testing.expectEqual(@as(u8, 24), s.due(500_000, true).?.qp);
}

test "held while the rate side says no, then resumes where it was" {
    var s: Still = .init(.{});
    s.onContent(0);
    try testing.expectEqual(@as(?Step, null), s.due(150_000, false));
    try testing.expectEqual(@as(u64, 1), s.stats.held);
    try testing.expectEqual(@as(u8, 0), s.due(400_000, true).?.index);
}

test "config for a frame rate" {
    const c = Config.forFps(30);
    try testing.expectEqual(@as(Micros, 33_333), c.step_gap_us);
    try testing.expectEqualSlices(u8, &.{ 24, 16, 8 }, c.stepList());
}
