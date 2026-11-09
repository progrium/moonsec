//! A browser page as a moonsec host (web/host/README.md): the multi-user host
//! (app/multi_host.zig: one encode fanned out to every member, each member a host session
//! with its own packetizer, NACK retransmits, rate estimate, input receiver and acks, clock
//! pongs), the host end of the Opus audio stage, and the host side of pairing and admission
//! (core/pair, spec/pairing-v0.md), compiled to wasm32-wasi and driven by web/src/host/
//! through the C ABI below.
//!
//! The page captures and encodes itself (a canvas into WebCodecs `VideoEncoder`; game
//! audio into PCM or WebCodecs `AudioEncoder`), hands each access unit to the host, and
//! injects the input actions the host pops back into the page. The worker owns the iroh
//! connections: each one runs pairing or admission here (`mh_conn_*`), and an admitted one
//! becomes a member (`mh_peer_add`) with its own pipe.
//!
//! Same conventions as the client's module (app/web.zig): one instance per Worker, Zig-owned
//! buffers, `ms_send(ctx, ptr, len)` for every outgoing datagram (`ctx` names the member's
//! connection), times in µs on the Worker's `performance.now()` clock as f64 (the pairing
//! window uses wall-clock µs). Exports are `mh_*`. Bump `abi_version` when an extern struct
//! or a signature below changes (web/src/host/core.ts reads them by offset).
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const audio_stage = @import("audio_stage");
const opus = @import("opus");
const host_session = @import("host_session.zig");
const multi_host = @import("multi_host.zig");
const web_pipe = @import("web_pipe.zig");

const MultiHost = multi_host.MultiHost;
/// A member's pipe. The host receives acks, feedback and input, not video: a small ring.
const HostPipe = web_pipe.Pipe(256);
const proto = core.proto;
const pair = core.pair;
const ex = pair.exchange;
const Micros = i64;

pub const abi_version: u32 = 2;

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
/// down = connected, buttons and axes below). `from` is the member (roster id) it came
/// from; 0 is the host itself (releases when input changes hands).
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
    from: u32 = 0,
    _pad: u32 = 0,
};

/// One member's counters and its host-side stages (capture, encode, input) as count, last,
/// p50, p99 µs.
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

/// What there is one of: the encode, the roster, input policy, audio (`mh_multi_stats`).
pub const MultiStatsOut = extern struct {
    frames: f64,
    keyframes: f64,
    refreshes: f64,
    encode_drops: f64,
    joins: f64,
    leaves: f64,
    inputs_dropped: f64,
    inputs_applied: f64,
    releases: f64,
    format_refusals: f64,
    members: f64,
    owner: f64,
    bitrate_bps: f64,
    audio_frames: f64,
    audio_datagrams: f64,
    audio_errors: f64,
};

pub const WebPeer = struct {
    pipe: HostPipe,
    peer: *multi_host.Peer,
    stats: StatsOut = undefined,
};

/// A pairing window shared by every exchange that started on it. Closing or replacing it
/// marks it closed; it is freed once no exchange refers to it.
const SharedWindow = struct {
    w: ex.Window,
    refs: u32 = 1,

    fn release(s: *SharedWindow) void {
        s.refs -= 1;
        if (s.refs == 0) gpa.destroy(s);
    }
};

pub const WebHost = struct {
    m: MultiHost,
    peers: std.ArrayList(*WebPeer) = .empty,
    audio: ?audio_stage.HostAudio,
    channels: u8,
    au: []u8 = &.{},
    pending_bitrate: u64 = 0,
    /// Long-term reference tokens the clients acked, from the last `mh_encode_begin`.
    acked: [16]f64 = undefined,
    acked_n: u32 = 0,
    action: ActionOut = .{},
    stats: MultiStatsOut = undefined,
    pcm: [480 * 2]f32 = undefined,
    opus_pkt: [proto.max_datagram]u8 = undefined,
    aout: audio_stage.HostAudio.Out = .{},
    audio_stats: struct { frames: u64 = 0, datagrams: u64 = 0, errors: u64 = 0 } = .{},

    // pairing
    io: [io_len]u8 = undefined,
    host_id: pair.Id = [_]u8{0} ** 32,
    name_buf: [ex.max_name]u8 = undefined,
    name_len: usize = 0,
    window: ?*SharedWindow = null,
    window_paired: u32 = 0,
    qr: pair.qr.Code = undefined,
    qr_out: [pair.qr.max_size * pair.qr.max_size]u8 = undefined,

    const io_len = 4096;

    fn closeWindow(w: *WebHost) void {
        if (w.window) |sw| {
            sw.w.deadline_us = 0;
            sw.release();
        }
        w.window = null;
    }
};

