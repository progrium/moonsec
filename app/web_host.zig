//! A browser page as a moonsec host (spike, web/host/README.md): the host session
//! (app/host_session.zig: packetizer, NACK retransmits, recovery, rate controller, input
//! receiver and acks, clock pongs) and the host end of the Opus audio stage, compiled to
//! wasm32-wasi and driven by web/src/host/ through the C ABI below.
//!
//! The page captures and encodes itself (a canvas into WebCodecs `VideoEncoder`; game
//! audio into PCM or WebCodecs `AudioEncoder`), hands each access unit to the session,
//! and injects the input actions the session pops back into the page.
//!
//! Same conventions as the client's module (app/web.zig): one instance per Worker, Zig-owned
//! buffers, `ms_send` for every outgoing datagram, times in µs on the Worker's
//! `performance.now()` clock as f64. Exports are `mh_*`. Bump `abi_version` when an
//! extern struct below changes (web/src/host/core.ts reads them by offset).
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const audio_stage = @import("audio_stage");
const opus = @import("opus");
const host_session = @import("host_session.zig");
const web_pipe = @import("web_pipe.zig");

const HostSession = host_session.HostSession;
const JsPipe = web_pipe.JsPipe;
const proto = core.proto;
const Micros = i64;

pub const abi_version: u32 = 1;

const gpa = std.heap.wasm_allocator;

fn us(t: f64) Micros {
    return @intFromFloat(t);
}

fn f(x: anytype) f64 {
    return switch (@typeInfo(@TypeOf(x))) {
        .int, .comptime_int => @floatFromInt(x),
        .float, .comptime_float => @floatCast(x),
        .bool => if (x) 1 else 0,
        else => @compileError("f64 of " ++ @typeName(@TypeOf(x))),
    };
}

/// One input action for the page to inject (web/src/host/core.ts `readAction`).
/// kind: 1 key (code = HID usage), 2 button (1-based), 3 scroll (a, b = dx, dy; 120 per
/// notch), 4 motion (a, b = dx, dy), 5 abs (a, b = 0..65535), 6 pad (code = index,
/// down = connected, buttons and axes below).
pub const ActionOut = extern struct {
    kind: u32 = 0,
    code: u32 = 0,
    down: u32 = 0,
    buttons: u32 = 0,
    a: i32 = 0,
    b: i32 = 0,
    lx: i32 = 0,
    ly: i32 = 0,
    rx: i32 = 0,
    ry: i32 = 0,
    lt: i32 = 0,
    rt: i32 = 0,
    /// Client capture time (client clock; 0 when the action has none, e.g. motion).
    time: f64 = 0,
};

/// Host counters and the host-side stages (capture, encode, input) as count, last, p50, p99 µs.
pub const StatsOut = extern struct {
    frames: f64,
    keyframes: f64,
    refreshes: f64,
    encode_drops: f64,
    bytes: f64,
    shards: f64,
    nacks: f64,
    retransmits: f64,
    feedback: f64,
    frame_acks: f64,
    recovery_requests: f64,
    pings: f64,
    inputs_applied: f64,
    hellos: f64,
    malformed: f64,
    pacing_bps: f64,
    rtt_us: f64,
    bitrate_bps: f64,
    audio_frames: f64,
    audio_datagrams: f64,
    audio_errors: f64,
    rx_drops: f64,
    stages: [3][4]f64,
};

pub const WebHost = struct {
    pipe: JsPipe,
    s: HostSession,
    audio: ?audio_stage.HostAudio,
    channels: u8,
    au: []u8 = &.{},
    pending_bitrate: u64 = 0,
    /// Long-term reference tokens the client acked, from the last `mh_encode_begin`.
    acked: [16]f64 = undefined,
    acked_n: u32 = 0,
    action: ActionOut = .{},
    stats: StatsOut = undefined,
    pcm: [480 * 2]f32 = undefined,
    opus_pkt: [proto.max_datagram]u8 = undefined,
    aout: audio_stage.HostAudio.Out = .{},
    audio_stats: struct { frames: u64 = 0, datagrams: u64 = 0, errors: u64 = 0 } = .{},
};

export fn mh_abi_version() u32 {
    return abi_version;
}

