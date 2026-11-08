//! The host and client apps with the synthetic backend over the in-process simulated
//! network, in virtual time: the unit tests, `moonsec sim` and the soak.
//!
//! Each side's clock is its simulated local clock; nothing blocks, so an hour of
//! streaming runs in a minute or two and every run with the same seed is identical.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const simnet = @import("simnet");
const synthetic = @import("synthetic");
const apps = @import("apps.zig");

const Micros = i64;

pub const Profile = enum {
    /// Wired LAN, the Phase 2 gate's setting: 1 ms each way, 0.3 ms jitter, 100 Mbit/s,
    /// 0.5% random loss and 1% reordering in each direction.
    lan,
    /// The Phase 1 gate's path: 10 ms each way, 3 ms jitter, 50 Mbit/s, 2% loss, 2% reordering.
    wan,
    /// No loss, no jitter.
    clean,

    pub fn link(p: Profile) simnet.LinkConfig {
        return switch (p) {
            .lan => .{ .steps = &.{.{ .t_us = 0, .bps = 100e6 }}, .delay_us = 1 * simnet.MS, .jitter_us = 300, .loss = 0.005, .reorder_p = 0.01, .reorder_extra_us = 1 * simnet.MS, .overhead_bytes = 48 },
            .wan => .{ .steps = &.{.{ .t_us = 0, .bps = 50e6 }}, .delay_us = 10 * simnet.MS, .jitter_us = 3 * simnet.MS, .loss = 0.02, .reorder_p = 0.02, .reorder_extra_us = 5 * simnet.MS, .overhead_bytes = 48 },
            .clean => .{ .steps = &.{.{ .t_us = 0, .bps = 100e6 }}, .delay_us = 1 * simnet.MS, .overhead_bytes = 48 },
        };
    }
};

pub const Options = struct {
    seed: u64 = 1,
    profile: Profile = .lan,
    seconds: u32 = 10,
    fps: u32 = 60,
    bitrate_bps: u64 = 10_000_000,
    width: u32 = 320,
    height: u32 = 180,
    slices: u8 = 4,
    /// Virtual-time step.
    step_us: Micros = 250,
    /// Loss starts this long after the start, so the first keyframe gets through cleanly
    /// (joining under loss is recovery's job, tested in core/recovery).
    warmup_us: Micros = 300_000,
    /// The client's clock runs this far from the host's.
    clock_offset_us: Micros = 3_217_000_000,
    /// Print a progress line every this many simulated seconds (0: never).
    progress_every_s: u32 = 0,
    input_interval_us: Micros = 25_000,
    /// Drop every host-to-client datagram for `outage_us` starting at `outage_at_us`
    /// (0: none), long enough that frames are lost and recovery has to step in.
    outage_at_us: Micros = 0,
    outage_us: Micros = 0,
};

pub const Result = struct {
    seconds: u32,
    host: struct {
        frames: u64,
        keyframes: u64,
        refreshes: u64,
        retransmits: u64,
        keys: u64,
        keys_wrong: u64,
        end: []const u8,
    },
    client: struct {
        presented: u64,
        unreadable: u64,
        corrupt: u64,
        decode_errors: u64,
        lost: u64,
        freezes: u64,
        longest_gap_us: Micros,
        stalls_100ms: u64,
        input_sent: u64,
        total_p50_us: Micros,
        total_p99_us: Micros,
        end: []const u8,
    },
    sim_losses: u64,

    pub fn expectedFrames(r: Result, fps: u32) u64 {
        return @as(u64, r.seconds) * fps;
    }

    /// What `moonsec sim`/`soak` and the tests hold a run to. Null when it passes.
    pub fn failure(r: Result, o: Options) ?[]const u8 {
        const want = r.expectedFrames(o.fps);
        if (r.client.presented * 100 < want * 95) return "client presented under 95% of the frames";
        if (r.client.freezes > 0) return "the freeze detector saw a freeze";
        if (r.client.unreadable > 0) return "a presented frame's pattern did not read back";
        if (r.client.corrupt > 0) return "the decoder saw a corrupt access unit";
        if (r.host.keys_wrong > 0) return "input arrived out of order";
        if (o.input_interval_us > 0 and r.host.keys * 100 < r.client.input_sent * 95) return "input events went missing";
        if (r.client.total_p50_us <= 0) return "no glass-to-glass samples";
        return null;
    }

    pub fn print(r: Result, w: *std.Io.Writer) !void {
        try w.print("{d} s: host sent {d} frames (keyframes {d}, LTR refreshes {d}, retransmits {d}); client presented {d}, lost {d}, decode errors {d}, unreadable {d}, corrupt {d}\n", .{ r.seconds, r.host.frames, r.host.keyframes, r.host.refreshes, r.host.retransmits, r.client.presented, r.client.lost, r.client.decode_errors, r.client.unreadable, r.client.corrupt });
        try w.print("  freezes {d}, longest gap {d:.1} ms, stalls >100 ms {d}; glass-to-glass p50 {d:.2} ms p99 {d:.2} ms; keys {d}/{d} (wrong {d}); sim losses {d}\n", .{
            r.client.freezes,
            @as(f64, @floatFromInt(r.client.longest_gap_us)) / 1000,
            r.client.stalls_100ms,
            @as(f64, @floatFromInt(r.client.total_p50_us)) / 1000,
            @as(f64, @floatFromInt(r.client.total_p99_us)) / 1000,
            r.host.keys,
            r.client.input_sent,
            r.host.keys_wrong,
            r.sim_losses,
        });
        try w.print("  host: {s}; client: {s}\n", .{ r.host.end, r.client.end });
    }
};

