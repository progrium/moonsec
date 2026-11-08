//! Bottleneck capacity from frame packet-train dispersion.
//!
//! When the pacer sends a frame faster than the bottleneck, the bottleneck
//! spreads it out to its own rate, so (bytes after the first packet) /
//! (last arrival − first arrival) measures link capacity. S11 read 1.00× on
//! wired links and 1.01–1.02× on simulated Wi-Fi from a 300 ms median. It
//! measures the link, not our share of it: use it for pacing and as a probe,
//! never as the target on its own.
//!
//! Probe frames (S11b): when pacing follows the estimate, a frame can't
//! leave faster than the estimate, so under fair queueing the train reads
//! our share and never sees the link free up. The controller paces one frame
//! now and then at 2x the estimate and marks it with `markProbe`. Probe
//! samples are kept apart from the median: the two newest, if recent, give a
//! second reading (the lower of the two), and the estimate is the higher of
//! that and the median.
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
    // Probe frames still in flight, and the two newest probe samples.
    probe_ids: [4]u32 = [_]u32{std.math.maxInt(u32)} ** 4,
    probe_next: usize = 0,
    cur_probe: bool = false,
    probe_t: [2]i64 = .{ std.math.minInt(i64), std.math.minInt(i64) },
    probe_v: [2]f64 = .{ 0, 0 },
    probe_samples: u32 = 0,

    const S = 64;

    /// The frame `frame` is paced fast as a probe.
    pub fn markProbe(self: *TrainCap, frame: u32) void {
        self.probe_ids[self.probe_next] = frame;
        self.probe_next = (self.probe_next + 1) % self.probe_ids.len;
    }

    /// Forget the probe readings: the path got worse (the controller cut), and
    /// probes from before would hold the estimate at the old capacity.
    pub fn clearProbes(self: *TrainCap) void {
        self.probe_t = .{ std.math.minInt(i64), std.math.minInt(i64) };
    }

    fn isProbe(self: *const TrainCap, frame: u32) bool {
        for (self.probe_ids) |p| if (p == frame) return true;
        return false;
    }

    /// Feed results in send order.
    pub fn onResult(self: *TrainCap, r: PacketResult) void {
        if (r.frame != self.cur_frame) {
            self.cur_frame = r.frame;
            self.cur_probe = self.isProbe(r.frame);
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
                if (self.cur_probe) {
                    self.probe_t[0] = self.probe_t[1];
                    self.probe_v[0] = self.probe_v[1];
                    self.probe_t[1] = r.recv_us;
                    self.probe_v[1] = v;
                    self.probe_samples += 1;
                    return;
                }
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

    /// The median, or the probe reading when that is higher: the lower of
    /// the two newest probe samples, if both arrived in the `probe_window_us`
    /// before `now_recv_us`. Null when there is neither.
    pub fn estimateWithProbes(self: *const TrainCap, now_recv_us: i64, window_us: i64, probe_window_us: i64) ?f64 {
        const m = self.estimate(now_recv_us, window_us);
        const since = now_recv_us - probe_window_us;
        const p: ?f64 = if (self.probe_t[0] >= since and self.probe_t[1] >= since) @min(self.probe_v[0], self.probe_v[1]) else null;
        if (m) |mv| return if (p) |pv| @max(mv, pv) else mv;
        return p;
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

test "probe frames read spare capacity the median can't see" {
    var tc = TrainCap{};
    // Ordinary frames dispersed at our 12 Mbit/s share (800 us per packet),
    // two probe frames dispersed at the 24 Mbit/s link rate.
    var seq: u64 = 0;
    for (0..20) |f| {
        const fid: u32 = @intCast(f);
        const probe = f == 10 or f == 15;
        if (probe) tc.markProbe(fid);
        const gap: i64 = if (probe) 400 else 800;
        const base: i64 = @intCast(f * 16_667);
        for (0..8) |k| {
            const kk: i64 = @intCast(k);
            tc.onResult(.{ .seq = seq, .send_us = base, .recv_us = base + 5000 + kk * gap, .size = 1200, .frame = fid, .frame_last = k == 7 });
            seq += 1;
        }
    }
    const now: i64 = 20 * 16_667;
    try std.testing.expectApproxEqRel(@as(f64, 12e6), tc.estimate(now, 300_000).?, 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 24e6), tc.estimateWithProbes(now, 300_000, 2_000_000).?, 1e-9);
    // One probe alone is not enough, nor are stale ones.
    try std.testing.expectApproxEqRel(@as(f64, 12e6), tc.estimateWithProbes(now + 3_000_000, 4_000_000, 2_000_000).?, 1e-9);
    try std.testing.expectEqual(@as(u32, 2), tc.probe_samples);
}
