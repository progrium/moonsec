//! Zig binding for libopus (built from source by codec/opus/libopus.zig).
//!
//! Only what the audio stream uses: a float encoder with the in-band FEC and loss
//! settings, a float decoder with FEC decode and packet-loss concealment, and TOC
//! inspection. State lives in memory from the caller's allocator, not libopus' malloc.
//!
//! Opus in-band FEC (LBRR) is a low-bitrate copy of the previous frame that SILK
//! writes into the current packet. It exists only in SILK and hybrid modes, and SILK
//! needs frames of at least 10 ms; CELT-only packets (5 ms frames, or music at higher
//! bitrates) never carry it. `Packet.hasFec` tells which packets do.

const std = @import("std");
pub const c = @import("opus_c");

pub const sample_rate = 48_000;

pub const Error = error{
    BadArg,
    BufferTooSmall,
    InternalError,
    InvalidPacket,
    Unimplemented,
    InvalidState,
    AllocFail,
    Unknown,
};

fn check(ret: c_int) Error!c_int {
    if (ret >= 0) return ret;
    return switch (ret) {
        c.OPUS_BAD_ARG => error.BadArg,
        c.OPUS_BUFFER_TOO_SMALL => error.BufferTooSmall,
        c.OPUS_INTERNAL_ERROR => error.InternalError,
        c.OPUS_INVALID_PACKET => error.InvalidPacket,
        c.OPUS_UNIMPLEMENTED => error.Unimplemented,
        c.OPUS_INVALID_STATE => error.InvalidState,
        c.OPUS_ALLOC_FAIL => error.AllocFail,
        else => error.Unknown,
    };
}

pub const Application = enum(c_int) {
    voip = c.OPUS_APPLICATION_VOIP,
    audio = c.OPUS_APPLICATION_AUDIO,
    /// CELT only: lowest algorithmic delay (2.5 ms lookahead instead of 6.5 ms), no SILK,
    /// so no in-band FEC.
    restricted_lowdelay = c.OPUS_APPLICATION_RESTRICTED_LOWDELAY,
};

pub const Signal = enum(c_int) {
    auto = c.OPUS_AUTO,
    voice = c.OPUS_SIGNAL_VOICE,
    music = c.OPUS_SIGNAL_MUSIC,
};

pub const Mode = enum { silk, hybrid, celt };

/// OPUS_SET_INBAND_FEC values.
pub const InbandFec = enum(c_int) {
    off = 0,
    /// FEC on; when the configured loss is high enough libopus moves even music to SILK
    /// or hybrid mode to be able to write it, at a cost in music quality.
    on = 1,
    /// FEC on, but music stays in CELT (no FEC for it); speech-like content still gets
    /// SILK/hybrid with FEC. New in libopus 1.5.
    unless_music = 2,
};

/// Reads an Opus packet's TOC byte (RFC 6716, section 3.1).
pub const Packet = struct {
    data: []const u8,

    pub fn mode(p: Packet) Mode {
        const config = p.data[0] >> 3;
        return if (config < 12) .silk else if (config < 16) .hybrid else .celt;
    }

    /// Samples per channel at 48 kHz.
    pub fn samples(p: Packet) Error!u32 {
        return @intCast(try check(c.opus_packet_get_nb_samples(p.data.ptr, @intCast(p.data.len), sample_rate)));
    }

    /// True when the packet carries in-band FEC (LBRR) for the frame before it.
    pub fn hasFec(p: Packet) bool {
        return c.opus_packet_has_lbrr(p.data.ptr, @intCast(p.data.len)) > 0;
    }
};

