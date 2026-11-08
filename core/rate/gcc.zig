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
    acked_window_us: i64 = 500_000,
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
    /// Last standing-queue reading, for telemetry.
    standing_us: ?f64 = null,
    // counters, for telemetry
    overuse_events: u32 = 0,
    drains: u32 = 0,
    jumps: u32 = 0,
    drain_giveups: u32 = 0,

    pub fn init(cfg: Config) Gcc {
        std.debug.assert(cfg.window >= 2 and cfg.window <= Config.max_window);
        std.debug.assert(cfg.app_share > 0 and cfg.app_share <= 1);
        var g = Gcc{ .cfg = cfg, .bitrate = cfg.start_bps, .in_ramp = cfg.initial_ramp };
        g.acked.window_us = cfg.acked_window_us;
        return g;
    }

    /// The rate the controller allows, bits per second.
    pub fn target(self: *const Gcc) f64 {
        return std.math.clamp(@min(self.bitrate, self.loss_cap), self.cfg.min_bps, self.cfg.max_bps);
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
        for (rs) |r| {
            if (self.win_start < 0) self.win_start = now_us;
            self.win_sent += 1;
            if (!r.received()) {
                self.win_lost += 1;
                continue;
            }
            self.acked.add(r.recv_us, r.size);
            self.last_recv = @max(self.last_recv, r.recv_us);
            self.owd.add(r);
            self.packet(r);
        }
        self.updateLoss(now_us);
        self.updateRate(now_us);
        if (self.cfg.drain_us > 0) self.drain(now_us);
    }

    // --- standing-queue drain ---------------------------------------------

    fn drain(self: *Gcc, now_us: i64) void {
        const q = self.owd.standing() orelse return;
        self.standing_us = q;
        if (q <= self.cfg.drain_us) {
            self.over_since_us = -1;
        } else if (self.over_since_us < 0) self.over_since_us = now_us;
        const over_for = if (self.over_since_us < 0) 0 else now_us - self.over_since_us;
        if (self.cfg.drain_giveup_us > 0 and over_for > self.cfg.drain_giveup_us) {
            self.drain_off_until_us = now_us + self.cfg.drain_off_us;
            self.over_since_us = -1;
            self.drain_giveups += 1;
        }
        const enabled = now_us >= self.drain_off_until_us;
        const spaced = self.last_drain_us < 0 or now_us - self.last_drain_us > self.cfg.rtt_us + 50_000;
        if (enabled and q > self.cfg.drain_us and over_for >= self.cfg.drain_hold_us and spaced) {
            if (self.acked.rate(self.last_recv)) |a| {
                self.bitrate = @max(self.cfg.min_bps, @min(self.bitrate, drainFactor(q) * a / self.cfg.app_share));
                self.last_drain_us = now_us;
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
                } else if (self.link_cap != null) {
                    // Additive: about one packet per response time.
                    const bits_per_frame = r / 30.0;
                    const ppf = @ceil(bits_per_frame / (1200.0 * 8.0));
                    const avg_pkt = bits_per_frame / ppf;
                    const resp_s = @as(f64, @floatFromInt(self.cfg.rtt_us)) / 1e6 + 0.1;
                    r += @max(4000.0, avg_pkt / resp_s) * dt_s;
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
