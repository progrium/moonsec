//! S11 simulator: a 60 fps video sender, a pacer, one bottleneck (wired or
//! Wi-Fi-like) shared with cross traffic, a receiver that sends
//! transport-wide feedback every few ms, and the controllers from est.zig.
//! Discrete-event, deterministic per seed.
const std = @import("std");
const est = @import("est.zig");

const US: i64 = 1;
const MS: i64 = 1000;
const SEC: i64 = 1_000_000;
const PKT: u32 = 1200;
const TRAIN_WIN: i64 = 300 * MS;

// ---------------------------------------------------------------------------
// Scenarios

pub const Cross = union(enum) {
    none,
    /// CBR UDP that toggles on and off with exponential periods.
    onoff: struct { bps: f64, mean_on_us: i64, mean_off_us: i64 },
    /// One Reno flow in the same queue, active in [start, stop).
    tcp: struct { start_us: i64, stop_us: i64 },
    /// Line-rate bursts (a web page, a download chunk) at exponential intervals.
    bursts: struct { bytes: u32, mean_gap_us: i64 },
};

pub const Step = struct { t: i64, bps: f64 };

pub const Scenario = struct {
    name: []const u8,
    duration_us: i64 = 60 * SEC,
    rtt_us: i64 = 20 * MS,
    qlimit_bytes: u32 = 500_000,
    steps: []const Step,
    /// random capacity changes every 2–5 s in [lo, hi] (overrides steps after t=0)
    fade: ?struct { lo: f64, hi: f64 } = null,
    wifi: bool = false,
    agg_min_us: i64 = 500,
    agg_max_us: i64 = 4 * MS,
    stall_mean_gap_us: i64 = 2 * SEC,
    stall_min_us: i64 = 5 * MS,
    stall_max_us: i64 = 60 * MS,
    cross: Cross = .none,
    /// samples count as steady this long after the last capacity/cross change
    steady_after_us: i64 = 5 * SEC,
};

pub const Pacing = enum { x1, x2_5, train };

pub const Variant = struct {
    name: []const u8,
    kind: est.Kind,
    burst_grouping: bool = true,
    initial_ramp: bool = false,
    pacing: Pacing = .x2_5,
    probe: bool = false, // feed the frame-train capacity into the controller
    drain_us: f64 = 0, // GCC hybrid standing-queue drain threshold
    drain_hold_us: i64 = 150_000,
    drain_giveup_us: i64 = 1_500_000,
    /// encoder bitrate as a share of the controller's target (pacing still
    /// follows the capacity estimate); < 1 trades bitrate for frame delay
    encoder_share: f64 = 1.0,
    qdelay_target_us: f64 = 5_000,
};

pub const RunCfg = struct {
    scen: Scenario,
    variant: Variant,
    seed: u64,
    fb_interval_us: i64 = 5 * MS,
    start_bps: f64 = 5_000_000,
    csv: bool = false,
};

// ---------------------------------------------------------------------------
// Event machinery

const Flow = enum(u8) { media, udp, tcp };

const Packet = struct {
    flow: Flow,
    size: u32,
    seq: u64 = 0,
    send_us: i64 = 0,
    enq_us: i64 = 0,
    frame: u32 = 0,
    frame_last: bool = false,
};

const EvKind = enum(u8) {
    frame,
    pacer,
    service_done,
    deliver,
    stall_start,
    stall_end,
    cap_change,
    fb_timer,
    fb_arrive,
    udp_tick,
    udp_toggle,
    tcp_start,
    tcp_ack,
    tcp_loss,
    burst,
    sample,
};

const Event = struct {
    t: i64,
    order: u64,
    kind: EvKind,
    a: u64 = 0,
    b: f64 = 0,
};

fn evLess(_: void, x: Event, y: Event) std.math.Order {
    if (x.t != y.t) return std.math.order(x.t, y.t);
    return std.math.order(x.order, y.order);
}

const FrameRec = struct {
    capture_us: i64,
    npkts: u32,
    arrived: u32 = 0,
    lost: bool = false,
    last_arr: i64 = 0,
};

const FbEntry = struct { seq: u64, recv_us: i64 };

