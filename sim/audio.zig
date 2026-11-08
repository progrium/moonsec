//! The audio stream end to end over the simulated network, with real libopus.
//!
//! Host (endpoint A): every 10 ms (true time) a frame of a synthetic signal goes through
//! `HostAudio` (codec/opus/stage.zig: Opus with in-band FEC, then `core.audio.Sender`
//! with light RS parity), and a lossless reference decoder decodes every packet. Client
//! (endpoint B): datagrams go into `ClientAudio` (the jitter buffer and an Opus decoder);
//! a device renders a frame every 10 ms of its own clock, with a configurable skew.
//!
//! Each run reports what the buffer did (decoded, FEC, RS, concealed, late, trimmed),
//! the latency from capture to playout, and the SNR of the played audio against the
//! lossless reference decode, overall and over the frames that needed repair.
//!
//! Counts are deterministic per seed on one platform. Encoder decisions go through
//! libm, so exact counts can differ slightly between operating systems; tests use bounds.

const std = @import("std");
const simnet = @import("simnet");
const core = @import("core");
const opus = @import("opus");
const stage = @import("audio_stage");

const proto = core.proto;
const audio = core.audio;
const MS = simnet.MS;
const SEC = simnet.SEC;

pub const Signal = enum { speech, music };

pub const Scenario = struct {
    name: []const u8,
    about: []const u8,
    duration_us: i64 = 10 * SEC,
    net: simnet.LinkConfig,
    signal: Signal = .music,
    encoder: opus.EncoderOptions = .{},
    rs: audio.sender.Config = .{},
    buffer: audio.receiver.Config = .{},
    /// Device clock error: + means the device runs slow (pulls less often).
    skew_ppm: i64 = 0,
};

pub const Result = struct {
    frames: u64 = 0,
    frames_with_fec: u64 = 0,
    parity: u64 = 0,
    /// Audio datagrams the network lost (random loss and blackouts).
    lost: u64 = 0,
    kbps: f64 = 0,
    buf: audio.receiver.Stats = .{},
    latency_p50_ms: f64 = 0,
    latency_p99_ms: f64 = 0,
    /// Played audio against the lossless reference decode, dB.
    snr_db: f64 = 0,
    /// Same, over frames played by FEC or concealment only (inf when there were none).
    repaired_snr_db: f64 = std.math.inf(f64),
    /// Of frames whose packet was lost: how many were rebuilt (RS) or FEC-decoded.
    covered_pct: f64 = 100,
    /// The lossless decode against the input (delayed by the codec lookahead), dB: what
    /// the encoder settings cost before any loss. Waveform SNR, not a perceptual score.
    codec_snr_db: f64 = 0,
    /// Packets by Opus mode.
    silk: u64 = 0,
    hybrid: u64 = 0,
    celt: u64 = 0,
};

const frame_samples = 480;

fn nextSeq(s: *u32) u32 {
    defer s.* +%= 1;
    return s.*;
}
const frame_us = 10 * MS;

fn signal(kind: Signal, out: []f32, channels: u8, start: u64, seed: u64) void {
    switch (kind) {
        .speech => opus.testSignal(out, channels, start, seed),
        .music => {
            // A held chord plus noise "hats" at 8 Hz: tonal and noisy content at once,
            // with no pauses, as game and desktop audio usually is.
            var prng = std.Random.DefaultPrng.init(seed +% start);
            const r = prng.random();
            const frames = out.len / channels;
            for (0..frames) |i| {
                const t = @as(f64, @floatFromInt(start + i)) / opus.sample_rate;
                var s: f64 = 0;
                for ([_]f64{ 220, 277.18, 329.63, 440, 1760, 3520 }) |f| s += @sin(2 * std.math.pi * f * t) * 0.08;
                s += 0.05 * (r.float(f64) * 2 - 1) * (0.5 + 0.5 * @sin(2 * std.math.pi * 8 * t));
                for (0..channels) |ch| out[i * channels + ch] = @floatCast(if (ch == 0) s else -s * 0.7 + 0.03 * @sin(2 * std.math.pi * 660 * t));
            }
        },
    }
}