export fn mh_abi_version() u32 {
    return abi_version;
}

/// A new host. `codec` is `api.Codec` (h264 1, hevc 2, av1 3); `channels` 0 turns audio
/// off, else 1 or 2 at 48 kHz in 10 ms frames. `ltr` 0: the encoder has no long-term
/// references (WebCodecs), so every recovery is an IDR. `policy` is the input policy
/// (spec/multi-user-v0.md: 0 owner, 1 everyone, 2 view only); `max_members` at most 32.
export fn mh_host_new(codec: u32, width: u32, height: u32, fps: u32, bitrate_bps: f64, channels: u32, ltr: u32, rate_control: u32, policy: u32, max_members: u32) ?*WebHost {
    if (channels > 2 or policy > 2 or max_members == 0 or max_members > core.multi.max_members) return null;
    const w = gpa.create(WebHost) catch return null;
    w.* = .{ .m = undefined, .audio = null, .channels = @intCast(channels) };
    if (channels > 0) w.audio = audio_stage.HostAudio.init(gpa, .{ .encoder = .{ .channels = w.channels }, .frame_samples = 480 }) catch {
        gpa.destroy(w);
        return null;
    };
    const cfg: multi_host.Config = .{
        .session = .{
            .codec = @enumFromInt(@as(u8, @truncate(codec))),
            .width = width,
            .height = height,
            .fps = fps,
            .bitrate_bps = @intFromFloat(bitrate_bps),
            .slices = 1,
            .ltr = ltr != 0,
            .rate_control = rate_control != 0,
            .loss_policy = true,
        },
        .roster = .{ .policy = @enumFromInt(@as(u8, @intCast(policy))), .max_members = @intCast(max_members) },
    };
    w.m = MultiHost.init(gpa, cfg) catch {
        if (w.audio) |*a| a.deinit(gpa);
        gpa.destroy(w);
        return null;
    };
    return w;
}

export fn mh_host_free(w: *WebHost) void {
    w.m.deinit();
    for (w.peers.items) |p| gpa.destroy(p);
    w.peers.deinit(gpa);
    if (w.audio) |*a| a.deinit(gpa);
    if (w.au.len > 0) gpa.free(w.au);
    w.closeWindow();
    gpa.destroy(w);
}

// --- members -------------------------------------------------------------------------

/// An admitted client becomes a member. `ctx` is what `ms_send` gets for its datagrams;
/// its name (UTF-8, up to 64 bytes) is at `mh_io`. `may_control`: its input may apply.
/// Null when the session is full.
export fn mh_peer_add(w: *WebHost, ctx: u32, name_len: u32, may_control: u32) ?*WebPeer {
    const p = gpa.create(WebPeer) catch return null;
    p.* = .{ .pipe = .{ .ctx = ctx }, .peer = undefined };
    const name = w.io[0..@min(name_len, ex.max_name)];
    p.peer = w.m.addPeer(.{ .ptr = &p.pipe, .vtable = &HostPipe.vtable }, null, name, may_control != 0) catch {
        gpa.destroy(p);
        return null;
    };
    // The pipe lives as long as the multi host keeps the member's session (until free).
    w.peers.append(gpa, p) catch {
        p.peer.s.abort("out of memory");
        return null;
    };
    return p;
}

/// The member's roster id (what `ActionOut.from` says).
export fn mh_peer_id(p: *WebPeer) u32 {
    return p.peer.id;
}

