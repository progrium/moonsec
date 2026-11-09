//! The browser client's core (Phase 6, docs/design.md "Web client"): the client session
//! (reassembly, NACKs, transport feedback, frame acks and recovery, clock sync, input)
//! and the Opus audio stage, compiled to wasm32-wasi and driven by the TypeScript client
//! in web/ through the C ABI below. The same code the native clients run; only the
//! PacketPipe and the clock are JavaScript's.
//!
//! Threading: one instance lives in one Worker and every call comes from it.
//!
//! Buffers are Zig-owned. JavaScript writes an arriving datagram straight into the
//! receive ring (`ms_rx_slot`, then `ms_rx_commit`), reads frames and PCM in place
//! (`ms_next_frame`, `ms_audio_render`), and gets every outgoing datagram through the
//! imported `ms_send(ctx, ptr, len)`, which must copy it before returning. Times are
//! microseconds on the Worker's `performance.now()` clock, passed as f64 so JavaScript
//! never deals in BigInt. Structs returned by pointer are `extern` with the layouts
//! web/src/core.ts reads; bump `abi_version` when one changes.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const pipe_mod = @import("pipe");
const audio_stage = @import("audio_stage");
const client_session = @import("client_session.zig");

const ClientSession = client_session.ClientSession;
const proto = core.proto;
const Micros = i64;

pub const abi_version: u32 = 1;

/// Supplied by JavaScript: send one datagram (copy it; the bytes are reused).
extern "env" fn ms_send(ctx: u32, ptr: [*]const u8, len: usize) void;

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

/// The PacketPipe JavaScript implements: a receive ring it fills, `ms_send` out, and
/// the path stats its transport reports (`ms_set_path`).
const JsPipe = struct {
    ctx: u32,
    slots: [ring][slot_cap]u8 = undefined,
    lens: [ring]u16 = undefined,
    times: [ring]Micros = undefined,
    head: usize = 0,
    len: usize = 0,
    path: pipe_mod.PathStats = .{},
    recv_drops: u64 = 0,
    closed: bool = false,

    const ring = 1024;
    const slot_cap = 2048;

    fn send(p: *anyopaque, data: []const u8) pipe_mod.SendError!void {
        const s: *JsPipe = @ptrCast(@alignCast(p));
        if (s.closed) return error.Closed;
        if (data.len > proto.max_datagram) return error.TooLarge;
        ms_send(s.ctx, data.ptr, data.len);
        s.path.sent += 1;
    }

    fn recv(p: *anyopaque, buf: []u8) pipe_mod.RecvError!?pipe_mod.Received {
        const s: *JsPipe = @ptrCast(@alignCast(p));
        if (s.len == 0) return if (s.closed) error.Closed else null;
        const n = s.lens[s.head];
        if (buf.len < n) return error.BufferTooSmall;
        @memcpy(buf[0..n], s.slots[s.head][0..n]);
        const t = s.times[s.head];
        s.head = (s.head + 1) % ring;
        s.len -= 1;
        s.path.received += 1;
        return .{ .len = n, .recv_us = t };
    }

    fn setPacingRate(_: *anyopaque, _: u64) void {}

    fn stats(p: *anyopaque) pipe_mod.PathStats {
        const s: *JsPipe = @ptrCast(@alignCast(p));
        var st = s.path;
        st.recv_drops = s.recv_drops;
        return st;
    }

    fn maxDatagramSize(_: *anyopaque) usize {
        return proto.max_datagram;
    }

    const vtable: pipe_mod.PacketPipe.VTable = .{ .send = send, .recv = recv, .setPacingRate = setPacingRate, .stats = stats, .maxDatagramSize = maxDatagramSize };
};

/// Frame handed to the decoder (web/src/core.ts `readFrame`).
pub const FrameOut = extern struct {
    data: u32,
    len: u32,
    frame_id: u32,
    keyframe: u32,
    codec: u32,
    _pad: u32 = 0,
    /// Host clock.
    capture_us: f64,
    /// Client clock.
    received_us: f64,
};

/// The host's stream config (zeros until it arrives).
pub const ConfigOut = extern struct {
    codec: u32 = 0,
    slices: u32 = 0,
    fps: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    _pad: u32 = 0,
    bitrate_bps: f64 = 0,
};