const SideClock = struct {
    net: *simnet.Net,
    side: simnet.Side,

    fn now(p: ?*anyopaque) Micros {
        const c: *SideClock = @ptrCast(@alignCast(p.?));
        return c.net.localTime(c.side);
    }

    fn clock(c: *SideClock) api.Clock {
        return .{ .ptr = c, .nowFn = now };
    }
};

fn patternContent(ctx: ?*anyopaque, _: *const api.DecodedFrame) u64 {
    const c: *synthetic.Client = @ptrCast(@alignCast(ctx.?));
    return if (c.presenter.last_stamp) |s| s.frame else 0;
}

pub fn run(gpa: std.mem.Allocator, o: Options, log: ?*std.Io.Writer) !Result {
    const net = try gpa.create(simnet.Net);
    defer gpa.destroy(net);
    var cfg: simnet.Config = .{ .seed = o.seed, .a_to_b = o.profile.link(), .b_to_a = o.profile.link() };
    cfg.b.clock_offset_us = o.clock_offset_us;
    const loss = cfg.a_to_b.loss;
    cfg.a_to_b.loss = 0;
    cfg.b_to_a.loss = 0;
    try net.init(gpa, cfg);
    defer net.deinit();

    var hc: SideClock = .{ .net = net, .side = .a };
    var cc: SideClock = .{ .net = net, .side = .b };
    const sh = try synthetic.openHost(gpa, .{ .clock = hc.clock(), .width = o.width, .height = o.height });
    const hb = sh.backend();
    defer hb.deinit();
    const sc = try synthetic.openClient(gpa, .{ .clock = cc.clock(), .input_interval_us = o.input_interval_us });
    const cb = sc.backend();
    defer cb.deinit();

    var host = try apps.HostApp.init(gpa, hb, .{ .fps = o.fps, .bitrate_bps = o.bitrate_bps, .slices = o.slices }, net.pipeFor(.a));
    defer host.deinit();
    var client = try apps.ClientApp.init(gpa, cb, .{ .content_ctx = sc, .contentFn = patternContent }, net.pipeFor(.b));
    defer client.deinit();

    const end_us: Micros = @as(Micros, o.seconds) * simnet.SEC;
    var t: Micros = 0;
    var loss_on = false;
    var next_progress: Micros = @as(Micros, o.progress_every_s) * simnet.SEC;
    var closing = false;
    while (!(host.done() and client.done())) : (t += o.step_us) {
        if (!loss_on and t >= o.warmup_us) {
            for (&net.links) |*l| l.cfg.loss = loss;
            loss_on = true;
        }
        if (o.outage_us > 0) {
            if (t == o.outage_at_us) net.links[0].cfg.loss = 1.0;
            if (t == o.outage_at_us + o.outage_us) net.links[0].cfg.loss = loss;
        }
        if (!closing and t >= end_us) {
            client.s.close(net.localTime(.b));
            closing = true;
        }
        if (t > end_us + 30 * simnet.SEC) return error.Hung;
        try net.runUntil(t);
        host.tick();
        client.tick();
        if (log) |w| if (o.progress_every_s > 0 and t >= next_progress) {
            const fz = client.s.freeze.stats;
            try w.print("  t={d} s: presented {d}, freezes {d}, longest gap {d:.1} ms\n", .{ @divTrunc(t, simnet.SEC), client.s.stats.frames_presented, fz.freezes, @as(f64, @floatFromInt(fz.longest_gap_us)) / 1000 });
            try w.flush();
            next_progress += @as(Micros, o.progress_every_s) * simnet.SEC;
        };
    }
    client.s.freeze.finish(client.s.freeze.last_new_us orelse 0);

    if (log) |w| {
        try host.s.report(w);
        try client.s.report(w);
    }
    const snap = client.s.tele.snapshot();
    const fz = client.s.freeze.stats;
    return .{
        .seconds = o.seconds,
        .host = .{
            .frames = host.s.stats.frames,
            .keyframes = host.s.stats.keyframes,
            .refreshes = host.s.stats.refreshes,
            .retransmits = host.s.stats.retransmits,
            .keys = sh.injector.keys,
            .keys_wrong = sh.injector.wrong,
            .end = @tagName(host.s.end),
        },
        .client = .{
            .presented = client.s.stats.frames_presented,
            .unreadable = sc.presenter.stats.unreadable,
            .corrupt = sc.decoder.stats.corrupt,
            .decode_errors = client.s.stats.decode_errors,
            .lost = client.s.stats.frames_lost,
            .freezes = fz.freezes,
            .longest_gap_us = fz.longest_gap_us,
            .stalls_100ms = fz.stalls[1],
            .input_sent = sc.input.sent,
            .total_p50_us = snap.stage(.total).p50,
            .total_p99_us = snap.stage(.total).p99,
            .end = @tagName(client.s.end),
        },
        .sim_losses = net.linkStats(.a).random_losses + net.linkStats(.b).random_losses,
    };
}
