//! Standing queue delay from one-way delays.
//!
//! standing = (min OWD over the last `filter_us`) − (min OWD over
//! `base_window_us`). The short minimum filters Wi-Fi aggregation batching
//! and per-packet jitter; the long minimum is the propagation baseline plus
//! the clock offset, so the offset cancels.
const std = @import("std");
const PacketResult = @import("types.zig").PacketResult;

pub const OwdTracker = struct {
    base_window_us: i64 = 10_000_000,
    filter_us: i64 = 20_000,
    // The base window as 10 buckets of per-bucket minimum.
    bucket_min: [10]i64 = [_]i64{std.math.maxInt(i64)} ** 10,
    bucket_t: [10]i64 = [_]i64{-1} ** 10,
    // Recent (arrival, OWD) samples for the short filter.
    rt: [R]i64 = undefined,
    ro: [R]i64 = undefined,
    rn: usize = 0,
    rh: usize = 0,
    last_recv: i64 = 0,
    /// A baseline held by `freezeBase`: the base never rises above it.
    frozen: ?i64 = null,

    const R = 512;

    /// Keep the current baseline until `thawBase`, however long the window
    /// stays above it (a foreign flow's standing queue, S11b).
    pub fn freezeBase(self: *OwdTracker) void {
        self.frozen = self.baseOwd();
    }

    pub fn thawBase(self: *OwdTracker) void {
        self.frozen = null;
    }

    pub fn add(self: *OwdTracker, r: PacketResult) void {
        const owd = r.recv_us - r.send_us;
        self.last_recv = @max(self.last_recv, r.recv_us);
        const bw = @divTrunc(self.base_window_us, 10);
        const bi: usize = @intCast(@mod(@divTrunc(r.recv_us, bw), 10));
        const bstart = @divTrunc(r.recv_us, bw) * bw;
        if (self.bucket_t[bi] != bstart) {
            self.bucket_t[bi] = bstart;
            self.bucket_min[bi] = owd;
        } else self.bucket_min[bi] = @min(self.bucket_min[bi], owd);
        const i = (self.rh + self.rn) % R;
        if (self.rn == R) self.rh = (self.rh + 1) % R else self.rn += 1;
        self.rt[i] = r.recv_us;
        self.ro[i] = owd;
    }

    /// The 10 s minimum OWD (propagation plus clock offset), null before any sample.
    pub fn baseOwd(self: *const OwdTracker) ?i64 {
        var b: i64 = self.frozen orelse std.math.maxInt(i64);
        for (self.bucket_min) |m| b = @min(b, m);
        return if (b == std.math.maxInt(i64)) null else b;
    }

    /// Standing queue in microseconds, null before any sample.
    pub fn standing(self: *OwdTracker) ?f64 {
        while (self.rn > 0 and self.rt[self.rh] < self.last_recv - self.filter_us) {
            self.rh = (self.rh + 1) % R;
            self.rn -= 1;
        }
        if (self.rn == 0) return null;
        var mn: i64 = std.math.maxInt(i64);
        for (0..self.rn) |k| mn = @min(mn, self.ro[(self.rh + k) % R]);
        const base = self.baseOwd() orelse return null;
        return @floatFromInt(mn - base);
    }
};

fn pkt(send: i64, recv: i64) PacketResult {
    return .{ .seq = 0, .send_us = send, .recv_us = recv, .size = 1200, .frame = 0, .frame_last = false };
}

test "standing queue ignores the clock offset" {
    var o = OwdTracker{};
    const offset: i64 = 987_000_000;
    // 10 ms propagation, no queue.
    var t: i64 = 0;
    while (t < 1_000_000) : (t += 1000) o.add(pkt(t, t + 10_000 + offset));
    try std.testing.expectEqual(@as(?f64, 0), o.standing());
    // A 40 ms standing queue builds and stays.
    while (t < 1_200_000) : (t += 1000) o.add(pkt(t, t + 50_000 + offset));
    try std.testing.expectEqual(@as(?f64, 40_000), o.standing());
}

test "a frozen baseline outlasts the 10 s window" {
    var o = OwdTracker{};
    var t: i64 = 0;
    while (t < 1_000_000) : (t += 1000) o.add(pkt(t, t + 10_000));
    o.freezeBase();
    // 60 ms of foreign queue for 15 s: the window alone would forget the 10 ms base.
    while (t < 16_000_000) : (t += 1000) o.add(pkt(t, t + 70_000));
    try std.testing.expectEqual(@as(?f64, 60_000), o.standing());
    o.thawBase();
    try std.testing.expectEqual(@as(?f64, 0), o.standing());
}
