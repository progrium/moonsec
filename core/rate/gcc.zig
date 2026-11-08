//! Delay-based Google Congestion Control, ported from S11's `est.zig`, which
//! follows libwebrtc: InterArrivalDelta grouping with burst grouping,
//! TrendlineEstimator, the adaptive-threshold overuse detector and
//! AimdRateControl, plus a loss cap above 10% loss.
//!
//! Two additions make it the `gcc-hybrid` controller S11 recommends:
//!  - `onCapacity` lets the frame-train capacity estimate jump the rate up,
//!    the job WebRTC's padding probes do. Without it GCC ramps at 8%/s and
//!    holds 24–35% of capacity.
//!  - The standing-queue drain (`drain_us` > 0): a gradient detector can't
//!    see a queue that stopped growing, so an absolute check on the standing
//!    queue cuts the rate to drain it, with a hold for Wi-Fi stalls and
//!    bursts and a give-up for queues a loss-based flow keeps full.
//!
//! S11b's real-qdisc runs added three more, all on by default:
//!  - Competing-flow mode. When the drain gives up, a loss-based flow is
//!    holding a standing queue we can't drain. Until it leaves, a delay
//!    overuse cuts only if the queue grows `competing_margin_us` past the
//!    level it had when the drain gave up, each loss event cuts by `beta`,
//!    and the rate grows multiplicatively instead of creeping additively.
//!    Without it the trendline reads every Cubic sawtooth or BBR probe as
//!    overuse and slides to ~0.3x a fair share in a deep FIFO.
//!  - A loss rule below 10%: loss above `loss_high` while the queue is up
//!    (so random loss on an empty path doesn't count) cuts the rate to what
//!    is getting through. Stock GCC is otherwise loss-blind in a full
//!    shallow buffer and takes 1.6x its share at 9% loss.
//!  - `floor_bps`, set by the controller, keeps the rate where frames still
//!    carry enough packets for the train estimate.
const std = @import("std");
const types = @import("types.zig");
const PacketResult = types.PacketResult;
const Usage = types.Usage;
const AckedRate = @import("acked.zig").AckedRate;
const OwdTracker = @import("owd.zig").OwdTracker;

