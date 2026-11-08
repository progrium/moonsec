//! `zig build sim-rate -- [options]`: the core's rate controller (`core.rate`,
//! S11's gcc-hybrid) driving a 60 fps stream over the simulated network, with
//! S11's metrics, so its numbers can be checked against S11's table.
//!
//!   --scenario NAME   one s11-* scenario (default: all eight)
//!   --variant NAME    gcc-hybrid or gcc-hybrid-enc60 (default: both)
//!   --seeds N         seeds 1..N (default 5)
//!   --csv FILE        write per-run rows (S11's summary.csv columns)
//!   --trace FILE      write every run's 100 ms samples
//!   --check           first option: exit 1 if a median leaves S11's bands
//!
//! Endpoint A is the host: S11's frame source (target/60 × lognormal σ 0.25,
//! 4× scene change every 180 frames, 1200-byte packets) sent through A's
//! `PacketPipe`, which paces at the controller's pacing rate. Endpoint B is
//! the client: every 5 ms of its clock it sends a `proto.Feedback` message
//! (the real wire encoding) with arrival times for every packet since the
//! last one. The host decodes it and feeds `Controller.onFeedbackMsg`.
const std = @import("std");
const simnet = @import("simnet");
const core = @import("core");
const scenarios = @import("scenarios.zig");

const rate = core.rate;
const proto = core.proto;
const MS = simnet.MS;
const SEC = simnet.SEC;
const PKT = 1200;
/// Media header: 'M', seq u64, frame u32, then a last-of-frame byte.
const HDR = 14;
const FB_EVERY = 5 * MS;
const START_BPS = 5_000_000;

pub const Variant = struct {
    name: []const u8,
    app_share: f64 = 1.0,
};

pub const variants = [_]Variant{
    .{ .name = "gcc-hybrid" },
    .{ .name = "gcc-hybrid-enc60", .app_share = 0.6 },
};

/// S11's metrics (spikes/s11-capacity-estimation/README.md, "Metrics").
pub const Summary = struct {
    est_p10: f64 = 0,
    est_p50: f64 = 0,
    est_p90: f64 = 0,
    util_p50: f64 = 0,
    train_p50: f64 = 0,
    q_p50: f64 = 0,
    q_p95: f64 = 0,
    q_p99: f64 = 0,
    frame_p50: f64 = 0,
    frame_p95: f64 = 0,
    frame_p99: f64 = 0,
    frames_lost: u32 = 0,
    frames: u32 = 0,
    loss_pct: f64 = 0,
    /// -1 = never.
    startup_ms: f64 = -1,
    down_react_ms: f64 = -1,
    down_peak_ms: f64 = -1,
    down_drain_ms: f64 = -1,
    up_ms: f64 = -1,
    media_mbps: f64 = 0,
    overuses: u32 = 0,
    drains: u32 = 0,
};

const Sample = struct {
    t: i64,
    cap: f64,
    avail: f64,
    target: f64,
    train: f64,
    media: f64,
    p95: f64,
    steady: bool,
    pace: f64,
    qbytes: u64,
    overuses: u32,
    drains: u32,
    jumps: u32,
};

const Frame = struct {
    capture_us: i64,
    npkts: u32,
    arrived: u32 = 0,
    last_arr: i64 = 0,
};

/// Samples count as steady this long after a capacity or cross-traffic change
/// (S11: 1 s for the fade, 2 s for on/off UDP, 5 s otherwise).
fn steadyAfter(name: []const u8) i64 {
    if (std.mem.eql(u8, name, "s11-wifi-fade")) return 1 * SEC;
    if (std.mem.eql(u8, name, "s11-wifi-udp-cross")) return 2 * SEC;
    return 5 * SEC;
}

const Host = struct {
    ctl: *rate.Controller,
    /// seq -> when it left the pacer (host clock), for the queueing metric.
    sent_us: std.ArrayList(i64) = .empty,

    fn onPaced(ctx: ?*anyopaque, data: []const u8, local_us: i64) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        if (data.len < HDR or data[0] != 'M') return;
        const seq = std.mem.readInt(u64, data[1..9], .little);
        const frame = std.mem.readInt(u32, data[9..13], .little);
        self.ctl.onSent(seq, local_us, @intCast(data.len), frame, data[13] == 1);
        self.sent_us.items[@intCast(seq)] = local_us;
    }
};

