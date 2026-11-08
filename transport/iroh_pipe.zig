//! `PacketPipe` over iroh (the shim, transport/iroh.zig): `IrohPipe` over one connection,
//! and `IrohLink`, which replaces the connection when it drops.
//!
//! The shim does the work: `send` queues a QUIC datagram (iroh evicts the oldest
//! when its send buffer is full, counted in `send_drops`), `setPacingRate` sets
//! the AppRate target, and the shim's exact datagram counters fill `PathStats`.
//! The shim moves the target to whichever path iroh selects; `PathStats` reports the
//! selected path, a `path_epoch` that changes with it, and the no-ack-progress flag.
//!
//! The ABI gives no per-datagram arrival time, so `recv_us` is the shim clock
//! (`iroh.nowUs()`) at the moment the datagram is read. A caller that reads its
//! pipe promptly loses little; the core's feedback should use the same clock.
const std = @import("std");
const iroh = @import("iroh");
const pipe = @import("pipe");

const Io = std.Io;

pub const IrohPipe = struct {
    conn: iroh.Conn,
    pacing_bps: u64 = 0,
    closed: bool = false,

    pub fn init(conn: iroh.Conn) IrohPipe {
        return .{ .conn = conn };
    }

    pub fn packetPipe(self: *IrohPipe) pipe.PacketPipe {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn send(self: *IrohPipe, data: []const u8) pipe.SendError!void {
        if (self.closed) return error.Closed;
        if (data.len > self.conn.maxDatagramSize()) return error.TooLarge;
        self.conn.sendDatagram(data) catch |e| switch (e) {
            error.Closed => {
                self.closed = true;
                return error.Closed;
            },
            // The shim only refuses a datagram for its size (checked above) or a
            // closed connection; anything else reads as a local drop.
            else => {},
        };
    }

    pub fn recv(self: *IrohPipe, buf: []u8) pipe.RecvError!?pipe.Received {
        const d = self.conn.recvDatagram(buf, 0) catch |e| switch (e) {
            error.WouldBlock, error.Timeout => return null,
            error.BufferTooSmall => return error.BufferTooSmall,
            error.Closed => {
                self.closed = true;
                return error.Closed;
            },
            else => return null,
        };
        return .{ .len = d.len, .recv_us = @intCast(iroh.nowUs()) };
    }

    pub fn setPacingRate(self: *IrohPipe, bps: u64) void {
        self.conn.setTargetBitrate(bps) catch return;
        self.pacing_bps = bps;
    }

    pub fn stats(self: *IrohPipe) pipe.PathStats {
        // Path changes and stalls are read from the stats below, so the events are only
        // drained here to keep the shim's queue short (and to see a close).
        while (self.conn.pollEvent() catch null) |ev| {
            if (ev.kind() == .conn_closed) self.closed = true;
        }
        const s = self.conn.stats() catch return .{ .pacing_bps = self.pacing_bps };
        if (s.closed != 0) self.closed = true;
        var out: pipe.PathStats = .{
            .pacing_bps = s.target_bps,
            .sent = s.dgram_sent,
            .received = s.dgram_read,
            .send_drops = s.dgram_send_drops,
            .recv_drops = s.dgram_recv_drops_quic + s.dgram_recv_drops_shim,
            // The shim counts queued datagrams, not bytes; report a full-size estimate.
            .send_queue_bytes = s.dgram_send_queued * 1200,
            .path_id = s.selected_path,
            .path_epoch = s.path_selections,
            .connected = s.closed == 0,
        };
        var paths: [8]iroh.PathStats = undefined;
        const ps = self.conn.pathStats(&paths) catch return out;
        for (ps) |p| if (p.path_id == s.selected_path) {
            out.rtt_us = @intCast(p.rtt_us);
            out.relayed = p.is_relay != 0;
            out.stalled = p.no_ack_progress != 0;
        };
        return out;
    }

    pub fn maxDatagramSize(self: *IrohPipe) usize {
        return self.conn.maxDatagramSize();
    }

    fn vSend(ptr: *anyopaque, data: []const u8) pipe.SendError!void {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        return self.send(data);
    }
    fn vRecv(ptr: *anyopaque, buf: []u8) pipe.RecvError!?pipe.Received {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        return self.recv(buf);
    }
    fn vSetPacingRate(ptr: *anyopaque, bps: u64) void {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        self.setPacingRate(bps);
    }
    fn vStats(ptr: *anyopaque) pipe.PathStats {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        return self.stats();
    }
    fn vMax(ptr: *anyopaque) usize {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        return self.maxDatagramSize();
    }

    const vtable = pipe.PacketPipe.VTable{
        .send = vSend,
        .recv = vRecv,
        .setPacingRate = vSetPacingRate,
        .stats = vStats,
        .maxDatagramSize = vMax,
    };
};

/// A `PacketPipe` that survives a dropped connection.
///
/// The dialing side (the client) dials the ticket again, with backoff, when its connection
/// closes or when the session calls `reconnect` (nothing heard from the host for a while).
/// It keeps the old connection until the new one is up and switches only if the old one
/// stayed silent meanwhile, so a path that comes back by itself is not torn down.
///
/// The accepting side (the host) accepts in the background. A new connection replaces a
/// closed one at once; while the current one is open, the newcomer waits until it delivers
/// a datagram (the client sends on a new connection right away) and then replaces it. So
/// a stray dial never steals a working session. (Pairing will decide who may connect.)
///
/// Every call is non-blocking: dialing and accepting run on a worker task, which hands
/// connections over to the caller's thread. Connections are freed on the caller's thread.
/// `PathStats.conn_epoch` counts replacements, and the pacing rate carries over.
pub const IrohLink = struct {
    pub const Role = enum { dial, accept };

    pub const Options = struct {
        role: Role,
        /// dial: the host's ticket.
        ticket: [:0]const u8 = "",
        alpn: []const u8,
        connect_timeout_ms: u32 = 5_000,
        /// Backoff between failed dials: doubles from min to max.
        retry_min_ms: u32 = 250,
        retry_max_ms: u32 = 4_000,
    };

    pub const Stats = struct {
        dials: u64 = 0,
        dial_failures: u64 = 0,
        accepts: u64 = 0,
        /// Connections replaced (= `conn_epoch`).
        switches: u64 = 0,
        /// New connections closed unused: the old one came back first, or a newer one won.
        discarded: u64 = 0,
        /// Datagrams dropped while there was no connection.
        offline_drops: u64 = 0,
    };

    io: Io,
    ep: iroh.Endpoint,
    opts: Options,
    stats_: Stats = .{},

    // The caller's thread.
    cur: ?IrohPipe = null,
    /// accept: a newer connection, adopted once it delivers.
    cand: ?iroh.Conn = null,
    installed: u64 = 0,
    conn_epoch: u32 = 0,
    pacing_bps: u64 = 0,
    /// dial: a reconnect is under way.
    redialing: bool = false,
    /// dial: the current connection delivered after the reconnect request.
    heard_since_request: bool = false,
    /// Counters of retired connections, so `PathStats` stays cumulative.
    base: pipe.PathStats = .{},
    path_epoch_base: u32 = 0,

    // Shared with the worker.
    mu: Io.Mutex = .init,
    ready: ?iroh.Conn = null,
    want_dial: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    worker: ?Io.Future(void) = null,
    w_dials: std.atomic.Value(u64) = .init(0),
    w_failures: std.atomic.Value(u64) = .init(0),
    w_accepts: std.atomic.Value(u64) = .init(0),

    /// Starts the worker; a dialing link dials at once. `self` must not move afterwards.
    pub fn start(self: *IrohLink, io: Io, ep: iroh.Endpoint, opts: Options) !void {
        self.* = .{ .io = io, .ep = ep, .opts = opts, .want_dial = opts.role == .dial };
        self.worker = try io.concurrent(work, .{self});
    }

    /// Stops the worker (waits for a dial or accept in progress) and frees every connection.
    /// The endpoint stays the caller's.
    pub fn deinit(self: *IrohLink) void {
        self.stop.store(true, .release);
        if (self.worker) |*w| w.await(self.io);
        self.worker = null;
        if (self.ready) |c| c.deinit(0);
        if (self.cand) |c| c.deinit(0);
        if (self.cur) |p| p.conn.deinit(0);
        self.ready = null;
        self.cand = null;
        self.cur = null;
    }

    pub fn packetPipe(self: *IrohLink) pipe.PacketPipe {
        return .{ .ptr = self, .vtable = &link_vtable };
    }

    pub fn linkStats(self: *const IrohLink) Stats {
        var s = self.stats_;
        s.dials = self.w_dials.load(.monotonic);
        s.dial_failures = self.w_failures.load(.monotonic);
        s.accepts = self.w_accepts.load(.monotonic);
        return s;
    }

    /// The current connection, if any (for tests and diagnostics).
    pub fn conn(self: *const IrohLink) ?iroh.Conn {
        return if (self.cur) |p| p.conn else null;
    }

    fn lock(self: *IrohLink) void {
        self.mu.lockUncancelable(self.io);
    }
    fn unlock(self: *IrohLink) void {
        self.mu.unlock(self.io);
    }

    fn sleepMs(self: *IrohLink, ms: u32) void {
        // In short steps, so `deinit` does not wait out a long backoff.
        var left = ms;
        while (left > 0 and !self.stop.load(.acquire)) {
            const d = @min(left, 20);
            self.io.sleep(.fromMilliseconds(d), .awake) catch {};
            left -= d;
        }
    }

    fn handOver(self: *IrohLink, c: iroh.Conn) void {
        self.lock();
        const old = self.ready;
        self.ready = c;
        if (self.opts.role == .dial) self.want_dial = false;
        self.unlock();
        // Never handed to the caller, so never used: free it here.
        if (old) |o| o.deinit(0);
    }

    fn work(self: *IrohLink) void {
        var backoff = self.opts.retry_min_ms;
        while (!self.stop.load(.acquire)) switch (self.opts.role) {
            .dial => {
                self.lock();
                const want = self.want_dial;
                self.unlock();
                if (!want) {
                    self.sleepMs(10);
                    continue;
                }
                _ = self.w_dials.fetchAdd(1, .monotonic);
                const c = self.ep.connect(self.opts.ticket, self.opts.alpn, self.opts.connect_timeout_ms) catch {
                    _ = self.w_failures.fetchAdd(1, .monotonic);
                    self.sleepMs(backoff);
                    backoff = @min(backoff * 2, self.opts.retry_max_ms);
                    continue;
                };
                backoff = self.opts.retry_min_ms;
                self.handOver(c);
            },
            .accept => {
                const c = self.ep.accept(200) catch continue;
                _ = self.w_accepts.fetchAdd(1, .monotonic);
                self.handOver(c);
            },
        };
    }

    /// Fold the current connection's counters into `base` and free it.
    fn retire(self: *IrohLink) void {
        var p = self.cur orelse return;
        const s = p.stats();
        self.base.sent += s.sent;
        self.base.received += s.received;
        self.base.send_drops += s.send_drops + s.send_queue_bytes / 1200;
        self.base.recv_drops += s.recv_drops;
        self.path_epoch_base +%= s.path_epoch +% 1;
        p.conn.deinit(0);
        self.cur = null;
    }

    fn install(self: *IrohLink, c: iroh.Conn) void {
        self.retire();
        self.cur = IrohPipe.init(c);
        if (self.installed > 0) {
            self.conn_epoch +%= 1;
            self.stats_.switches += 1;
        }
        self.installed += 1;
        self.redialing = false;
        self.heard_since_request = false;
        if (self.pacing_bps > 0) self.cur.?.setPacingRate(self.pacing_bps);
    }

    fn curOpen(self: *const IrohLink) bool {
        return if (self.cur) |p| !p.closed else false;
    }

    /// Take a connection from the worker, if it has one.
    fn adopt(self: *IrohLink) void {
        self.lock();
        const got = self.ready;
        self.ready = null;
        self.unlock();
        const c = got orelse return;
        switch (self.opts.role) {
            .dial => {
                if (self.curOpen() and self.heard_since_request) {
                    // The old connection came back while we dialed: keep it.
                    c.deinit(0);
                    self.stats_.discarded += 1;
                    self.redialing = false;
                    return;
                }
                self.install(c);
            },
            .accept => {
                if (!self.curOpen()) return self.install(c);
                if (self.cand) |old| {
                    old.deinit(0);
                    self.stats_.discarded += 1;
                }
                self.cand = c;
            },
        }
    }

    fn requestDial(self: *IrohLink) void {
        if (self.opts.role != .dial or self.redialing) return;
        self.redialing = true;
        self.heard_since_request = false;
        self.lock();
        self.want_dial = true;
        self.unlock();
    }

    fn onClosed(self: *IrohLink) void {
        if (self.opts.role == .dial) self.requestDial();
    }

    fn send(ptr: *anyopaque, data: []const u8) pipe.SendError!void {
        const self: *IrohLink = @ptrCast(@alignCast(ptr));
        self.adopt();
        if (!self.curOpen()) {
            if (self.cur != null) self.onClosed();
            self.stats_.offline_drops += 1;
            return;
        }
        self.cur.?.send(data) catch |e| switch (e) {
            error.Closed => {
                self.onClosed();
                self.stats_.offline_drops += 1;
            },
            error.TooLarge => return error.TooLarge,
        };
    }

    fn recv(ptr: *anyopaque, buf: []u8) pipe.RecvError!?pipe.Received {
        const self: *IrohLink = @ptrCast(@alignCast(ptr));
        self.adopt();
        if (self.cand) |c| if (!self.curOpen()) {
            // The old connection is gone: no need to wait for the newcomer to speak.
            self.cand = null;
            self.install(c);
        };
        if (self.cand) |c| {
            var cp = IrohPipe.init(c);
            if (cp.recv(buf)) |r| {
                if (r) |got| {
                    // The client moved to this connection: follow it.
                    self.cand = null;
                    self.install(c);
                    return got;
                }
            } else |e| switch (e) {
                error.Closed => {
                    c.deinit(0);
                    self.cand = null;
                    self.stats_.discarded += 1;
                },
                error.BufferTooSmall => return error.BufferTooSmall,
            }
        }
        if (!self.curOpen()) {
            if (self.cur != null) self.onClosed();
            return null;
        }
        const r = self.cur.?.recv(buf) catch |e| switch (e) {
            error.Closed => {
                self.onClosed();
                return null;
            },
            error.BufferTooSmall => return error.BufferTooSmall,
        };
        if (r != null and self.redialing) self.heard_since_request = true;
        return r;
    }

    fn setPacingRate(ptr: *anyopaque, bps: u64) void {
        const self: *IrohLink = @ptrCast(@alignCast(ptr));
        self.pacing_bps = bps;
        if (self.cur) |*p| p.setPacingRate(bps);
    }

    fn stats(ptr: *anyopaque) pipe.PathStats {
        const self: *IrohLink = @ptrCast(@alignCast(ptr));
        self.adopt();
        var out: pipe.PathStats = .{ .pacing_bps = self.pacing_bps, .connected = false };
        if (self.cur) |*p| {
            out = p.stats();
            if (p.closed) self.onClosed();
        }
        out.sent += self.base.sent + self.stats_.offline_drops;
        out.received += self.base.received;
        out.send_drops += self.base.send_drops + self.stats_.offline_drops;
        out.recv_drops += self.base.recv_drops;
        out.path_epoch +%= self.path_epoch_base;
        out.conn_epoch = self.conn_epoch;
        out.connected = self.curOpen();
        return out;
    }

    fn maxDatagramSize(ptr: *anyopaque) usize {
        const self: *IrohLink = @ptrCast(@alignCast(ptr));
        if (self.cur) |*p| {
            const n = p.maxDatagramSize();
            if (n > 0) return n;
        }
        return 1200; // until connected: what iroh always allows
    }

    fn reconnect(ptr: *anyopaque) void {
        const self: *IrohLink = @ptrCast(@alignCast(ptr));
        self.requestDial();
    }

    const link_vtable = pipe.PacketPipe.VTable{
        .send = send,
        .recv = recv,
        .setPacingRate = setPacingRate,
        .stats = stats,
        .maxDatagramSize = maxDatagramSize,
        .reconnect = reconnect,
    };
};