/// A new host session. `codec` is `api.Codec` (h264 1, hevc 2, av1 3); `channels` 0 turns
/// audio off, else 1 or 2 at 48 kHz in 10 ms frames. `ltr` 0: the encoder has no long-term
/// references (WebCodecs), so every recovery is an IDR.
export fn mh_host_new(ctx: u32, codec: u32, width: u32, height: u32, fps: u32, bitrate_bps: f64, channels: u32, ltr: u32, rate_control: u32) ?*WebHost {
    if (channels > 2) return null;
    const w = gpa.create(WebHost) catch return null;
    w.* = .{ .pipe = .{ .ctx = ctx }, .s = undefined, .audio = null, .channels = @intCast(channels) };
    if (channels > 0) w.audio = audio_stage.HostAudio.init(gpa, .{ .encoder = .{ .channels = w.channels }, .frame_samples = 480 }) catch {
        gpa.destroy(w);
        return null;
    };
    const cfg: host_session.Config = .{
        .codec = @enumFromInt(@as(u8, @truncate(codec))),
        .width = width,
        .height = height,
        .fps = fps,
        .bitrate_bps = @intFromFloat(bitrate_bps),
        .slices = 1,
        .ltr = ltr != 0,
        .rate_control = rate_control != 0,
        .loss_policy = true,
    };
    w.s = HostSession.init(gpa, cfg, .{ .ptr = &w.pipe, .vtable = &JsPipe.vtable }) catch {
        if (w.audio) |*a| a.deinit(gpa);
        gpa.destroy(w);
        return null;
    };
    return w;
}

export fn mh_host_free(w: *WebHost) void {
    w.s.deinit();
    if (w.audio) |*a| a.deinit(gpa);
    if (w.au.len > 0) gpa.free(w.au);
    gpa.destroy(w);
}

// --- pipe (same as the client's) ---------------------------------------------------

export fn mh_rx_slot(w: *WebHost) ?[*]u8 {
    const p = &w.pipe;
    if (p.len == JsPipe.ring) {
        p.recv_drops += 1;
        return null;
    }
    return &p.slots[(p.head + p.len) % JsPipe.ring];
}

export fn mh_rx_slot_cap() u32 {
    return JsPipe.slot_cap;
}

export fn mh_rx_commit(w: *WebHost, len: u32, recv_us: f64) void {
    const p = &w.pipe;
    if (p.len == JsPipe.ring or len > JsPipe.slot_cap) return;
    const i = (p.head + p.len) % JsPipe.ring;
    p.lens[i] = @intCast(len);
    p.times[i] = us(recv_us);
    p.len += 1;
}

export fn mh_set_path(w: *WebHost, rtt_us: f64, relayed: u32, path_epoch: u32, conn_epoch: u32, connected: u32) void {
    const p = &w.pipe.path;
    p.rtt_us = us(rtt_us);
    p.relayed = relayed != 0;
    p.path_epoch = path_epoch;
    p.conn_epoch = conn_epoch;
    p.connected = connected != 0;
}

export fn mh_pipe_closed(w: *WebHost) void {
    w.pipe.closed = true;
}

// --- session -------------------------------------------------------------------------

export fn mh_step(w: *WebHost, now_us: f64) void {
    w.s.step(us(now_us));
}

export fn mh_next_wake(w: *WebHost, now_us: f64) f64 {
    return f(w.s.nextWake(us(now_us)));
}

/// 0 waiting for a client, 1 streaming, 2 ended.
export fn mh_state(w: *WebHost) u32 {
    return @intFromEnum(w.s.state);
}

/// host_session.End order: none, client_bye, peer_timeout, pipe_closed, closed, failed.
export fn mh_end(w: *WebHost) u32 {
    return @intFromEnum(w.s.end);
}

export fn mh_streaming(w: *WebHost) u32 {
    return @intFromBool(w.s.streaming());
}

export fn mh_close(w: *WebHost, now_us: f64) void {
    w.s.close(us(now_us));
}

// --- encode stage ------------------------------------------------------------------

/// Start one encode: 0 normal, 1 LTR refresh, 2 keyframe. Pair with `mh_encode_done` or
/// `mh_encode_dropped`. `mh_encode_bitrate` is then the new target (0: unchanged).
export fn mh_encode_begin(w: *WebHost) u32 {
    const p = w.s.encodeParams();
    w.pending_bitrate = p.bitrate_bps;
    w.acked_n = @intCast(@min(p.acked_ltr_tokens.len, w.acked.len));
    for (p.acked_ltr_tokens[0..w.acked_n], 0..) |t, i| w.acked[i] = f(t);
    return switch (p.force) {
        .none => 0,
        .ltr_refresh => 1,
        .idr => 2,
    };
}

