//! Zig binding for the moonsec iroh shim (shim/include/iroh_shim.h, ABI v0.1).
//! Thin, allocation-free wrapper: Zig owns every buffer passed to the shim.
//! Tests: transport/iroh_test.zig (loopback) and transport/iroh_netns_test.zig (Linux netns).
const std = @import("std");
pub const c = @import("iroh_shim_c");

pub const Error = error{
    WouldBlock,
    Closed,
    Invalid,
    Timeout,
    BufferTooSmall,
    Internal,
    Unknown,
};

fn check(rc: i32) Error!void {
    return switch (rc) {
        c.IROH_OK => {},
        c.IROH_ERR_AGAIN => error.WouldBlock,
        c.IROH_ERR_CLOSED => error.Closed,
        c.IROH_ERR_INVALID => error.Invalid,
        c.IROH_ERR_TIMEOUT => error.Timeout,
        c.IROH_ERR_TOO_SMALL => error.BufferTooSmall,
        c.IROH_ERR_INTERNAL => error.Internal,
        else => error.Unknown,
    };
}

/// Message for the most recent failed shim call on this thread.
pub fn lastError() []const u8 {
    return std.mem.span(c.iroh_last_error());
}

fn cstr(buf: []u8) [:0]const u8 {
    const n = std.mem.indexOfScalar(u8, buf, 0).?;
    return buf[0..n :0];
}

/// Optional; call before anything else. `hook(ctx)` runs on the shim's single runtime
/// thread at startup so the host can pin it and raise its priority.
pub fn init(hook: ?*const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) Error!void {
    try check(c.iroh_shim_init(hook, ctx));
}

pub fn version() u32 {
    return c.iroh_shim_version();
}

/// Microseconds on the shim's monotonic clock (the clock `Event.t_us` uses).
pub fn nowUs() u64 {
    return c.iroh_shim_now_us();
}

pub const path_none: u32 = c.IROH_PATH_NONE;

pub const RelayMode = enum(u32) {
    default = c.IROH_RELAY_DEFAULT,
    disabled = c.IROH_RELAY_DISABLED,
    custom = c.IROH_RELAY_CUSTOM,
    /// Custom relays without n0 discovery (dial by ticket).
    custom_only = c.IROH_RELAY_CUSTOM_ONLY,
};

/// Endpoint options. Numeric fields left at 0 take the shim's defaults (see iroh_shim.h).
pub const BindOptions = struct {
    secret_key: ?*const [32]u8 = null,
    alpn: []const u8 = "",
    relay_mode: RelayMode = .default,
    relay_urls: ?[*:0]const u8 = null,
    bind_addr: ?[*:0]const u8 = null,
    /// QUIC datagram send buffer, bytes (default 1 MiB). Must hold the largest frame.
    datagram_send_buffer: usize = 0,
    /// QUIC datagram receive buffer, bytes (default 2 MiB).
    datagram_recv_buffer: usize = 0,
    /// Datagrams the shim queues for the caller (default 4096).
    recv_queue_len: u32 = 0,
    /// Per-path idle timeout (default 300 ms) and keep-alive (default 100 ms).
    path_idle_timeout_ms: u32 = 0,
    path_keepalive_ms: u32 = 0,
    /// Connection idle timeout (default: iroh's).
    conn_idle_timeout_ms: u32 = 0,
    /// Pacing target for new connections, bits/s (0 = unpaced until `Conn.setTargetBitrate`).
    initial_target_bps: u64 = 0,
    /// AppRate burst credit, us (null = default 20 ms, 0 = none).
    burst_us: ?u32 = null,
    /// Selected-path stall that raises `.no_ack_progress`, ms (null = default 150, 0 = off).
    no_ack_progress_ms: ?u32 = null,
};

