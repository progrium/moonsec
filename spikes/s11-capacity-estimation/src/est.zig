//! S11: sans-I/O capacity estimators and rate controllers.
//!
//! Everything here is driven by transport-wide feedback: for every media
//! packet the sender knows its send time and size, and the receiver reports
//! its arrival time (or that it never arrived). Times are microseconds on two
//! unsynchronised clocks; only differences of one-way delay are used, so the
//! clock offset cancels. Rates are bits per second.
//!
//! Two controllers:
//!  - `Gcc`: a port of the delay-based half of WebRTC's Google Congestion
//!    Control (InterArrivalDelta grouping, TrendlineEstimator, adaptive
//!    threshold overuse detector, AimdRateControl), plus a simple loss cap.
//!  - `QDelay`: a queue-delay-target controller (LEDBAT/SCReAM-style) that
//!    keeps a windowed minimum one-way delay as the base and steers the
//!    standing queue towards a target.
//! And one passive capacity estimator:
//!  - `TrainCap`: per-frame packet-train dispersion at the receiver. When the
//!    pacer sends a frame faster than the bottleneck, the bottleneck spreads
//!    it out to its own rate, so bytes / dispersion measures capacity.
const std = @import("std");

pub const Result = struct {
    seq: u64,
    send_us: i64,
    recv_us: i64, // -1 = lost
    size: u32,
    frame: u32, // frame id the packet belongs to
    frame_last: bool, // last packet of its frame
};

pub const Usage = enum { normal, overuse, underuse };

// ---------------------------------------------------------------------------
// Acknowledged (received) bitrate over a sliding window of arrival time.

pub const AckedRate = struct {
    const N = 32768;
    t: [N]i64 = undefined,
    sz: [N]u32 = undefined,
    head: usize = 0,
    len: usize = 0,
    bytes: u64 = 0,
    window_us: i64 = 500_000,
    first_us: i64 = -1,

    pub fn add(self: *AckedRate, recv_us: i64, size: u32) void {
        if (self.first_us < 0) self.first_us = recv_us;
        if (self.len == N) self.popFront();
        const i = (self.head + self.len) % N;
        self.t[i] = recv_us;
        self.sz[i] = size;
        self.len += 1;
        self.bytes += size;
        while (self.len > 0 and self.t[self.head] < recv_us - self.window_us) self.popFront();
    }
    fn popFront(self: *AckedRate) void {
        self.bytes -= self.sz[self.head];
        self.head = (self.head + 1) % N;
        self.len -= 1;
    }
    /// null until at least 100 ms of arrivals have been seen.
    pub fn rate(self: *const AckedRate, now_recv_us: i64) ?f64 {
        if (self.first_us < 0) return null;
        const span = @min(self.window_us, now_recv_us - self.first_us);
        if (span < 100_000) return null;
        return @as(f64, @floatFromInt(self.bytes)) * 8.0 * 1e6 / @as(f64, @floatFromInt(span));
    }
};

// ---------------------------------------------------------------------------
// GCC

pub const GccConfig = struct {
    burst_grouping: bool = true, // merge Wi-Fi style arrival bursts into one group
    group_us: i64 = 5_000,
    window: usize = 20,
    smoothing: f64 = 0.9,
    threshold_gain: f64 = 4.0,
    k_up: f64 = 0.0087,
    k_down: f64 = 0.039,
    overuse_time_ms: f64 = 10.0,
    beta: f64 = 0.85,
    mult_increase: f64 = 1.08, // per second, far from link capacity
    min_bps: f64 = 500_000,
    max_bps: f64 = 400_000_000,
    start_bps: f64 = 5_000_000,
    rtt_us: i64 = 20_000, // for the additive increase response time
    initial_ramp: bool = false, // fast startup: double per 100 ms until first overuse
    /// Hybrid: also cut when the absolute standing queue exceeds this
    /// (0 = off). A gradient detector can't see a queue that stopped growing.
    drain_us: f64 = 0,
    /// ...but only once the queue has stayed above it this long, so Wi-Fi
    /// stalls and cross-traffic bursts that clear by themselves are ignored
    drain_hold_us: i64 = 150_000,
    /// If the queue stays up this long despite our cuts, we are not the one
    /// filling it (a loss-based flow is): stop draining for 10 s, or the
    /// stream starves.
    drain_giveup_us: i64 = 1_500_000,
    acked_window_us: i64 = 500_000,
    /// The encoder sends this share of the target (headroom for frame delay).
    /// Acked-rate rules divide by it so an app-limited stream isn't mistaken
    /// for a smaller link.
    app_share: f64 = 1.0,
};