pub fn run(gpa: std.mem.Allocator, sc: Scenario, seed: u64) !Result {
    const ch = sc.encoder.channels;
    const n_frames: usize = @intCast(@divTrunc(sc.duration_us, frame_us));

    var net: simnet.Net = undefined;
    try net.init(gpa, .{
        .seed = seed,
        .b = .{ .clock_offset_us = 987 * SEC },
        .a_to_b = sc.net,
        .b_to_a = .{ .delay_us = sc.net.delay_us },
    });
    defer net.deinit();
    const pa = net.pipeFor(.a);
    const pb = net.pipeFor(.b);

    var host = try stage.HostAudio.init(gpa, .{ .encoder = sc.encoder, .rs = sc.rs, .frame_samples = frame_samples });
    defer host.deinit(gpa);
    var client = try stage.ClientAudio.init(gpa, ch, sc.buffer);
    defer client.deinit(gpa);
    const rx = client.rx;
    var ref_dec = try opus.Decoder.init(gpa, ch);
    defer ref_dec.deinit(gpa);

    // Reference decode of every frame, by sequence number.
    const fl = frame_samples * @as(usize, ch);
    const ref = try gpa.alloc(f32, n_frames * fl);
    defer gpa.free(ref);
    const input = try gpa.alloc(f32, n_frames * fl);
    defer gpa.free(input);
    // Which frames' packets reached the client (frame datagram, not parity).
    const arrived = try gpa.alloc(bool, n_frames);
    defer gpa.free(arrived);
    @memset(arrived, false);
    var latencies: std.ArrayList(i64) = .empty;
    defer latencies.deinit(gpa);

    var res: Result = .{};
    var pcm: [frame_samples * 2]f32 = undefined;
    var out: [frame_samples * 2]f32 = undefined;
    var dgs: stage.HostAudio.Out = .{};
    var rx_buf: [proto.max_datagram]u8 = undefined;
    var env_seq: u32 = 0;
    var sig_e: f64 = 0;
    var err_e: f64 = 0;
    var rep_sig: f64 = 0;
    var rep_err: f64 = 0;
    var repaired_frames: u64 = 0;

    var next_host: i64 = 0;
    var host_frame: usize = 0;
    // Device pulls, in ns of true time so a ppm skew accumulates exactly.
    const pull_ns: i64 = frame_us * 1000 + @divTrunc(frame_us * 1000 * sc.skew_ppm, 1_000_000);
    var next_pull_ns: i64 = 0;
    const end_us = sc.duration_us + 200 * MS;
    while (true) {
        const next_pull = @divTrunc(next_pull_ns + 999, 1000);
        var t = @min(next_pull, if (host_frame < n_frames) next_host else std.math.maxInt(i64));
        if (net.nextEventTime()) |e| t = @min(t, e);
        if (t > end_us) break;
        try net.runUntil(t);

        while (try pb.recv(&rx_buf)) |r| {
            const m = proto.decode(rx_buf[0..r.len]) catch continue;
            const env = m.envelope();
            if (env.stream != .audio) continue;
            if (env.kind == @intFromEnum(audio.Kind.frame)) {
                const f = try audio.Frame.parse(m.other.payload);
                if (f.header.seq < n_frames) arrived[f.header.seq] = true;
            }
            client.onMessage(env, m.other.payload, r.recv_us);
        }

        if (host_frame < n_frames and t == next_host) {
            signal(sc.signal, pcm[0..fl], ch, host_frame * frame_samples, seed);
            @memcpy(input[host_frame * fl ..][0..fl], pcm[0..fl]);
            try host.encode(pcm[0..fl], @intCast(net.localTime(.a)), &env_seq, nextSeq, &dgs);
            for (0..dgs.n) |i| try pa.send(dgs.datagram(i));
            const info: opus.Packet = .{ .data = host.last };
            switch (info.mode()) {
                .silk => res.silk += 1,
                .hybrid => res.hybrid += 1,
                .celt => res.celt += 1,
            }
            _ = try ref_dec.decode(host.last, ref[host_frame * fl ..][0..fl]);
            host_frame += 1;
            next_host += frame_us;
        }

        // The device stops once the last frame's slot has played.
        if (t == next_pull and !(rx.anchored and rx.next_seq >= n_frames)) {
            const r = try client.render(net.localTime(.b), &out);
            const repaired = r.kind == .fec or r.kind == .conceal;
            if (r.kind == .decode) try latencies.append(gpa, t - @as(i64, r.seq.?) * frame_us);
            if (r.seq) |sq| if (sq < n_frames) {
                const want = ref[sq * fl ..][0..fl];
                var fs: f64 = 0;
                var fe: f64 = 0;
                for (want, out[0..fl]) |w, o| {
                    fs += w * w;
                    fe += (o - w) * (o - w);
                }
                sig_e += fs;
                err_e += fe;
                if (repaired) {
                    rep_sig += fs;
                    rep_err += fe;
                    repaired_frames += 1;
                }
            };
        }
        if (t == next_pull) next_pull_ns += pull_ns;
    }

    const tx = host.tx;
    res.frames = tx.stats.frames;
    res.frames_with_fec = tx.stats.frames_with_fec;
    res.parity = tx.stats.parity;
    const ls = net.linkStats(.a);
    res.lost = ls.random_losses + ls.blackout_drops + ls.queue_drops;
    res.kbps = @as(f64, @floatFromInt(tx.stats.bytes * 8)) / (@as(f64, @floatFromInt(sc.duration_us)) / 1000);
    res.buf = rx.stats;
    res.snr_db = if (err_e == 0) std.math.inf(f64) else 10 * std.math.log10(sig_e / err_e);
    if (repaired_frames > 0) res.repaired_snr_db = if (rep_err == 0) std.math.inf(f64) else 10 * std.math.log10(rep_sig / rep_err);
    var missing: u64 = 0;
    for (arrived) |a| {
        if (!a) missing += 1;
    }
    if (missing > 0) {
        const covered = rx.stats.rs_recovered + rx.stats.fec;
        res.covered_pct = 100 * @as(f64, @floatFromInt(@min(covered, missing))) / @as(f64, @floatFromInt(missing));
    }
    // Codec SNR after a 0.5 s warm-up, input delayed by the lookahead.
    const delay = @as(usize, try host.enc.lookahead()) * ch;
    var cs: f64 = 0;
    var ce: f64 = 0;
    for (n_frames / 20 * fl..n_frames * fl) |i| {
        const x = input[i - delay];
        cs += x * x;
        ce += (ref[i] - x) * (ref[i] - x);
    }
    res.codec_snr_db = 10 * std.math.log10(cs / ce);
    std.mem.sort(i64, latencies.items, {}, std.sort.asc(i64));
    if (latencies.items.len > 0) {
        res.latency_p50_ms = @as(f64, @floatFromInt(latencies.items[latencies.items.len / 2])) / 1000;
        res.latency_p99_ms = @as(f64, @floatFromInt(latencies.items[latencies.items.len * 99 / 100])) / 1000;
    }
    return res;
}

