//! The host and client apps: a platform backend bundle, a session and a `PacketPipe`,
//! wired into the pipeline (docs/design.md, "Threading").
//!
//! Two ways to drive the same code:
//!   - `tick(now)` runs every stage once on the caller's thread with non-blocking calls.
//!     The in-process sim and the soak use it in virtual time, where nothing may block.
//!   - `runThreaded` gives the media stage (capture+encode, or decode+present) its own
//!     thread next to the network thread. One mutex guards the session; the slow backend
//!     calls run outside it.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const pipe_mod = @import("pipe");
const HostSession = @import("host_session.zig").HostSession;
const ClientSession = @import("client_session.zig").ClientSession;
const host_session = @import("host_session.zig");
const client_session = @import("client_session.zig");

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
    session: struct { peer_timeout_us: Micros = 5_000_000, pace: bool = true } = .{},
};

pub const HostApp = struct {
    be: api.HostBackend,
    s: HostSession,
    opts: HostOptions,
    size: api.Size,
    last_frame_us: ?Micros = null,
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
            .peer_timeout_us = o.session.peer_timeout_us,
        }, p);
        return .{ .be = be, .s = s, .opts = o, .size = size };
    }

    pub fn deinit(a: *HostApp) void {
        a.be.capture.stop();
        a.s.deinit();
    }

    /// Network stage: pipe, timers, input injection. Call with the session lock held.
    fn network(a: *HostApp, now: Micros) void {
        a.s.step(now);
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
};

pub const ClientApp = struct {
    be: api.ClientBackend,
    s: ClientSession,
    opts: ClientOptions,
    configured: bool = false,
    quit: bool = false,
    overlay: api.Overlay = .{ .telemetry = .{} },
    next_overlay: Micros = 0,
    stats: struct { decode_errors: u64 = 0, present_errors: u64 = 0 } = .{},

    pub fn init(gpa: std.mem.Allocator, be: api.ClientBackend, o: ClientOptions, p: pipe_mod.PacketPipe) !ClientApp {
        var cfg = o.session;
        cfg.codecs = be.decoder.caps().codecs;
        return .{ .be = be, .s = try ClientSession.init(gpa, cfg, p), .opts = o };
    }

    pub fn deinit(a: *ClientApp) void {
        a.s.deinit();
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