pub const EncoderOptions = struct {
    channels: u8 = 2,
    application: Application = .audio,
    signal: Signal = .auto,
    bitrate: i32 = 128_000,
    /// 0-10; 10 is libopus' default. Below 7 libopus skips its music/speech analysis,
    /// so `InbandFec.unless_music` treats everything as speech and music loses CELT.
    complexity: u8 = 10,
    /// Write in-band FEC (LBRR) where the mode allows it. See `InbandFec`.
    inband_fec: InbandFec = .unless_music,
    /// Expected loss in percent. libopus sizes the LBRR copy from it, and from about
    /// 1-2% it moves mixed content toward SILK/hybrid so FEC can be written.
    packet_loss_pct: u8 = 10,
    /// Constant bitrate (VBR off): packet sizes follow the bitrate, not the content.
    cbr: bool = false,
};

pub const Encoder = struct {
    mem: []align(16) u8,
    channels: u8,

    pub fn init(gpa: std.mem.Allocator, o: EncoderOptions) (Error || std.mem.Allocator.Error)!Encoder {
        const size: usize = @intCast(c.opus_encoder_get_size(o.channels));
        if (size == 0) return error.BadArg;
        const mem = try gpa.alignedAlloc(u8, .@"16", size);
        errdefer gpa.free(mem);
        var e: Encoder = .{ .mem = mem, .channels = o.channels };
        _ = try check(c.opus_encoder_init(e.st(), sample_rate, o.channels, @intFromEnum(o.application)));
        try e.set(c.OPUS_SET_BITRATE_REQUEST, o.bitrate);
        try e.set(c.OPUS_SET_COMPLEXITY_REQUEST, o.complexity);
        try e.set(c.OPUS_SET_SIGNAL_REQUEST, @intFromEnum(o.signal));
        try e.set(c.OPUS_SET_INBAND_FEC_REQUEST, @intFromEnum(o.inband_fec));
        try e.set(c.OPUS_SET_PACKET_LOSS_PERC_REQUEST, o.packet_loss_pct);
        try e.set(c.OPUS_SET_VBR_REQUEST, @intFromBool(!o.cbr));
        return e;
    }

    pub fn deinit(e: *Encoder, gpa: std.mem.Allocator) void {
        gpa.free(e.mem);
        e.* = undefined;
    }

    fn st(e: *const Encoder) *c.OpusEncoder {
        return @ptrCast(e.mem.ptr);
    }

    fn set(e: *Encoder, request: c_int, value: i32) Error!void {
        _ = try check(c.moonsec_opus_encoder_set(e.st(), request, value));
    }

    fn get(e: *const Encoder, request: c_int) Error!i32 {
        var v: c.opus_int32 = 0;
        _ = try check(c.moonsec_opus_encoder_get(e.st(), request, &v));
        return v;
    }

    pub fn setBitrate(e: *Encoder, bps: i32) Error!void {
        try e.set(c.OPUS_SET_BITRATE_REQUEST, bps);
    }

    pub fn setPacketLossPct(e: *Encoder, pct: u8) Error!void {
        try e.set(c.OPUS_SET_PACKET_LOSS_PERC_REQUEST, pct);
    }

    pub fn setInbandFec(e: *Encoder, mode: InbandFec) Error!void {
        try e.set(c.OPUS_SET_INBAND_FEC_REQUEST, @intFromEnum(mode));
    }

    /// Samples per channel the encoder looks ahead (algorithmic delay) at 48 kHz.
    pub fn lookahead(e: *const Encoder) Error!u32 {
        return @intCast(try e.get(c.OPUS_GET_LOOKAHEAD_REQUEST));
    }

    /// Encodes one frame of interleaved float PCM (`frame` samples per channel: 120,
    /// 240, 480 or 960 at 48 kHz). Returns the packet, a prefix of `out`.
    pub fn encode(e: *Encoder, pcm: []const f32, out: []u8) Error![]u8 {
        std.debug.assert(pcm.len % e.channels == 0);
        const frame: c_int = @intCast(pcm.len / e.channels);
        const n = try check(c.opus_encode_float(e.st(), pcm.ptr, frame, out.ptr, @intCast(@min(out.len, std.math.maxInt(i32)))));
        return out[0..@intCast(n)];
    }

    pub fn finalRange(e: *const Encoder) u32 {
        var r: c.opus_uint32 = 0;
        _ = c.moonsec_opus_encoder_final_range(e.st(), &r);
        return r;
    }
};