/// `trace`, if given, gets one CSV row per 100 ms sample.
pub fn runOne(gpa: std.mem.Allocator, sc: scenarios.Scenario, v: Variant, seed: u64, trace: ?*Trace) !Summary {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = sc.net;
    cfg.seed = seed;
    const net = try gpa.create(simnet.Net);
    defer gpa.destroy(net);
    try net.init(gpa, cfg);
    defer net.deinit();
    const a = net.pipeFor(.a);
    const b = net.pipeFor(.b);
    const b_offset = cfg.b.clock_offset_us;
    const one_way = cfg.a_to_b.delay_us;
    const stall_duty = if (cfg.a_to_b.wifi) |w| w.stallDuty() else 0;

    const ctl = try gpa.create(rate.Controller);
    defer gpa.destroy(ctl);
    ctl.reset(.{ .gcc = .{ .start_bps = START_BPS, .rtt_us = 2 * one_way }, .app_share = v.app_share });
    var host = Host{ .ctl = ctl };
    net.setPacedHook(.a, .{ .ctx = &host, .func = Host.onPaced });
    a.setPacingRate(@intFromFloat(ctl.pacingBps()));

    // The frame source has its own random stream (S11: lognormal sizes).
    var prng = std.Random.DefaultPrng.init(seed ^ 0x72617465);
    const rnd = prng.random();

    var frames: std.ArrayList(Frame) = .empty;
    var samples: std.ArrayList(Sample) = .empty;
    var q_all: std.ArrayList(f32) = .empty;
    var q_win: std.ArrayList(f32) = .empty;
    var frame_delays: std.ArrayList(f32) = .empty;
    // Client side: arrivals since the last feedback, indexed from fb_base.
    var fb_base: u64 = 0;
    var fb_arr: std.ArrayList(?u64) = .empty;
    var fb_seq: u16 = 0;

    var next_frame: i64 = 0;
    var next_fb: i64 = FB_EVERY;
    var next_sample: i64 = 100 * MS;
    var seq: u64 = 0;
    var win_media_bytes: u64 = 0;
    var tot_media_bytes: u64 = 0;
    var last_change: i64 = 0;
    var last_cap = net.capacity(.a);
    var last_avail = net.available(.a);
    var buf: [PKT]u8 = undefined;
    @memset(&buf, 0x5a);

    while (true) {
        var t = @min(next_frame, @min(next_fb, next_sample));
        if (net.nextEventTime()) |e| t = @min(t, e);
        if (t > sc.duration_us) break;
        try net.runUntil(t);

        const cap = net.capacity(.a);
        const avail = net.available(.a);
        if (cap != last_cap or avail != last_avail) last_change = t;
        last_cap = cap;
        last_avail = avail;

        // Client: read media as it lands.
        while (try b.recv(&buf)) |r| {
            if (r.len < HDR or buf[0] != 'M') continue;
            const s = std.mem.readInt(u64, buf[1..9], .little);
            const fid = std.mem.readInt(u32, buf[9..13], .little);
            const now_b = r.recv_us - b_offset;
            if (s >= fb_base) {
                const i: usize = @intCast(s - fb_base);
                while (fb_arr.items.len <= i) try fb_arr.append(arena, null);
                fb_arr.items[i] = @intCast(r.recv_us);
            }
            // Ground-truth metrics (sim time; A's clock has no offset).
            const f = &frames.items[fid];
            win_media_bytes += r.len;
            tot_media_bytes += r.len;
            f.arrived += 1;
            f.last_arr = now_b;
            if (f.arrived == f.npkts and f.capture_us >= 5 * SEC) {
                try frame_delays.append(arena, @as(f32, @floatFromInt(now_b - f.capture_us - one_way)) / 1000.0);
            }
            // Queueing: one-way delay above propagation.
            const sent = host.sent_us.items[@intCast(s)];
            const q = @as(f32, @floatFromInt(now_b - sent - one_way)) / 1000.0;
            if (now_b > 5 * SEC) try q_all.append(arena, q);
            try q_win.append(arena, q);
        }

        // Client: feedback every 5 ms.
        if (t == next_fb) {
            if (fb_arr.items.len > 0) {
                var mbuf: [PKT]u8 = undefined;
                mbuf[0] = 'F';
                var e = proto.wire.Encoder.init(mbuf[1..]);
                // Cut to what fits one datagram; the rest goes next time.
                var n = fb_arr.items.len;
                while (true) {
                    e = proto.wire.Encoder.init(mbuf[1..]);
                    const msg = proto.Feedback{ .feedback_seq = fb_seq, .base_seq = @truncate(fb_base), .ref_time_us = @intCast(net.localTime(.b)), .arrivals = fb_arr.items[0..n] };
                    if (msg.encode(&e)) |_| break else |_| n /= 2;
                }
                fb_seq +%= 1;
                try b.send(mbuf[0 .. 1 + e.pos]);
                std.mem.copyForwards(?u64, fb_arr.items[0 .. fb_arr.items.len - n], fb_arr.items[n..]);
                fb_arr.shrinkRetainingCapacity(fb_arr.items.len - n);
                fb_base += n;
            }
            next_fb += FB_EVERY;
        }

        // Host: feedback in, rates out.
        var fb_in = false;
        while (try a.recv(&buf)) |r| {
            if (r.len < 1 or buf[0] != 'F') continue;
            var d = proto.wire.Decoder.init(buf[1..r.len]);
            const view = try proto.Feedback.decode(&d);
            ctl.onFeedbackMsg(net.localTime(.a), view);
            fb_in = true;
        }
        if (fb_in) a.setPacingRate(@intFromFloat(ctl.pacingAt(t)));

        // Host: one frame.
        if (t == next_frame) {
            const fid: u32 = @intCast(frames.items.len);
            var bytes = ctl.encoderBps() / 8.0 / 60.0 * @exp(0.25 * rnd.floatNorm(f64) - 0.03);
            if (fid % 180 == 0 and fid > 0) bytes *= 4;
            const n: u32 = @max(1, @as(u32, @intFromFloat(@ceil(bytes / PKT))));
            var left: u32 = @intFromFloat(@max(bytes, 100));
            try frames.append(arena, .{ .capture_us = t, .npkts = n });
            ctl.onFrame(t, fid, @intFromFloat(@max(bytes, 100)));
            a.setPacingRate(@intFromFloat(ctl.pacingAt(t)));
            for (0..n) |k| {
                const sz: u32 = if (k + 1 == n) @max(left, 100) else PKT;
                left -|= sz;
                buf[0] = 'M';
                std.mem.writeInt(u64, buf[1..9], seq, .little);
                std.mem.writeInt(u32, buf[9..13], fid, .little);
                buf[13] = @intFromBool(k + 1 == n);
                seq += 1;
                try host.sent_us.append(arena, 0);
                try a.send(buf[0..@max(sz, HDR)]);
            }
            next_frame += 16_667;
        }

        if (t == next_sample) {
            var p95: f64 = 0;
            if (q_win.items.len > 0) {
                std.mem.sort(f32, q_win.items, {}, std.sort.asc(f32));
                p95 = q_win.items[(q_win.items.len * 95) / 100];
            }
            try samples.append(arena, .{
                .t = t,
                .cap = cap,
                .avail = avail,
                .target = ctl.targetBps(),
                .train = ctl.capacityBps() orelse 0,
                .media = @as(f64, @floatFromInt(win_media_bytes)) * 8 * 10,
                .p95 = p95,
                .steady = t > 5 * SEC and t - last_change > steadyAfter(sc.name),
                .pace = ctl.pacingBps(),
                .qbytes = net.queueBytes(.a),
                .overuses = ctl.gcc.overuse_events,
                .drains = ctl.gcc.drains,
                .jumps = ctl.gcc.jumps,
            });
            if (trace) |tr| {
                const x = samples.items[samples.items.len - 1];
                try tr.out.print(tr.gpa, "{s},{s},{d},{d:.1},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d},{d},{d},{d}\n", .{
                    sc.name[4..], v.name, seed, @as(f64, @floatFromInt(x.t)) / 1e6, x.cap / 1e6, x.avail / 1e6, x.target / 1e6, x.pace / 1e6, x.train / 1e6, x.media / 1e6, x.p95, x.qbytes, x.overuses, x.drains, x.jumps,
                });
            }
            q_win.clearRetainingCapacity();
            win_media_bytes = 0;
            next_sample += 100 * MS;
        }
    }

    // --- summary (S11's definitions) ----------------------------------------
    var s = Summary{};
    std.mem.sort(f32, q_all.items, {}, std.sort.asc(f32));
    std.mem.sort(f32, frame_delays.items, {}, std.sort.asc(f32));
    s.q_p50 = pctf(q_all.items, 50);
    s.q_p95 = pctf(q_all.items, 95);
    s.q_p99 = pctf(q_all.items, 99);
    s.frame_p50 = pctf(frame_delays.items, 50);
    s.frame_p95 = pctf(frame_delays.items, 95);
    s.frame_p99 = pctf(frame_delays.items, 99);
    for (frames.items) |f| {
        // Frames still in flight at the end are not lost.
        if (f.capture_us < 5 * SEC or f.capture_us > sc.duration_us - 1 * SEC) continue;
        s.frames += 1;
        if (f.arrived < f.npkts) s.frames_lost += 1;
    }
    const ls = net.linkStats(.a);
    s.loss_pct = if (ls.sent > 0) 100 * @as(f64, @floatFromInt(ls.sent - ls.delivered)) / @as(f64, @floatFromInt(ls.sent)) else 0;
    s.media_mbps = @as(f64, @floatFromInt(tot_media_bytes)) * 8 / (@as(f64, @floatFromInt(sc.duration_us)) / 1e6) / 1e6;
    s.overuses = ctl.gcc.overuse_events;
    s.drains = ctl.gcc.drains;

    var ratios: std.ArrayList(f64) = .empty;
    var utils: std.ArrayList(f64) = .empty;
    var trains: std.ArrayList(f64) = .empty;
    for (samples.items) |x| {
        if (!x.steady or x.avail <= 0) continue;
        try ratios.append(arena, x.target / x.avail);
        try utils.append(arena, x.media / x.avail);
        if (x.train > 0) try trains.append(arena, x.train / (x.cap * (1 - stall_duty)));
    }
    std.mem.sort(f64, ratios.items, {}, std.sort.asc(f64));
    std.mem.sort(f64, utils.items, {}, std.sort.asc(f64));
    std.mem.sort(f64, trains.items, {}, std.sort.asc(f64));
    s.est_p10 = pctd(ratios.items, 10);
    s.est_p50 = pctd(ratios.items, 50);
    s.est_p90 = pctd(ratios.items, 90);
    s.util_p50 = pctd(utils.items, 50);
    s.train_p50 = pctd(trains.items, 50);

    for (samples.items) |x| if (x.target >= 0.8 * x.avail) {
        s.startup_ms = @floatFromInt(@divTrunc(x.t, MS));
        break;
    };
    const steps = cfg.a_to_b.steps;
    if (cfg.a_to_b.fade == null and steps.len > 1) {
        var did_down = false;
        var did_up = false;
        for (steps[1..], 1..) |st, k| {
            const down = st.bps < steps[k - 1].bps;
            if (down and !did_down) {
                did_down = true;
                var peak: f64 = 0;
                var last_bad: i64 = st.t_us;
                for (samples.items) |x| {
                    if (x.t <= st.t_us or x.t > st.t_us + 5 * SEC) continue;
                    if (s.down_react_ms < 0 and x.target <= x.avail) s.down_react_ms = @floatFromInt(@divTrunc(x.t - st.t_us, MS));
                    peak = @max(peak, x.p95);
                    if (x.p95 >= 20) last_bad = x.t;
                }
                s.down_peak_ms = peak;
                s.down_drain_ms = @floatFromInt(@divTrunc(last_bad - st.t_us, MS));
            } else if (!down and !did_up) {
                did_up = true;
                for (samples.items) |x| {
                    if (x.t <= st.t_us) continue;
                    if (x.target >= 0.8 * x.avail) {
                        s.up_ms = @floatFromInt(@divTrunc(x.t - st.t_us, MS));
                        break;
                    }
                }
            }
        }
    }
    return s;
}