export fn mh_rx_slot(p: *WebPeer) ?[*]u8 {
    const q = &p.pipe;
    if (q.len == HostPipe.ring) {
        q.recv_drops += 1;
        return null;
    }
    return &q.slots[(q.head + q.len) % HostPipe.ring];
}

export fn mh_rx_slot_cap() u32 {
    return HostPipe.slot_cap;
}

export fn mh_rx_commit(p: *WebPeer, len: u32, recv_us: f64) void {
    const q = &p.pipe;
    if (q.len == HostPipe.ring or len > HostPipe.slot_cap) return;
    const i = (q.head + q.len) % HostPipe.ring;
    q.lens[i] = @intCast(len);
    q.times[i] = us(recv_us);
    q.len += 1;
}

export fn mh_set_path(p: *WebPeer, rtt_us: f64, relayed: u32, path_epoch: u32, conn_epoch: u32, connected: u32) void {
    const s = &p.pipe.path;
    s.rtt_us = us(rtt_us);
    s.relayed = relayed != 0;
    s.path_epoch = path_epoch;
    s.conn_epoch = conn_epoch;
    s.connected = connected != 0;
}

export fn mh_pipe_closed(p: *WebPeer) void {
    p.pipe.closed = true;
}

/// 0 waiting for the client's hello, 1 streaming, 2 ended (or left the session).
export fn mh_peer_state(p: *WebPeer) u32 {
    if (p.peer.left) return 2;
    return @intFromEnum(p.peer.s.state);
}

/// host_session.End order: none, client_bye, peer_timeout, pipe_closed, closed, failed.
export fn mh_peer_end(p: *WebPeer) u32 {
    return @intFromEnum(p.peer.s.end);
}

/// End one member's session (the host's user removed it).
export fn mh_peer_close(p: *WebPeer, now_us: f64) void {
    if (!p.peer.left) p.peer.s.close(us(now_us));
}

// --- session -------------------------------------------------------------------------

export fn mh_step(w: *WebHost, now_us: f64) void {
    w.m.step(us(now_us));
}

export fn mh_next_wake(w: *WebHost, now_us: f64) f64 {
    const now = us(now_us);
    var t = now + 5_000;
    for (w.m.peers.items) |p| if (!p.left) {
        t = @min(t, p.s.nextWake(now));
    };
    return f(t);
}

/// Members in the session now.
export fn mh_members(w: *WebHost) u32 {
    var n: u32 = 0;
    for (w.m.peers.items) |p| n += @intFromBool(!p.left);
    return n;
}

export fn mh_streaming(w: *WebHost) u32 {
    return @intFromBool(w.m.streaming());
}

export fn mh_close(w: *WebHost, now_us: f64) void {
    w.m.close(us(now_us));
}

// --- encode stage ------------------------------------------------------------------

/// Start one encode: 0 normal, 1 LTR refresh, 2 keyframe. Pair with `mh_encode_done` or
/// `mh_encode_dropped`. `mh_encode_bitrate` is then the new target (0: unchanged).
export fn mh_encode_begin(w: *WebHost) u32 {
    const p = w.m.encodeParams();
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

/// Long-term reference tokens every member acked since the previous encode
/// (`mh_encode_acked_n` of them at `mh_encode_acked`, f64 each). The encoder may reference
/// any of them for a refresh.
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
/// the encoder's output for the frame captured at `captured_us`: packetize it and send it
/// to every streaming member. `ltr_token` >= 0 when the encoder kept this frame as a
/// long-term reference; `ltr_refresh` when it references only an acked one.
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
    w.m.onEncoded(ef, &cf, us(now_us));
}

export fn mh_encode_dropped(w: *WebHost) void {
    w.m.onEncodeDropped();
}

// --- input stage ---------------------------------------------------------------------

/// The next input action to inject, or null. Valid until the next call.
export fn mh_next_action(w: *WebHost) ?*const ActionOut {
    const p = w.m.popAction() orelse return null;
    var o: ActionOut = .{ .time = f(p.time), .from = p.from };
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

/// The page dispatched an action from member `from`, captured at `client_time` (0: none),
/// at `now_us`.
export fn mh_on_injected(w: *WebHost, from: u32, client_time: f64, now_us: f64) void {
    w.m.onInjected(@intCast(from), us(client_time), us(now_us));
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
        w.m.sendAudio(env.kind, dg[proto.Envelope.size..], now);
    }
    w.audio_stats.frames += 1;
    w.audio_stats.datagrams += w.aout.n;
    return @intCast(w.aout.n);
}