export fn mh_encode_bitrate(w: *WebHost) f64 {
    return f(w.pending_bitrate);
}

/// Long-term reference tokens acked since the previous encode (`mh_encode_acked_n` of them
/// at `mh_encode_acked`, f64 each). The encoder may reference any of them for a refresh.
export fn mh_encode_acked_n(w: *WebHost) u32 {
    return w.acked_n;
}

export fn mh_encode_acked(w: *WebHost) [*]const f64 {
    return &w.acked;
}

/// Room for an access unit of `len` bytes; write it there, then `mh_encode_done`.
export fn mh_au_buf(w: *WebHost, len: u32) ?[*]u8 {
    if (w.au.len < len) {
        if (w.au.len > 0) gpa.free(w.au);
        w.au = gpa.alloc(u8, @max(len, 256 * 1024)) catch {
            w.au = &.{};
            return null;
        };
    }
    return w.au.ptr;
}

/// The access unit at `mh_au_buf` (`len` bytes, Annex B for H.264/HEVC, OBUs for AV1) is
/// the encoder's output for the frame captured at `captured_us`: packetize and send it.
/// `ltr_token` >= 0 when the encoder kept this frame as a long-term reference; `ltr_refresh`
/// when it references only an acked one.
export fn mh_encode_done(w: *WebHost, len: u32, keyframe: u32, ltr_token: f64, ltr_refresh: u32, capture_start_us: f64, captured_us: f64, encode_start_us: f64, encoded_us: f64, width: u32, height: u32, now_us: f64) void {
    const slices = [_][]const u8{w.au[0..len]};
    const ef: api.EncodedFrame = .{
        .slices = &slices,
        .keyframe = keyframe != 0,
        .ltr_token = if (ltr_token >= 0) @intFromFloat(ltr_token) else null,
        .ltr_refresh = ltr_refresh != 0,
        .encode_start_us = us(encode_start_us),
        .encoded_us = us(encoded_us),
    };
    const cf: api.CapturedFrame = .{
        .image = .{ .width = width, .height = height },
        .seq = 0,
        .capture_start_us = us(capture_start_us),
        .captured_us = us(captured_us),
    };
    w.s.onEncoded(ef, &cf, us(now_us));
}

export fn mh_encode_dropped(w: *WebHost) void {
    w.s.onEncodeDropped();
}

// --- input stage ---------------------------------------------------------------------

/// The next input action to inject, or null. Valid until the next call.
export fn mh_next_action(w: *WebHost) ?*const ActionOut {
    const p = w.s.popAction() orelse return null;
    var o: ActionOut = .{ .time = f(p.time) };
    switch (p.action) {
        .key => |k| {
            o.kind = 1;
            o.code = k.code;
            o.down = @intFromBool(k.down);
        },
        .button => |b| {
            o.kind = 2;
            o.code = b.code;
            o.down = @intFromBool(b.down);
        },
        .scroll => |s| {
            o.kind = 3;
            o.a = s.dx;
            o.b = s.dy;
        },
        .motion => |m| {
            o.kind = 4;
            o.a = m.dx;
            o.b = m.dy;
        },
        .abs => |a| {
            o.kind = 5;
            o.a = a.x;
            o.b = a.y;
        },
        .pad => |pd| {
            o.kind = 6;
            o.code = pd.index;
            o.down = @intFromBool(pd.connected);
            o.buttons = pd.state.buttons;
            o.lx = pd.state.lx;
            o.ly = pd.state.ly;
            o.rx = pd.state.rx;
            o.ry = pd.state.ry;
            o.lt = pd.state.lt;
            o.rt = pd.state.rt;
        },
    }
    w.action = o;
    return &w.action;
}

/// The page dispatched an action captured at `client_time` (0: none) at `now_us`.
export fn mh_on_injected(w: *WebHost, client_time: f64, now_us: f64) void {
    w.s.onInjected(us(client_time), us(now_us));
}

// --- audio stage -----------------------------------------------------------------------