pub const Summary = struct {
    est_ratio_p10: f64 = 0,
    est_ratio_p50: f64 = 0,
    est_ratio_p90: f64 = 0,
    util_p50: f64 = 0, // media goodput / available capacity, steady windows
    train_ratio_p50: f64 = 0,
    net_p50: f64 = 0,
    net_p95: f64 = 0,
    net_p99: f64 = 0,
    frame_p50: f64 = 0,
    frame_p95: f64 = 0,
    frame_p99: f64 = 0,
    frames_lost: u32 = 0,
    frames: u32 = 0,
    loss_pct: f64 = 0,
    down_react_ms: f64 = -1, // first step down: until target <= new available
    down_peak_ms: f64 = -1, // first step down: peak p95 net delay in following 5 s
    down_drain_ms: f64 = -1, // first step down: until p95 net delay stays < 20 ms
    up_ms: f64 = -1, // first step up: until target >= 0.8 x new available
    startup_ms: f64 = -1, // until target >= 0.8 x available at t=0
    media_mbps: f64 = 0,
    cross_mbps: f64 = 0,
    overuses: u32 = 0,
};

const Sim = struct {
    gpa: std.mem.Allocator,
    cfg: RunCfg,
    rng: std.Random.DefaultPrng,
    q: std.PriorityQueue(Event, void, evLess) = .empty,
    order: u64 = 0,
    now: i64 = 0,
    pkts: std.ArrayList(Packet) = .empty,
    clock_offset: i64 = 987_654_321, // receiver clock offset, must cancel out

    // controller state
    ctl: est.Controller,
    train: est.TrainCap = .{},
    target: f64,
    pace: f64,

    // sender
    frames: std.ArrayList(FrameRec) = .empty,
    pacer_fifo: std.ArrayList(u32) = .empty,
    pacer_head: usize = 0,
    pacer_next: i64 = 0,
    pacer_armed: bool = false,
    next_seq: u64 = 0,
    sent: std.ArrayList(u32) = .empty, // seq -> packet index
    fb_expected: u64 = 0,
    results: std.ArrayList(est.Result) = .empty,

    // bottleneck
    cap: f64,
    queue: std.ArrayList(u32) = .empty,
    qhead: usize = 0,
    qbytes: u64 = 0,
    busy: bool = false,
    stalled: bool = false,
    agg_next: i64 = 0,
    stall_time: i64 = 0,

    // receiver
    fb_pending: std.ArrayList(FbEntry) = .empty,
    fb_last_arrive: i64 = 0,

    // cross traffic
    udp_on: bool = false,
    tcp_cwnd: f64 = 10,
    tcp_ssthresh: f64 = 1e9,
    tcp_inflight: u32 = 0,
    tcp_last_cut: i64 = -SEC,
    tcp_active: bool = false,

    // metrics
    net_delays: std.ArrayList(f32) = .empty,
    frame_delays: std.ArrayList(f32) = .empty,
    win_delays: std.ArrayList(f32) = .empty,
    win_media_bytes: u64 = 0,
    win_cross_bytes: u64 = 0,
    tot_media_bytes: u64 = 0,
    tot_cross_bytes: u64 = 0,
    media_sent: u64 = 0,
    media_lost: u64 = 0,
    samples: std.ArrayList(Sample) = .empty,
    last_change_us: i64 = 0, // last capacity or cross change (for steady windows)
    csv: std.ArrayList(u8) = .empty,

    const Sample = struct {
        t: i64,
        cap: f64,
        avail: f64,
        target: f64,
        pace: f64,
        train: f64,
        media: f64,
        cross: f64,
        p95: f64,
        steady: bool,
    };

    fn rnd(self: *Sim) std.Random {
        return self.rng.random();
    }

    fn at(self: *Sim, t: i64, kind: EvKind, a: u64, b: f64) !void {
        self.order += 1;
        try self.q.push(self.gpa, .{ .t = t, .order = self.order, .kind = kind, .a = a, .b = b });
    }

    fn expDur(self: *Sim, mean: i64) i64 {
        return @intFromFloat(self.rnd().floatExp(f64) * @as(f64, @floatFromInt(mean)));
    }

    fn stallDuty(self: *const Sim) f64 {
        const s = self.cfg.scen;
        if (!s.wifi) return 0;
        const mean_stall = @as(f64, @floatFromInt(s.stall_min_us + s.stall_max_us)) / 2;
        return mean_stall / (mean_stall + @as(f64, @floatFromInt(s.stall_mean_gap_us)));
    }

    /// Capacity available to the media flow right now (ground truth).
    fn available(self: *const Sim) f64 {
        var a = self.cap * (1 - self.stallDuty());
        switch (self.cfg.scen.cross) {
            .onoff => |o| if (self.udp_on) {
                a -= o.bps;
            },
            .tcp => if (self.tcp_active) {
                a /= 2; // fair share
            },
            else => {},
        }
        return @max(a, 0);
    }

    fn setRates(self: *Sim) void {
        self.target = self.ctl.target();
        const tc = self.train.estimate(self.now + self.clock_offset, TRAIN_WIN);
        self.pace = switch (self.cfg.variant.pacing) {
            .x1 => self.target,
            .x2_5 => 2.5 * self.target,
            .train => if (tc) |c| std.math.clamp(c, 1.1 * self.target, 4 * self.target) else 2.5 * self.target,
        };
    }

    // --- sender ------------------------------------------------------------

    fn onFrame(self: *Sim) !void {
        const fid: u32 = @intCast(self.frames.items.len);
        var bytes = self.cfg.variant.encoder_share * self.target / 8.0 / 60.0 * @exp(0.25 * self.rnd().floatNorm(f64) - 0.03);
        if (fid % 180 == 0 and fid > 0) bytes *= 4; // a scene change every 3 s
        const n: u32 = @max(1, @as(u32, @intFromFloat(@ceil(bytes / PKT))));
        const total: u32 = @intFromFloat(@max(bytes, 100));
        var left = total;
        for (0..n) |k| {
            const sz = if (k + 1 == n) @max(left, 100) else PKT;
            left -|= sz;
            try self.pkts.append(self.gpa, .{ .flow = .media, .size = sz, .frame = fid, .frame_last = k + 1 == n });
            try self.pacer_fifo.append(self.gpa, @intCast(self.pkts.items.len - 1));
        }
        try self.frames.append(self.gpa, .{ .capture_us = self.now, .npkts = n });
        if (!self.pacer_armed) {
            self.pacer_armed = true;
            try self.at(@max(self.now, self.pacer_next), .pacer, 0, 0);
        }
        try self.at(self.now + 16_667, .frame, 0, 0);
    }

    fn onPacer(self: *Sim) !void {
        if (self.pacer_head >= self.pacer_fifo.items.len) {
            self.pacer_armed = false;
            return;
        }
        const idx = self.pacer_fifo.items[self.pacer_head];
        self.pacer_head += 1;
        const p = &self.pkts.items[idx];
        p.seq = self.next_seq;
        self.next_seq += 1;
        p.send_us = self.now;
        try self.sent.append(self.gpa, idx);
        self.media_sent += 1;
        try self.enqueue(idx);
        self.pacer_next = @max(self.pacer_next, self.now - 2 * MS) + @as(i64, @intFromFloat(@as(f64, @floatFromInt(p.size)) * 8e6 / self.pace));
        if (self.pacer_head < self.pacer_fifo.items.len) {
            try self.at(@max(self.now, self.pacer_next), .pacer, 0, 0);
        } else self.pacer_armed = false;
    }

    // --- bottleneck -------------------------------------------------------

    fn enqueue(self: *Sim, idx: u32) !void {
        const p = &self.pkts.items[idx];
        if (self.qbytes + p.size > self.cfg.scen.qlimit_bytes) {
            switch (p.flow) {
                .media => {}, // receiver never sees it; feedback reports it lost
                .tcp => try self.at(self.now + self.cfg.scen.rtt_us, .tcp_loss, 0, 0),
                .udp => {},
            }
            return;
        }
        p.enq_us = self.now;
        try self.queue.append(self.gpa, idx);
        self.qbytes += p.size;
        try self.kick();
    }

    fn kick(self: *Sim) !void {
        if (self.busy or self.stalled or self.qhead >= self.queue.items.len) return;
        const idx = self.queue.items[self.qhead];
        const sz = self.pkts.items[idx].size;
        self.busy = true;
        const tx: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(sz)) * 8e6 / self.cap));
        try self.at(self.now + @max(tx, 1), .service_done, idx, 0);
    }

    fn onServiceDone(self: *Sim, idx: u32) !void {
        self.qhead += 1;
        self.qbytes -= self.pkts.items[idx].size;
        if (self.qhead > 4096 and self.qhead * 2 > self.queue.items.len) {
            const rest = self.queue.items[self.qhead..];
            std.mem.copyForwards(u32, self.queue.items[0..rest.len], rest);
            self.queue.shrinkRetainingCapacity(rest.len);
            self.qhead = 0;
        }
        self.busy = false;
        var out = self.now;
        if (self.cfg.scen.wifi) {
            // A-MPDU style: packets leave the radio in aggregates, so the
            // receiver sees them in batches at aggregate boundaries.
            const s = self.cfg.scen;
            while (self.agg_next < self.now) self.agg_next += s.agg_min_us + @as(i64, @intCast(self.rnd().uintLessThan(u64, @intCast(s.agg_max_us - s.agg_min_us))));
            out = self.agg_next;
        }
        try self.at(out + @divTrunc(self.cfg.scen.rtt_us, 2), .deliver, idx, @floatFromInt(out));
        try self.kick();
    }

    // --- receiver -----------------------------------------------------------

    fn onDeliver(self: *Sim, idx: u32, out_us: i64) !void {
        const p = self.pkts.items[idx];
        switch (p.flow) {
            .media => {
                const recv = self.now + self.clock_offset;
                try self.fb_pending.append(self.gpa, .{ .seq = p.seq, .recv_us = recv });
                const net = @as(f32, @floatFromInt(self.now - p.send_us - @divTrunc(self.cfg.scen.rtt_us, 2))) / 1000.0;
                if (self.now > 5 * SEC) try self.net_delays.append(self.gpa, net);
                try self.win_delays.append(self.gpa, net);
                self.win_media_bytes += p.size;
                self.tot_media_bytes += p.size;
                const f = &self.frames.items[p.frame];
                f.arrived += 1;
                f.last_arr = self.now;
                if (f.arrived == f.npkts and !f.lost and self.now > 5 * SEC) {
                    try self.frame_delays.append(self.gpa, @as(f32, @floatFromInt(self.now - f.capture_us - @divTrunc(self.cfg.scen.rtt_us, 2))) / 1000.0);
                }
            },
            .tcp => {
                self.win_cross_bytes += p.size;
                self.tot_cross_bytes += p.size;
                try self.at(self.now + @divTrunc(self.cfg.scen.rtt_us, 2), .tcp_ack, 0, 0);
            },
            .udp => {
                self.win_cross_bytes += p.size;
                self.tot_cross_bytes += p.size;
            },
        }
        _ = out_us;
    }

    fn onFbTimer(self: *Sim) !void {
        if (self.fb_pending.items.len > 0) {
            // carry the batch to the sender; reverse path has its own small jitter on Wi-Fi
            var t = self.now + @divTrunc(self.cfg.scen.rtt_us, 2);
            if (self.cfg.scen.wifi) t += @intCast(self.rnd().uintLessThan(u64, 2000));
            t = @max(t, self.fb_last_arrive);
            self.fb_last_arrive = t;
            const batch = try self.gpa.dupe(FbEntry, self.fb_pending.items);
            self.fb_pending.clearRetainingCapacity();
            try self.at(t, .fb_arrive, @intFromPtr(batch.ptr), @floatFromInt(batch.len));
        }
        try self.at(self.now + self.cfg.fb_interval_us, .fb_timer, 0, 0);
    }

    fn onFbArrive(self: *Sim, ptr: u64, len: usize) !void {
        const batch = @as([*]FbEntry, @ptrFromInt(ptr))[0..len];
        defer self.gpa.free(batch);
        self.results.clearRetainingCapacity();
        const max_seq = batch[len - 1].seq;
        var bi: usize = 0;
        var s = self.fb_expected;
        while (s <= max_seq) : (s += 1) {
            const p = self.pkts.items[self.sent.items[s]];
            var recv: i64 = -1;
            if (bi < len and batch[bi].seq == s) {
                recv = batch[bi].recv_us;
                bi += 1;
            } else {
                self.media_lost += 1;
                self.frames.items[p.frame].lost = true;
            }
            const r = est.Result{ .seq = s, .send_us = p.send_us, .recv_us = recv, .size = p.size, .frame = p.frame, .frame_last = p.frame_last };
            try self.results.append(self.gpa, r);
            self.train.onResult(r);
        }
        self.fb_expected = max_seq + 1;
        self.ctl.onFeedback(self.now, self.results.items);
        if (self.cfg.variant.probe) {
            if (self.train.estimate(self.now + self.clock_offset, TRAIN_WIN)) |c| self.ctl.onCapacity(self.now, c);
        }
        self.setRates();
    }

    // --- cross traffic ------------------------------------------------------

    fn tcpSend(self: *Sim) !void {
        if (!self.tcp_active) return;
        while (@as(f64, @floatFromInt(self.tcp_inflight)) < self.tcp_cwnd) {
            try self.pkts.append(self.gpa, .{ .flow = .tcp, .size = 1500 });
            self.tcp_inflight += 1;
            try self.enqueue(@intCast(self.pkts.items.len - 1));
        }
    }

    fn onTcpAck(self: *Sim) !void {
        self.tcp_inflight -|= 1;
        if (self.tcp_cwnd < self.tcp_ssthresh) self.tcp_cwnd += 1 else self.tcp_cwnd += 1 / self.tcp_cwnd;
        self.tcp_cwnd = @min(self.tcp_cwnd, 20000);
        try self.tcpSend();
    }

    fn onTcpLoss(self: *Sim) !void {
        self.tcp_inflight -|= 1;
        if (self.now - self.tcp_last_cut > self.cfg.scen.rtt_us) {
            self.tcp_cwnd = @max(self.tcp_cwnd / 2, 2);
            self.tcp_ssthresh = self.tcp_cwnd;
            self.tcp_last_cut = self.now;
        }
        try self.tcpSend();
    }

    // --- sampling -----------------------------------------------------------

    fn onSample(self: *Sim) !void {
        var p95: f64 = 0;
        if (self.win_delays.items.len > 0) {
            std.mem.sort(f32, self.win_delays.items, {}, std.sort.asc(f32));
            p95 = self.win_delays.items[(self.win_delays.items.len * 95) / 100];
        }
        const tc = self.train.estimate(self.now + self.clock_offset, TRAIN_WIN) orelse 0;
        const s = Sample{
            .t = self.now,
            .cap = self.cap,
            .avail = self.available(),
            .target = self.target,
            .pace = self.pace,
            .train = tc,
            .media = @as(f64, @floatFromInt(self.win_media_bytes)) * 8 * 10,
            .cross = @as(f64, @floatFromInt(self.win_cross_bytes)) * 8 * 10,
            .p95 = p95,
            .steady = self.now > 5 * SEC and self.now - self.last_change_us > self.cfg.scen.steady_after_us,
        };
        try self.samples.append(self.gpa, s);
        if (self.cfg.csv) try self.csv.print(self.gpa, "{d:.1},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d}\n", .{
            @as(f64, @floatFromInt(self.now)) / 1e6, s.cap / 1e6, s.avail / 1e6, s.target / 1e6, s.pace / 1e6, s.train / 1e6, s.media / 1e6, s.cross / 1e6, s.p95, self.qbytes,
        });
        self.win_delays.clearRetainingCapacity();
        self.win_media_bytes = 0;
        self.win_cross_bytes = 0;
        try self.at(self.now + 100 * MS, .sample, 0, 0);
    }

    fn run(self: *Sim) !Summary {
        const sc = self.cfg.scen;
        self.cap = sc.steps[0].bps;
        try self.at(0, .frame, 0, 0);
        try self.at(self.cfg.fb_interval_us, .fb_timer, 0, 0);
        try self.at(100 * MS, .sample, 0, 0);
        for (sc.steps[1..]) |st| try self.at(st.t, .cap_change, 0, st.bps);
        if (sc.fade) |f| {
            var t: i64 = 2 * SEC;
            while (t < sc.duration_us) {
                try self.at(t, .cap_change, 0, f.lo + self.rnd().float(f64) * (f.hi - f.lo));
                t += 2 * SEC + @as(i64, @intCast(self.rnd().uintLessThan(u64, 3 * SEC)));
            }
        }
        if (sc.wifi) try self.at(self.expDur(sc.stall_mean_gap_us), .stall_start, 0, 0);
        switch (sc.cross) {
            .onoff => |o| try self.at(self.expDur(o.mean_off_us), .udp_toggle, 0, 0),
            .tcp => |t| {
                try self.at(t.start_us, .tcp_start, 1, 0);
                try self.at(t.stop_us, .tcp_start, 0, 0);
            },
            .bursts => |b| try self.at(self.expDur(b.mean_gap_us), .burst, 0, 0),
            .none => {},
        }

        while (self.q.pop()) |ev| {
            if (ev.t > sc.duration_us) break;
            self.now = ev.t;
            switch (ev.kind) {
                .frame => try self.onFrame(),
                .pacer => try self.onPacer(),
                .service_done => try self.onServiceDone(@intCast(ev.a)),
                .deliver => try self.onDeliver(@intCast(ev.a), @intFromFloat(ev.b)),
                .stall_start => {
                    self.stalled = true;
                    const d = sc.stall_min_us + @as(i64, @intCast(self.rnd().uintLessThan(u64, @intCast(sc.stall_max_us - sc.stall_min_us))));
                    self.stall_time += d;
                    try self.at(self.now + d, .stall_end, 0, 0);
                },
                .stall_end => {
                    self.stalled = false;
                    try self.kick();
                    try self.at(self.now + self.expDur(sc.stall_mean_gap_us), .stall_start, 0, 0);
                },
                .cap_change => {
                    self.cap = ev.b;
                    self.last_change_us = self.now;
                },
                .fb_timer => try self.onFbTimer(),
                .fb_arrive => try self.onFbArrive(ev.a, @intFromFloat(ev.b)),
                .udp_toggle => {
                    const o = sc.cross.onoff;
                    self.udp_on = !self.udp_on;
                    self.last_change_us = self.now;
                    if (self.udp_on) try self.at(self.now, .udp_tick, 0, 0);
                    try self.at(self.now + self.expDur(if (self.udp_on) o.mean_on_us else o.mean_off_us), .udp_toggle, 0, 0);
                },
                .udp_tick => if (self.udp_on) {
                    const o = sc.cross.onoff;
                    try self.pkts.append(self.gpa, .{ .flow = .udp, .size = PKT });
                    try self.enqueue(@intCast(self.pkts.items.len - 1));
                    try self.at(self.now + @as(i64, @intFromFloat(@as(f64, PKT) * 8e6 / o.bps)), .udp_tick, 0, 0);
                },
                .tcp_start => {
                    self.tcp_active = ev.a == 1;
                    self.last_change_us = self.now;
                    if (self.tcp_active) {
                        self.tcp_cwnd = 10;
                        self.tcp_ssthresh = 1e9;
                        try self.tcpSend();
                    }
                },
                .tcp_ack => try self.onTcpAck(),
                .tcp_loss => try self.onTcpLoss(),
                .burst => {
                    const b = sc.cross.bursts;
                    var left: u32 = b.bytes;
                    while (left > 0) {
                        const sz = @min(left, 1500);
                        left -= sz;
                        try self.pkts.append(self.gpa, .{ .flow = .udp, .size = sz });
                        try self.enqueue(@intCast(self.pkts.items.len - 1));
                    }
                    try self.at(self.now + self.expDur(b.mean_gap_us), .burst, 0, 0);
                },
                .sample => try self.onSample(),
            }
        }
        // free any undelivered feedback batches
        while (self.q.pop()) |ev| if (ev.kind == .fb_arrive) self.gpa.free(@as([*]FbEntry, @ptrFromInt(ev.a))[0..@intFromFloat(ev.b)]);
        return self.summarize();
    }

    fn summarize(self: *Sim) !Summary {
        var s = Summary{};
        const pct = struct {
            fn f(xs: []f32, p: usize) f64 {
                if (xs.len == 0) return 0;
                return xs[@min(xs.len - 1, (xs.len * p) / 100)];
            }
            fn g(xs: []f64, p: usize) f64 {
                if (xs.len == 0) return 0;
                return xs[@min(xs.len - 1, (xs.len * p) / 100)];
            }
        };
        std.mem.sort(f32, self.net_delays.items, {}, std.sort.asc(f32));
        std.mem.sort(f32, self.frame_delays.items, {}, std.sort.asc(f32));
        s.net_p50 = pct.f(self.net_delays.items, 50);
        s.net_p95 = pct.f(self.net_delays.items, 95);
        s.net_p99 = pct.f(self.net_delays.items, 99);
        s.frame_p50 = pct.f(self.frame_delays.items, 50);
        s.frame_p95 = pct.f(self.frame_delays.items, 95);
        s.frame_p99 = pct.f(self.frame_delays.items, 99);
        for (self.frames.items) |f| {
            if (f.capture_us < 5 * SEC) continue;
            s.frames += 1;
            if (f.lost) s.frames_lost += 1;
        }
        s.loss_pct = if (self.media_sent > 0) 100 * @as(f64, @floatFromInt(self.media_lost)) / @as(f64, @floatFromInt(self.media_sent)) else 0;
        const secs = @as(f64, @floatFromInt(self.cfg.scen.duration_us)) / 1e6;
        s.media_mbps = @as(f64, @floatFromInt(self.tot_media_bytes)) * 8 / secs / 1e6;
        s.cross_mbps = @as(f64, @floatFromInt(self.tot_cross_bytes)) * 8 / secs / 1e6;

        var ratios: std.ArrayList(f64) = .empty;
        var utils: std.ArrayList(f64) = .empty;
        var trains: std.ArrayList(f64) = .empty;
        defer ratios.deinit(self.gpa);
        defer utils.deinit(self.gpa);
        defer trains.deinit(self.gpa);
        for (self.samples.items) |x| {
            if (!x.steady or x.avail <= 0) continue;
            try ratios.append(self.gpa, x.target / x.avail);
            try utils.append(self.gpa, x.media / x.avail);
            if (x.train > 0) try trains.append(self.gpa, x.train / (x.cap * (1 - self.stallDuty())));
        }
        std.mem.sort(f64, ratios.items, {}, std.sort.asc(f64));
        std.mem.sort(f64, utils.items, {}, std.sort.asc(f64));
        std.mem.sort(f64, trains.items, {}, std.sort.asc(f64));
        s.est_ratio_p10 = pct.g(ratios.items, 10);
        s.est_ratio_p50 = pct.g(ratios.items, 50);
        s.est_ratio_p90 = pct.g(ratios.items, 90);
        s.util_p50 = pct.g(utils.items, 50);
        s.train_ratio_p50 = pct.g(trains.items, 50);

        // startup
        for (self.samples.items) |x| if (x.target >= 0.8 * x.avail) {
            s.startup_ms = @floatFromInt(@divTrunc(x.t, MS));
            break;
        };
        // first step down / up from the fixed schedule
        const steps = self.cfg.scen.steps;
        var did_down = false;
        var did_up = false;
        for (steps[1..], 1..) |st, k| {
            const down = st.bps < steps[k - 1].bps;
            if (down and !did_down) {
                did_down = true;
                var peak: f64 = 0;
                var last_bad: i64 = st.t;
                for (self.samples.items) |x| {
                    if (x.t <= st.t or x.t > st.t + 5 * SEC) continue;
                    if (s.down_react_ms < 0 and x.target <= x.avail) s.down_react_ms = @floatFromInt(@divTrunc(x.t - st.t, MS));
                    peak = @max(peak, x.p95);
                    if (x.p95 >= 20) last_bad = x.t;
                }
                s.down_peak_ms = peak;
                s.down_drain_ms = @floatFromInt(@divTrunc(last_bad - st.t, MS));
            } else if (!down and !did_up) {
                did_up = true;
                for (self.samples.items) |x| {
                    if (x.t <= st.t) continue;
                    if (x.target >= 0.8 * x.avail) {
                        s.up_ms = @floatFromInt(@divTrunc(x.t - st.t, MS));
                        break;
                    }
                }
            }
        }
        switch (self.ctl) {
            .gcc => |g| s.overuses = g.overuse_events,
            else => {},
        }
        return s;
    }
};