// ---------------------------------------------------------------------------
// Scenarios

const fec_only: audio.sender.Config = .{ .m = 0 };
const wifi: simnet.WiFi = .{};
const blackout = [_]simnet.Window{.{ .start_us = 5 * SEC, .end_us = 5 * SEC + 300 * MS }};

pub const all = [_]Scenario{
    .{ .name = "lan", .about = "1 ms one way, nothing wrong", .net = .{ .delay_us = 1 * MS } },
    .{ .name = "jitter-15", .about = "10 ms one way, 0-15 ms jitter (inside the 20 ms buffer)", .net = .{ .delay_us = 10 * MS, .jitter_us = 15 * MS } },
    .{ .name = "jitter-30", .about = "10 ms one way, 0-30 ms jitter (beyond the buffer)", .net = .{ .delay_us = 10 * MS, .jitter_us = 30 * MS } },
    .{ .name = "loss-5-music-rs", .about = "5% loss, music, in-band FEC + RS(2+1)", .net = .{ .delay_us = 10 * MS, .loss = 0.05 } },
    .{ .name = "loss-5-music-fec", .about = "5% loss, music, in-band FEC only", .net = .{ .delay_us = 10 * MS, .loss = 0.05 }, .rs = fec_only },
    .{ .name = "loss-5-music-fec1", .about = "5% loss, music, in-band FEC mode 1 (may force hybrid), no RS", .net = .{ .delay_us = 10 * MS, .loss = 0.05 }, .rs = fec_only, .encoder = .{ .inband_fec = .on } },
    .{ .name = "loss-5-speech-rs", .about = "5% loss, speech, in-band FEC + RS(2+1)", .net = .{ .delay_us = 10 * MS, .loss = 0.05 }, .signal = .speech },
    .{ .name = "loss-5-speech-fec", .about = "5% loss, speech, in-band FEC only", .net = .{ .delay_us = 10 * MS, .loss = 0.05 }, .signal = .speech, .rs = fec_only },
    .{ .name = "loss-bursty", .about = "2% loss in bursts of 4 (Gilbert-Elliott), FEC + RS", .net = .{ .delay_us = 10 * MS, .loss = 0.02, .loss_burst = 4 } },
    .{ .name = "blackout", .about = "300 ms blackout at 5 s", .net = .{ .delay_us = 10 * MS, .blackouts = &blackout } },
    .{ .name = "wifi", .about = "S11's synthetic Wi-Fi: aggregation and 5-60 ms radio stalls", .net = .{ .delay_us = 2 * MS, .wifi = wifi } },
    .{ .name = "drift-slow", .about = "device clock 0.25% slow over 20 s", .duration_us = 20 * SEC, .net = .{ .delay_us = 10 * MS }, .skew_ppm = 2500 },
    .{ .name = "drift-fast", .about = "device clock 0.25% fast over 20 s", .duration_us = 20 * SEC, .net = .{ .delay_us = 10 * MS }, .skew_ppm = -2500 },
};

