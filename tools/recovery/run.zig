//! The recovery gate's run: one host backend's encoder, driven frame by frame through
//! `core.recovery` (host and client) over a simulated link that drops frames at a set
//! rate. Records every frame's size and type, how long the client stayed frozen, and
//! whether any IDR went out after the first.
//!
//! Time is virtual (one tick per frame), so a run is deterministic for a given seed and
//! encoder; the encoder itself runs for real. The link delays frames and acks by half the
//! RTT each way and loses whole frames (a frame reassembly could not complete).
//!
//! Phase 5 gate (docs/design.md): "LTR recovery without keyframe spikes on NVENC and
//! VideoToolbox". `verdict` checks it: no IDR after the first, and every recovery frame
//! well under the size of an IDR.
const std = @import("std");
const api = @import("platform");
const core = @import("core");
const recovery = core.recovery;

pub const Expect = enum {
    /// The gate: long-term-reference refreshes, no IDR after the first.
    ltr,
    /// The fallback for encoders without LTR (Media Foundation): every loss recovers
    /// through an IDR and the stream never stays frozen.
    idr,
};

pub const Config = struct {
    frames: u32 = 600,
    fps: u32 = 60,
    width: u32 = 1920,
    height: u32 = 1080,
    codec: api.Codec = .h264,
    bitrate_bps: u64 = 20_000_000,
    /// Ask the encoder for long-term references (only if its caps have them).
    ltr: bool = true,
    /// Chance that a loss event starts on a given frame, after `warmup`.
    loss: f64 = 0.02,
    /// Frames lost per loss event.
    burst: u32 = 1,
    rtt_us: u64 = 30_000,
    seed: u64 = 1,
    /// Frames before the first loss (the client acks some LTRs first).
    warmup: u32 = 60,
    /// After `frames`, run lossless until the client is decoding again (at most this many),
    /// then force one IDR to measure its size at steady state.
    tail: u32 = 120,
    expect: Expect = .ltr,
    /// Pass when the largest recovery frame is at most this fraction of the IDR size.
    max_refresh_ratio: f64 = 0.5,
    /// Print one line per frame.
    trace: bool = false,
};

/// Makes the picture for frame `i` (the encoder's input). Valid until the next call.
pub const Source = struct {
    ptr: *anyopaque,
    frameFn: *const fn (ptr: *anyopaque, i: u32, time_us: api.Micros) anyerror!*const api.CapturedFrame,

    pub fn frame(s: Source, i: u32, time_us: api.Micros) !*const api.CapturedFrame {
        return s.frameFn(s.ptr, i, time_us);
    }
};

pub const FrameKind = enum { idr, refresh, p, dropped };

pub const FrameRecord = struct {
    /// Index of the input picture.
    input: u32,
    kind: FrameKind,
    bytes: usize = 0,
    encode_us: api.Micros = 0,
    lost: bool = false,
    forced: recovery.host.Force = .none,
    ltr_token: ?u64 = null,
};

pub const SizeStats = struct {
    n: u64 = 0,
    sum: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    pub fn add(s: *SizeStats, v: u64) void {
        s.n += 1;
        s.sum += v;
        s.min = @min(s.min, v);
        s.max = @max(s.max, v);
    }
    pub fn mean(s: SizeStats) u64 {
        return if (s.n == 0) 0 else s.sum / s.n;
    }
};