fn pctf(xs: []const f32, p: usize) f64 {
    if (xs.len == 0) return 0;
    return xs[@min(xs.len - 1, (xs.len * p) / 100)];
}

fn pctd(xs: []const f64, p: usize) f64 {
    if (xs.len == 0) return 0;
    return xs[@min(xs.len - 1, (xs.len * p) / 100)];
}

/// S11's medians over 5 seeds on its own simulator
/// (spikes/s11-capacity-estimation/results/matrix/summary.csv). -1 = none.
pub const S11Ref = struct {
    scen: []const u8,
    variant: []const u8,
    est: f64,
    util: f64,
    q_p50: f64,
    q_p99: f64,
    frame_p50: f64,
    frame_p99: f64,
    start: f64,
    down: f64,
    drain: f64,
    up: f64,
};

pub const s11_ref = [_]S11Ref{
    .{ .scen = "wired-steps", .variant = "gcc-hybrid", .est = 0.86, .util = 0.88, .q_p50 = 2.1, .q_p99 = 10.8, .frame_p50 = 15.9, .frame_p99 = 95.5, .start = 1600, .down = 300, .drain = 800, .up = 1700 },
    .{ .scen = "wired-steps", .variant = "gcc-hybrid-enc60", .est = 1.14, .util = 0.68, .q_p50 = 3.3, .q_p99 = 41.7, .frame_p50 = 10.5, .frame_p99 = 79.5, .start = 600, .down = 500, .drain = 700, .up = 1200 },
    .{ .scen = "wifi-steps", .variant = "gcc-hybrid", .est = 0.74, .util = 0.73, .q_p50 = 3.6, .q_p99 = 53.0, .frame_p50 = 13.7, .frame_p99 = 82.7, .start = 1300, .down = 300, .drain = 1700, .up = 1800 },
    .{ .scen = "wifi-steps", .variant = "gcc-hybrid-enc60", .est = 0.96, .util = 0.56, .q_p50 = 3.7, .q_p99 = 41.3, .frame_p50 = 10.4, .frame_p99 = 56.7, .start = 1200, .down = 400, .drain = 3900, .up = 1600 },
    .{ .scen = "wifi-lan", .variant = "gcc-hybrid", .est = 0.75, .util = 0.76, .q_p50 = 3.6, .q_p99 = 47.8, .frame_p50 = 14.2, .frame_p99 = 78.9, .start = 1600, .down = 300, .drain = 4300, .up = 1600 },
    .{ .scen = "wifi-lan", .variant = "gcc-hybrid-enc60", .est = 0.92, .util = 0.56, .q_p50 = 3.7, .q_p99 = 42.4, .frame_p50 = 10.6, .frame_p99 = 54.9, .start = 1200, .down = 1200, .drain = 4000, .up = 1100 },
    .{ .scen = "wifi-fade", .variant = "gcc-hybrid", .est = 0.76, .util = 0.75, .q_p50 = 3.5, .q_p99 = 91.1, .frame_p50 = 13.8, .frame_p99 = 98.2, .start = 1700, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wifi-fade", .variant = "gcc-hybrid-enc60", .est = 0.98, .util = 0.59, .q_p50 = 4.0, .q_p99 = 63.7, .frame_p50 = 10.9, .frame_p99 = 74.7, .start = 1200, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wifi-udp-cross", .variant = "gcc-hybrid", .est = 0.68, .util = 0.70, .q_p50 = 3.6, .q_p99 = 51.6, .frame_p50 = 11.4, .frame_p99 = 63.1, .start = 1600, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wifi-udp-cross", .variant = "gcc-hybrid-enc60", .est = 0.95, .util = 0.59, .q_p50 = 3.5, .q_p99 = 49.8, .frame_p50 = 9.8, .frame_p99 = 55.9, .start = 1200, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wifi-tcp", .variant = "gcc-hybrid", .est = 0.55, .util = 0.55, .q_p50 = 3.8, .q_p99 = 65.0, .frame_p50 = 17.9, .frame_p99 = 87.3, .start = 1300, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wifi-tcp", .variant = "gcc-hybrid-enc60", .est = 0.85, .util = 0.50, .q_p50 = 4.2, .q_p99 = 67.2, .frame_p50 = 13.8, .frame_p99 = 85.3, .start = 1200, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wifi-bursts", .variant = "gcc-hybrid", .est = 0.57, .util = 0.57, .q_p50 = 3.6, .q_p99 = 62.6, .frame_p50 = 11.2, .frame_p99 = 78.5, .start = 3400, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wifi-bursts", .variant = "gcc-hybrid-enc60", .est = 0.75, .util = 0.46, .q_p50 = 3.5, .q_p99 = 49.5, .frame_p50 = 9.1, .frame_p99 = 56.0, .start = 1200, .down = -1, .drain = -1, .up = -1 },
    .{ .scen = "wired-60ms", .variant = "gcc-hybrid", .est = 0.86, .util = 0.88, .q_p50 = 2.1, .q_p99 = 13.3, .frame_p50 = 15.7, .frame_p99 = 98.8, .start = 1700, .down = 300, .drain = 900, .up = 1800 },
    .{ .scen = "wired-60ms", .variant = "gcc-hybrid-enc60", .est = 1.16, .util = 0.69, .q_p50 = 3.6, .q_p99 = 48.6, .frame_p50 = 10.7, .frame_p99 = 79.7, .start = 700, .down = 600, .drain = 800, .up = 1200 },
};

fn findRef(scen: []const u8, variant: []const u8) ?S11Ref {
    for (s11_ref) |r| if (std.mem.eql(u8, r.scen, scen) and std.mem.eql(u8, r.variant, variant)) return r;
    return null;
}

/// How far a median may sit from S11's and still count as reproducing it.
/// The port itself is bit-exact on S11's simulator; what remains is a
/// different random realization of the same models (stall timing, frame
/// sizes), so the bands are about seed noise, not tuning. Doing better
/// than S11 is allowed more slack than doing worse.
fn checkRow(m: Summary, r: S11Ref, wired: bool, failures: *u32) void {
    const full = std.mem.eql(u8, r.variant, "gcc-hybrid");
    // Next to Reno, est is a fraction of our fair share: competing-flow mode (S11b) is
    // meant to raise it, so anything up to a fair share passes.
    const est_hi = if (std.mem.eql(u8, r.scen, "wifi-tcp")) @max(r.est + 0.20, 1.05) else r.est + 0.20;
    expect(failures, r, "est", m.est_p50 >= r.est - 0.08 and m.est_p50 <= est_hi, m.est_p50, r.est);
    expect(failures, r, "util", m.util_p50 >= r.util - 0.08, m.util_p50, r.util);
    expect(failures, r, "q p50", m.q_p50 <= r.q_p50 + 1.0, m.q_p50, r.q_p50);
    expect(failures, r, "q p99", m.q_p99 <= @max(1.3 * r.q_p99, r.q_p99 + 5), m.q_p99, r.q_p99);
    // With app_share < 1 the target is a capacity estimate and may sit
    // above the available rate, so the reaction rules don't apply.
    if (!full) return;
    if (r.down >= 0) expect(failures, r, "down ms", m.down_react_ms >= 0 and m.down_react_ms <= r.down + 200, m.down_react_ms, r.down);
    if (wired and r.drain >= 0) expect(failures, r, "drain ms", m.down_drain_ms >= 0 and m.down_drain_ms <= r.drain + 300, m.down_drain_ms, r.drain);
}

fn expect(failures: *u32, r: S11Ref, what: []const u8, ok: bool, got: f64, want: f64) void {
    if (ok) return;
    failures.* += 1;
    std.debug.print("FAIL {s} {s}: {s} {d:.2}, S11 {d:.2}\n", .{ r.scen, r.variant, what, got, want });
}

pub const Trace = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    pub const header = "scenario,variant,seed,t,cap,avail,target,pace,train,media,p95_ms,qbytes,overuses,drains,jumps\n";
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var only_scen: ?[]const u8 = null;
    var only_var: ?[]const u8 = null;
    var seeds: u64 = 5;
    var csv_path: ?[]const u8 = null;
    var trace_path: ?[]const u8 = null;
    var check = false;
    var i: usize = 1;
    while (i < args.len and std.mem.eql(u8, args[i], "--check")) {
        check = true;
        i += 1;
    }
    while (i + 1 < args.len) : (i += 2) {
        const k = args[i];
        const val = args[i + 1];
        if (std.mem.eql(u8, k, "--scenario")) {
            only_scen = val;
        } else if (std.mem.eql(u8, k, "--variant")) {
            only_var = val;
        } else if (std.mem.eql(u8, k, "--seeds")) {
            seeds = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, k, "--csv")) {
            csv_path = val;
        } else if (std.mem.eql(u8, k, "--trace")) {
            trace_path = val;
        } else {
            std.debug.print("unknown option {s}\n", .{k});
            std.process.exit(2);
        }
    }

    var failures: u32 = 0;
    var trace = Trace{ .gpa = arena };
    try trace.out.appendSlice(arena, Trace.header);
    var csv: std.ArrayList(u8) = .empty;
    try csv.print(arena, "scenario,variant,seed,est_p10,est_p50,est_p90,util_p50,train_p50,net_p50,net_p95,net_p99,frame_p50,frame_p95,frame_p99,frames_lost,frames,loss_pct,startup_ms,down_react_ms,down_peak_ms,down_drain_ms,up_ms,media_mbps,overuses,drains\n", .{});
    std.debug.print("| scenario | variant | est | util | train | q p50 | q p99 | frame p50 | frame p99 | lost | start ms | down ms | peak ms | drain ms | up ms |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n", .{});
    for (scenarios.all) |sc| {
        if (!std.mem.startsWith(u8, sc.name, "s11-")) continue;
        if (only_scen) |o| if (!std.mem.eql(u8, o, sc.name)) continue;
        for (variants) |v| {
            if (only_var) |o| if (!std.mem.eql(u8, o, v.name)) continue;
            const runs = try arena.alloc(Summary, seeds);
            for (runs, 1..) |*r, seed| {
                r.* = try runOne(gpa, sc, v, seed, if (trace_path != null) &trace else null);
                try csv.print(arena, "{s},{s},{d},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d},{d},{d:.3},{d:.0},{d:.0},{d:.1},{d:.0},{d:.0},{d:.2},{d},{d}\n", .{
                    sc.name[4..], v.name, seed, r.est_p10, r.est_p50, r.est_p90, r.util_p50, r.train_p50, r.q_p50, r.q_p95, r.q_p99, r.frame_p50, r.frame_p95, r.frame_p99, r.frames_lost, r.frames, r.loss_pct, r.startup_ms, r.down_react_ms, r.down_peak_ms, r.down_drain_ms, r.up_ms, r.media_mbps, r.overuses, r.drains,
                });
            }
            const m = median(runs);
            std.debug.print("| {s} | {s} | {d:.2} | {d:.2} | {d:.2} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.0} | {s} | {s} | {s} | {s} | {s} |\n", .{
                sc.name[4..], v.name, m.est_p50, m.util_p50, m.train_p50, m.q_p50, m.q_p99, m.frame_p50, m.frame_p99, @as(f64, @floatFromInt(m.frames_lost)), ms(arena, m.startup_ms), ms(arena, m.down_react_ms), ms(arena, m.down_peak_ms), ms(arena, m.down_drain_ms), ms(arena, m.up_ms),
            });
            if (findRef(sc.name[4..], v.name)) |r| {
                std.debug.print("| {s} | S11 {s} | {d:.2} | {d:.2} | | {d:.1} | {d:.1} | {d:.1} | {d:.1} | | {s} | {s} | | {s} | {s} |\n", .{
                    r.scen, r.variant, r.est, r.util, r.q_p50, r.q_p99, r.frame_p50, r.frame_p99, ms(arena, r.start), ms(arena, r.down), ms(arena, r.drain), ms(arena, r.up),
                });
                if (check) checkRow(m, r, sc.net.a_to_b.wifi == null, &failures);
            }
        }
    }
    if (csv_path) |p| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = p, .data = csv.items });
    if (trace_path) |p| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = p, .data = trace.out.items });
    if (check) {
        if (failures > 0) {
            std.debug.print("{d} metric(s) outside S11's bands\n", .{failures});
            std.process.exit(1);
        }
        std.debug.print("all medians within S11's bands\n", .{});
    }
}

fn ms(arena: std.mem.Allocator, v: f64) []const u8 {
    if (v < 0) return "–";
    return std.fmt.allocPrint(arena, "{d:.0}", .{v}) catch "?";
}

/// Field-wise median across seeds, as S11's scripts/table.py takes it
/// (-1 "never" values included as they are).
pub fn median(runs: []const Summary) Summary {
    var out = Summary{};
    inline for (std.meta.fields(Summary)) |f| {
        var vals: [64]f64 = undefined;
        const n = @min(runs.len, vals.len);
        for (runs[0..n], 0..) |r, k| {
            const x: f64 = switch (@typeInfo(f.type)) {
                .float => @field(r, f.name),
                .int => @floatFromInt(@field(r, f.name)),
                else => unreachable,
            };
            vals[k] = x;
        }
        std.mem.sort(f64, vals[0..n], {}, std.sort.asc(f64));
        const v = if (n % 2 == 1) vals[n / 2] else (vals[n / 2 - 1] + vals[n / 2]) / 2;
        @field(out, f.name) = switch (@typeInfo(f.type)) {
            .float => v,
            .int => @intFromFloat(v),
            else => unreachable,
        };
    }
    return out;
}