/// Overlay numbers: header fields, then per telemetry stage (capture, encode, network,
/// decode, present, total, input) count, last, p50, p99 in microseconds (-1: none).
pub const OverlayOut = extern struct {
    bitrate_bps: f64,
    pacing_bps: f64,
    rtt_us: f64,
    loss: f64,
    relayed: f64,
    freezes: f64,
    clock_synced: f64,
    frames: f64,
    stages: [core.telemetry.Stage.count][4]f64,
};

/// Session counters, in this order (web/src/core.ts `statNames`).
pub const StatsOut = extern struct {
    frames_received: f64,
    frames_lost: f64,
    frames_dropped: f64,
    frames_stale: f64,
    frames_decoded: f64,
    decode_errors: f64,
    frames_presented: f64,
    queue_overflows: f64,
    shards: f64,
    nacks: f64,
    feedback: f64,
    frame_acks: f64,
    pongs: f64,
    input_events: f64,
    input_packets: f64,
    malformed: f64,
    recovery_requests: f64,
    freezes: f64,
    audio_decoded: f64,
    audio_fec: f64,
    audio_rs_recovered: f64,
    audio_concealed: f64,
    audio_late: f64,
    audio_silence: f64,
    audio_delay_us: f64,
    rx_drops: f64,
};

pub const Web = struct {
    pipe: JsPipe,
    s: ClientSession,
    audio: ?audio_stage.ClientAudio,
    channels: u8,
    frame: FrameOut = undefined,
    config: ConfigOut = .{},
    overlay: OverlayOut = undefined,
    stats: StatsOut = undefined,
    pcm: [2880 * 2]f32 = undefined,

    fn onAudio(ctx: ?*anyopaque, env: proto.Envelope, payload: []const u8, recv_us: Micros) void {
        const w: *Web = @ptrCast(@alignCast(ctx.?));
        if (w.audio) |*a| a.onMessage(env, payload, recv_us);
    }
};

export fn ms_abi_version() u32 {
    return abi_version;
}

/// A new session. `codecs` is the `CodecSet` byte (h264 1, hevc 2, av1 4); `channels`
/// 0 turns audio off, else 1 or 2 at 48 kHz. `ctx` is passed back to `ms_send`.
export fn ms_client_new(ctx: u32, codecs: u32, nonce: u32, max_width: u32, max_height: u32, channels: u32) ?*Web {
    if (channels > 2) return null;
    const w = gpa.create(Web) catch return null;
    w.pipe = .{ .ctx = ctx };
    w.channels = @intCast(channels);
    w.audio = null;
    if (channels > 0) w.audio = audio_stage.ClientAudio.init(gpa, w.channels, .{}) catch {
        gpa.destroy(w);
        return null;
    };
    const cfg: client_session.Config = .{
        .codecs = @bitCast(@as(u8, @truncate(codecs))),
        .nonce = nonce,
        .max_width = max_width,
        .max_height = max_height,
        .audio_ctx = if (channels > 0) w else null,
        .onAudio = if (channels > 0) Web.onAudio else null,
    };
    w.s = ClientSession.init(gpa, cfg, .{ .ptr = &w.pipe, .vtable = &JsPipe.vtable }) catch {
        if (w.audio) |*a| a.deinit(gpa);
        gpa.destroy(w);
        return null;
    };
    w.frame = std.mem.zeroes(FrameOut);
    return w;
}

export fn ms_client_free(w: *Web) void {
    w.s.deinit();
    if (w.audio) |*a| a.deinit(gpa);
    gpa.destroy(w);
}

/// Where to write the next arriving datagram (`ms_rx_slot_cap` bytes), or null when
/// the ring is full (the datagram is dropped and counted).
export fn ms_rx_slot(w: *Web) ?[*]u8 {
    const p = &w.pipe;
    if (p.len == JsPipe.ring) {
        p.recv_drops += 1;
        return null;
    }
    return &p.slots[(p.head + p.len) % JsPipe.ring];
}

export fn ms_rx_slot_cap() u32 {
    return JsPipe.slot_cap;
}

/// The datagram written at `ms_rx_slot` is `len` bytes and arrived at `recv_us`.
export fn ms_rx_commit(w: *Web, len: u32, recv_us: f64) void {
    const p = &w.pipe;
    if (p.len == JsPipe.ring or len > JsPipe.slot_cap) return;
    const i = (p.head + p.len) % JsPipe.ring;
    p.lens[i] = @intCast(len);
    p.times[i] = us(recv_us);
    p.len += 1;
}