pub const Result = struct {
    caps_ltr: bool,
    used_ltr: bool,
    frames: u64 = 0,
    dropped_by_encoder: u64 = 0,
    lost: u64 = 0,
    loss_events: u64 = 0,
    first_idr_bytes: u64 = 0,
    /// The IDR forced after the tail, at steady state (0 when the run did not get there).
    calibration_idr_bytes: u64 = 0,
    /// IDRs after the first, not counting the calibration one.
    later_idrs: u64 = 0,
    idr_sizes: SizeStats = .{},
    refresh_sizes: SizeStats = .{},
    p_sizes: SizeStats = .{},
    encode_us: SizeStats = .{},
    freezes: u64 = 0,
    freeze_max_us: u64 = 0,
    freeze_total_us: u64 = 0,
    requests: u64 = 0,
    retries: u64 = 0,
    decode_errors: u64 = 0,
    /// Forced refreshes the encoder emitted as plain P frames (it did not report
    /// `ltr_refresh`): the client would take them as recovery points.
    refresh_mismatches: u64 = 0,
    /// The client was decoding when the run ended.
    recovered: bool = false,
    host: recovery.host.Stats = .{},

    /// The IDR size recovery frames are compared with: the calibration IDR when there is
    /// one, else the largest IDR seen.
    pub fn idrBytes(r: *const Result) u64 {
        return if (r.calibration_idr_bytes > 0) r.calibration_idr_bytes else r.idr_sizes.max;
    }

    /// The IDR is under twice a mean P frame: the rate control held it to the one-frame
    /// VBV, so sizes cannot show a keyframe spike (the cost went into quality instead).
    pub fn idrCapped(r: *const Result) bool {
        return r.p_sizes.n > 0 and r.idrBytes() < 2 * r.p_sizes.mean();
    }

    pub fn refreshVsP(r: *const Result) f64 {
        if (r.p_sizes.n == 0 or r.refresh_sizes.n == 0) return 0;
        return @as(f64, @floatFromInt(r.refresh_sizes.max)) / @as(f64, @floatFromInt(r.p_sizes.mean()));
    }

    pub fn refreshRatio(r: *const Result) f64 {
        const idr = r.idrBytes();
        if (idr == 0 or r.refresh_sizes.n == 0) return 0;
        return @as(f64, @floatFromInt(r.refresh_sizes.max)) / @as(f64, @floatFromInt(idr));
    }
};

pub const Verdict = struct {
    pass: bool,
    /// Why it failed (static strings), empty on a pass.
    reasons: [8][]const u8 = undefined,
    n: usize = 0,

    fn fail(v: *Verdict, why: []const u8) void {
        v.pass = false;
        if (v.n < v.reasons.len) {
            v.reasons[v.n] = why;
            v.n += 1;
        }
    }
    pub fn list(v: *const Verdict) []const []const u8 {
        return v.reasons[0..v.n];
    }
};

pub fn verdict(r: *const Result, cfg: Config) Verdict {
    var v: Verdict = .{ .pass = true };
    if (!r.recovered) v.fail("the client was still frozen at the end");
    if (r.decode_errors > 0) v.fail("the decoder rejected frames");
    if (r.refresh_mismatches > 0) v.fail("the encoder did not report a forced LTR refresh as one");
    if (r.loss_events == 0) v.fail("no frame was lost (raise --loss or --frames)");
    switch (cfg.expect) {
        .ltr => {
            if (!r.caps_ltr) v.fail("the encoder has no long-term references");
            if (r.later_idrs > 0) v.fail("an IDR was sent after the first");
            if (r.refresh_sizes.n == 0) v.fail("no LTR refresh was sent");
            // With a capped IDR the size comparison says nothing; no IDR after the first is
            // then the whole check (the report says so).
            if (r.refresh_sizes.n > 0 and !r.idrCapped() and r.refreshRatio() > cfg.max_refresh_ratio) v.fail("a recovery frame was not well under the IDR size");
        },
        .idr => {
            if (r.refresh_sizes.n > 0) v.fail("the encoder sent LTR refreshes (expected IDR recovery)");
            if (r.host.recovery_idrs == 0) v.fail("no recovery IDR was sent");
        },
    }
    return v;
}

const InFlight = struct {
    at_us: u64,
    meta: recovery.FrameMeta,
    data: []u8,
};

const AckInFlight = struct { at_us: u64, ack: recovery.Ack };

