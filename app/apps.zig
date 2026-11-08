//! The host and client apps: a platform backend bundle, a session and a `PacketPipe`,
//! wired into the pipeline (docs/design.md, "Threading").
//!
//! Two ways to drive the same code:
//!   - `tick(now)` runs every stage once on the caller's thread with non-blocking calls.
//!     The in-process sim and the soak use it in virtual time, where nothing may block.
//!   - `runThreaded` gives the media stage (capture+encode, or decode+present) its own
//!     thread next to the network thread. One mutex guards the session; the slow backend
//!     calls run outside it.
//!
//! Audio rides the network stage: when the backend has an audio source (host) or sink
//! (client), the Opus stage (codec/opus/stage.zig) encodes 10 ms frames from the source
//! and sends them on the audio stream, and the client renders from its jitter buffer
//! into the sink, keeping about one frame queued. Both calls are non-blocking.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const pipe_mod = @import("pipe");
const HostSession = @import("host_session.zig").HostSession;
const ClientSession = @import("client_session.zig").ClientSession;
const host_session = @import("host_session.zig");
const client_session = @import("client_session.zig");
const audio_stage = @import("audio_stage");

const proto = core.proto;

const Io = std.Io;
const Micros = i64;

pub const HostOptions = struct {
    fps: u32 = 60,
    bitrate_bps: u64 = 10_000_000,
    slices: u8 = 4,
    codec: api.Codec = .passthrough,
    display: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Re-send the last picture when the screen has not changed for this long, so a
    /// static desktop keeps streaming (and a lost frame on it still gets repaired).
    repeat_after_us: Micros = 100_000,
    /// Stream the backend's audio source, if it has one.
    audio: bool = true,
    session: struct { peer_timeout_us: Micros = 5_000_000, pace: bool = true, rate_control: bool = false } = .{},
    /// Hold video while the path is stalled (host_session.Config.pause_on_stall).
    pause_on_stall: bool = true,
};

pub const HostApp = struct {
    be: api.HostBackend,
    s: HostSession,
    opts: HostOptions,
    size: api.Size,
    last_frame_us: ?Micros = null,
    audio: ?*HostAudio = null,
    stats: struct { capture_timeouts: u64 = 0, encode_errors: u64 = 0, inject_errors: u64 = 0 } = .{},

    pub fn init(gpa: std.mem.Allocator, be: api.HostBackend, o: HostOptions, p: pipe_mod.PacketPipe) !HostApp {
        const size = try be.capture.start(.{ .display = o.display, .fps = o.fps, .width = o.width, .height = o.height });
        errdefer be.capture.stop();
        const caps = be.encoder.caps();
        if (!caps.codecs.has(o.codec)) return error.Unsupported;
        const slices = @min(o.slices, caps.max_slices);
        try be.encoder.configure(.{ .codec = o.codec, .width = size.width, .height = size.height, .fps = o.fps, .bitrate_bps = o.bitrate_bps, .slices = slices, .ltr = caps.ltr });
        const s = try HostSession.init(gpa, .{
            .codec = o.codec,
            .width = size.width,
            .height = size.height,
            .fps = o.fps,
            .bitrate_bps = o.bitrate_bps,
            .slices = slices,
            .ltr = caps.ltr,
            .pace = o.session.pace,
            .rate_control = o.session.rate_control,
            .peer_timeout_us = o.session.peer_timeout_us,
            .pause_on_stall = o.pause_on_stall,
        }, p);
        var app: HostApp = .{ .be = be, .s = s, .opts = o, .size = size };
        errdefer app.s.deinit();
        if (o.audio) if (be.audio) |src| {
            app.audio = try HostAudio.init(gpa, src);
        };
        return app;
    }

    pub fn deinit(a: *HostApp) void {
        a.be.capture.stop();
        if (a.audio) |au| au.deinit();
        a.s.deinit();
    }

    /// Network stage: pipe, timers, input injection. Call with the session lock held.
    fn network(a: *HostApp, now: Micros) void {
        a.s.step(now);
        if (a.audio) |au| au.pump(&a.s, now);
        while (a.s.popAction()) |p| {
            if (a.be.input) |inj| inj.inject(p.action) catch {
                a.stats.inject_errors += 1;
            };
            a.s.onInjected(p.time, a.be.clock.now());
        }
    }

    fn grab(a: *HostApp, timeout_us: Micros) api.Error!?api.CapturedFrame {
        if (try a.be.capture.acquire(timeout_us)) |f| return f;
        a.stats.capture_timeouts += 1;
        const last = a.last_frame_us orelse return null;
        if (a.be.clock.now() - last < a.opts.repeat_after_us) return null;
        return a.be.capture.repeatLast();
    }

    /// One encode, given a captured frame: the lock is taken around the session calls only.
    fn encodeOne(a: *HostApp, f: *const api.CapturedFrame, lock: ?Lock) void {
        if (lock) |l| l.lock();
        const live = a.s.streaming();
        const params = if (live) a.s.encodeParams() else api.EncodeParams{};
        if (lock) |l| l.unlock();
        if (!live) return;
        const r = a.be.encoder.encode(f, params);
        if (lock) |l| l.lock();
        defer if (lock) |l| l.unlock();
        if (r) |ef_| {
            if (ef_) |ef| {
                a.s.onEncoded(ef, f, a.be.clock.now());
                a.last_frame_us = f.captured_us;
            } else a.s.onEncodeDropped();
        } else |_| {
            a.stats.encode_errors += 1;
            a.s.onEncodeDropped();
        }
    }

    /// Run every stage once, without blocking.
    pub fn tick(a: *HostApp) void {
        a.network(a.be.clock.now());
        if (!a.s.streaming()) return;
        const f = (a.grab(0) catch return) orelse return;
        defer a.be.capture.release(&f);
        a.encodeOne(&f, null);
    }

    pub fn nextWake(a: *const HostApp, now: Micros) Micros {
        return a.s.nextWake(now);
    }

    pub fn done(a: *const HostApp) bool {
        return a.s.ended();
    }

    /// Network thread here, capture+encode on its own thread, until the session ends.
    pub fn runThreaded(a: *HostApp, io: Io) !void {
        var mu: Io.Mutex = .init;
        const lock: Lock = .{ .mu = &mu, .io = io };
        var stop: std.atomic.Value(bool) = .init(false);
        var media = try io.concurrent(hostMedia, .{ a, lock, &stop });
        defer {
            stop.store(true, .release);
            media.await(io);
        }
        netLoop(HostApp, a, io, lock);
    }

    fn hostMedia(a: *HostApp, lock: Lock, stop: *std.atomic.Value(bool)) void {
        const interval = @divTrunc(1_000_000, @as(Micros, a.opts.fps));
        while (!stop.load(.acquire)) {
            lock.lock();
            const live = a.s.streaming();
            lock.unlock();
            if (!live) {
                lock.io.sleep(.fromMilliseconds(2), .awake) catch {};
                continue;
            }
            const f = (a.grab(interval) catch {
                lock.io.sleep(.fromMilliseconds(2), .awake) catch {};
                continue;
            }) orelse continue;
            a.encodeOne(&f, lock);
            a.be.capture.release(&f);
        }
    }
};