pub const Endpoint = struct {
    handle: *c.IrohEndpoint,

    pub fn bind(opts: BindOptions) Error!Endpoint {
        const raw: c.IrohBindOpts = .{
            .secret_key = if (opts.secret_key) |k| k else null,
            .alpn = opts.alpn.ptr,
            .alpn_len = opts.alpn.len,
            .relay_mode = @intFromEnum(opts.relay_mode),
            .relay_urls = opts.relay_urls,
            .bind_addr = opts.bind_addr,
            .datagram_send_buffer = opts.datagram_send_buffer,
            .datagram_recv_buffer = opts.datagram_recv_buffer,
            .recv_queue_len = opts.recv_queue_len,
            .path_idle_timeout_ms = opts.path_idle_timeout_ms,
            .path_keepalive_ms = opts.path_keepalive_ms,
            .conn_idle_timeout_ms = opts.conn_idle_timeout_ms,
            .initial_target_bps = opts.initial_target_bps,
            .burst_us = if (opts.burst_us) |v| (if (v == 0) c.IROH_BURST_OFF else v) else 0,
            .no_ack_progress_ms = if (opts.no_ack_progress_ms) |v| (if (v == 0) c.IROH_NO_ACK_OFF else v) else 0,
        };
        var out: ?*c.IrohEndpoint = null;
        try check(c.iroh_endpoint_bind(&raw, &out));
        return .{ .handle = out.? };
    }

    pub fn deinit(self: Endpoint) void {
        c.iroh_endpoint_free(self.handle);
    }

    /// Wait until the endpoint has registered with its home relay.
    pub fn online(self: Endpoint, timeout_ms: u32) Error!void {
        try check(c.iroh_endpoint_online(self.handle, timeout_ms));
    }

    /// Writes the endpoint ID into `buf` and returns it as a slice.
    pub fn id(self: Endpoint, buf: []u8) Error![:0]const u8 {
        try check(c.iroh_endpoint_id(self.handle, buf.ptr, buf.len));
        return cstr(buf);
    }

    /// Writes a dialable ticket into `buf` and returns it as a slice.
    pub fn ticket(self: Endpoint, buf: []u8) Error![:0]const u8 {
        var len: usize = 0;
        try check(c.iroh_endpoint_ticket(self.handle, buf.ptr, buf.len, &len));
        return buf[0..len :0];
    }

    pub fn connect(self: Endpoint, ticket_str: [*:0]const u8, alpn: []const u8, timeout_ms: u32) Error!Conn {
        var out: ?*c.IrohConn = null;
        try check(c.iroh_endpoint_connect(self.handle, ticket_str, alpn.ptr, alpn.len, timeout_ms, &out));
        return .{ .handle = out.? };
    }

    pub fn accept(self: Endpoint, timeout_ms: u32) Error!Conn {
        var out: ?*c.IrohConn = null;
        try check(c.iroh_endpoint_accept(self.handle, timeout_ms, &out));
        return .{ .handle = out.? };
    }
};

pub const EventKind = enum(u32) {
    path_opened = c.IROH_EV_PATH_OPENED,
    path_selected = c.IROH_EV_PATH_SELECTED,
    path_closed = c.IROH_EV_PATH_CLOSED,
    lagged = c.IROH_EV_LAGGED,
    no_ack_progress = c.IROH_EV_NO_ACK_PROGRESS,
    ack_resumed = c.IROH_EV_ACK_RESUMED,
    conn_closed = c.IROH_EV_CONN_CLOSED,
    _,
};

pub const Event = struct {
    raw: c.IrohEvent,

    pub fn kind(self: *const Event) EventKind {
        return @enumFromInt(self.raw.kind);
    }
    pub fn pathId(self: *const Event) u32 {
        return self.raw.path_id;
    }
    pub fn isRelay(self: *const Event) bool {
        return self.raw.is_relay != 0;
    }
    pub fn remoteAddr(self: *const Event) []const u8 {
        const p: [*:0]const u8 = @ptrCast(&self.raw.remote_addr);
        return std.mem.span(p);
    }
};

/// Exact datagram accounting; see iroh_shim.h.
pub const ConnStats = c.IrohConnStats;
pub const PathStats = c.IrohPathStats;

/// `PathStats.remote_addr` as a slice.
pub fn pathRemoteAddr(p: *const PathStats) []const u8 {
    const z: [*:0]const u8 = @ptrCast(&p.remote_addr);
    return std.mem.span(z);
}