/// Runs the gate. `decoder` (optional) checks the frames the client decodes; without one
/// every frame the client passes counts as decoded.
pub fn run(gpa: std.mem.Allocator, enc: api.Encoder, src: Source, decoder: ?api.Decoder, cfg: Config, records: ?*std.ArrayList(FrameRecord), out: ?*std.Io.Writer) !Result {
    const caps = enc.caps();
    const use_ltr = cfg.ltr and caps.ltr;
    var res: Result = .{ .caps_ltr = caps.ltr, .used_ltr = use_ltr };
    try enc.configure(.{
        .codec = cfg.codec,
        .width = cfg.width,
        .height = cfg.height,
        .fps = cfg.fps,
        .bitrate_bps = cfg.bitrate_bps,
        .slices = 1,
        .ltr = use_ltr,
    });
    if (decoder) |d| try d.configure(.{ .codec = cfg.codec, .width = cfg.width, .height = cfg.height });

    const frame_us: u64 = 1_000_000 / @max(cfg.fps, 1);
    const owd_us = cfg.rtt_us / 2;
    var host = recovery.Host.init(.{ .ltr = use_ltr });
    host.setRetryWindow(@intCast(cfg.rtt_us / frame_us + 2));
    var client = recovery.Client.init(.{ .frame_interval_us = frame_us });
    client.setRtt(cfg.rtt_us);

    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rand = prng.random();

    var frames: std.ArrayList(InFlight) = .empty;
    defer {
        for (frames.items) |f| gpa.free(f.data);
        frames.deinit(gpa);
    }
    var acks: std.ArrayList(AckInFlight) = .empty;
    defer acks.deinit(gpa);

    var next_id: recovery.FrameId = 0;
    var burst_left: u32 = 0;
    var tail_left: u32 = cfg.tail;
    var calibrating = false;
    var i: u32 = 0;
    var tick: u64 = 0;
    while (true) : (tick += 1) {
        const now = tick * frame_us;
        const in_main = i < cfg.frames;
        if (!in_main and !calibrating) {
            // Tail: lossless until the client decodes again and the host owes no recovery.
            const settled = client.state == .decoding and !host.recoveryPending();
            if (settled or tail_left == 0) {
                if (!settled) break; // never recovered: no calibration
                calibrating = true;
            } else tail_left -= 1;
        }

        // 1. Acks that reached the host.
        var a: usize = 0;
        while (a < acks.items.len) {
            if (acks.items[a].at_us <= now) {
                host.onAck(&acks.items[a].ack);
                _ = acks.orderedRemove(a);
            } else a += 1;
        }

        // 2. The host encodes frame i.
        const dir = host.nextEncode();
        var params: api.EncodeParams = .{
            .force = switch (dir.force) {
                .none => .none,
                .ltr_refresh => .ltr_refresh,
                .idr => .idr,
            },
            .acked_ltr_tokens = dir.acked_tokens,
        };
        if (calibrating) params.force = .idr;
        const pic = try src.frame(i, @intCast(now));
        const ef_opt = try enc.encode(pic, params);
        var rec: FrameRecord = .{ .input = i, .kind = .dropped, .forced = dir.force };
        if (ef_opt) |ef| {
            // The backend's own clock around its encode call.
            const enc_us = ef.encoded_us - ef.encode_start_us;
            rec.encode_us = enc_us;
            const id = next_id;
            next_id +%= 1;
            const flags = host.onEncoded(id, ef.ltr_token, ef.keyframe);
            if (flags.refresh and !ef.ltr_refresh) res.refresh_mismatches += 1;
            var bytes: usize = 0;
            for (ef.slices) |s| bytes += s.len;
            rec.bytes = bytes;
            rec.ltr_token = ef.ltr_token;
            rec.kind = if (ef.keyframe) .idr else if (flags.refresh) .refresh else .p;
            res.frames += 1;
            res.encode_us.add(@intCast(@max(enc_us, 0)));

            if (calibrating) {
                if (ef.keyframe) res.calibration_idr_bytes = bytes;
            } else switch (rec.kind) {
                .idr => {
                    if (res.idr_sizes.n == 0) res.first_idr_bytes = bytes else res.later_idrs += 1;
                    res.idr_sizes.add(bytes);
                },
                .refresh => res.refresh_sizes.add(bytes),
                .p => res.p_sizes.add(bytes),
                .dropped => {},
            }

            // 3. The link: lose it, or deliver it after half the RTT.
            var lost = false;
            if (in_main and i >= cfg.warmup) {
                if (burst_left > 0) {
                    lost = true;
                    burst_left -= 1;
                } else if (rand.float(f64) < cfg.loss) {
                    lost = true;
                    burst_left = cfg.burst -| 1;
                    res.loss_events += 1;
                }
            }
            rec.lost = lost;
            if (lost) {
                res.lost += 1;
            } else {
                const data = try gpa.alloc(u8, bytes);
                var off: usize = 0;
                for (ef.slices) |s| {
                    @memcpy(data[off..][0..s.len], s);
                    off += s.len;
                }
                try frames.append(gpa, .{
                    .at_us = now + owd_us,
                    .meta = .{ .frame_id = id, .keyframe = ef.keyframe, .refresh = flags.refresh, .ltr_token = ef.ltr_token },
                    .data = data,
                });
            }
        } else {
            host.onEncodeDropped();
            res.dropped_by_encoder += 1;
        }
        if (records) |l| try l.append(gpa, rec);
        if (cfg.trace) if (out) |w| {
            try w.print("frame {d:>5} {s:<8} {d:>8} B  enc {d:>6} us{s}{s}\n", .{
                i,
                @tagName(rec.kind),
                rec.bytes,
                rec.encode_us,
                if (rec.lost) "  LOST" else "",
                if (rec.forced != .none) if (rec.forced == .idr) "  (forced idr)" else "  (forced refresh)" else "",
            });
        };
        i += 1;
        if (calibrating) break;

        // 4. The client: frames that arrived by now, in order, then its acks.
        while (frames.items.len > 0 and frames.items[0].at_us <= now) {
            const f = frames.orderedRemove(0);
            defer gpa.free(f.data);
            if (client.onFrame(f.meta, now) == .drop) continue;
            var ok = true;
            if (decoder) |d| {
                const au: api.AccessUnit = .{ .codec = cfg.codec, .frame_id = f.meta.frame_id, .data = f.data, .keyframe = f.meta.keyframe, .capture_us = 0, .received_us = @intCast(now) };
                if (d.decode(&au)) |df| {
                    if (df) |pic_out| d.release(&pic_out);
                } else |_| ok = false;
            }
            if (!ok) res.decode_errors += 1;
            client.onDecoded(f.meta, ok, now);
        }
        if (client.poll(now)) |ack| try acks.append(gpa, .{ .at_us = now + owd_us, .ack = ack });
    }

    res.recovered = client.state == .decoding;
    res.freezes = client.stats.freezes;
    res.freeze_max_us = client.stats.frozen_us_max;
    res.freeze_total_us = client.stats.frozen_us_total;
    res.requests = client.stats.requests;
    res.retries = client.stats.retries;
    res.host = host.stats;
    return res;
}

