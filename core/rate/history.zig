//! The sender's record of media packets, joined with the client's arrival
//! reports to make `PacketResult`s.
//!
//! Transport-wide feedback only carries sequence numbers and arrival times;
//! the send time, size and frame membership stay on the host.
const std = @import("std");
const PacketResult = @import("types.zig").PacketResult;

/// One per-packet entry of a feedback message.
pub const Arrival = struct {
    seq: u64,
    /// Client clock, or `PacketResult.lost`.
    recv_us: i64,
};

pub const SendHistory = struct {
    /// Ring size: about 2 s at 400 Mbit/s of 1200-byte packets. Feedback
    /// older than that is ignored.
    pub const N = 1 << 16;

    const Entry = struct {
        seq: u64 = std.math.maxInt(u64),
        send_us: i64 = 0,
        size: u32 = 0,
        frame: u32 = 0,
        frame_last: bool = false,
    };

    ring: [N]Entry = [_]Entry{.{}} ** N,
    /// Lowest sequence number not yet reported. Feedback below it is a
    /// duplicate and is skipped.
    next_expected: u64 = 0,
    started: bool = false,

    pub fn onSent(self: *SendHistory, seq: u64, send_us: i64, size: u32, frame: u32, frame_last: bool) void {
        if (!self.started) {
            self.started = true;
            self.next_expected = seq;
        }
        self.ring[seq % N] = .{ .seq = seq, .send_us = send_us, .size = size, .frame = frame, .frame_last = frame_last };
    }

    fn result(self: *const SendHistory, seq: u64, recv_us: i64) ?PacketResult {
        const e = self.ring[seq % N];
        if (e.seq != seq) return null;
        return .{ .seq = seq, .send_us = e.send_us, .recv_us = recv_us, .size = e.size, .frame = e.frame, .frame_last = e.frame_last };
    }

    /// Join a feedback batch (sorted by `seq`) with the send records. Every
    /// sequence number from the last one reported up to the batch's highest
    /// that the batch does not mention is reported lost, so `out` comes back
    /// in send order with no gaps. Returns the filled prefix of `out`; a
    /// batch that would overflow `out` is cut short and the rest is reported
    /// by the next call.
    pub fn join(self: *SendHistory, batch: []const Arrival, out: []PacketResult) []PacketResult {
        var n: usize = 0;
        var bi: usize = 0;
        while (bi < batch.len and batch[bi].seq < self.next_expected) bi += 1;
        if (bi == batch.len) return out[0..0];
        const max_seq = batch[batch.len - 1].seq;
        // Feedback older than the ring holds can't be joined.
        if (max_seq >= N and self.next_expected < max_seq - N + 1) self.next_expected = max_seq - N + 1;
        var s = self.next_expected;
        while (s <= max_seq and n < out.len) : (s += 1) {
            var recv: i64 = PacketResult.lost;
            while (bi < batch.len and batch[bi].seq < s) bi += 1;
            if (bi < batch.len and batch[bi].seq == s) {
                recv = batch[bi].recv_us;
                bi += 1;
            }
            if (self.result(s, recv)) |r| {
                out[n] = r;
                n += 1;
            }
        }
        self.next_expected = s;
        return out[0..n];
    }
};

test "join fills gaps as lost" {
    const h = try std.testing.allocator.create(SendHistory);
    defer std.testing.allocator.destroy(h);
    h.* = .{};
    for (0..6) |i| h.onSent(100 + i, @intCast(i * 10), 1200, 7, i == 5);
    var out: [16]PacketResult = undefined;
    const got = h.join(&.{ .{ .seq = 100, .recv_us = 5 }, .{ .seq = 102, .recv_us = 25 } }, &out);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expect(got[0].received());
    try std.testing.expect(!got[1].received());
    try std.testing.expectEqual(@as(i64, 20), got[2].send_us);
    // A late duplicate of 101 is ignored; 103 is lost, 104 and 105 arrive.
    const got2 = h.join(&.{ .{ .seq = 101, .recv_us = 15 }, .{ .seq = 104, .recv_us = 45 }, .{ .seq = 105, .recv_us = 55 } }, &out);
    try std.testing.expectEqual(@as(usize, 3), got2.len);
    try std.testing.expectEqual(@as(u64, 103), got2[0].seq);
    try std.testing.expect(!got2[0].received());
    try std.testing.expect(got2[2].frame_last);
}