pub fn find(name: []const u8) ?Scenario {
    for (all) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

// ---------------------------------------------------------------------------
// Tests (shortened runs; `zig build audio-sim` runs them at full length)

const testing = std.testing;

fn short(name: []const u8, dur: i64) Scenario {
    var s = find(name).?;
    s.duration_us = dur;
    return s;
}

test "lan: every frame decodes, latency is the 20 ms buffer plus the path" {
    const r = try run(testing.allocator, short("lan", 3 * SEC), 1);
    try testing.expectEqual(@as(u64, 0), r.buf.concealed + r.buf.fec + r.buf.late + r.buf.dropped + r.buf.inserted);
    try testing.expect(r.latency_p50_ms >= 16 and r.latency_p50_ms <= 32);
    try testing.expect(std.math.isInf(r.snr_db));
}

test "jitter inside the target costs nothing; beyond it frames are late" {
    const a = try run(testing.allocator, short("jitter-15", 3 * SEC), 1);
    try testing.expectEqual(@as(u64, 0), a.buf.late);
    try testing.expectEqual(@as(u64, 0), a.buf.concealed + a.buf.fec);
    // Long enough for the buffer to trim down from a slow first packet.
    const b = try run(testing.allocator, short("jitter-30", 6 * SEC), 1);
    try testing.expect(b.buf.late > 20);
}

test "5% loss: RS rebuilds most lost frames bit-exact" {
    const r = try run(testing.allocator, short("loss-5-music-rs", 5 * SEC), 1);
    try testing.expect(r.lost > 30);
    try testing.expect(r.buf.rs_recovered > 15);
    try testing.expect(r.covered_pct > 85);
    try testing.expect(r.buf.concealed * 10 < r.lost);
    try testing.expect(r.snr_db > 15);
}

test "music: in-band FEC alone covers few losses" {
    const r = try run(testing.allocator, short("loss-5-music-fec", 5 * SEC), 1);
    try testing.expectEqual(@as(u64, 0), r.buf.rs_recovered);
    try testing.expect(r.frames_with_fec * 4 < r.frames);
    try testing.expect(r.covered_pct < 50);
}

test "speech: in-band FEC covers active frames" {
    const r = try run(testing.allocator, short("loss-5-speech-fec", 5 * SEC), 1);
    try testing.expect(r.frames_with_fec * 3 > r.frames);
    try testing.expect(r.buf.fec > 5);
}

test "blackout: concealed through, then plays on without resync" {
    var s = short("blackout", 7 * SEC);
    s.net.blackouts = &.{.{ .start_us = 3 * SEC, .end_us = 3 * SEC + 300 * MS }};
    const r = try run(testing.allocator, s, 1);
    try testing.expect(r.buf.concealed >= 25 and r.buf.concealed <= 32);
    try testing.expectEqual(@as(u64, 0), r.buf.resyncs);
}

test "drift: the buffer trims or stretches and stays near target" {
    const slow = try run(testing.allocator, short("drift-slow", 12 * SEC), 1);
    try testing.expect(slow.buf.dropped >= 2);
    try testing.expectEqual(@as(u64, 0), slow.buf.late + slow.buf.concealed);
    try testing.expect(slow.latency_p99_ms < 45);
    const fast = try run(testing.allocator, short("drift-fast", 12 * SEC), 1);
    try testing.expect(fast.buf.inserted >= 2);
    try testing.expectEqual(@as(u64, 0), fast.buf.late);
}

test "runs are deterministic by seed" {
    const a = try run(testing.allocator, short("loss-bursty", 2 * SEC), 3);
    const b = try run(testing.allocator, short("loss-bursty", 2 * SEC), 3);
    try testing.expectEqual(a, b);
}