pub fn report(w: *std.Io.Writer, name: []const u8, r: *const Result, cfg: Config) !void {
    const v = verdict(r, cfg);
    try w.print("recovery gate: {s}, {s} {d}x{d}@{d} {d} kbit/s, loss {d:.1}% (bursts of {d}), RTT {d} ms, seed {d}\n", .{
        name, @tagName(cfg.codec), cfg.width, cfg.height, cfg.fps, cfg.bitrate_bps / 1000, cfg.loss * 100, cfg.burst, cfg.rtt_us / 1000, cfg.seed,
    });
    try w.print("  encoder LTR: {s}{s}\n", .{ if (r.caps_ltr) "yes" else "no", if (r.caps_ltr and !r.used_ltr) " (not used)" else "" });
    try w.print("  frames {d} encoded, {d} dropped by the encoder, {d} lost in {d} events\n", .{ r.frames, r.dropped_by_encoder, r.lost, r.loss_events });
    try w.print("  IDR: first {d} B, steady-state {d} B, {d} after the first\n", .{ r.first_idr_bytes, r.calibration_idr_bytes, r.later_idrs });
    try w.print("  P frames: mean {d} B (max {d})\n", .{ r.p_sizes.mean(), r.p_sizes.max });
    try w.print("  recovery frames (LTR refresh): {d}, mean {d} B, max {d} B = {d:.2}x IDR (limit {d:.2}x)\n", .{
        r.refresh_sizes.n, r.refresh_sizes.mean(), r.refresh_sizes.max, r.refreshRatio(), cfg.max_refresh_ratio,
    });
    try w.print("  recovery frames vs mean P: max {d:.2}x\n", .{r.refreshVsP()});
    if (r.idrCapped()) try w.print("  note: the IDR is under 2x a P frame (rate control held it to the VBV), so the size limit is not checked\n", .{});
    try w.print("  recovery IDRs: {d}; requests {d} (retries {d}, duplicates at host {d})\n", .{ r.host.recovery_idrs, r.requests, r.retries, r.host.duplicate_requests });
    const mean_freeze: f64 = if (r.freezes == 0) 0 else @as(f64, @floatFromInt(r.freeze_total_us)) / 1000 / @as(f64, @floatFromInt(r.freezes));
    try w.print("  freezes {d}: max {d:.1} ms, mean {d:.1} ms\n", .{ r.freezes, @as(f64, @floatFromInt(r.freeze_max_us)) / 1000, mean_freeze });
    try w.print("  encode time: mean {d} us, max {d} us\n", .{ r.encode_us.mean(), r.encode_us.max });
    try w.print("  decode errors {d}; refreshes not reported by the encoder {d}; client decoding at the end: {s}\n", .{ r.decode_errors, r.refresh_mismatches, if (r.recovered) "yes" else "no" });
    if (v.pass) {
        try w.print("PASS ({s})\n", .{switch (cfg.expect) {
            .ltr => if (r.idrCapped())
                "LTR recovery, no IDR after the first; IDR capped, size limit not checked"
            else
                "LTR recovery, no IDR after the first, recovery frames under the IDR limit",
            .idr => "IDR fallback: every loss recovered through an IDR",
        }});
    } else {
        try w.print("FAIL\n", .{});
        for (v.list()) |why| try w.print("  - {s}\n", .{why});
    }
}

