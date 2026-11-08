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
//! Two things keep the train estimate alive (S11b):
//!  - A target floor where an encoder frame still has `floor_pkts` packets.
//!    Below it no frame gives a sample, nothing jumps the target, and
//!    recovery falls back to GCC's 8%/s ramp (16.6 s in one S11b run).
//!  - Probe frames: `framePacingBps` returns `probe_mult` x the pacing rate
//!    for one frame every `probe_interval_us`, so the train can see spare
//!    capacity even when pacing has locked onto our share of a fair queue.
//!
//! Sans-I/O: the caller passes the host clock in and reads the rates out.
const std = @import("std");
const types = @import("types.zig");
const PacketResult = types.PacketResult;
const gcc_mod = @import("gcc.zig");
const Gcc = gcc_mod.Gcc;
const TrainCap = @import("train.zig").TrainCap;
const history = @import("history.zig");
const proto = @import("../proto/root.zig");

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
    /// Pacing in competing-flow mode, x the target.
    competing_pace: f64 = 1.5,
    /// Target floor: an encoder frame keeps `floor_pkts` packets of
    /// `pkt_bytes` at `fps` (with 25% margin for frame-size spread). Used only
    /// while the link last measured at least twice the floor, so a slow link
    /// can still go below it. 0 = off.
    floor_pkts: u32 = 4,
    pkt_bytes: u32 = 1200,
    fps: f64 = 60,
    /// Pace one frame at `probe_mult` x the pacing rate every
    /// `probe_interval_us`; 0 = off. Probe samples count for
    /// `probe_window_us` (see `TrainCap.estimateWithProbes`).
    probe_interval_us: i64 = 500_000,
    probe_mult: f64 = 2.0,
    probe_window_us: i64 = 2_000_000,
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
    competing: bool,
    competing_entries: u32,
    competing_cuts: u32,
    loss_cuts: u32,
    floor_bps: f64,
    probes: u32,
};

/// The 64-bit sequence number nearest `ref` whose low 32 bits are `seq`.
pub fn widen(ref: u64, seq: u32) u64 {
    const lo: u32 = @truncate(ref);
    const diff: i32 = @bitCast(seq -% lo);
    const r = @as(i128, ref) + diff;
    return if (r < 0) seq else @intCast(r);
}

test "widen" {
    try std.testing.expectEqual(@as(u64, 5), widen(0, 5));
    try std.testing.expectEqual(@as(u64, 0x1_0000_0002), widen(0xffff_fff0, 2));
    try std.testing.expectEqual(@as(u64, 0xffff_fff0), widen(0x1_0000_0002, 0xffff_fff0));
}

