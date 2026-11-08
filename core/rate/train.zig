//! Bottleneck capacity from frame packet-train dispersion.
//!
//! When the pacer sends a frame faster than the bottleneck, the bottleneck
//! spreads it out to its own rate, so (bytes after the first packet) /
//! (last arrival − first arrival) measures link capacity. S11 read 1.00× on
//! wired links and 1.01–1.02× on simulated Wi-Fi from a 300 ms median. It
//! measures the link, not our share of it: use it for pacing and as a probe,
//! never as the target on its own.
const std = @import("std");
const PacketResult = @import("types.zig").PacketResult;

pub const TrainCap = struct {
    /// Frames with fewer packets give no sample (about 2.9 Mbit/s at 60 fps
    /// with 1200-byte packets).
    min_pkts: u32 = 4,
    /// Dispersions shorter than this are timer noise.
    min_disp_us: i64 = 200,

    cur_frame: u32 = std.math.maxInt(u32),
    first_arr: i64 = 0,
    last_arr: i64 = 0,
    bytes: u64 = 0,
    pkts: u32 = 0,
    lost: bool = false,
    // Recent samples: (arrival time, bps).
    st: [S]i64 = undefined,
    sv: [S]f64 = undefined,
    sn: usize = 0,
    sh: usize = 0,

    const S = 64;

    /// Feed results in send order.
    pub fn onResult(self: *TrainCap, r: PacketResult) void {
        if (r.frame != self.cur_frame) {
            self.cur_frame = r.frame;
            self.pkts = 0;
            self.bytes = 0;
            self.lost = false;
        }
        if (!r.received()) {
            self.lost = true;
            return;
        }
        if (self.pkts == 0) {
            self.first_arr = r.recv_us;
            self.last_arr = r.recv_us;
        } else {
            self.bytes += r.size; // the first packet's bytes are excluded
            self.first_arr = @min(self.first_arr, r.recv_us);
            self.last_arr = @max(self.last_arr, r.recv_us);
        }
        self.pkts += 1;
        if (r.frame_last and !self.lost and self.pkts >= self.min_pkts) {
            const disp = self.last_arr - self.first_arr;
            if (disp >= self.min_disp_us) {
                const v = @as(f64, @floatFromInt(self.bytes)) * 8e6 / @as(f64, @floatFromInt(disp));
                const i = (self.sh + self.sn) % S;
                if (self.sn == S) self.sh = (self.sh + 1) % S else self.sn += 1;
                self.st[i] = r.recv_us;
                self.sv[i] = v;
            }
        }
    }

    /// Median of the samples that arrived in the `window_us` before
    /// `now_recv_us` (client clock), or null if there are fewer than 5.
    pub fn estimate(self: *const TrainCap, now_recv_us: i64, window_us: i64) ?f64 {
        var buf: [S]f64 = undefined;
        var n: usize = 0;
        for (0..self.sn) |k| {
            const i = (self.sh + k) % S;
            if (self.st[i] >= now_recv_us - window_us) {
                buf[n] = self.sv[i];
                n += 1;
            }
        }
        if (n < 5) return null;
        std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
        return buf[n / 2];
    }
};

test "train estimate reads bottleneck rate" {
    var tc = TrainCap{};
    // 10 frames of 8 packets, serialized at 24 Mbit/s (1200 B every 400 us).
    var seq: u64 = 0;
    for (0..10) |f| {
        const base: i64 = @intCast(f * 16_667);
        for (0..8) |k| {
            const kk: i64 = @intCast(k);
            tc.onResult(.{ .seq = seq, .send_us = base + kk * 100, .recv_us = base + 5000 + kk * 400, .size = 1200, .frame = @intCast(f), .frame_last = k == 7 });
            seq += 1;
        }
    }
    const e = tc.estimate(10 * 16_667, 300_000).?;
    try std.testing.expectApproxEqRel(@as(f64, 24e6), e, 1e-9);
}

test "frames with a loss or too few packets give no sample" {
    var tc = TrainCap{};
    for (0..10) |f| {
        const base: i64 = @intCast(f * 16_667);
        for (0..3) |k| {
            const kk: i64 = @intCast(k);
            tc.onResult(.{ .seq = 0, .send_us = base, .recv_us = base + kk * 400, .size = 1200, .frame = @intCast(f), .frame_last = k == 2 });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), tc.sn);
}