pub fn writeJson(w: *std.Io.Writer, name: []const u8, r: *const Result, cfg: Config) !void {
    const v = verdict(r, cfg);
    try w.print("{{\"backend\":\"{s}\",\"codec\":\"{s}\",\"width\":{d},\"height\":{d},\"fps\":{d},\"bitrate_bps\":{d},", .{ name, @tagName(cfg.codec), cfg.width, cfg.height, cfg.fps, cfg.bitrate_bps });
    try w.print("\"loss\":{d},\"burst\":{d},\"rtt_us\":{d},\"seed\":{d},\"expect\":\"{s}\",\"max_refresh_ratio\":{d},", .{ cfg.loss, cfg.burst, cfg.rtt_us, cfg.seed, @tagName(cfg.expect), cfg.max_refresh_ratio });
    try w.print("\"caps_ltr\":{},\"used_ltr\":{},\"frames\":{d},\"encoder_drops\":{d},\"lost\":{d},\"loss_events\":{d},", .{ r.caps_ltr, r.used_ltr, r.frames, r.dropped_by_encoder, r.lost, r.loss_events });
    try w.print("\"first_idr_bytes\":{d},\"calibration_idr_bytes\":{d},\"later_idrs\":{d},\"p_mean_bytes\":{d},\"p_max_bytes\":{d},", .{ r.first_idr_bytes, r.calibration_idr_bytes, r.later_idrs, r.p_sizes.mean(), r.p_sizes.max });
    try w.print("\"refreshes\":{d},\"refresh_mean_bytes\":{d},\"refresh_max_bytes\":{d},\"refresh_ratio\":{d:.4},\"refresh_vs_p\":{d:.4},\"idr_capped\":{},", .{ r.refresh_sizes.n, r.refresh_sizes.mean(), r.refresh_sizes.max, r.refreshRatio(), r.refreshVsP(), r.idrCapped() });
    try w.print("\"recovery_idrs\":{d},\"requests\":{d},\"retries\":{d},\"freezes\":{d},\"freeze_max_us\":{d},\"freeze_total_us\":{d},", .{ r.host.recovery_idrs, r.requests, r.retries, r.freezes, r.freeze_max_us, r.freeze_total_us });
    try w.print("\"encode_mean_us\":{d},\"encode_max_us\":{d},\"decode_errors\":{d},\"refresh_mismatches\":{d},\"recovered\":{},\"pass\":{}}}\n", .{ r.encode_us.mean(), r.encode_us.max, r.decode_errors, r.refresh_mismatches, r.recovered, v.pass });
}