pub const ClientOptions = struct {
    mode: api.PresentMode = .lowest_latency,
    windowed: bool = true,
    session: client_session.Config = .{},
    /// Content identity for the freeze detector, from the presented frame. Default: frame id.
    content_ctx: ?*anyopaque = null,
    contentFn: ?*const fn (ctx: ?*anyopaque, f: *const api.DecodedFrame) u64 = null,
    overlay_interval_us: Micros = 100_000,
    /// Play the audio stream into the backend's sink, if it has one.
    audio: bool = true,
};

pub const ClientApp = struct {
    be: api.ClientBackend,
    s: ClientSession,
    opts: ClientOptions,
    configured: bool = false,
    quit: bool = false,
    overlay: api.Overlay = .{ .telemetry = .{} },
    next_overlay: Micros = 0,
    audio: ?*ClientAudio = null,
    stats: struct { decode_errors: u64 = 0, present_errors: u64 = 0 } = .{},

    pub fn init(gpa: std.mem.Allocator, be: api.ClientBackend, o: ClientOptions, p: pipe_mod.PacketPipe) !ClientApp {
        var cfg = o.session;
        cfg.codecs = be.decoder.caps().codecs;
        var au: ?*ClientAudio = null;
        if (o.audio) if (be.audio) |sink| {
            au = try ClientAudio.init(gpa, sink);
            cfg.audio_ctx = au;
            cfg.onAudio = ClientAudio.onAudio;
        };
        errdefer if (au) |x| x.deinit();
        return .{ .be = be, .s = try ClientSession.init(gpa, cfg, p), .opts = o, .audio = au };
    }

    pub fn deinit(a: *ClientApp) void {
        a.s.deinit();
        if (a.audio) |au| au.deinit();
    }

    fn network(a: *ClientApp, now: Micros) void {
        // Input is polled only while streaming: before the host's config there is no one
        // to send it to, and the source keeps (or drops) it by its own rules.
        if (a.be.input) |src| if (a.s.state == .streaming) {
            var evs: [64]api.InputEvent = undefined;
            const n = src.poll(&evs) catch 0;
            for (evs[0..n]) |e| {
                if (e.what == .quit) a.quit = true else a.s.onInput(e);
            }
        };
        if (a.quit) a.s.close(now);
        a.s.step(now);
        if (a.audio) |au| if (a.s.state == .streaming) au.render(a.be.clock.now());
    }

    /// Configure the decoder and presenter once the host's config is in.
    fn configure(a: *ClientApp) bool {
        if (a.configured) return true;
        const c = a.s.config orelse return false;
        a.be.decoder.configure(.{ .codec = c.codec, .width = c.width, .height = c.height }) catch {
            a.s.close(a.be.clock.now());
            return false;
        };
        a.be.presenter.configure(.{ .width = c.width, .height = c.height, .mode = a.opts.mode, .windowed = a.opts.windowed }) catch {
            a.s.close(a.be.clock.now());
            return false;
        };
        a.configured = true;
        return true;
    }

    /// Decode and present one frame. Returns false when there was none.
    fn mediaOne(a: *ClientApp, lock: ?Lock) bool {
        if (lock) |l| l.lock();
        const ok = a.configure();
        const au_ = if (ok) a.s.nextAccessUnit() else null;
        const now = a.be.clock.now();
        if (now >= a.next_overlay) {
            a.overlay = a.s.overlay(now);
            a.next_overlay = now + a.opts.overlay_interval_us;
        }
        const ov = a.overlay;
        if (lock) |l| l.unlock();
        const au = au_ orelse return false;
        const r = a.be.decoder.decode(&au);
        const decoded_at = a.be.clock.now();
        const df = r catch {
            a.stats.decode_errors += 1;
            if (lock) |l| l.lock();
            a.s.onDecoded(au.frame_id, false, decoded_at);
            if (lock) |l| l.unlock();
            return true;
        } orelse return true;
        defer a.be.decoder.release(&df);
        const pr = a.be.presenter.present(&df, &ov);
        const content = if (a.opts.contentFn) |f| f(a.opts.content_ctx, &df) else df.frame_id;
        if (lock) |l| l.lock();
        defer if (lock) |l| l.unlock();
        a.s.onDecoded(au.frame_id, true, df.decoded_us);
        if (pr) |p| a.s.onPresented(au.frame_id, p.presented_us, content) else |_| {
            a.stats.present_errors += 1;
        }
        return true;
    }

    pub fn tick(a: *ClientApp) void {
        a.network(a.be.clock.now());
        while (a.mediaOne(null)) {}
    }

    pub fn nextWake(a: *ClientApp, now: Micros) Micros {
        return a.s.nextWake(now);
    }

    pub fn done(a: *const ClientApp) bool {
        return a.s.ended();
    }

    pub fn runThreaded(a: *ClientApp, io: Io) !void {
        var mu: Io.Mutex = .init;
        const lock: Lock = .{ .mu = &mu, .io = io };
        var stop: std.atomic.Value(bool) = .init(false);
        var media = try io.concurrent(clientMedia, .{ a, lock, &stop });
        defer {
            stop.store(true, .release);
            media.await(io);
        }
        netLoop(ClientApp, a, io, lock);
    }

    fn clientMedia(a: *ClientApp, lock: Lock, stop: *std.atomic.Value(bool)) void {
        while (!stop.load(.acquire)) {
            if (!a.mediaOne(lock)) lock.io.sleep(.fromMicroseconds(500), .awake) catch {};
        }
    }
};