pub const Controller = struct {
    cfg: Config,
    gcc: Gcc,
    train: TrainCap = .{},
    history: history.SendHistory = .{},
    /// Newest arrival seen (client clock): the "now" of receiver-side windows.
    last_recv_us: i64 = std.math.minInt(i64),
    capacity: ?f64 = null,
    /// Newest non-null capacity, for the floor's "is the link fast enough".
    last_capacity: ?f64 = null,
    last_probe_us: i64 = std.math.minInt(i64),
    /// The probe frame's pacing rate holds until this host time.
    probe_until_us: i64 = std.math.minInt(i64),
    probe_bps: f64 = 0,
    pacer_busy_until_us: i64 = std.math.minInt(i64),
    probes: u32 = 0,
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
        self.last_capacity = null;
        self.last_probe_us = std.math.minInt(i64);
        self.probe_until_us = std.math.minInt(i64);
        self.probe_bps = 0;
        self.pacer_busy_until_us = std.math.minInt(i64);
        self.probes = 0;
    }

    /// Call as a frame of `bytes` enters the pacer, then pace at
    /// `pacingAt(now)` from here on. Every `probe_interval_us` this marks the
    /// frame a probe, and `pacingAt` returns `probe_mult` x the pacing rate
    /// until the frame has left at that rate.
    pub fn onFrame(self: *Controller, now_us: i64, frame: u32, bytes: usize) void {
        // When the pacer should be done with what it has: a probe must not
        // speed up a backlog (a scene-change frame, or the old rate's queue
        // after a capacity drop), only a frame of its own.
        const idle = now_us >= self.pacer_busy_until_us;
        const start = @max(now_us, self.pacer_busy_until_us);
        self.pacer_busy_until_us = start + @as(i64, @intFromFloat(@as(f64, @floatFromInt(bytes)) * 8e6 / @max(self.pacingAt(now_us), 1)));
        if (self.cfg.probe_interval_us <= 0 or !idle) return;
        // Nor a frame much bigger than usual, which would leave a long queue.
        if (@as(f64, @floatFromInt(bytes)) > 1.5 * self.encoderBps() / 8 / self.cfg.fps) return;
        if (self.last_probe_us != std.math.minInt(i64) and now_us - self.last_probe_us < self.cfg.probe_interval_us) return;
        // A frame too small for a sample (or with no packets to spare) can't probe.
        if (bytes < @as(usize, self.cfg.pkt_bytes) * self.train.min_pkts) return;
        self.last_probe_us = now_us;
        self.train.markProbe(frame);
        self.gcc.probe_frames = self.train.probe_ids;
        self.probes += 1;
        self.probe_bps = self.cfg.probe_mult * self.pacingBps();
        const dur: i64 = @intFromFloat(@as(f64, @floatFromInt(bytes)) * 8e6 / self.probe_bps);
        self.probe_until_us = now_us + dur + 1_000;
        self.pacer_busy_until_us = now_us + dur;
    }

    /// The pacing rate to apply at host time `now_us`: `pacingBps`, or the
    /// probe rate while a probe frame is leaving.
    pub fn pacingAt(self: *const Controller, now_us: i64) f64 {
        return if (now_us < self.probe_until_us) @max(self.probe_bps, self.pacingBps()) else self.pacingBps();
    }

    /// Tell the controller the encoder's frame rate (the ladder changes it);
    /// the train floor depends on it.
    pub fn setFrameRate(self: *Controller, fps: f64) void {
        self.cfg.fps = fps;
        self.updateFloor();
    }

    /// The floor on the target currently in force, bits per second (0 = none).
    pub fn floorBps(self: *const Controller) f64 {
        return self.gcc.floor_bps;
    }

    fn updateFloor(self: *Controller) void {
        if (self.cfg.floor_pkts == 0) return self.gcc.setFloor(0);
        const enc = @as(f64, @floatFromInt(self.cfg.floor_pkts * self.cfg.pkt_bytes)) * 8 * self.cfg.fps * 1.25;
        const f = enc / self.cfg.app_share;
        const ok = if (self.last_capacity) |c| c >= 2 * f else false;
        self.gcc.setFloor(if (ok) f else 0);
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

    /// Feed a decoded transport-wide feedback message (`proto.Feedback`).
    /// Its 32-bit sequence numbers are widened against the send history, so
    /// `onSent` must be given the same transport sequence numbers, widened.
    pub fn onFeedbackMsg(self: *Controller, now_us: i64, msg: proto.Feedback.View) void {
        var buf: [256]history.Arrival = undefined;
        var n: usize = 0;
        var it = msg.iterator();
        const ref = self.history.next_expected;
        while (it.next()) |st| {
            buf[n] = .{ .seq = widen(ref, st.seq), .recv_us = if (st.arrival_us) |a| @intCast(a) else PacketResult.lost };
            n += 1;
            if (n == buf.len) {
                self.onArrivals(now_us, buf[0..n]);
                n = 0;
            }
        }
        if (n > 0) self.onArrivals(now_us, buf[0..n]);
    }

    /// Feed results already joined with the send records, in send order.
    /// `now_us` is the host clock when the feedback arrived.
    pub fn onFeedback(self: *Controller, now_us: i64, rs: []const PacketResult) void {
        for (rs) |r| {
            self.train.onResult(r);
            if (r.received()) self.last_recv_us = @max(self.last_recv_us, r.recv_us);
        }
        const cut_before = self.gcc.last_decrease_us;
        self.gcc.onFeedback(now_us, rs);
        if (self.gcc.last_decrease_us != cut_before) self.train.clearProbes();
        self.capacity = if (self.last_recv_us == std.math.minInt(i64)) null else self.train.estimateWithProbes(self.last_recv_us, self.cfg.train_window_us, self.cfg.probe_window_us);
        if (self.capacity) |c| self.last_capacity = c;
        self.updateFloor();
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
        // Next to a loss-based flow in a shared FIFO, frames paced at link rate
        // are the bursts that overflow it: pace near the target instead.
        if (self.gcc.competing) return self.cfg.competing_pace * t;
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
            .competing = g.competing,
            .competing_entries = g.competing_entries,
            .competing_cuts = g.competing_cuts,
            .loss_cuts = g.loss_cuts,
            .floor_bps = g.floor_bps,
            .probes = self.probes,
        };
    }
};