const Group = struct {
    first_send: i64 = -1,
    send: i64 = -1, // last send time in group
    first_arr: i64 = -1,
    arr: i64 = -1, // last arrival in group
    size: u64 = 0,
    fn complete(g: Group) bool {
        return g.first_send >= 0;
    }
};

pub const Gcc = struct {
    cfg: GccConfig,
    // inter-arrival grouping
    cur: Group = .{},
    prev: Group = .{},
    // trendline
    first_arr_ms: f64 = -1,
    acc_delay: f64 = 0,
    smoothed: f64 = 0,
    num_deltas: u32 = 0,
    hist_x: [64]f64 = undefined,
    hist_y: [64]f64 = undefined,
    hist_n: usize = 0,
    hist_head: usize = 0,
    // detector
    threshold: f64 = 12.5,
    last_thr_update_ms: f64 = -1,
    time_over_ms: f64 = -1,
    overuse_count: u32 = 0,
    prev_trend: f64 = 0,
    usage: Usage = .normal,
    last_trend: f64 = 0, // modified trend, for logging
    // aimd
    state: enum { hold, increase, decrease } = .increase,
    bitrate: f64,
    link_cap: ?f64 = null, // kbps, exp. mean of acked rate at overuse
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
    overuse_events: u32 = 0,
    last_jump_us: i64 = -1,
    owd: OwdTracker = .{},
    last_drain_us: i64 = -1,
    drains: u32 = 0,
    over_since_us: i64 = -1,
    drain_off_until_us: i64 = -1,

    /// A capacity measurement from outside the delay detector (frame trains).
    /// Lets the rate jump up instead of creeping at 8%/s, the job WebRTC's
    /// probe controller does with padding probes.
    pub fn onCapacity(self: *Gcc, now_us: i64, cap: f64) void {
        if (self.state != .increase) return;
        if (self.last_decrease_us >= 0 and now_us - self.last_decrease_us < 2_000_000) return;
        if (self.last_jump_us >= 0 and now_us - self.last_jump_us < 500_000) return;
        const nr = @min(0.85 * cap, 3 * self.bitrate);
        if (nr <= self.bitrate) return;
        self.bitrate = @min(nr, self.cfg.max_bps);
        self.in_ramp = false;
        self.last_jump_us = now_us;
    }

    pub fn init(cfg: GccConfig) Gcc {
        var g = Gcc{ .cfg = cfg, .bitrate = cfg.start_bps, .in_ramp = cfg.initial_ramp };
        g.acked.window_us = cfg.acked_window_us;
        return g;
    }

    pub fn target(self: *const Gcc) f64 {
        return std.math.clamp(@min(self.bitrate, self.loss_cap), self.cfg.min_bps, self.cfg.max_bps);
    }

    /// Feed one feedback batch (results in send order).
    pub fn onFeedback(self: *Gcc, now_us: i64, rs: []const Result) void {
        for (rs) |r| {
            if (self.win_start < 0) self.win_start = now_us;
            self.win_sent += 1;
            if (r.recv_us < 0) {
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
        if (self.cfg.drain_us > 0) {
            if (self.owd.standing()) |q| {
                if (q <= self.cfg.drain_us) {
                    self.over_since_us = -1;
                } else if (self.over_since_us < 0) self.over_since_us = now_us;
                const over_for = if (self.over_since_us < 0) 0 else now_us - self.over_since_us;
                if (self.cfg.drain_giveup_us > 0 and over_for > self.cfg.drain_giveup_us) {
                    self.drain_off_until_us = now_us + 10_000_000;
                    self.over_since_us = -1;
                }
                const enabled = now_us >= self.drain_off_until_us;
                if (enabled and q > self.cfg.drain_us and over_for >= self.cfg.drain_hold_us and (self.last_drain_us < 0 or now_us - self.last_drain_us > self.cfg.rtt_us + 50_000)) {
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
        }
    }

    fn belongsToBurst(self: *const Gcc, r: Result) bool {
        if (!self.cfg.burst_grouping) return false;
        const arr_delta = r.recv_us - self.cur.arr;
        const send_delta = r.send_us - self.cur.send;
        if (send_delta == 0) return true;
        const prop_delta = arr_delta - send_delta;
        return prop_delta < 0 and arr_delta <= 5_000 and r.recv_us - self.cur.first_arr < 100_000;
    }

    fn packet(self: *Gcc, r: Result) void {
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
                if (arr_delta >= 0) self.trend(@as(f64, @floatFromInt(arr_delta)) / 1000.0, @as(f64, @floatFromInt(send_delta)) / 1000.0, @as(f64, @floatFromInt(self.cur.arr)) / 1000.0);
            }
            self.prev = self.cur;
            self.cur = .{ .first_send = r.send_us, .send = r.send_us, .first_arr = r.recv_us, .arr = r.recv_us, .size = r.size };
        } else {
            self.cur.send = @max(self.cur.send, r.send_us);
            self.cur.arr = @max(self.cur.arr, r.recv_us);
            self.cur.size += r.size;
        }
    }

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

// ---------------------------------------------------------------------------
// Queue-delay-target controller

pub const QDelayConfig = struct {
    target_us: f64 = 5_000,
    base_window_us: i64 = 10_000_000,
    filter_us: i64 = 20_000, // standing queue = min over this window (filters Wi-Fi batching)
    up_gain: f64 = 0.5, // max fractional increase per second
    down_gain: f64 = 1.0,
    min_bps: f64 = 500_000,
    max_bps: f64 = 400_000_000,
    start_bps: f64 = 5_000_000,
    rtt_us: i64 = 20_000,
};

/// Standing queue delay from one-way delays: (min OWD over the last
/// `filter_us`) minus (min OWD over `base_window_us`). The short min filters
/// Wi-Fi aggregation batching; the long min is the propagation baseline.
pub const OwdTracker = struct {
    base_window_us: i64 = 10_000_000,
    filter_us: i64 = 20_000,
    bucket_min: [10]i64 = [_]i64{std.math.maxInt(i64)} ** 10,
    bucket_t: [10]i64 = [_]i64{-1} ** 10,
    rt: [512]i64 = undefined,
    ro: [512]i64 = undefined,
    rn: usize = 0,
    rh: usize = 0,
    last_recv: i64 = 0,

    pub fn add(self: *OwdTracker, r: Result) void {
        const owd = r.recv_us - r.send_us;
        self.last_recv = @max(self.last_recv, r.recv_us);
        const bw = @divTrunc(self.base_window_us, 10);
        const bi: usize = @intCast(@mod(@divTrunc(r.recv_us, bw), 10));
        const bstart = @divTrunc(r.recv_us, bw) * bw;
        if (self.bucket_t[bi] != bstart) {
            self.bucket_t[bi] = bstart;
            self.bucket_min[bi] = owd;
        } else self.bucket_min[bi] = @min(self.bucket_min[bi], owd);
        const i = (self.rh + self.rn) % 512;
        if (self.rn == 512) self.rh = (self.rh + 1) % 512 else self.rn += 1;
        self.rt[i] = r.recv_us;
        self.ro[i] = owd;
    }

    /// Standing queue in microseconds, null before any sample.
    pub fn standing(self: *OwdTracker) ?f64 {
        while (self.rn > 0 and self.rt[self.rh] < self.last_recv - self.filter_us) {
            self.rh = (self.rh + 1) % 512;
            self.rn -= 1;
        }
        if (self.rn == 0) return null;
        var mn: i64 = std.math.maxInt(i64);
        for (0..self.rn) |k| mn = @min(mn, self.ro[(self.rh + k) % 512]);
        var base: i64 = std.math.maxInt(i64);
        for (self.bucket_min) |b| base = @min(base, b);
        return @floatFromInt(mn - base);
    }
};

pub const QDelay = struct {
    cfg: QDelayConfig,
    bitrate: f64,
    owd: OwdTracker = .{},
    last_us: i64 = -1,
    last_cut_us: i64 = -1,
    qdelay_us: f64 = 0,
    acked: AckedRate = .{},
    last_recv: i64 = 0,
    loss_cap: f64 = std.math.inf(f64),
    win_sent: u32 = 0,
    win_lost: u32 = 0,
    win_start: i64 = -1,
    last_jump_us: i64 = -1,

    pub fn onCapacity(self: *QDelay, now_us: i64, cap: f64) void {
        if (self.qdelay_us > self.cfg.target_us) return;
        if (self.last_cut_us >= 0 and now_us - self.last_cut_us < 2_000_000) return;
        if (self.last_jump_us >= 0 and now_us - self.last_jump_us < 500_000) return;
        const nr = @min(0.85 * cap, 3 * self.bitrate);
        if (nr <= self.bitrate) return;
        self.bitrate = @min(nr, self.cfg.max_bps);
        self.last_jump_us = now_us;
    }

    pub fn init(cfg: QDelayConfig) QDelay {
        return .{ .cfg = cfg, .bitrate = cfg.start_bps, .owd = .{ .base_window_us = cfg.base_window_us, .filter_us = cfg.filter_us } };
    }
    pub fn target(self: *const QDelay) f64 {
        return std.math.clamp(@min(self.bitrate, self.loss_cap), self.cfg.min_bps, self.cfg.max_bps);
    }

    pub fn onFeedback(self: *QDelay, now_us: i64, rs: []const Result) void {
        for (rs) |r| {
            if (self.win_start < 0) self.win_start = now_us;
            self.win_sent += 1;
            if (r.recv_us < 0) {
                self.win_lost += 1;
                continue;
            }
            self.acked.add(r.recv_us, r.size);
            self.last_recv = @max(self.last_recv, r.recv_us);
            self.owd.add(r);
        }
        self.qdelay_us = self.owd.standing() orelse return;

        // loss cap, same rule as GCC
        if (now_us - self.win_start >= 1_000_000 and self.win_sent >= 20) {
            const loss = @as(f64, @floatFromInt(self.win_lost)) / @as(f64, @floatFromInt(self.win_sent));
            if (loss > 0.10) self.loss_cap = @min(self.loss_cap, self.bitrate) * (1 - 0.5 * loss) else if (loss < 0.02) self.loss_cap = std.math.inf(f64);
            self.win_sent = 0;
            self.win_lost = 0;
            self.win_start = now_us;
        }

        if (self.last_us < 0) self.last_us = now_us;
        const dt = @as(f64, @floatFromInt(@min(now_us - self.last_us, 100_000))) / 1e6;
        self.last_us = now_us;
        const acked = self.acked.rate(self.last_recv);
        const off = std.math.clamp((self.cfg.target_us - self.qdelay_us) / self.cfg.target_us, -4, 1);
        var r = self.bitrate;
        if (self.qdelay_us > 4 * self.cfg.target_us) {
            // Deep queue: send below what is getting through by enough to
            // drain the standing queue in ~200 ms (queued bytes ~ acked x
            // qdelay); at most once per RTT + 50 ms so the cut can take effect.
            if (acked) |a| {
                if (self.last_cut_us < 0 or now_us - self.last_cut_us > self.cfg.rtt_us + 50_000) {
                    r = @min(r, drainFactor(self.qdelay_us) * a);
                    self.last_cut_us = now_us;
                }
            }
        } else if (off >= 0) {
            r += r * self.cfg.up_gain * off * dt;
            if (acked) |a| r = @max(@min(r, 1.5 * a + 10_000), @min(self.bitrate, r));
        } else {
            r += r * self.cfg.down_gain * off * dt;
        }
        self.bitrate = std.math.clamp(r, self.cfg.min_bps, self.cfg.max_bps);
    }
};

pub fn drainFactor(qdelay_us: f64) f64 {
    return std.math.clamp(1 - qdelay_us / 200_000, 0.5, 0.85);
}

// ---------------------------------------------------------------------------
// Packet-train capacity estimate from frame dispersion

pub const TrainCap = struct {
    cur_frame: u32 = std.math.maxInt(u32),
    first_arr: i64 = 0,
    last_arr: i64 = 0,
    bytes: u64 = 0,
    pkts: u32 = 0,
    lost: bool = false,
    // recent samples (time, bps)
    st: [64]i64 = undefined,
    sv: [64]f64 = undefined,
    sn: usize = 0,
    sh: usize = 0,
    min_pkts: u32 = 4,

    pub fn onResult(self: *TrainCap, r: Result) void {
        if (r.frame != self.cur_frame) {
            self.cur_frame = r.frame;
            self.pkts = 0;
            self.bytes = 0;
            self.lost = false;
        }
        if (r.recv_us < 0) {
            self.lost = true;
            return;
        }
        if (self.pkts == 0) {
            self.first_arr = r.recv_us;
            self.last_arr = r.recv_us;
        } else {
            self.bytes += r.size; // first packet's bytes are excluded
            self.first_arr = @min(self.first_arr, r.recv_us);
            self.last_arr = @max(self.last_arr, r.recv_us);
        }
        self.pkts += 1;
        if (r.frame_last and !self.lost and self.pkts >= self.min_pkts) {
            const disp = self.last_arr - self.first_arr;
            if (disp >= 200) {
                const v = @as(f64, @floatFromInt(self.bytes)) * 8e6 / @as(f64, @floatFromInt(disp));
                const i = (self.sh + self.sn) % 64;
                if (self.sn == 64) self.sh = (self.sh + 1) % 64 else self.sn += 1;
                self.st[i] = r.recv_us;
                self.sv[i] = v;
            }
        }
    }

    /// Median of samples in the last `window_us`, null if fewer than 5.
    pub fn estimate(self: *const TrainCap, now_recv_us: i64, window_us: i64) ?f64 {
        var buf: [64]f64 = undefined;
        var n: usize = 0;
        for (0..self.sn) |k| {
            const i = (self.sh + k) % 64;
            if (self.st[i] >= now_recv_us - window_us) {
                buf[n] = self.sv[i];
                n += 1;
            }
        }
        if (n < 5) return null;
        std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
        return buf[n / 2];
    }
};

// ---------------------------------------------------------------------------

pub const Kind = enum { gcc, qdelay };

pub const Controller = union(Kind) {
    gcc: Gcc,
    qdelay: QDelay,

    pub fn onFeedback(self: *Controller, now_us: i64, rs: []const Result) void {
        switch (self.*) {
            inline else => |*c| c.onFeedback(now_us, rs),
        }
    }
    pub fn onCapacity(self: *Controller, now_us: i64, cap: f64) void {
        switch (self.*) {
            inline else => |*c| c.onCapacity(now_us, cap),
        }
    }
    pub fn target(self: *const Controller) f64 {
        return switch (self.*) {
            inline else => |*c| c.target(),
        };
    }
};

test "acked rate" {
    var a = AckedRate{};
    var t: i64 = 0;
    while (t < 1_000_000) : (t += 1000) a.add(t, 1250); // 1250 B/ms = 10 Mbit/s
    const r = a.rate(t - 1000).?;
    try std.testing.expect(@abs(r - 10e6) < 0.1e6);
}