pub const Decoder = struct {
    mem: []align(16) u8,
    channels: u8,

    pub fn init(gpa: std.mem.Allocator, channels: u8) (Error || std.mem.Allocator.Error)!Decoder {
        const size: usize = @intCast(c.opus_decoder_get_size(channels));
        if (size == 0) return error.BadArg;
        const mem = try gpa.alignedAlloc(u8, .@"16", size);
        errdefer gpa.free(mem);
        const d: Decoder = .{ .mem = mem, .channels = channels };
        _ = try check(c.opus_decoder_init(d.st(), sample_rate, channels));
        return d;
    }

    pub fn deinit(d: *Decoder, gpa: std.mem.Allocator) void {
        gpa.free(d.mem);
        d.* = undefined;
    }

    fn st(d: *const Decoder) *c.OpusDecoder {
        return @ptrCast(d.mem.ptr);
    }

    /// Decodes a packet into interleaved float PCM; `pcm.len / channels` is the frame
    /// size. Returns samples per channel written.
    pub fn decode(d: *Decoder, packet: []const u8, pcm: []f32) Error!usize {
        return d.call(packet, pcm, false);
    }

    /// Recovers the frame before `next` from `next`'s in-band FEC. `pcm` must be exactly
    /// the lost frame's length. Without FEC in `next`, libopus conceals instead.
    pub fn decodeFec(d: *Decoder, next: []const u8, pcm: []f32) Error!usize {
        return d.call(next, pcm, true);
    }

    /// Packet-loss concealment for one missing frame of `pcm.len / channels` samples.
    pub fn conceal(d: *Decoder, pcm: []f32) Error!usize {
        return d.call(&.{}, pcm, false);
    }

    fn call(d: *Decoder, packet: []const u8, pcm: []f32, fec: bool) Error!usize {
        std.debug.assert(pcm.len % d.channels == 0);
        const frame: c_int = @intCast(pcm.len / d.channels);
        const data: ?[*]const u8 = if (packet.len == 0) null else packet.ptr;
        const n = try check(c.opus_decode_float(d.st(), data, @intCast(packet.len), pcm.ptr, frame, @intFromBool(fec)));
        return @intCast(n);
    }

    pub fn finalRange(d: *const Decoder) u32 {
        var r: c.opus_uint32 = 0;
        _ = c.moonsec_opus_decoder_final_range(d.st(), &r);
        return r;
    }

    pub fn reset(d: *Decoder) void {
        _ = c.moonsec_opus_decoder_reset(d.st());
    }
};

pub fn versionString() []const u8 {
    return std.mem.span(c.opus_get_version_string());
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Deterministic speech-like test signal, interleaved: a gliding pitch with eight
/// harmonics, a 4 Hz syllable envelope with short pauses, and a little noise. `start` is
/// the index of the first sample (per channel), so consecutive calls continue the signal.
pub fn testSignal(out: []f32, channels: u8, start: u64, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed +% start);
    const r = prng.random();
    const frames = out.len / channels;
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(start + i)) / sample_rate;
        // Pitch glides 100-180 Hz; the phase is the integral of 140 + 40 sin(2 pi 0.7 t).
        const glide: f64 = 40.0 / (2 * std.math.pi * 0.7);
        const phase = 2 * std.math.pi * (140 * t - glide * @cos(2 * std.math.pi * 0.7 * t));
        var s: f64 = 0;
        var h: f64 = 1;
        while (h <= 8) : (h += 1) s += @sin(h * phase) / h;
        const env = @max(0, @sin(2 * std.math.pi * 4 * t)) * (if (@mod(t, 1.5) < 1.2) @as(f64, 1) else 0);
        s = 0.25 * env * s + 0.01 * (r.float(f64) * 2 - 1);
        for (0..channels) |ch| out[i * channels + ch] = @floatCast(if (ch == 0) s else s * 0.8);
    }
}

