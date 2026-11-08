//! `PacketPipe`: the core's view of the transport (design.md, Architecture, layer 3).
//!
//! The core is sans-I/O. It hands datagrams to a pipe, reads datagrams back,
//! tells the pipe how fast to pace, and reads path stats and drop counts. It never
//! learns whether the pipe is iroh, the simulated network or a UDP socket.
//!
//! Every call is non-blocking. Times are microseconds on the local monotonic
//! clock of the endpoint that owns the pipe; two endpoints' clocks are unrelated,
//! so only differences of one side's timestamps carry meaning.
const std = @import("std");

pub const SendError = error{
    /// The datagram is larger than `maxDatagramSize()`.
    TooLarge,
    /// The pipe is closed.
    Closed,
};

pub const RecvError = error{
    /// The buffer is smaller than the next datagram; the datagram stays queued.
    BufferTooSmall,
    /// The pipe is closed and fully drained.
    Closed,
};

pub const Received = struct {
    /// Bytes written into the caller's buffer.
    len: usize,
    /// When the datagram reached the receiving endpoint (before it waited for
    /// the application to read it), on the receiver's local clock.
    recv_us: i64,
};

/// Path stats and drop counters. Counters are cumulative since the pipe opened.
pub const PathStats = struct {
    /// Smoothed round-trip estimate of the selected path, 0 when unknown.
    rtt_us: i64 = 0,
    /// Pacing rate currently applied (bits/s), 0 = unpaced.
    pacing_bps: u64 = 0,
    /// Datagrams accepted by `send`.
    sent: u64 = 0,
    /// Datagrams handed to the application by `recv`.
    received: u64 = 0,
    /// Accepted datagrams that never left this endpoint (send-buffer evictions).
    send_drops: u64 = 0,
    /// Datagrams that arrived but were dropped before the application read
    /// them (receive-buffer overflow).
    recv_drops: u64 = 0,
    /// Bytes waiting in the send buffer right now.
    send_queue_bytes: u64 = 0,
    /// True when the selected path goes through a relay.
    relayed: bool = false,
};

/// A type-erased packet pipe. Implementations: `transport/sim.zig` (tests and
/// simulation) and the iroh shim binding.
pub const PacketPipe = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, data: []const u8) SendError!void,
        recv: *const fn (ptr: *anyopaque, buf: []u8) RecvError!?Received,
        setPacingRate: *const fn (ptr: *anyopaque, bps: u64) void,
        stats: *const fn (ptr: *anyopaque) PathStats,
        maxDatagramSize: *const fn (ptr: *anyopaque) usize,
    };

    /// Queue one unreliable datagram. It may still be dropped later; drops the
    /// pipe can see show up in `stats()`.
    pub fn send(self: PacketPipe, data: []const u8) SendError!void {
        return self.vtable.send(self.ptr, data);
    }

    /// Read the next datagram, or null when none is waiting.
    pub fn recv(self: PacketPipe, buf: []u8) RecvError!?Received {
        return self.vtable.recv(self.ptr, buf);
    }

    /// Pace sends at `bps` bits/s (the core's capacity estimate). 0 turns pacing off.
    pub fn setPacingRate(self: PacketPipe, bps: u64) void {
        self.vtable.setPacingRate(self.ptr, bps);
    }

    pub fn stats(self: PacketPipe) PathStats {
        return self.vtable.stats(self.ptr);
    }

    pub fn maxDatagramSize(self: PacketPipe) usize {
        return self.vtable.maxDatagramSize(self.ptr);
    }
};

test "PacketPipe dispatches through the vtable" {
    const Loop = struct {
        buf: [64]u8 = undefined,
        len: ?usize = null,
        rate: u64 = 0,

        fn send(p: *anyopaque, d: []const u8) SendError!void {
            const s: *@This() = @ptrCast(@alignCast(p));
            if (d.len > s.buf.len) return error.TooLarge;
            @memcpy(s.buf[0..d.len], d);
            s.len = d.len;
        }
        fn recv(p: *anyopaque, b: []u8) RecvError!?Received {
            const s: *@This() = @ptrCast(@alignCast(p));
            const n = s.len orelse return null;
            if (b.len < n) return error.BufferTooSmall;
            @memcpy(b[0..n], s.buf[0..n]);
            s.len = null;
            return .{ .len = n, .recv_us = 7 };
        }
        fn setRate(p: *anyopaque, bps: u64) void {
            const s: *@This() = @ptrCast(@alignCast(p));
            s.rate = bps;
        }
        fn stats(p: *anyopaque) PathStats {
            const s: *@This() = @ptrCast(@alignCast(p));
            return .{ .pacing_bps = s.rate };
        }
        fn max(_: *anyopaque) usize {
            return 64;
        }
        const vt = PacketPipe.VTable{ .send = send, .recv = recv, .setPacingRate = setRate, .stats = stats, .maxDatagramSize = max };
    };
    var l = Loop{};
    const pipe = PacketPipe{ .ptr = &l, .vtable = &Loop.vt };
    try pipe.send("hello");
    var out: [8]u8 = undefined;
    const r = (try pipe.recv(&out)).?;
    try std.testing.expectEqualStrings("hello", out[0..r.len]);
    try std.testing.expectEqual(@as(?Received, null), try pipe.recv(&out));
    pipe.setPacingRate(5_000_000);
    try std.testing.expectEqual(@as(u64, 5_000_000), pipe.stats().pacing_bps);
    try std.testing.expectError(error.TooLarge, pipe.send(&([_]u8{0} ** 65)));
}
