//! Acknowledged (received) bitrate over a sliding window of arrival time.
const std = @import("std");

pub const AckedRate = struct {
    /// Enough for 500 ms at 400 Mbit/s of 1200-byte packets; older entries
    /// are dropped first if the window ever holds more.
    const N = 32768;

    t: [N]i64 = undefined,
    sz: [N]u32 = undefined,
    head: usize = 0,
    len: usize = 0,
    bytes: u64 = 0,
    window_us: i64 = 500_000,
    first_us: i64 = -1,

    pub fn add(self: *AckedRate, recv_us: i64, size: u32) void {
        if (self.first_us < 0) self.first_us = recv_us;
        if (self.len == N) self.popFront();
        const i = (self.head + self.len) % N;
        self.t[i] = recv_us;
        self.sz[i] = size;
        self.len += 1;
        self.bytes += size;
        while (self.len > 0 and self.t[self.head] < recv_us - self.window_us) self.popFront();
    }

    fn popFront(self: *AckedRate) void {
        self.bytes -= self.sz[self.head];
        self.head = (self.head + 1) % N;
        self.len -= 1;
    }

    /// Bits per second, or null until 100 ms of arrivals have been seen.
    /// `now_recv_us` is on the client clock (the newest arrival time).
    pub fn rate(self: *const AckedRate, now_recv_us: i64) ?f64 {
        if (self.first_us < 0) return null;
        const span = @min(self.window_us, now_recv_us - self.first_us);
        if (span < 100_000) return null;
        return @as(f64, @floatFromInt(self.bytes)) * 8.0 * 1e6 / @as(f64, @floatFromInt(span));
    }
};

test "acked rate reads a constant stream" {
    var a = AckedRate{};
    var t: i64 = 0;
    while (t < 1_000_000) : (t += 1000) a.add(t, 1250); // 1250 B/ms = 10 Mbit/s
    const r = a.rate(t - 1000).?;
    try std.testing.expect(@abs(r - 10e6) < 0.1e6);
}

test "acked rate needs 100 ms of history" {
    var a = AckedRate{};
    a.add(0, 1200);
    a.add(50_000, 1200);
    try std.testing.expectEqual(@as(?f64, null), a.rate(50_000));
}
