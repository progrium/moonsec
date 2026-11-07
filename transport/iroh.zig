//! Zig binding for the moonsec iroh shim (shim/include/iroh_shim.h).
//! Thin, allocation-free wrapper: Zig owns every buffer passed to the shim.
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

pub fn version() u32 {
    return c.iroh_shim_version();
}

pub const RelayMode = enum(u32) {
    default = c.IROH_RELAY_DEFAULT,
    disabled = c.IROH_RELAY_DISABLED,
    custom = c.IROH_RELAY_CUSTOM,
};

pub const BindOptions = struct {
    secret_key: ?*const [32]u8 = null,
    alpn: []const u8 = "",
    relay_mode: RelayMode = .default,
    relay_urls: ?[*:0]const u8 = null,
    bind_addr: ?[*:0]const u8 = null,
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
};