pub fn runOne(gpa: std.mem.Allocator, cfg: RunCfg) !struct { sum: Summary, csv: []u8 } {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = cfg.variant;
    const ctl: est.Controller = switch (v.kind) {
        .gcc => .{ .gcc = est.Gcc.init(.{ .burst_grouping = v.burst_grouping, .initial_ramp = v.initial_ramp, .start_bps = cfg.start_bps, .rtt_us = cfg.scen.rtt_us, .drain_us = v.drain_us, .drain_hold_us = v.drain_hold_us, .drain_giveup_us = v.drain_giveup_us, .app_share = v.encoder_share }) },
        .qdelay => .{ .qdelay = est.QDelay.init(.{ .target_us = v.qdelay_target_us, .start_bps = cfg.start_bps, .rtt_us = cfg.scen.rtt_us }) },
    };
    var sim = Sim{
        .gpa = a,
        .cfg = cfg,
        .rng = std.Random.DefaultPrng.init(cfg.seed),
        .ctl = ctl,
        .target = cfg.start_bps,
        .pace = 2.5 * cfg.start_bps,
        .cap = 0,
    };
    sim.setRates();
    const sum = try sim.run();
    return .{ .sum = sum, .csv = try gpa.dupe(u8, sim.csv.items) };
}

// ---------------------------------------------------------------------------

