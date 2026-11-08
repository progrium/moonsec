//! `PacketPipe` over an iroh connection (the shim, transport/iroh.zig).
//!
//! The shim does the work: `send` queues a QUIC datagram (iroh evicts the oldest
//! when its send buffer is full, counted in `send_drops`), `setPacingRate` sets
//! the AppRate target, and the shim's exact datagram counters fill `PathStats`.
//!
//! The ABI gives no per-datagram arrival time, so `recv_us` is the shim clock
//! (`iroh.nowUs()`) at the moment the datagram is read. A caller that reads its
//! pipe promptly loses little; the core's feedback should use the same clock.
const std = @import("std");
const iroh = @import("iroh");
const pipe = @import("pipe");

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

    fn send(ptr: *anyopaque, data: []const u8) pipe.SendError!void {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
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

    fn recv(ptr: *anyopaque, buf: []u8) pipe.RecvError!?pipe.Received {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
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

    fn setPacingRate(ptr: *anyopaque, bps: u64) void {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        self.conn.setTargetBitrate(bps) catch return;
        self.pacing_bps = bps;
    }

    fn stats(ptr: *anyopaque) pipe.PathStats {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        const s = self.conn.stats() catch return .{ .pacing_bps = self.pacing_bps };
        var out: pipe.PathStats = .{
            .pacing_bps = s.target_bps,
            .sent = s.dgram_sent,
            .received = s.dgram_read,
            .send_drops = s.dgram_send_drops,
            .recv_drops = s.dgram_recv_drops_quic + s.dgram_recv_drops_shim,
            // The shim counts queued datagrams, not bytes; report a full-size estimate.
            .send_queue_bytes = s.dgram_send_queued * 1200,
        };
        var paths: [8]iroh.PathStats = undefined;
        const ps = self.conn.pathStats(&paths) catch return out;
        for (ps) |p| if (p.is_selected != 0) {
            out.rtt_us = @intCast(p.rtt_us);
            out.relayed = p.is_relay != 0;
        };
        return out;
    }

    fn maxDatagramSize(ptr: *anyopaque) usize {
        const self: *IrohPipe = @ptrCast(@alignCast(ptr));
        return self.conn.maxDatagramSize();
    }

    const vtable = pipe.PacketPipe.VTable{
        .send = send,
        .recv = recv,
        .setPacingRate = setPacingRate,
        .stats = stats,
        .maxDatagramSize = maxDatagramSize,
    };
};