/// Path stats from the transport. Bump `path_epoch` when the path changes and
/// `conn_epoch` when the connection is replaced.
export fn ms_set_path(w: *Web, rtt_us: f64, relayed: u32, path_epoch: u32, conn_epoch: u32, connected: u32) void {
    const p = &w.pipe.path;
    p.rtt_us = us(rtt_us);
    p.relayed = relayed != 0;
    p.path_epoch = path_epoch;
    p.conn_epoch = conn_epoch;
    p.connected = connected != 0;
}

/// The transport is gone: the session ends once the ring is drained.
export fn ms_pipe_closed(w: *Web) void {
    w.pipe.closed = true;
}

/// Drain the ring and run timers. Call on every arrival and at `ms_next_wake`.
export fn ms_step(w: *Web, now_us: f64) void {
    w.s.step(us(now_us));
}

export fn ms_next_wake(w: *Web, now_us: f64) f64 {
    return f(w.s.nextWake(us(now_us)));
}

/// 0 connecting, 1 streaming, 2 ended.
export fn ms_state(w: *Web) u32 {
    return @intFromEnum(w.s.state);
}

/// Why it ended (client_session.End order: none, host_bye, peer_timeout,
/// connect_timeout, pipe_closed, closed, failed).
export fn ms_end(w: *Web) u32 {
    return @intFromEnum(w.s.end);
}

/// Leave: sends byes over the next steps, then the state is `ended`.
export fn ms_close(w: *Web, now_us: f64) void {
    w.s.close(us(now_us));
}

export fn ms_config(w: *Web) *const ConfigOut {
    if (w.s.config) |c| w.config = .{ .codec = @intFromEnum(c.codec), .slices = c.slices, .fps = c.fps, .width = c.width, .height = c.height, .bitrate_bps = f(c.bitrate_bps) };
    return &w.config;
}

/// The next frame to decode, or null. Its bytes are valid until the next call.
/// Frames after a loss are held back until the recovery frame (core/recovery), so
/// every frame returned here is decodable given the ones before it.
export fn ms_next_frame(w: *Web) ?*const FrameOut {
    const au = w.s.nextAccessUnit() orelse return null;
    w.frame = .{
        .data = @intFromPtr(au.data.ptr),
        .len = @intCast(au.data.len),
        .frame_id = au.frame_id,
        .keyframe = @intFromBool(au.keyframe),
        .codec = @intFromEnum(au.codec),
        .capture_us = f(au.capture_us),
        .received_us = f(au.received_us),
    };
    return &w.frame;
}

/// The decoder finished frame `id` (ok = 0: it failed; recovery asks for a refresh).
export fn ms_on_decoded(w: *Web, id: u32, ok: u32, decoded_us: f64) void {
    w.s.onDecoded(id, ok != 0, us(decoded_us));
}

export fn ms_on_presented(w: *Web, id: u32, presented_us: f64) void {
    w.s.onPresented(id, us(presented_us), id);
}

/// Renders the next audio frame from the jitter buffer into `ms_audio_buf` (interleaved
/// f32, `ms_audio_channels` channels). Returns samples per channel; 0 before the stream
/// starts or with audio off. Call whenever the output holds less than a frame or two.
export fn ms_audio_render(w: *Web, now_us: f64) u32 {
    const a = if (w.audio) |*x| x else return 0;
    if (w.s.state != .streaming) return 0;
    const r = a.render(us(now_us), &w.pcm) catch return 0;
    return @intCast(r.samples);
}

export fn ms_audio_buf(w: *Web) [*]const f32 {
    return &w.pcm;
}

export fn ms_audio_channels(w: *Web) u32 {
    return w.channels;
}