pub const Conn = struct {
    handle: *c.IrohConn,

    pub fn deinit(self: Conn, error_code: u32) void {
        c.iroh_conn_free(self.handle, error_code);
    }

    pub fn sendDatagram(self: Conn, data: []const u8) Error!void {
        try check(c.iroh_conn_send_datagram(self.handle, data.ptr, data.len));
    }

    /// Receives one datagram into `buf`. `timeout_ms == 0` is non-blocking (error.WouldBlock).
    pub fn recvDatagram(self: Conn, buf: []u8, timeout_ms: u32) Error![]u8 {
        var len: usize = 0;
        try check(c.iroh_conn_recv_datagram(self.handle, buf.ptr, buf.len, timeout_ms, &len));
        return buf[0..len];
    }

    pub fn maxDatagramSize(self: Conn) usize {
        return c.iroh_conn_max_datagram_size(self.handle);
    }

    pub fn localDrops(self: Conn) u64 {
        return c.iroh_conn_local_drops(self.handle);
    }

    pub fn remoteId(self: Conn, buf: []u8) Error![:0]const u8 {
        try check(c.iroh_conn_remote_id(self.handle, buf.ptr, buf.len));
        return cstr(buf);
    }

    /// Pacing target for the selected path, bits/s (the core's capacity estimate; 0 = unpaced).
    pub fn setTargetBitrate(self: Conn, bps: u64) Error!void {
        try check(c.iroh_conn_set_target_bitrate(self.handle, bps));
    }

    /// AppRate burst credit in us of the target rate (0 = none).
    pub fn setBurst(self: Conn, burst_us: u32) Error!void {
        try check(c.iroh_conn_set_burst(self.handle, burst_us));
    }

    /// Pollable handle (fd on Unix, SOCKET on Windows) that turns readable when a datagram or
    /// event arrives or the connection closes. Call `clearWakeup` before draining.
    pub fn wakeupHandle(self: Conn) i64 {
        return c.iroh_conn_wakeup_handle(self.handle);
    }

    pub fn clearWakeup(self: Conn) void {
        c.iroh_conn_wakeup_clear(self.handle);
    }

    /// Next path event or signal, or null if none is pending.
    pub fn pollEvent(self: Conn) Error!?Event {
        var ev: Event = .{ .raw = undefined };
        check(c.iroh_conn_poll_event(self.handle, &ev.raw)) catch |e| switch (e) {
            error.WouldBlock => return null,
            else => return e,
        };
        return ev;
    }

    pub fn stats(self: Conn) Error!ConnStats {
        var s: ConnStats = undefined;
        try check(c.iroh_conn_stats(self.handle, &s));
        return s;
    }

    /// Fills `buf` with per-path stats; returns the filled prefix (at most `buf.len` paths).
    pub fn pathStats(self: Conn, buf: []PathStats) Error![]PathStats {
        var n: usize = 0;
        try check(c.iroh_conn_path_stats(self.handle, buf.ptr, buf.len, &n));
        return buf[0..@min(n, buf.len)];
    }

    /// Opens a bidirectional stream (the peer sees it after the first write).
    pub fn openBi(self: Conn, timeout_ms: u32) Error!Stream {
        var out: ?*c.IrohStream = null;
        try check(c.iroh_conn_open_bi(self.handle, timeout_ms, &out));
        return .{ .handle = out.? };
    }

    /// Accepts a peer-opened bidirectional stream; `timeout_ms == 0` polls (error.WouldBlock).
    pub fn acceptBi(self: Conn, timeout_ms: u32) Error!Stream {
        var out: ?*c.IrohStream = null;
        try check(c.iroh_conn_accept_bi(self.handle, timeout_ms, &out));
        return .{ .handle = out.? };
    }
};

pub const Stream = struct {
    handle: *c.IrohStream,

    /// A nonzero `error_code` resets the stream; 0 lets an unfinished send side finish.
    pub fn deinit(self: Stream, error_code: u32) void {
        c.iroh_stream_free(self.handle, error_code);
    }

    pub fn writeAll(self: Stream, data: []const u8, timeout_ms: u32) Error!void {
        try check(c.iroh_stream_write(self.handle, data.ptr, data.len, timeout_ms));
    }

    /// Reads into `buf`; an empty slice means the peer finished the stream.
    /// `timeout_ms == 0` polls (error.WouldBlock).
    pub fn read(self: Stream, buf: []u8, timeout_ms: u32) Error![]u8 {
        var n: usize = 0;
        try check(c.iroh_stream_read(self.handle, buf.ptr, buf.len, timeout_ms, &n));
        return buf[0..n];
    }

    pub fn finish(self: Stream) Error!void {
        try check(c.iroh_stream_finish(self.handle));
    }
};