// ---------------------------------------------------------------------------
// Audio stage glue

/// The host's audio: 10 ms of PCM from the source at a time, through Opus and the audio
/// sender, onto the session's audio stream.
pub const HostAudio = struct {
    gpa: std.mem.Allocator,
    src: api.AudioSource,
    stage: audio_stage.HostAudio,
    channels: u8,
    out: audio_stage.HostAudio.Out = .{},
    pcm: [frame_samples * 2]f32 = undefined,
    fill: usize = 0,
    first_us: Micros = 0,
    stats: struct { frames: u64 = 0, datagrams: u64 = 0, errors: u64 = 0 } = .{},

    pub const frame_samples = 480;

    fn init(gpa: std.mem.Allocator, src: api.AudioSource) !*HostAudio {
        const fmt = try src.start(.{});
        errdefer src.stop();
        if (fmt.rate != api.audio_rate or fmt.channels == 0 or fmt.channels > 2) return error.Unsupported;
        const h = try gpa.create(HostAudio);
        errdefer gpa.destroy(h);
        h.* = .{ .gpa = gpa, .src = src, .channels = fmt.channels, .stage = try audio_stage.HostAudio.init(gpa, .{ .encoder = .{ .channels = fmt.channels }, .frame_samples = frame_samples }) };
        return h;
    }

    fn deinit(h: *HostAudio) void {
        h.src.stop();
        h.stage.deinit(h.gpa);
        h.gpa.destroy(h);
    }

    /// The session stamps the envelope seq when it sends, so the stage's is a placeholder.
    fn noSeq(_: void) u32 {
        return 0;
    }

    /// Read what the source has, encode every complete frame, send it while streaming.
    fn pump(h: *HostAudio, s: *HostSession, now: Micros) void {
        const want = @as(usize, frame_samples) * h.channels;
        while (true) {
            const c = h.src.read(h.pcm[h.fill..want], 0) catch {
                h.stats.errors += 1;
                return;
            };
            if (c.frames == 0) return;
            if (h.fill == 0) h.first_us = c.time_us;
            h.fill += c.frames * h.channels;
            if (h.fill < want) continue;
            h.fill = 0;
            if (!s.streaming()) continue;
            h.stage.encode(h.pcm[0..want], @intCast(@max(0, h.first_us)), {}, noSeq, &h.out) catch {
                h.stats.errors += 1;
                continue;
            };
            h.stats.frames += 1;
            for (0..h.out.n) |i| {
                const dg = h.out.datagram(i);
                var d = proto.wire.Decoder.init(dg);
                const env = proto.Envelope.decode(&d) catch unreachable;
                s.sendAudio(env.kind, dg[proto.Envelope.size..], now);
                h.stats.datagrams += 1;
            }
        }
    }
};