const M = 1_000_000.0;

const steps_std = [_]Step{ .{ .t = 0, .bps = 50 * M }, .{ .t = 20 * SEC, .bps = 20 * M }, .{ .t = 40 * SEC, .bps = 80 * M } };
const steps_lan = [_]Step{ .{ .t = 0, .bps = 100 * M }, .{ .t = 20 * SEC, .bps = 40 * M }, .{ .t = 40 * SEC, .bps = 150 * M } };
const flat80 = [_]Step{.{ .t = 0, .bps = 80 * M }};
const flat50 = [_]Step{.{ .t = 0, .bps = 50 * M }};
const fade0 = [_]Step{.{ .t = 0, .bps = 60 * M }};

pub const scenarios = [_]Scenario{
    .{ .name = "wired-steps", .steps = &steps_std },
    .{ .name = "wifi-steps", .steps = &steps_std, .wifi = true },
    .{ .name = "wifi-lan", .steps = &steps_lan, .wifi = true, .rtt_us = 2 * MS },
    .{ .name = "wifi-fade", .steps = &fade0, .wifi = true, .fade = .{ .lo = 25 * M, .hi = 120 * M }, .steady_after_us = 1 * SEC },
    .{ .name = "wifi-udp-cross", .steps = &flat80, .wifi = true, .cross = .{ .onoff = .{ .bps = 40 * M, .mean_on_us = 4 * SEC, .mean_off_us = 4 * SEC } }, .steady_after_us = 2 * SEC },
    .{ .name = "wifi-tcp", .steps = &flat50, .wifi = true, .cross = .{ .tcp = .{ .start_us = 20 * SEC, .stop_us = 40 * SEC } } },
    .{ .name = "wifi-bursts", .steps = &flat50, .wifi = true, .cross = .{ .bursts = .{ .bytes = 300_000, .mean_gap_us = 2 * SEC } } },
    .{ .name = "wired-60ms", .steps = &steps_std, .rtt_us = 60 * MS },
};