pub const Config = struct {
    /// Merge Wi-Fi style arrival bursts into one group. Without it,
    /// aggregation reads as overuse and halves the rate (S11).
    burst_grouping: bool = true,
    group_us: i64 = 5_000,
    window: usize = 20,
    smoothing: f64 = 0.9,
    threshold_gain: f64 = 4.0,
    k_up: f64 = 0.0087,
    k_down: f64 = 0.039,
    overuse_time_ms: f64 = 10.0,
    beta: f64 = 0.85,
    /// Per second, far from link capacity.
    mult_increase: f64 = 1.08,
    min_bps: f64 = 500_000,
    max_bps: f64 = 400_000_000,
    start_bps: f64 = 5_000_000,
    /// For the additive-increase response time and the drain spacing.
    rtt_us: i64 = 20_000,
    /// Blind startup: double every 100 ms until the first overuse.
    initial_ramp: bool = false,
    /// Standing-queue drain threshold; 0 turns the drain off.
    drain_us: f64 = 30_000,
    /// The queue must stay above the threshold this long before a cut, so
    /// Wi-Fi stalls and cross-traffic bursts that clear by themselves pass.
    drain_hold_us: i64 = 150_000,
    /// If the queue stays up this long despite our cuts, a loss-based flow is
    /// filling it: stop draining for `drain_off_us`, or the stream starves.
    /// 0 never gives up.
    drain_giveup_us: i64 = 1_500_000,
    drain_off_us: i64 = 10_000_000,
    /// Give up early when a drain isn't working: if the queue is still above
    /// `drain_stuck_frac` of its level at the episode's first cut this long
    /// after it, a loss-based flow is filling it. 0 = only `drain_giveup_us`.
    /// A capacity drop drains in 0.4–0.9 s (S11, S11b), so 600 ms leaves it
    /// alone; a Cubic flow's queue doesn't move, and every cut until the
    /// give-up is share handed to it.
    drain_stuck_us: i64 = 600_000,
    drain_stuck_frac: f64 = 0.75,
    acked_window_us: i64 = 500_000,
    /// Competing-flow mode after the drain gives up (S11b). Off restores
    /// S11's give-up, where the drain just switches off for `drain_off_us`.
    competing: bool = true,
    /// In competing mode, delay overuse cuts only when the standing queue is
    /// this far above the foreign flow's level.
    competing_margin_us: f64 = 20_000,
    /// Competing mode ends after this many loss windows in a row whose mean
    /// queueing is under `drain_us`: the other flow has left. (The 20 ms
    /// minimum dips well under a Cubic flow's queue at each of its backoffs,
    /// so the standing queue alone would end it too early.)
    competing_exit_windows: u32 = 2,
    /// After a loss cut in competing mode, the rate returns to where it was
    /// in about this long.
    competing_regain_us: i64 = 1_000_000,
    /// The other way in: `competing_overuses` delay cuts in a row within
    /// `competing_overuse_span_us`, with the standing queue never under
    /// `loss_queue_us` in between. Our own queue empties after a cut; one
    /// that doesn't is a flow like BBR, whose queue is too short for the
    /// drain's 30 ms but whose probes read as overuse. 0 = off.
    competing_overuses: u32 = 0,
    competing_overuse_span_us: i64 = 5_000_000,
    /// Leave competing mode this long after entering and let the drain test
    /// the queue again, so a false entry (a lone flow on a bufferbloated
    /// link) can't fill the buffer for good. If the queue is still foreign,
    /// the drain's early give-up re-enters within about 0.6 s and the
    /// rate from before the recheck is regained.
    competing_recheck_us: i64 = 20_000_000,
    /// Loss rule below the 10% cap: over `loss_window_us` (and at least 20
    /// packets), loss above `loss_high` with mean queueing above
    /// `loss_queue_us` cuts to (1 - loss/2) x the acked rate. 0 turns it off.
    loss_high: f64 = 0.02,
    loss_queue_us: f64 = 5_000,
    loss_window_us: i64 = 500_000,
    /// Train jump: target goes to `probe_factor` × the capacity estimate, at
    /// most `probe_max_mult` × the current rate, at most once per
    /// `probe_gap_us`, and not within `probe_quiet_us` of a decrease.
    probe_factor: f64 = 0.85,
    probe_max_mult: f64 = 3,
    probe_gap_us: i64 = 500_000,
    probe_quiet_us: i64 = 2_000_000,
    /// Share of the target the encoder actually sends (headroom for frame
    /// delay). Acked-rate rules divide by it so an app-limited stream isn't
    /// read as a smaller link and spiral down.
    app_share: f64 = 1.0,
    /// Max ever kept in the trendline window.
    pub const max_window = 64;
};

const Group = struct {
    first_send: i64 = -1,
    send: i64 = -1, // last send time in the group
    first_arr: i64 = -1,
    arr: i64 = -1, // last arrival in the group
    size: u64 = 0,

    fn complete(g: Group) bool {
        return g.first_send >= 0;
    }
};

pub const State = enum { hold, increase, decrease };