/// The client's audio: datagrams into the jitter buffer, and frames out of it into the
/// sink whenever the sink holds less than `low_water` frames.
pub const ClientAudio = struct {
    gpa: std.mem.Allocator,
    sink: api.AudioSink,
    stage: audio_stage.ClientAudio,
    channels: u8,
    /// One rendered frame (up to 60 ms stereo), and how much of it the sink has taken.
    buf: [2880 * 2]f32 = undefined,
    pending: []const f32 = &.{},
    stats: struct { rendered: u64 = 0, errors: u64 = 0 } = .{},

    pub const low_water = 480;

    fn init(gpa: std.mem.Allocator, sink: api.AudioSink) !*ClientAudio {
        const fmt = try sink.start(.{});
        errdefer sink.stop();
        if (fmt.rate != api.audio_rate or fmt.channels == 0 or fmt.channels > 2) return error.Unsupported;
        const c = try gpa.create(ClientAudio);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .sink = sink, .channels = fmt.channels, .stage = try audio_stage.ClientAudio.init(gpa, fmt.channels, .{}) };
        return c;
    }

    fn deinit(c: *ClientAudio) void {
        c.sink.stop();
        c.stage.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    fn onAudio(ctx: ?*anyopaque, env: proto.Envelope, payload: []const u8, recv_us: Micros) void {
        const c: *ClientAudio = @ptrCast(@alignCast(ctx.?));
        c.stage.onMessage(env, payload, recv_us);
    }

    fn render(c: *ClientAudio, now: Micros) void {
        while (true) {
            if (c.pending.len > 0) {
                const n = c.sink.write(c.pending) catch {
                    c.stats.errors += 1;
                    c.pending = &.{};
                    return;
                };
                c.pending = c.pending[n * c.channels ..];
                if (c.pending.len > 0) return;
            }
            if (c.sink.queued() >= low_water) return;
            const r = c.stage.render(now, &c.buf) catch {
                c.stats.errors += 1;
                return;
            };
            if (r.samples == 0) return;
            c.stats.rendered += 1;
            c.pending = c.buf[0 .. r.samples * c.channels];
        }
    }

    pub fn bufferStats(c: *const ClientAudio) @TypeOf(c.stage.rx.stats) {
        return c.stage.rx.stats;
    }
};

pub const Lock = struct {
    mu: *Io.Mutex,
    io: Io,

    pub fn lock(l: Lock) void {
        l.mu.lockUncancelable(l.io);
    }
    pub fn unlock(l: Lock) void {
        l.mu.unlock(l.io);
    }
};

/// The network thread: step the session, sleep until it next has work (at most 1 ms, since
/// datagrams can arrive any time and the pipes have no wakeup handle yet).
fn netLoop(comptime App: type, a: *App, io: Io, lock: Lock) void {
    while (true) {
        lock.lock();
        a.network(a.be.clock.now());
        const done = a.s.ended();
        const now = a.be.clock.now();
        const wait = a.s.nextWake(now) - now;
        lock.unlock();
        if (done) return;
        if (wait > 0) io.sleep(.fromMicroseconds(@min(wait, 1000)), .awake) catch {};
    }
}