/// Where to write one 10 ms frame of interleaved f32 PCM at 48 kHz (480 × channels).
export fn mh_audio_pcm(w: *WebHost) [*]f32 {
    return &w.pcm;
}

/// Where to write one Opus packet (up to `mh_audio_pkt_cap` bytes) from WebCodecs.
export fn mh_audio_pkt(w: *WebHost) [*]u8 {
    return &w.opus_pkt;
}

export fn mh_audio_pkt_cap() u32 {
    return core.audio.wire.max_packet;
}

fn noSeq(_: void) u32 {
    return 0;
}

fn sendAudioOut(w: *WebHost, now: Micros) u32 {
    for (0..w.aout.n) |i| {
        const dg = w.aout.datagram(i);
        var d = proto.wire.Decoder.init(dg);
        const env = proto.Envelope.decode(&d) catch unreachable;
        w.s.sendAudio(env.kind, dg[proto.Envelope.size..], now);
    }
    w.audio_stats.frames += 1;
    w.audio_stats.datagrams += w.aout.n;
    return @intCast(w.aout.n);
}

/// Encode the frame at `mh_audio_pcm` with the core's libopus and send it (frame plus any
/// Reed-Solomon parity). Returns the datagrams sent; 0 when not streaming.
export fn mh_audio_encode(w: *WebHost, capture_us: f64, now_us: f64) u32 {
    const a = if (w.audio) |*x| x else return 0;
    if (!w.s.streaming()) return 0;
    const n = @as(usize, 480) * w.channels;
    a.encode(w.pcm[0..n], @intFromFloat(@max(0, capture_us)), {}, noSeq, &w.aout) catch {
        w.audio_stats.errors += 1;
        return 0;
    };
    return sendAudioOut(w, us(now_us));
}

/// Send the Opus packet at `mh_audio_pkt` (`len` bytes, `samples` per channel, encoded
/// elsewhere, e.g. WebCodecs `AudioEncoder`) through the audio sender.
export fn mh_audio_packet(w: *WebHost, len: u32, samples: u32, capture_us: f64, now_us: f64) u32 {
    const a = if (w.audio) |*x| x else return 0;
    if (!w.s.streaming()) return 0;
    const pkt = w.opus_pkt[0..len];
    const dg = a.tx.frame(&w.aout.bufs[0], 0, @intFromFloat(@max(0, capture_us)), @intCast(samples), (opus.Packet{ .data = pkt }).hasFec(), pkt) catch {
        w.audio_stats.errors += 1;
        return 0;
    };
    w.aout.lens[0] = dg.len;
    w.aout.n = 1;
    while (a.tx.parity(&w.aout.bufs[w.aout.n], 0) catch null) |p| {
        w.aout.lens[w.aout.n] = p.len;
        w.aout.n += 1;
    }
    return sendAudioOut(w, us(now_us));
}

// --- stats -------------------------------------------------------------------------------

export fn mh_stats(w: *WebHost) *const StatsOut {
    const st = w.s.stats;
    var o: StatsOut = std.mem.zeroes(StatsOut);
    inline for (@typeInfo(host_session.Stats).@"struct".fields) |fl| {
        if (@hasField(StatsOut, fl.name)) @field(o, fl.name) = f(@field(st, fl.name));
    }
    const p = w.pipe.path;
    o.pacing_bps = f(p.pacing_bps);
    o.rtt_us = f(p.rtt_us);
    o.bitrate_bps = f(w.s.bitrate_bps);
    o.audio_frames = f(w.audio_stats.frames);
    o.audio_datagrams = f(w.audio_stats.datagrams);
    o.audio_errors = f(w.audio_stats.errors);
    o.rx_drops = f(w.pipe.recv_drops);
    const snap = w.s.tele.snapshot();
    const stages = [_]core.telemetry.Stage{ .capture, .encode, .input };
    inline for (stages, 0..) |stg, i| {
        const ss = snap.stage(stg);
        const last = snap.last.get(stg);
        o.stages[i] = .{
            f(ss.count),
            if (last) |l| f(l) else -1,
            if (ss.count > 0) f(ss.p50) else -1,
            if (ss.count > 0) f(ss.p99) else -1,
        };
    }
    w.stats = o;
    return &w.stats;
}

comptime {
    std.debug.assert(@sizeOf(ActionOut) == 56);
    std.debug.assert(@sizeOf(StatsOut) == 8 * (22 + 12));
}