pub const variants = [_]Variant{
    .{ .name = "gcc", .kind = .gcc },
    .{ .name = "gcc-x1", .kind = .gcc, .pacing = .x1 },
    .{ .name = "gcc-train", .kind = .gcc, .pacing = .train },
    .{ .name = "gcc-nogroup", .kind = .gcc, .burst_grouping = false },
    .{ .name = "gcc-ramp", .kind = .gcc, .initial_ramp = true },
    .{ .name = "gcc-probe", .kind = .gcc, .pacing = .train, .probe = true },
    .{ .name = "gcc-hybrid", .kind = .gcc, .pacing = .train, .probe = true, .drain_us = 30_000 },
    .{ .name = "gcc-hybrid-nohold", .kind = .gcc, .pacing = .train, .probe = true, .drain_us = 30_000, .drain_hold_us = 0, .drain_giveup_us = 0 },
    .{ .name = "gcc-hybrid-enc60", .kind = .gcc, .pacing = .train, .probe = true, .drain_us = 30_000, .encoder_share = 0.6 },
    .{ .name = "qdelay", .kind = .qdelay },
    .{ .name = "qdelay-probe", .kind = .qdelay, .pacing = .train, .probe = true },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var only_scen: ?[]const u8 = null;
    var only_var: ?[]const u8 = null;
    var seeds: u64 = 3;
    var outdir: []const u8 = "results/sim";
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--scen")) only_scen = args[i + 1];
        if (std.mem.eql(u8, args[i], "--variant")) only_var = args[i + 1];
        if (std.mem.eql(u8, args[i], "--seeds")) seeds = try std.fmt.parseInt(u64, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--out")) outdir = args[i + 1];
    }
    var table: std.ArrayList(u8) = .empty;
    try table.print(arena, "scenario,variant,seed,est_p10,est_p50,est_p90,util_p50,train_p50,net_p50,net_p95,net_p99,frame_p50,frame_p95,frame_p99,frames_lost,frames,loss_pct,startup_ms,down_react_ms,down_peak_ms,down_drain_ms,up_ms,media_mbps,cross_mbps,overuses\n", .{});
    for (scenarios) |sc| {
        if (only_scen) |o| if (!std.mem.eql(u8, o, sc.name)) continue;
        for (variants) |v| {
            if (only_var) |o| if (!std.mem.eql(u8, o, v.name)) continue;
            for (1..seeds + 1) |seed| {
                const r = try runOne(gpa, .{ .scen = sc, .variant = v, .seed = seed, .csv = seed == 1 });
                defer gpa.free(r.csv);
                const s = r.sum;
                try table.print(arena, "{s},{s},{d},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d},{d},{d:.3},{d:.0},{d:.0},{d:.1},{d:.0},{d:.0},{d:.2},{d:.2},{d}\n", .{
                    sc.name, v.name, seed, s.est_ratio_p10, s.est_ratio_p50, s.est_ratio_p90, s.util_p50, s.train_ratio_p50, s.net_p50, s.net_p95, s.net_p99, s.frame_p50, s.frame_p95, s.frame_p99, s.frames_lost, s.frames, s.loss_pct, s.startup_ms, s.down_react_ms, s.down_peak_ms, s.down_drain_ms, s.up_ms, s.media_mbps, s.cross_mbps, s.overuses,
                });
                std.debug.print("{s:<15} {s:<13} s{d} est p50 {d:.2} [{d:.2}-{d:.2}] util {d:.2} train {d:.2} | net p50/95/99 {d:.1}/{d:.1}/{d:.1} ms | frame p50/99 {d:.1}/{d:.1} | lost {d}/{d} | start {d:.0} down {d:.0}/{d:.0}ms peak {d:.0} up {d:.0}\n", .{
                    sc.name, v.name, seed, s.est_ratio_p50, s.est_ratio_p10, s.est_ratio_p90, s.util_p50, s.train_ratio_p50, s.net_p50, s.net_p95, s.net_p99, s.frame_p50, s.frame_p99, s.frames_lost, s.frames, s.startup_ms, s.down_react_ms, s.down_drain_ms, s.down_peak_ms, s.up_ms,
                });
                if (seed == 1) {
                    const path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.csv", .{ outdir, sc.name, v.name });
                    var data: std.ArrayList(u8) = .empty;
                    try data.print(arena, "t,cap,avail,target,pace,train,media,cross,p95_ms,qbytes\n{s}", .{r.csv});
                    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = data.items });
                }
            }
        }
    }
    const tpath = try std.fmt.allocPrint(arena, "{s}/summary.csv", .{outdir});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = tpath, .data = table.items });
}

test {
    _ = est;
}
