//! The `gcc-hybrid` rate controller from S11: GCC with burst grouping, the
//! frame-train capacity estimate for pacing and for jumping the target up,
//! and the standing-queue drain.
//!
//! It produces three numbers from transport-wide feedback:
//!  - `pacingBps`: the rate the transport paces at. It follows the
//!    frame-train capacity estimate (clamped to 1.1–4× the target), so a
//!    frame leaves at link rate; 2.5× the target before there is an estimate.
//!  - `targetBps`: what the path can take from us.
//!  - `encoderBps`: `app_share` × the target, what the encoder should send.
//!    Below 1 it trades bitrate for frame delay: frame transport time is
//!    about (encoder rate / capacity) × the frame interval.
//!
//! Sans-I/O: the caller passes the host clock in and reads the rates out.
const std = @import("std");
const types = @import("types.zig");
const PacketResult = types.PacketResult;
const gcc_mod = @import("gcc.zig");
const Gcc = gcc_mod.Gcc;
const TrainCap = @import("train.zig").TrainCap;
const history = @import("history.zig");

pub const Config = struct {
    gcc: gcc_mod.Config = .{},
    /// Let the train estimate jump the target up (S11 `gcc-probe`).
    probe: bool = true,
    /// Window of the train estimate's median.
    train_window_us: i64 = 300_000,
    /// Pacing is the train estimate clamped to [floor, ceil] × target...
    pace_floor: f64 = 1.1,
    pace_ceil: f64 = 4.0,
    /// ...or this × target before there is an estimate (WebRTC's 2.5×).
    pace_fallback: f64 = 2.5,
    /// Share of the target the encoder sends, in (0, 1].
    app_share: f64 = 1.0,
};

/// Estimator state for logging and the telemetry overlay.
pub const Telemetry = struct {
    target_bps: f64,
    encoder_bps: f64,
    pacing_bps: f64,
    capacity_bps: ?f64,
    standing_queue_us: ?f64,
    acked_bps: ?f64,
    state: gcc_mod.State,
    usage: types.Usage,
    trend: f64,
    threshold: f64,
    loss_capped: bool,
    drain_enabled: bool,
    overuses: u32,
    drains: u32,
    jumps: u32,
    drain_giveups: u32,
};

pub const Controller = struct {
    cfg: Config,
    gcc: Gcc,
    train: TrainCap = .{},
    history: history.SendHistory = .{},
    /// Newest arrival seen (client clock): the "now" of receiver-side windows.
    last_recv_us: i64 = std.math.minInt(i64),
    capacity: ?f64 = null,
    results_buf: [1024]PacketResult = undefined,

    pub fn init(cfg: Config) Controller {
        var g = cfg.gcc;
        g.app_share = cfg.app_share;
        return .{ .cfg = cfg, .gcc = Gcc.init(g) };
    }

    /// Initialise in place. The controller holds about 1.9 MB of history,
    /// so heap or static storage is the place for it.
    pub fn reset(self: *Controller, cfg: Config) void {
        var g = cfg.gcc;
        g.app_share = cfg.app_share;
        self.cfg = cfg;
        self.gcc = Gcc.init(g);
        self.train = .{};
        self.history = .{};
        self.last_recv_us = std.math.minInt(i64);
        self.capacity = null;
    }

    /// Record a media packet as it leaves the pacer, for joining with
    /// feedback by `onArrivals`. Not needed when calling `onFeedback`.
    pub fn onSent(self: *Controller, seq: u64, send_us: i64, size: u32, frame: u32, frame_last: bool) void {
        self.history.onSent(seq, send_us, size, frame, frame_last);
    }

    /// Feed a transport-wide feedback batch of (seq, arrival) sorted by seq.
    /// Sequence numbers the batch skips are counted lost.
    pub fn onArrivals(self: *Controller, now_us: i64, batch: []const history.Arrival) void {
        var rest = batch;
        while (true) {
            const before = self.history.next_expected;
            const rs = self.history.join(rest, &self.results_buf);
            if (rs.len > 0) self.onFeedback(now_us, rs);
            // join stops when results_buf fills; continue with the remainder.
            const done = self.history.next_expected;
            if (done == before) break;
            var k: usize = 0;
            while (k < rest.len and rest[k].seq < done) k += 1;
            if (k == rest.len) break;
            rest = rest[k..];
        }
    }

    /// Feed results already joined with the send records, in send order.
    /// `now_us` is the host clock when the feedback arrived.
    pub fn onFeedback(self: *Controller, now_us: i64, rs: []const PacketResult) void {
        for (rs) |r| {
            self.train.onResult(r);
            if (r.received()) self.last_recv_us = @max(self.last_recv_us, r.recv_us);
        }
        self.gcc.onFeedback(now_us, rs);
        self.capacity = if (self.last_recv_us == std.math.minInt(i64)) null else self.train.estimate(self.last_recv_us, self.cfg.train_window_us);
        if (self.cfg.probe) {
            if (self.capacity) |c| self.gcc.onCapacity(now_us, c);
        }
    }

    /// The rate the path can take from us, bits per second.
    pub fn targetBps(self: *const Controller) f64 {
        return self.gcc.target();
    }

    /// What the encoder should produce, bits per second.
    pub fn encoderBps(self: *const Controller) f64 {
        return self.cfg.app_share * self.gcc.target();
    }

    /// The transport's pacing rate, bits per second.
    pub fn pacingBps(self: *const Controller) f64 {
        const t = self.gcc.target();
        return if (self.capacity) |c|
            std.math.clamp(c, self.cfg.pace_floor * t, self.cfg.pace_ceil * t)
        else
            self.cfg.pace_fallback * t;
    }

    /// Link capacity from frame trains, null while frames are too small or
    /// too few. It measures the link, not our share.
    pub fn capacityBps(self: *const Controller) ?f64 {
        return self.capacity;
    }

    pub fn telemetry(self: *const Controller, now_us: i64) Telemetry {
        const g = &self.gcc;
        return .{
            .target_bps = self.targetBps(),
            .encoder_bps = self.encoderBps(),
            .pacing_bps = self.pacingBps(),
            .capacity_bps = self.capacity,
            .standing_queue_us = g.standing_us,
            .acked_bps = g.acked.rate(g.last_recv),
            .state = g.state,
            .usage = g.usage,
            .trend = g.last_trend,
            .threshold = g.threshold,
            .loss_capped = g.loss_cap < g.bitrate,
            .drain_enabled = g.cfg.drain_us > 0 and now_us >= g.drain_off_until_us,
            .overuses = g.overuse_events,
            .drains = g.drains,
            .jumps = g.jumps,
            .drain_giveups = g.drain_giveups,
        };
    }
};