test "version string names 1.5.2" {
    try testing.expect(std.mem.indexOf(u8, versionString(), "1.5.2") != null);
}

test "encode and decode round trip, 10 ms stereo" {
    const gpa = testing.allocator;
    var enc = try Encoder.init(gpa, .{});
    defer enc.deinit(gpa);
    var dec = try Decoder.init(gpa, 2);
    defer dec.deinit(gpa);
    var pcm: [480 * 2]f32 = undefined;
    var out: [480 * 2]f32 = undefined;
    var buf: [1500]u8 = undefined;
    var energy_in: f64 = 0;
    var energy_err: f64 = 0;
    const delay = try enc.lookahead();
    var hist: [480 * 2 * 4]f32 = @splat(0);
    for (0..100) |f| {
        testSignal(&pcm, 2, f * 480, 1);
        const pkt = try enc.encode(&pcm, &buf);
        try testing.expect(pkt.len > 10);
        try testing.expectEqual(@as(u32, 480), try (Packet{ .data = pkt }).samples());
        try testing.expectEqual(@as(usize, 480), try dec.decode(pkt, &out));
        try testing.expectEqual(enc.finalRange(), dec.finalRange());
        // Compare against the input delayed by the lookahead, after a warm-up.
        std.mem.copyForwards(f32, hist[0 .. hist.len - pcm.len], hist[pcm.len..]);
        @memcpy(hist[hist.len - pcm.len ..], &pcm);
        if (f >= 10) {
            const off = hist.len - pcm.len - delay * 2;
            for (out, 0..) |o, i| {
                const x = hist[off + i];
                energy_in += x * x;
                energy_err += (o - x) * (o - x);
            }
        }
    }
    const snr = 10 * std.math.log10(energy_in / energy_err);
    try testing.expect(snr > 10);
}

test "in-band FEC recovers a lost frame better than concealment" {
    const gpa = testing.allocator;
    // Speech-like settings put the encoder in SILK/hybrid mode, where LBRR exists.
    var enc = try Encoder.init(gpa, .{ .channels = 1, .application = .voip, .bitrate = 32_000, .packet_loss_pct = 20 });
    defer enc.deinit(gpa);
    var dec_fec = try Decoder.init(gpa, 1);
    defer dec_fec.deinit(gpa);
    var dec_plc = try Decoder.init(gpa, 1);
    defer dec_plc.deinit(gpa);
    var dec_ref = try Decoder.init(gpa, 1);
    defer dec_ref.deinit(gpa);

    var pcm: [480]f32 = undefined;
    var bufs: [2][1500]u8 = undefined;
    var pkts: [2][]u8 = undefined;
    var a: [480]f32 = undefined;
    var b: [480]f32 = undefined;
    var ref: [480]f32 = undefined;
    var err_fec: f64 = 0;
    var err_plc: f64 = 0;
    var fec_packets: u32 = 0;
    for (0..200) |f| {
        testSignal(&pcm, 1, f * 480, 2);
        pkts[f % 2] = try enc.encode(&pcm, &bufs[f % 2]);
        const cur = pkts[f % 2];
        if ((Packet{ .data = cur }).hasFec()) fec_packets += 1;
        if (f == 0) continue;
        const prev = pkts[(f - 1) % 2];
        _ = try dec_ref.decode(prev, &ref);
        if (f % 10 == 5) {
            // Lose `prev`: one decoder recovers it from `cur`'s FEC, the other conceals.
            _ = try dec_fec.decodeFec(cur, &a);
            _ = try dec_plc.conceal(&b);
            for (ref, a, b) |r, x, y| {
                err_fec += (x - r) * (x - r);
                err_plc += (y - r) * (y - r);
            }
        } else {
            _ = try dec_fec.decode(prev, &a);
            _ = try dec_plc.decode(prev, &b);
        }
    }
    // The syllable envelope leaves the signal silent about half the time; SILK writes
    // LBRR only for frames its VAD calls active.
    try testing.expect(fec_packets > 70);
    try testing.expect(err_fec * 4 < err_plc);
}