export fn ms_overlay(w: *Web, now_us: f64) *const OverlayOut {
    const o = w.s.overlay(us(now_us));
    const snap = o.telemetry;
    w.overlay = .{
        .bitrate_bps = f(o.bitrate_bps),
        .pacing_bps = f(o.pacing_bps),
        .rtt_us = f(o.rtt_us),
        .loss = f(o.loss),
        .relayed = f(o.relayed),
        .freezes = f(o.freezes),
        .clock_synced = f(o.clock_synced),
        .frames = f(snap.counters.frames),
        .stages = undefined,
    };
    inline for (0..core.telemetry.Stage.count) |i| {
        const st: core.telemetry.Stage = @enumFromInt(i);
        const ss = snap.stage(st);
        const last = snap.last.get(st);
        w.overlay.stages[i] = .{
            f(ss.count),
            if (last) |l| f(l) else -1,
            if (ss.count > 0) f(ss.p50) else -1,
            if (ss.count > 0) f(ss.p99) else -1,
        };
    }
    return &w.overlay;
}

export fn ms_stats(w: *Web) *const StatsOut {
    const st = w.s.stats;
    var out: StatsOut = std.mem.zeroes(StatsOut);
    inline for (@typeInfo(client_session.Stats).@"struct".fields) |fl| {
        if (@hasField(StatsOut, fl.name)) @field(out, fl.name) = f(@field(st, fl.name));
    }
    out.recovery_requests = f(w.s.rec.stats.requests);
    out.freezes = f(w.s.freeze.stats.freezes);
    if (w.audio) |*a| {
        const bs = a.rx.stats;
        out.audio_decoded = f(bs.decoded);
        out.audio_fec = f(bs.fec);
        out.audio_rs_recovered = f(bs.rs_recovered);
        out.audio_concealed = f(bs.concealed);
        out.audio_late = f(bs.late);
        out.audio_silence = f(bs.silence);
        out.audio_delay_us = f(bs.delay_us);
    }
    out.rx_drops = f(w.pipe.recv_drops);
    w.stats = out;
    return &w.stats;
}

// --- input (web/src/input captures it on the page; client.ts forwards it here) --------

fn input(w: *Web, t: f64, what: api.InputEvent.What) void {
    w.s.onInput(.{ .time_us = us(t), .what = what });
}

/// USB HID usage.
export fn ms_input_key(w: *Web, code: u32, down: u32, t_us: f64) void {
    input(w, t_us, .{ .key = .{ .code = @truncate(code), .down = down != 0 } });
}

/// 1-based button.
export fn ms_input_button(w: *Web, code: u32, down: u32, t_us: f64) void {
    input(w, t_us, .{ .button = .{ .code = @truncate(code), .down = down != 0 } });
}

/// 120 per wheel notch.
export fn ms_input_scroll(w: *Web, dx: i32, dy: i32, t_us: f64) void {
    input(w, t_us, .{ .scroll = .{ .dx = dx, .dy = dy } });
}

export fn ms_input_move_rel(w: *Web, dx: i32, dy: i32, t_us: f64) void {
    input(w, t_us, .{ .move_rel = .{ .dx = dx, .dy = dy } });
}

/// 0..65535 across the streamed display.
export fn ms_input_move_abs(w: *Web, x: u32, y: u32, t_us: f64) void {
    input(w, t_us, .{ .move_abs = .{ .x = @truncate(x), .y = @truncate(y) } });
}

/// A pad's full state (`core.input.Gamepad`: XInput button bits, sticks up/right
/// positive, triggers 0..65535), or a disconnect when `connected` is 0.
export fn ms_input_pad(w: *Web, index: u32, connected: u32, buttons: u32, lx: i32, ly: i32, rx: i32, ry: i32, lt: i32, rt: i32, t_us: f64) void {
    if (index >= core.input.max_pads) return;
    const c = struct {
        fn f(v: i32, comptime T: type) T {
            return @intCast(std.math.clamp(v, std.math.minInt(T), std.math.maxInt(T)));
        }
    }.f;
    const state: ?core.input.Gamepad = if (connected == 0) null else .{
        .buttons = buttons,
        .lx = c(lx, i16),
        .ly = c(ly, i16),
        .rx = c(rx, i16),
        .ry = c(ry, i16),
        .lt = c(lt, u16),
        .rt = c(rt, u16),
    };
    input(w, t_us, .{ .pad = .{ .index = @intCast(index), .state = state } });
}

comptime {
    // web/src/core.ts reads these by offset.
    std.debug.assert(@sizeOf(FrameOut) == 40);
    std.debug.assert(@sizeOf(ConfigOut) == 32);
    std.debug.assert(@sizeOf(OverlayOut) == 8 * (8 + 4 * core.telemetry.Stage.count));
}