pub const Gcc = struct {
    cfg: Config,
    // inter-arrival grouping
    cur: Group = .{},
    prev: Group = .{},
    // trendline
    first_arr_ms: f64 = -1,
    acc_delay: f64 = 0,
    smoothed: f64 = 0,
    num_deltas: u32 = 0,
    hist_x: [Config.max_window]f64 = undefined,
    hist_y: [Config.max_window]f64 = undefined,
    hist_n: usize = 0,
    hist_head: usize = 0,
    // overuse detector
    threshold: f64 = 12.5,
    last_thr_update_ms: f64 = -1,
    time_over_ms: f64 = -1,
    overuse_count: u32 = 0,
    prev_trend: f64 = 0,
    usage: Usage = .normal,
    /// Modified trend (what the threshold is compared with), for telemetry.
    last_trend: f64 = 0,
    // AIMD
    state: State = .increase,
    bitrate: f64,
    link_cap: ?f64 = null, // kbit/s, exp. mean of the acked rate at overuse
    link_var: f64 = 0.4,
    last_change_us: i64 = -1,
    last_decrease_us: i64 = -1,
    in_ramp: bool,
    // loss
    loss_cap: f64 = std.math.inf(f64),
    win_sent: u32 = 0,
    win_lost: u32 = 0,
    win_start: i64 = -1,
    acked: AckedRate = .{},
    last_recv: i64 = 0,
    // train jump
    last_jump_us: i64 = -1,
    // standing-queue drain
    owd: OwdTracker = .{},
    last_drain_us: i64 = -1,
    over_since_us: i64 = -1,
    drain_off_until_us: i64 = -1,
    /// Highest standing queue while it was over the drain threshold: at a
    /// give-up, the foreign flow's level.
    over_max_us: f64 = 0,
    // competing-flow mode
    competing: bool = false,
    competing_level_us: f64 = 0,
    competing_low_windows: u32 = 0,
    competing_wmax: f64 = 0,
    competing_since_us: i64 = -1,
    recheck_bps: f64 = 0,
    recheck_us: i64 = -1,
    ou_streak: u32 = 0,
    ou_first_us: i64 = -1,
    ou_max_q: f64 = 0,
    drain_first_cut_us: i64 = -1,
    drain_first_q: f64 = 0,
    competing_last_cut_us: i64 = -1,
    // loss rule below 10%
    lw_sent: u32 = 0,
    lw_lost: u32 = 0,
    lw_q_sum: f64 = 0,
    lw_q_n: u32 = 0,
    lw_start: i64 = -1,
    batch_lost: u32 = 0,
    /// Probe frames (set by the controller): left out of the delay signals.
    probe_frames: [4]u32 = [_]u32{std.math.maxInt(u32)} ** 4,
    /// Lowest rate the controller keeps (train-estimate floor), 0 = none.
    floor_bps: f64 = 0,
    /// Last standing-queue reading, for telemetry.
    standing_us: ?f64 = null,
    // counters, for telemetry
    overuse_events: u32 = 0,
    drains: u32 = 0,
    jumps: u32 = 0,
    drain_giveups: u32 = 0,
    loss_cuts: u32 = 0,
    competing_cuts: u32 = 0,
    competing_entries: u32 = 0,

    pub fn init(cfg: Config) Gcc {
        std.debug.assert(cfg.window >= 2 and cfg.window <= Config.max_window);
        std.debug.assert(cfg.app_share > 0 and cfg.app_share <= 1);
        var g = Gcc{ .cfg = cfg, .bitrate = cfg.start_bps, .in_ramp = cfg.initial_ramp };
        g.acked.window_us = cfg.acked_window_us;
        return g;
    }

    /// The rate the controller allows, bits per second.
    pub fn target(self: *const Gcc) f64 {
        const lo = @max(self.cfg.min_bps, @min(self.floor_bps, self.cfg.max_bps));
        return std.math.clamp(@min(self.bitrate, self.loss_cap), lo, self.cfg.max_bps);
    }

    /// Keep the rate at or above `bps` (0 = no floor). The controller sets
    /// it so frames keep enough packets for the train estimate.
    pub fn setFloor(self: *Gcc, bps: f64) void {
        self.floor_bps = bps;
        if (bps > 0) self.bitrate = @max(self.bitrate, @min(bps, self.cfg.max_bps));
    }

    /// A capacity measurement from outside the delay detector (frame trains).
    /// Lets the rate jump up instead of creeping at 8%/s.
    pub fn onCapacity(self: *Gcc, now_us: i64, cap: f64) void {
        if (self.state != .increase) return;
        if (self.last_decrease_us >= 0 and now_us - self.last_decrease_us < self.cfg.probe_quiet_us) return;
        if (self.last_jump_us >= 0 and now_us - self.last_jump_us < self.cfg.probe_gap_us) return;
        const nr = @min(self.cfg.probe_factor * cap, self.cfg.probe_max_mult * self.bitrate);
        if (nr <= self.bitrate) return;
        self.bitrate = @min(nr, self.cfg.max_bps);
        self.in_ramp = false;
        self.last_jump_us = now_us;
        self.jumps += 1;
    }

    /// Feed one feedback batch, results in send order. `now_us` is the host
    /// clock when the feedback arrived.
    pub fn onFeedback(self: *Gcc, now_us: i64, rs: []const PacketResult) void {
        self.batch_lost = 0;
        for (rs) |r| {
            if (self.win_start < 0) self.win_start = now_us;
            if (self.lw_start < 0) self.lw_start = now_us;
            self.win_sent += 1;
            self.lw_sent += 1;
            if (!r.received()) {
                self.win_lost += 1;
                self.lw_lost += 1;
                self.batch_lost += 1;
                continue;
            }
            self.acked.add(r.recv_us, r.size);
            self.last_recv = @max(self.last_recv, r.recv_us);
            // A probe frame leaves at twice the link rate on purpose: the queue it
            // builds (and the next frame meets) is ours, short, and not congestion.
            if (self.isProbe(r.frame)) continue;
            self.owd.add(r);
            if (self.owd.baseOwd()) |b| {
                self.lw_q_sum += @floatFromInt(r.recv_us - r.send_us - b);
                self.lw_q_n += 1;
            }
            self.packet(r);
        }
        if (self.owd.standing()) |q| {
            self.standing_us = q;
            if (q < self.cfg.loss_queue_us) {
                self.ou_streak = 0;
                if (!self.competing) self.owd.thawBase();
            } else self.ou_max_q = @max(self.ou_max_q, q);
        }
        if (self.competing and self.cfg.competing_recheck_us > 0 and now_us - self.competing_since_us >= self.cfg.competing_recheck_us) {
            // Recheck: hand the queue back to the drain (the baseline stays frozen).
            // If the drain gives up again soon, re-entry restores this rate.
            self.recheck_bps = self.bitrate;
            self.recheck_us = now_us;
            self.competing = false;
            self.drain_off_until_us = now_us;
            self.over_since_us = -1;
        }
        self.updateLoss(now_us);
        if (self.competing) self.competingLoss(now_us) else self.lossRule(now_us);
        self.updateRate(now_us);
        if (self.cfg.drain_us > 0) self.drain(now_us);
        if (self.floor_bps > 0) self.bitrate = @max(self.bitrate, @min(self.floor_bps, self.cfg.max_bps));
    }

    /// A probe frame, or the frame after one, which can queue behind it.
    fn isProbe(self: *const Gcc, frame: u32) bool {
        for (self.probe_frames) |p| if (p != std.math.maxInt(u32) and (p == frame or p +% 1 == frame)) return true;
        return false;
    }

    /// In competing-flow mode, for telemetry.
    pub fn inCompetingMode(self: *const Gcc) bool {
        return self.competing;
    }

    // --- loss rule below 10% ------------------------------------------------

    fn cutTo(self: *Gcc, now_us: i64, factor: f64) bool {
        const a = if (self.acked.rate(self.last_recv)) |x| x / self.cfg.app_share else self.bitrate;
        const nr = @max(self.cfg.min_bps, @min(self.bitrate, a) * factor);
        if (nr >= self.bitrate) return false;
        self.bitrate = nr;
        self.last_decrease_us = now_us;
        self.state = .hold;
        self.in_ramp = false;
        return true;
    }

    fn lossRule(self: *Gcc, now_us: i64) void {
        if (now_us - self.lw_start < self.cfg.loss_window_us or self.lw_sent < 20) return;
        defer self.resetLossWindow(now_us);
        if (self.cfg.loss_high <= 0) return;
        const loss = @as(f64, @floatFromInt(self.lw_lost)) / @as(f64, @floatFromInt(self.lw_sent));
        if (loss <= self.cfg.loss_high or loss > 0.10) return; // above 10% the cap handles it
        const mean_q = if (self.lw_q_n > 0) self.lw_q_sum / @as(f64, @floatFromInt(self.lw_q_n)) else 0;
        if (mean_q < self.cfg.loss_queue_us) return; // random loss, not a full queue
        if (self.cutTo(now_us, 1 - 0.5 * loss)) self.loss_cuts += 1;
    }

    fn resetLossWindow(self: *Gcc, now_us: i64) void {
        self.lw_sent = 0;
        self.lw_lost = 0;
        self.lw_q_sum = 0;
        self.lw_q_n = 0;
        self.lw_start = now_us;
    }

    // --- competing-flow mode --------------------------------------------------

    /// Each loss event cuts by beta, at most once per queue-inflated RTT
    /// (the burst of drops one buffer overflow causes is one event).
    fn competingLoss(self: *Gcc, now_us: i64) void {
        if (now_us - self.lw_start >= self.cfg.loss_window_us) {
            const mean_q = if (self.lw_q_n > 0) self.lw_q_sum / @as(f64, @floatFromInt(self.lw_q_n)) else 0;
            self.competing_low_windows = if (mean_q < self.cfg.drain_us) self.competing_low_windows + 1 else 0;
            self.resetLossWindow(now_us);
            if (self.competing_low_windows >= self.cfg.competing_exit_windows) {
                // The other flow has left: back to normal, drain armed.
                self.competing = false;
                self.owd.thawBase();
                self.drain_off_until_us = now_us;
                self.over_since_us = -1;
                return;
            }
        }
        if (self.batch_lost == 0) return;
        const gap = self.cfg.rtt_us + @as(i64, @intFromFloat(self.standing_us orelse 0)) + 100_000;
        if (self.competing_last_cut_us >= 0 and now_us - self.competing_last_cut_us < gap) return;
        self.competing_last_cut_us = now_us;
        const before = self.bitrate;
        if (self.cutTo(now_us, self.cfg.beta)) {
            self.competing_cuts += 1;
            self.competing_wmax = before;
            // A loss cut is the other flow's sawtooth; keep growing at once.
            self.state = .increase;
        }
    }

    fn noteOveruseCut(self: *Gcc, now_us: i64) void {
        if (!self.cfg.competing or self.cfg.competing_overuses == 0 or self.competing) return;
        const q = self.standing_us orelse return;
        if (q < self.cfg.loss_queue_us) return;
        if (self.ou_streak == 0 or now_us - self.ou_first_us > self.cfg.competing_overuse_span_us) {
            self.ou_streak = 0;
            self.ou_first_us = now_us;
            self.ou_max_q = q;
        }
        self.ou_streak += 1;
        if (self.ou_streak >= self.cfg.competing_overuses) {
            self.ou_streak = 0;
            self.drain_off_until_us = now_us + self.cfg.drain_off_us;
            self.enterCompeting(now_us, self.ou_max_q);
        }
    }

    fn enterCompeting(self: *Gcc, now_us: i64, level_us: f64) void {
        // Hold the propagation baseline: under a standing foreign queue the 10 s
        // minimum would otherwise climb onto it, and the queue would seem to vanish.
        if (self.owd.frozen == null) self.owd.freezeBase();
        self.competing = true;
        self.competing_since_us = now_us;
        self.competing_level_us = level_us;
        self.competing_low_windows = 0;
        // Back from a recheck that found the foreign queue still there: regain the
        // rate the drain's cuts took, as after a loss cut.
        self.competing_wmax = if (self.recheck_us >= 0 and now_us - self.recheck_us < 3_000_000) self.recheck_bps else 0;
        self.recheck_us = -1;
        self.competing_entries += 1;
    }

    // --- standing-queue drain ---------------------------------------------

    fn drain(self: *Gcc, now_us: i64) void {
        const q = self.standing_us orelse return;
        // In competing mode the drain stays off until the other flow leaves (competingLoss).
        if (self.competing) return;
        if (q <= self.cfg.drain_us) {
            self.over_since_us = -1;
            self.over_max_us = 0;
            self.drain_first_cut_us = -1;
        } else {
            if (self.over_since_us < 0) self.over_since_us = now_us;
            self.over_max_us = @max(self.over_max_us, q);
        }
        const over_for = if (self.over_since_us < 0) 0 else now_us - self.over_since_us;
        const stuck = self.cfg.drain_stuck_us > 0 and self.drain_first_cut_us >= 0 and
            now_us - self.drain_first_cut_us >= self.cfg.drain_stuck_us and q > self.cfg.drain_stuck_frac * self.drain_first_q;
        if ((self.cfg.drain_giveup_us > 0 and over_for > self.cfg.drain_giveup_us) or stuck) {
            self.drain_first_cut_us = -1;
            self.drain_off_until_us = now_us + self.cfg.drain_off_us;
            self.over_since_us = -1;
            self.drain_giveups += 1;
            if (self.cfg.competing) self.enterCompeting(now_us, self.over_max_us);
            self.over_max_us = 0;
            return;
        }
        const enabled = now_us >= self.drain_off_until_us;
        const spaced = self.last_drain_us < 0 or now_us - self.last_drain_us > self.cfg.rtt_us + 50_000;
        if (enabled and q > self.cfg.drain_us and over_for >= self.cfg.drain_hold_us and spaced) {
            if (self.acked.rate(self.last_recv)) |a| {
                self.bitrate = @max(self.cfg.min_bps, @min(self.bitrate, drainFactor(q) * a / self.cfg.app_share));
                self.last_drain_us = now_us;
                if (self.drain_first_cut_us < 0) {
                    self.drain_first_cut_us = now_us;
                    self.drain_first_q = q;
                }
                self.last_decrease_us = now_us;
                self.state = .hold;
                self.in_ramp = false;
                self.drains += 1;
            }
        }
    }

    // --- inter-arrival grouping --------------------------------------------

    fn belongsToBurst(self: *const Gcc, r: PacketResult) bool {
        if (!self.cfg.burst_grouping) return false;
        const arr_delta = r.recv_us - self.cur.arr;
        const send_delta = r.send_us - self.cur.send;
        if (send_delta == 0) return true;
        const prop_delta = arr_delta - send_delta;
        return prop_delta < 0 and arr_delta <= 5_000 and r.recv_us - self.cur.first_arr < 100_000;
    }

    fn packet(self: *Gcc, r: PacketResult) void {
        if (self.cur.first_send < 0) {
            self.cur = .{ .first_send = r.send_us, .send = r.send_us, .first_arr = r.recv_us, .arr = r.recv_us, .size = r.size };
            return;
        }
        if (r.send_us < self.cur.first_send) return; // reordered
        const new_group = (r.send_us - self.cur.first_send > self.cfg.group_us) and !self.belongsToBurst(r);
        if (new_group) {
            if (self.prev.complete()) {
                const send_delta = self.cur.send - self.prev.send;
                const arr_delta = self.cur.arr - self.prev.arr;
                if (arr_delta >= 0) self.trend(msf(arr_delta), msf(send_delta), msf(self.cur.arr));
            }
            self.prev = self.cur;
            self.cur = .{ .first_send = r.send_us, .send = r.send_us, .first_arr = r.recv_us, .arr = r.recv_us, .size = r.size };
        } else {
            self.cur.send = @max(self.cur.send, r.send_us);
            self.cur.arr = @max(self.cur.arr, r.recv_us);
            self.cur.size += r.size;
        }
    }

    // --- trendline -----------------------------------------------------------

    fn trend(self: *Gcc, arr_delta_ms: f64, send_delta_ms: f64, arr_ms: f64) void {
        const delta = arr_delta_ms - send_delta_ms;
        self.num_deltas = @min(self.num_deltas + 1, 1000);
        if (self.first_arr_ms < 0) self.first_arr_ms = arr_ms;
        self.acc_delay += delta;
        self.smoothed = self.cfg.smoothing * self.smoothed + (1 - self.cfg.smoothing) * self.acc_delay;
        const w = self.cfg.window;
        const idx = (self.hist_head + self.hist_n) % w;
        if (self.hist_n == w) {
            self.hist_head = (self.hist_head + 1) % w;
        } else self.hist_n += 1;
        self.hist_x[idx] = arr_ms - self.first_arr_ms;
        self.hist_y[idx] = self.smoothed;
        var slope = self.prev_trend;
        if (self.hist_n == w) {
            var sx: f64 = 0;
            var sy: f64 = 0;
            for (0..w) |i| {
                sx += self.hist_x[i];
                sy += self.hist_y[i];
            }
            const mx = sx / @as(f64, @floatFromInt(w));
            const my = sy / @as(f64, @floatFromInt(w));
            var num: f64 = 0;
            var den: f64 = 0;
            for (0..w) |i| {
                num += (self.hist_x[i] - mx) * (self.hist_y[i] - my);
                den += (self.hist_x[i] - mx) * (self.hist_x[i] - mx);
            }
            if (den != 0) slope = num / den;
        }
        self.detect(slope, send_delta_ms, arr_ms);
    }

    // --- overuse detector ----------------------------------------------------

    fn detect(self: *Gcc, slope: f64, send_delta_ms: f64, now_ms: f64) void {
        if (self.num_deltas < 2) return;
        const m = @as(f64, @floatFromInt(@min(self.num_deltas, 60))) * slope * self.cfg.threshold_gain;
        self.last_trend = m;
        if (m > self.threshold) {
            if (self.time_over_ms == -1) {
                self.time_over_ms = send_delta_ms / 2;
            } else self.time_over_ms += send_delta_ms;
            self.overuse_count += 1;
            if (self.time_over_ms > self.cfg.overuse_time_ms and self.overuse_count > 1 and slope >= self.prev_trend) {
                self.time_over_ms = 0;
                self.overuse_count = 0;
                self.usage = .overuse;
            }
        } else if (m < -self.threshold) {
            self.time_over_ms = -1;
            self.overuse_count = 0;
            self.usage = .underuse;
        } else {
            self.time_over_ms = -1;
            self.overuse_count = 0;
            self.usage = .normal;
        }
        self.prev_trend = slope;
        // adaptive threshold
        if (self.last_thr_update_ms < 0) self.last_thr_update_ms = now_ms;
        const am = @abs(m);
        if (am > self.threshold + 15) {
            self.last_thr_update_ms = now_ms;
            return;
        }
        const k = if (am < self.threshold) self.cfg.k_down else self.cfg.k_up;
        const dt = @min(now_ms - self.last_thr_update_ms, 100);
        self.threshold += k * (am - self.threshold) * dt;
        self.threshold = std.math.clamp(self.threshold, 6, 600);
        self.last_thr_update_ms = now_ms;
    }

    // --- loss cap --------------------------------------------------------------

    fn updateLoss(self: *Gcc, now_us: i64) void {
        if (now_us - self.win_start < 1_000_000 or self.win_sent < 20) return;
        const loss = @as(f64, @floatFromInt(self.win_lost)) / @as(f64, @floatFromInt(self.win_sent));
        if (loss > 0.10) {
            self.loss_cap = @min(self.loss_cap, self.bitrate) * (1 - 0.5 * loss);
        } else if (loss < 0.02) {
            self.loss_cap = std.math.inf(f64);
        }
        self.win_sent = 0;
        self.win_lost = 0;
        self.win_start = now_us;
    }

    // --- AIMD ------------------------------------------------------------------

    fn updateRate(self: *Gcc, now_us: i64) void {
        const acked = if (self.acked.rate(self.last_recv)) |a| a / self.cfg.app_share else null;
        if (self.competing) {
            // The trend follows the other flow's sawtooth: overuse is its queue growing
            // (ours only once the queue is past its level), underuse is it backing off,
            // which is room for us rather than a queue of ours to let drain.
            const q = self.standing_us orelse 0;
            if (self.usage == .underuse or (self.usage == .overuse and q <= self.competing_level_us + self.cfg.competing_margin_us)) self.usage = .normal;
        }
        switch (self.usage) {
            .overuse => self.state = .decrease,
            .normal => if (self.state == .hold) {
                self.state = .increase;
            },
            .underuse => self.state = .hold,
        }
        if (self.last_change_us < 0) self.last_change_us = now_us;
        const dt_s = @as(f64, @floatFromInt(@min(now_us - self.last_change_us, 1_000_000))) / 1e6;
        var r = self.bitrate;
        switch (self.state) {
            .hold => {},
            .increase => {
                if (self.link_cap) |lc| {
                    if (acked) |a| {
                        if (a / 1000 > lc + 3 * @sqrt(self.link_var * lc)) self.link_cap = null;
                    }
                }
                if (self.in_ramp) {
                    r = r * std.math.pow(f64, 2.0, dt_s * 10.0);
                } else if (self.link_cap != null and !self.competing) {
                    // Additive: about one packet per response time.
                    const bits_per_frame = r / 30.0;
                    const ppf = @ceil(bits_per_frame / (1200.0 * 8.0));
                    const avg_pkt = bits_per_frame / ppf;
                    const resp_s = @as(f64, @floatFromInt(self.cfg.rtt_us)) / 1e6 + 0.1;
                    r += @max(4000.0, avg_pkt / resp_s) * dt_s;
                } else if (self.competing) {
                    // Next to a loss-based flow, grow like one: back toward the rate
                    // before the last loss cut within about `competing_regain_us`
                    // (Cubic's concave region), then at least a packet per RTT per RTT
                    // at the queue-inflated RTT. Otherwise every Cubic loss event
                    // costs us 15% for good and the rate settles at a few Mbit/s.
                    const rtt_s = @as(f64, @floatFromInt(self.cfg.rtt_us)) / 1e6 + (self.standing_us orelse 0) / 1e6;
                    const tcp = 1200.0 * 8.0 / (rtt_s * rtt_s);
                    var inc = @max(r * (std.math.pow(f64, self.cfg.mult_increase, dt_s) - 1), tcp * dt_s);
                    if (r < self.competing_wmax) {
                        const regain_s = @as(f64, @floatFromInt(self.cfg.competing_regain_us)) / 1e6;
                        inc = @max(inc, @min(self.competing_wmax - r, (self.competing_wmax - r) * dt_s / regain_s * 3));
                    }
                    r += inc;
                } else {
                    r += @max(r * (std.math.pow(f64, self.cfg.mult_increase, dt_s) - 1), 1000.0 * dt_s);
                }
                if (acked) |a| r = @min(r, 1.5 * a + 10_000);
                r = @max(r, self.bitrate); // the acked cap never lowers the rate
            },
            .decrease => {
                self.in_ramp = false;
                if (acked) |a| {
                    var nr = self.cfg.beta * a;
                    if (nr > self.bitrate) {
                        if (self.link_cap) |lc| nr = self.cfg.beta * lc * 1000;
                        nr = @min(nr, self.bitrate);
                    }
                    r = nr;
                    const ak = a / 1000;
                    if (self.link_cap) |lc| {
                        if (ak < lc - 3 * @sqrt(self.link_var * lc)) {
                            self.link_cap = ak;
                        } else {
                            const err = lc - ak;
                            self.link_cap = 0.95 * lc + 0.05 * ak;
                            self.link_var = std.math.clamp(0.95 * self.link_var + 0.05 * err * err / @max(lc, 1), 0.4, 2.5);
                        }
                    } else self.link_cap = ak;
                } else r = self.bitrate * self.cfg.beta;
                self.overuse_events += 1;
                self.noteOveruseCut(now_us);
                self.last_decrease_us = now_us;
                self.state = .hold;
                self.usage = .normal; // one decrease per detected overuse
            },
        }
        self.bitrate = std.math.clamp(r, self.cfg.min_bps, self.cfg.max_bps);
        self.last_change_us = now_us;
    }
};

/// Rate multiplier that drains a standing queue of `qdelay_us` in about
/// 200 ms (queued bytes ≈ acked rate × queue delay).
pub fn drainFactor(qdelay_us: f64) f64 {
    return std.math.clamp(1 - qdelay_us / 200_000, 0.5, 0.85);
}

fn msf(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

test "drain factor" {
    try std.testing.expectEqual(@as(f64, 0.85), drainFactor(10_000));
    try std.testing.expectEqual(@as(f64, 0.75), drainFactor(50_000));
    try std.testing.expectEqual(@as(f64, 0.5), drainFactor(500_000));
}
