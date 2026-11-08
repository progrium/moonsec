//! Runs one scenario with its reference load over the simulated network.
//!
//! Endpoint A sends 60 fps frames as datagrams through its `PacketPipe`; B
//! reads them and returns a 16-byte feedback datagram every 5 ms, so both
//! directions carry traffic. Everything goes through `PacketPipe`, the same
//! interface the core will drive, and the result carries a digest of every
//! delivery and drop, so equal digests mean identical runs.
const std = @import("std");
const simnet = @import("simnet");
const scenarios = @import("scenarios.zig");

const MS = simnet.MS;
const SEC = simnet.SEC;
const PAYLOAD = 1200;
const HDR = 16; // frame u32, index u16, count u16, send time i64
const FB_EVERY = 5 * MS;

pub const Options = struct {
    /// Stop early (0 = the scenario's duration). Tests use short runs.
    duration_us: i64 = 0,
};

pub const Result = struct {
    digest: u64,
    media_sent: u64,
    media_delivered: u64,
    send_drops: u64,
    queue_drops: u64,
    random_losses: u64,
    blackout_drops: u64,
    recv_drops: u64,
    reordered: u64,
    feedback_received: u64,
    frames: u32,
    frames_complete: u32,
    /// Longest gap between consecutive complete frames at the receiver.
    max_freeze_ms: f64,
    owd_p50_ms: f64,
    owd_p95_ms: f64,
    owd_p99_ms: f64,
    max_queue_bytes: u64,
    stall_ms: f64,
    cross_mbps: f64,
    media_mbps: f64,

    /// Every media datagram the network dropped, wherever it was dropped.
    /// (sent - delivered also counts datagrams still in flight at the end.)
    pub fn drops(r: Result) u64 {
        return r.send_drops + r.queue_drops + r.random_losses + r.blackout_drops + r.recv_drops;
    }

    pub fn lossPct(r: Result) f64 {
        if (r.media_sent == 0) return 0;
        return 100 * @as(f64, @floatFromInt(r.drops())) / @as(f64, @floatFromInt(r.media_sent));
    }
};

const FrameRx = struct { count: u16, got: u16 = 0 };

pub fn run(gpa: std.mem.Allocator, sc: scenarios.Scenario, seed: u64, opts: Options) !Result {
    var cfg = sc.net;
    cfg.seed = seed;
    const net = try gpa.create(simnet.Net);
    defer gpa.destroy(net);
    try net.init(gpa, cfg);
    defer net.deinit();

    const a = net.pipeFor(.a);
    const b = net.pipeFor(.b);
    const load = sc.load;
    if (load.pace_mult > 0) a.setPacingRate(@intFromFloat(load.pace_mult * load.bitrate_bps));
    const b_offset = cfg.b.clock_offset_us;
    const duration = if (opts.duration_us > 0) opts.duration_us else sc.duration_us;

    // The load has its own random stream, separate from the network's.
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6c6f6164);
    const rnd = prng.random();

    var frames_rx: std.AutoHashMapUnmanaged(u32, FrameRx) = .empty;
    defer frames_rx.deinit(gpa);
    var owd: std.ArrayList(f32) = .empty;
    defer owd.deinit(gpa);

    const frame_us: i64 = @divTrunc(SEC, load.fps);
    var next_frame: i64 = 0;
    var next_fb: i64 = FB_EVERY;
    var frame_id: u32 = 0;
    var frames_complete: u32 = 0;
    var last_complete: ?i64 = null;
    var max_freeze: i64 = 0;
    var fb_rx: u64 = 0;
    var buf: [PAYLOAD]u8 = undefined;
    @memset(&buf, 0xa5);

    while (true) {
        var t = @min(next_frame, next_fb);
        if (net.nextEventTime()) |e| t = @min(t, e);
        if (t > duration) break;
        try net.runUntil(t);

        if (t == next_frame) {
            var bytes = load.bitrate_bps / 8 / @as(f64, @floatFromInt(load.fps)) * @exp(0.25 * rnd.floatNorm(f64) - 0.03);
            if (load.scene_every > 0 and frame_id > 0 and frame_id % load.scene_every == 0) bytes *= 4;
            const total: usize = @intFromFloat(@max(bytes, 100));
            const n: usize = @max(1, (total + PAYLOAD - HDR - 1) / (PAYLOAD - HDR));
            var left = total;
            for (0..n) |k| {
                const sz = @max(HDR, @min(left, PAYLOAD));
                left -|= sz;
                std.mem.writeInt(u32, buf[0..4], frame_id, .little);
                std.mem.writeInt(u16, buf[4..6], @intCast(k), .little);
                std.mem.writeInt(u16, buf[6..8], @intCast(n), .little);
                std.mem.writeInt(i64, buf[8..16], net.localTime(.a), .little);
                try a.send(buf[0..sz]);
            }
            frame_id += 1;
            next_frame += frame_us;
        }

        // B reads media as soon as it lands.
        while (try b.recv(&buf)) |r| {
            const sent = std.mem.readInt(i64, buf[8..16], .little);
            try owd.append(gpa, @as(f32, @floatFromInt(r.recv_us - b_offset - sent)) / 1000.0);
            const fid = std.mem.readInt(u32, buf[0..4], .little);
            const gop = try frames_rx.getOrPut(gpa, fid);
            if (!gop.found_existing) gop.value_ptr.* = .{ .count = std.mem.readInt(u16, buf[6..8], .little) };
            gop.value_ptr.got += 1;
            if (gop.value_ptr.got == gop.value_ptr.count) {
                frames_complete += 1;
                const now = r.recv_us - b_offset;
                if (last_complete) |lc| max_freeze = @max(max_freeze, now - lc);
                last_complete = now;
                _ = frames_rx.remove(fid);
            }
        }

        if (t == next_fb) {
            var fb: [16]u8 = undefined;
            std.mem.writeInt(i64, fb[0..8], net.localTime(.b), .little);
            std.mem.writeInt(u64, fb[8..16], b.stats().received, .little);
            try b.send(&fb);
            next_fb += FB_EVERY;
        }
        while (try a.recv(&buf)) |_| fb_rx += 1;
    }

    std.mem.sort(f32, owd.items, {}, std.sort.asc(f32));
    const s = net.linkStats(.a);
    const secs = @as(f64, @floatFromInt(duration)) / 1e6;
    return .{
        .digest = net.digest(),
        .media_sent = s.sent,
        .media_delivered = s.delivered,
        .send_drops = s.send_drops,
        .queue_drops = s.queue_drops,
        .random_losses = s.random_losses,
        .blackout_drops = s.blackout_drops,
        .recv_drops = s.recv_drops,
        .reordered = s.reordered,
        .feedback_received = fb_rx,
        .frames = frame_id,
        .frames_complete = frames_complete,
        .max_freeze_ms = @as(f64, @floatFromInt(max_freeze)) / 1000.0,
        .owd_p50_ms = pct(owd.items, 50),
        .owd_p95_ms = pct(owd.items, 95),
        .owd_p99_ms = pct(owd.items, 99),
        .max_queue_bytes = s.max_queue_bytes,
        .stall_ms = @as(f64, @floatFromInt(s.stall_us)) / 1000.0,
        .cross_mbps = @as(f64, @floatFromInt(s.cross_delivered_bytes)) * 8 / secs / 1e6,
        .media_mbps = @as(f64, @floatFromInt(s.delivered_bytes)) * 8 / secs / 1e6,
    };
}

fn pct(xs: []const f32, p: usize) f64 {
    if (xs.len == 0) return 0;
    return xs[@min(xs.len - 1, (xs.len * p) / 100)];
}