/// Encode the frame at `mh_audio_pcm` with the core's libopus and send it (frame plus any
/// Reed-Solomon parity) to every member. Returns the datagrams sent; 0 when nobody streams.
export fn mh_audio_encode(w: *WebHost, capture_us: f64, now_us: f64) u32 {
    const a = if (w.audio) |*x| x else return 0;
    if (!w.m.streaming()) return 0;
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
    if (!w.m.streaming()) return 0;
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

export fn mh_peer_stats(p: *WebPeer) *const StatsOut {
    const s = &p.peer.s;
    const st = s.stats;
    var o: StatsOut = std.mem.zeroes(StatsOut);
    inline for (@typeInfo(host_session.Stats).@"struct".fields) |fl| {
        if (@hasField(StatsOut, fl.name)) @field(o, fl.name) = f(@field(st, fl.name));
    }
    const path = p.pipe.path;
    o.pacing_bps = f(path.pacing_bps);
    o.rtt_us = f(path.rtt_us);
    o.bitrate_bps = f(s.bitrate_bps);
    o.rx_drops = f(p.pipe.recv_drops);
    const snap = s.tele.snapshot();
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
    p.stats = o;
    return &p.stats;
}

export fn mh_multi_stats(w: *WebHost) *const MultiStatsOut {
    const st = w.m.stats;
    var o: MultiStatsOut = std.mem.zeroes(MultiStatsOut);
    inline for (@typeInfo(multi_host.Stats).@"struct".fields) |fl| {
        if (@hasField(MultiStatsOut, fl.name)) @field(o, fl.name) = f(@field(st, fl.name));
    }
    o.members = f(mh_members(w));
    o.owner = f(w.m.roster.owner);
    o.bitrate_bps = f(w.m.bitrate_bps);
    o.audio_frames = f(w.audio_stats.frames);
    o.audio_datagrams = f(w.audio_stats.datagrams);
    o.audio_errors = f(w.audio_stats.errors);
    w.stats = o;
    return &w.stats;
}

// --- pairing and admission (spec/pairing-v0.md) -------------------------------------------
//
// JS writes inputs into `mh_io` and reads results from it. The pairing window's clock is
// wall-clock µs (`Date.now() * 1000`), since a QR ticket's expiry is in unix seconds.

export fn mh_io(w: *WebHost) [*]u8 {
    return &w.io;
}

export fn mh_io_len() u32 {
    return WebHost.io_len;
}

/// This host's endpoint ID (32 bytes at `mh_io`) and then its name (`name_len` bytes after
/// it), for the pairing exchange.
export fn mh_pair_identity(w: *WebHost, name_len: u32) void {
    @memcpy(&w.host_id, w.io[0..32]);
    const n = pair.allowlist.sanitizeName(w.io[32..][0..@min(name_len, ex.max_name)], &w.name_buf);
    std.mem.copyForwards(u8, w.name_buf[0..n.len], n);
    w.name_len = n.len;
}

/// Opens a pairing window (replacing any open one) until `deadline_us`, for `pairings`
/// devices and `attempts` wrong guesses. `methods` bit 0: the QR ticket secret (16 random
/// bytes at `mh_io[0..16]`); bit 1: a PIN (from 16 random bytes at `mh_io[16..32]`).
/// Returns 0, or -1 when those PIN bytes were all rejected (draw again) or nothing is offered.
/// With a PIN it is at `mh_io[0..6]` afterwards, as digits.
export fn mh_window_open(w: *WebHost, methods: u32, deadline_us: f64, pairings: u32, attempts: u32) i32 {
    if (methods & 3 == 0 or pairings == 0 or attempts == 0) return -1;
    var win: ex.Window = .{ .deadline_us = us(deadline_us), .pairings_left = @intCast(@min(pairings, 255)), .attempts_left = @intCast(@min(attempts, 255)) };
    if (methods & 1 != 0) win.secret = w.io[0..16].*;
    if (methods & 2 != 0) win.pin = pair.pin.fromRandom(w.io[16..32]) orelse return -1;
    const sw = gpa.create(SharedWindow) catch return -1;
    sw.* = .{ .w = win };
    w.closeWindow();
    w.window = sw;
    w.window_paired = 0;
    @memset(w.io[0..32], 0);
    if (win.pin) |pn| @memcpy(w.io[0..6], &pn);
    return 0;
}

export fn mh_window_close(w: *WebHost) void {
    w.closeWindow();
}

/// The window's state at `now_us`: -1 none, 0 closed (deadline, attempts or pairings used
/// up; a pairing awaiting its confirm keeps it until that settles), 1 open.
export fn mh_window_state(w: *WebHost, now_us: f64) i32 {
    const sw = w.window orelse return -1;
    const now = us(now_us);
    if (sw.w.isOpen(now)) return 1;
    if (sw.w.pending > 0 and now < sw.w.deadline_us and sw.w.attempts_left > 0) return 1;
    return 0;
}

export fn mh_window_attempts_left(w: *WebHost) i32 {
    const sw = w.window orelse return -1;
    return sw.w.attempts_left;
}

/// Devices paired in the current window.
export fn mh_window_paired(w: *WebHost) u32 {
    return w.window_paired;
}

/// Writes a `MOONSEC1:` ticket to `mh_io` and returns its length (-1 on error). The host's
/// address (the shim's endpoint ticket text, `addr_len` bytes) is at `mh_io`. `with_secret`:
/// a QR ticket with the open window's secret, else an address ticket (pair by PIN).
export fn mh_ticket(w: *WebHost, addr_len: u32, with_secret: u32, expires_unix_s: f64) i32 {
    if (addr_len > pair.ticket.max_addr) return -1;
    var addr: [pair.ticket.max_addr]u8 = undefined;
    @memcpy(addr[0..addr_len], w.io[0..addr_len]);
    var t: pair.Ticket = .{ .host_id = w.host_id, .addr = addr[0..addr_len] };
    if (with_secret != 0) {
        const sw = w.window orelse return -1;
        t.secret = sw.w.secret orelse return -1;
        t.expires_unix_s = @intFromFloat(@max(0, expires_unix_s));
    }
    const out = t.encode(&w.io) catch return -1;
    return @intCast(out.len);
}

/// Encodes the text at `mh_io[0..len]` as a QR code: returns its size (modules per side)
/// and leaves size × size bytes (1 dark, 0 light, row by row) at `mh_qr_modules`; -1 if
/// it does not fit.
export fn mh_qr(w: *WebHost, len: u32) i32 {
    if (len > WebHost.io_len) return -1;
    w.qr.encode(w.io[0..len], .{}) catch return -1;
    const n: usize = w.qr.size;
    for (0..n) |y| for (0..n) |x| {
        w.qr_out[y * n + x] = @intFromBool(w.qr.get(x, y));
    };
    return @intCast(n);
}

export fn mh_qr_modules(w: *WebHost) [*]const u8 {
    return &w.qr_out;
}

/// One connection's first stream: admission or a pairing exchange.
pub const Conn = struct {
    w: *WebHost,
    peer_id: pair.Id,
    nonce: ex.Nonce,
    seed: ex.Seed,
    framer: ex.Framer = .{},
    state: enum { first, pairing, done } = .first,
    host: ex.Host = undefined,
    window: ?*SharedWindow = null,
    reply_len: u32 = 0,
    reason: u8 = 0,
    paired: ex.Paired = undefined,
};

/// A connection from the endpoint ID at `mh_io[0..32]`, with 16 random nonce bytes at
/// `mh_io[32..48]` and 32 secret random bytes at `mh_io[48..80]`.
export fn mh_conn_new(w: *WebHost) ?*Conn {
    const c = gpa.create(Conn) catch return null;
    c.* = .{ .w = w, .peer_id = w.io[0..32].*, .nonce = w.io[32..48].*, .seed = w.io[48..80].* };
    @memset(w.io[48..80], 0);
    return c;
}

export fn mh_conn_free(c: *Conn) void {
    if (c.state == .pairing) c.host.abort();
    if (c.window) |sw| sw.release();
    std.crypto.secureZero(u8, &c.seed);
    gpa.destroy(c);
}

/// Feeds `mh_io[0..len]` (bytes read from the stream). Returns how many it took; push the
/// rest after `mh_conn_step` has consumed a message.
export fn mh_conn_push(c: *Conn, len: u32) u32 {
    return @intCast(c.framer.push(c.w.io[0..@min(len, WebHost.io_len)]));
}

/// Runs the next whole message, if one has arrived, at wall-clock `now_us`:
///   0  need more bytes
///   1  write the reply (`mh_conn_reply`) and keep reading
///   2  paired: write the reply if any; `mh_conn_paired` has the client
///   3  failed: write the reply if any, then close the connection; `mh_conn_reason` says why
///   4  the client asks for a session: answer with `mh_conn_admit`
///   -1 malformed (close the connection)
export fn mh_conn_step(c: *Conn, now_us: f64) i32 {
    var msg: [ex.max_message]u8 = undefined;
    if (c.state == .done) return -1;
    const m = (c.framer.next(&msg) catch return -1) orelse return 0;
    c.reply_len = 0;
    if (c.state == .first) switch (ex.classify(m)) {
        .admit => {
            c.state = .done;
            return 4;
        },
        .invalid => {
            c.state = .done;
            return -1;
        },
        .pair => {
            // No window open: the client hears "not pairing right now".
            if (c.w.window) |sw| {
                sw.refs += 1;
                c.window = sw;
            }
            c.host = ex.Host.init(if (c.window) |sw| &sw.w else null, c.w.host_id, c.peer_id, c.nonce, c.seed, c.w.name_buf[0..c.w.name_len]);
            std.crypto.secureZero(u8, &c.seed);
            c.state = .pairing;
        },
    };
    const step = c.host.onMessage(m, us(now_us));
    switch (step) {
        .more => |r| {
            if (r) |b| reply(c, b);
            return 1;
        },
        .paired => |p| {
            if (p.reply) |b| reply(c, b);
            c.paired = p.paired;
            c.state = .done;
            if (c.window == c.w.window) c.w.window_paired += 1;
            return 2;
        },
        .failed => |x| {
            if (x.reply) |b| reply(c, b);
            c.reason = @intFromEnum(x.reason);
            c.state = .done;
            return 3;
        },
    }
}

fn reply(c: *Conn, b: []const u8) void {
    @memcpy(c.w.io[0..b.len], b);
    c.reply_len = @intCast(b.len);
}

/// The reply to write, at `mh_io`.
export fn mh_conn_reply(c: *Conn) u32 {
    return c.reply_len;
}

export fn mh_conn_reason(c: *Conn) u32 {
    return c.reason;
}

/// The paired client: its endpoint ID at `mh_io[0..32]`, its (sanitized) name after it.
/// Returns the name's length. Bit 8 set: it paired by PIN.
export fn mh_conn_paired(c: *Conn) u32 {
    const n = c.paired.name();
    @memcpy(c.w.io[0..32], &c.paired.peer_id);
    @memcpy(c.w.io[32..][0..n.len], n);
    return @as(u32, @intCast(n.len)) | (if (c.paired.method == .pin) @as(u32, 0x100) else 0);
}

/// The answer to `admit` (`allowed`: the client is on the allowlist), at `mh_io`.
export fn mh_conn_admit(c: *Conn, allowed: u32) u32 {
    var o: ex.Out = .{};
    const b = ex.admitReply(&o, allowed != 0);
    reply(c, b);
    return c.reply_len;
}

comptime {
    std.debug.assert(@sizeOf(ActionOut) == 64);
    std.debug.assert(@sizeOf(StatsOut) == 8 * (22 + 12));
    std.debug.assert(@sizeOf(MultiStatsOut) == 8 * 16);
}
