//! Host side: how the video stream recovers from loss on the current path.
//!
//! Design doc, "Loss recovery" and "Relay mode":
//!  - RTT under a quarter of the frame interval: NACK and selective retransmit, no FEC.
//!  - Otherwise: Reed-Solomon FEC, with parity sized from measured loss, at most 30%.
//!  - Relayed path (TCP underneath, so no loss but head-of-line blocking): FEC off,
//!    bitrate capped, lower resolution preferred, and a relay badge in the overlay.
//!
//! Sans-I/O. Feed packet counts from transport feedback with `onCounts`, then call
//! `update` with the path's RTT and relay state (once per frame is plenty). The result
//! says whether to answer NACKs, how much FEC to send (copy `parity` into the
//! packetizer) and which caps the rate ladder (core/rate) must stay under.
//!
//! Parity per group: for a group of k data shards, the fewest parity shards m for which
//! more than m of the k + m shards are lost with probability at most `residual`, when
//! each shard is lost independently at the measured rate. m is capped at
//! `max_overhead` × k (rounded, at least 1), so small groups still get one parity shard
//! and a 32-shard group at most 10. Loss in bursts beats this; NACK stays on as a backup
//! while the RTT leaves time for it.
const std = @import("std");
const packetizer = @import("packetizer.zig");
const ParityTable = packetizer.ParityTable;

pub const Mode = enum {
    /// Short RTT: retransmit on NACK, no FEC.
    nack,
    /// Long RTT: FEC sized from loss.
    fec,
    /// Relayed path: no FEC, capped bitrate, lower resolution.
    relay,
};

pub const Config = struct {
    /// NACK while RTT < this × the frame interval.
    nack_rtt_fraction: f64 = 0.25,
    /// Hysteresis around that threshold: switch to FEC above (1 + h)×, back below (1 − h)×.
    hysteresis: f64 = 0.2,
    /// After a NACK/FEC switch, hold the new mode at least this long. Relay changes
    /// apply at once.
    min_dwell_us: u64 = 2_000_000,
    /// Parity shards / data shards, at most.
    max_overhead: f64 = 0.30,
    /// Target chance a group cannot be rebuilt (independent loss).
    residual: f64 = 0.002,
    /// Below this loss estimate FEC sends no parity.
    min_loss: f64 = 0.002,
    /// Loss assumed in FEC mode until the meter has its first window (a quarter
    /// second): FEC is the mode because NACK would be too slow, so start protected.
    initial_loss: f64 = 0.05,
    /// In FEC mode, keep answering NACKs (a backup for bursts) while RTT is under this.
    /// Past it a retransmit lands after the client's frame timeout anyway.
    nack_backup_max_rtt_us: u64 = 80_000,
    /// Relay mode caps. Public relays carried ~8 Mbit/s in S5b, so stay well under.
    relay_max_bitrate_bps: u64 = 6_000_000,
    relay_max_height: u32 = 720,
    loss: LossMeter.Config = .{},
};

/// Bounds the rate ladder (core/rate) must respect.
pub const Caps = struct {
    max_bitrate_bps: ?u64 = null,
    /// Prefer this resolution or lower (lines).
    max_height: ?u32 = null,
    /// Path is relayed: show the relay badge in the overlay.
    relayed: bool = false,
};

pub const Inputs = struct {
    /// Path RTT; 0 when unknown (the mode is then kept).
    rtt_us: u64,
    /// Encoder frame interval (1 s / fps).
    frame_interval_us: u64,
    relayed: bool = false,
};

pub const Decision = struct {
    mode: Mode,
    /// Resend NACKed shards.
    nack: bool,
    /// Smoothed packet loss, 0..1.
    loss: f64,
    /// Parity / data shards for a group of `group_shards` (32) data shards: the FEC
    /// share the encoder budget has to leave room for (encoder = target / (1 + overhead)).
    overhead: f64,
    caps: Caps,
};

/// Packet loss from transport feedback, smoothed per window: the first window sets it,
/// then it rises fast (half the gap per window) and decays slowly (5%), so FEC is in
/// place for the next burst.
pub const LossMeter = struct {
    pub const Config = struct {
        window_us: u64 = 250_000,
        /// Fewer packets than this in a window: wait for more before updating.
        min_packets: u64 = 50,
        rise: f64 = 0.5,
        decay: f64 = 0.05,
    };

    cfg: LossMeter.Config = .{},
    estimate: f64 = 0,
    sent: u64 = 0,
    lost: u64 = 0,
    window_start: ?u64 = null,
    windows: u64 = 0,

    /// `sent` packets reported on, of which `lost` did not arrive.
    /// Returns true when the estimate was updated.
    pub fn onCounts(m: *LossMeter, now_us: u64, sent: u64, lost: u64) bool {
        std.debug.assert(lost <= sent);
        const start = m.window_start orelse blk: {
            m.window_start = now_us;
            break :blk now_us;
        };
        m.sent += sent;
        m.lost += lost;
        if (now_us -| start < m.cfg.window_us or m.sent < m.cfg.min_packets) return false;
        const f = @as(f64, @floatFromInt(m.lost)) / @as(f64, @floatFromInt(m.sent));
        const a = if (m.windows == 0) 1 else if (f > m.estimate) m.cfg.rise else m.cfg.decay;
        m.windows += 1;
        m.estimate += a * (f - m.estimate);
        if (m.estimate < 1e-4) m.estimate = 0;
        m.sent = 0;
        m.lost = 0;
        m.window_start = now_us;
        return true;
    }
};

/// Parity shards for k data shards at loss `p` (see the file comment).
pub fn parityFor(k: u8, p: f64, cfg: Config) u8 {
    if (k == 0 or p < cfg.min_loss) return 0;
    const kf: f64 = @floatFromInt(k);
    const cap_f = @max(1.0, @round(cfg.max_overhead * kf));
    const cap: u8 = @intFromFloat(@min(cap_f, @as(f64, packetizer.max_parity), 255.0 - kf));
    if (p >= 1) return cap;
    var m: u8 = 0;
    while (m < cap) : (m += 1) {
        if (tailAbove(@as(u32, k) + m, m, p) <= cfg.residual) return m;
    }
    return cap;
}

/// P(X > m) for X ~ Binomial(n, p).
fn tailAbove(n: u32, m: u32, p: f64) f64 {
    const q = 1 - p;
    var pmf = std.math.pow(f64, q, @floatFromInt(n));
    var cdf = pmf;
    var i: u32 = 0;
    while (i < m) : (i += 1) {
        pmf *= @as(f64, @floatFromInt(n - i)) / @as(f64, @floatFromInt(i + 1)) * (p / q);
        cdf += pmf;
    }
    return @max(0, 1 - cdf);
}

pub fn fillParity(table: *ParityTable, p: f64, cfg: Config) void {
    table[0] = 0;
    for (1..256) |k| table[k] = parityFor(@intCast(k), p, cfg);
}

pub const Policy = struct {
    cfg: Config = .{},
    mode: Mode = .nack,
    /// When the mode last changed between NACK and FEC.
    switched_us: ?u64 = null,
    meter: LossMeter = .{},
    /// Parity per group size for the current mode and loss; copy into the packetizer.
    parity: ParityTable = packetizer.no_parity,
    /// Loss the parity table was built for.
    table_loss: ?f64 = null,
    switches: u32 = 0,

    pub fn init(cfg: Config) Policy {
        return .{ .cfg = cfg, .meter = .{ .cfg = cfg.loss } };
    }

    /// Packets covered by a transport feedback message: `sent` reported, `lost` missing.
    pub fn onCounts(p: *Policy, now_us: u64, sent: u64, lost: u64) void {
        _ = p.meter.onCounts(now_us, sent, lost);
    }

    fn chooseMode(p: *Policy, now_us: u64, in: Inputs) Mode {
        if (in.relayed) return .relay;
        const threshold = p.cfg.nack_rtt_fraction * @as(f64, @floatFromInt(in.frame_interval_us));
        const rtt: f64 = @floatFromInt(in.rtt_us);
        const by_rtt: Mode = if (rtt < threshold) .nack else .fec;
        // Off a relay, or no mode yet: take the RTT's choice at once.
        if (p.mode == .relay) return if (in.rtt_us == 0) .nack else by_rtt;
        if (in.rtt_us == 0) return p.mode;
        if (p.switched_us) |t| if (now_us -| t < p.cfg.min_dwell_us) return p.mode;
        return switch (p.mode) {
            .nack => if (rtt > threshold * (1 + p.cfg.hysteresis)) .fec else .nack,
            .fec => if (rtt < threshold * (1 - p.cfg.hysteresis)) .nack else .fec,
            .relay => unreachable,
        };
    }

    pub fn update(p: *Policy, now_us: u64, in: Inputs) Decision {
        const mode = p.chooseMode(now_us, in);
        if (mode != p.mode) {
            if (mode != .relay and p.mode != .relay) p.switched_us = now_us;
            p.mode = mode;
            p.switches += 1;
        }
        const loss = if (p.meter.windows == 0) p.cfg.initial_loss else p.meter.estimate;
        switch (mode) {
            .nack, .relay => if (p.table_loss != null) {
                p.parity = packetizer.no_parity;
                p.table_loss = null;
            },
            .fec => {
                // Rebuild when the loss moved by over 10% (relative) or crossed zero.
                const stale = if (p.table_loss) |t| @abs(loss - t) > 0.1 * @max(t, p.cfg.min_loss) else true;
                if (stale) {
                    fillParity(&p.parity, loss, p.cfg);
                    p.table_loss = loss;
                }
            },
        }
        return .{
            .mode = mode,
            .nack = switch (mode) {
                .nack, .relay => true,
                .fec => in.rtt_us < p.cfg.nack_backup_max_rtt_us,
            },
            .loss = loss,
            .overhead = @as(f64, @floatFromInt(p.parity[32])) / 32.0,
            .caps = if (mode == .relay) .{
                .max_bitrate_bps = p.cfg.relay_max_bitrate_bps,
                .max_height = p.cfg.relay_max_height,
                .relayed = true,
            } else .{},
        };
    }
};

const testing = std.testing;

test "parity grows with loss and stops at 30%" {
    const cfg: Config = .{};
    try testing.expectEqual(@as(u8, 0), parityFor(32, 0, cfg));
    try testing.expectEqual(@as(u8, 0), parityFor(32, 0.001, cfg));
    var last: u8 = 0;
    for ([_]f64{ 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5 }) |p| {
        const m = parityFor(32, p, cfg);
        try testing.expect(m >= last);
        try testing.expect(m >= 1 and m <= 10);
        last = m;
    }
    try testing.expectEqual(@as(u8, 10), parityFor(32, 0.2, cfg));
    // Every group size: within the cap, and enough that the residual target holds
    // whenever it is reachable.
    for (1..256) |k| {
        const m = parityFor(@intCast(k), 0.05, cfg);
        const kf: f64 = @floatFromInt(k);
        try testing.expect(@as(f64, @floatFromInt(m)) <= @max(1.0, @round(0.3 * kf)));
        try testing.expect(m <= packetizer.max_parity and @as(usize, k) + m <= 255);
        if (m < @max(1.0, @round(0.3 * kf)) and m < packetizer.max_parity and k + m < 255) try testing.expect(tailAbove(@intCast(k + m), m, 0.05) <= cfg.residual);
    }
    // One parity shard even for a one-shard group.
    try testing.expectEqual(@as(u8, 1), parityFor(1, 0.05, cfg));
}

test "binomial tail" {
    try testing.expectApproxEqAbs(@as(f64, 0.5), tailAbove(1, 0, 0.5), 1e-12);
    // n = 3, p = 0.5: P(X > 1) = 4/8.
    try testing.expectApproxEqAbs(@as(f64, 0.5), tailAbove(3, 1, 0.5), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), tailAbove(3, 3, 0.5), 1e-12);
}

test "loss meter rises fast and decays slowly" {
    var m: LossMeter = .{};
    _ = m.onCounts(0, 0, 0);
    try testing.expect(!m.onCounts(100_000, 100, 10)); // window not over
    try testing.expect(m.onCounts(250_000, 100, 10)); // 20 of 200 = 10%, taken as is
    try testing.expectApproxEqAbs(@as(f64, 0.1), m.estimate, 1e-9);
    try testing.expect(m.onCounts(500_000, 100, 30)); // 30%: half the gap
    try testing.expectApproxEqAbs(@as(f64, 0.2), m.estimate, 1e-9);
    try testing.expect(m.onCounts(750_000, 100, 0)); // 0%: 5% of the gap
    try testing.expectApproxEqAbs(@as(f64, 0.19), m.estimate, 1e-9);
    // Too few packets: keep accumulating past the window.
    try testing.expect(!m.onCounts(2_000_000, 10, 10));
    try testing.expect(m.onCounts(2_000_001, 40, 0));
}

test "NACK under a quarter frame, FEC above, with hysteresis and dwell" {
    var p = Policy.init(.{});
    const fi: u64 = 16_667; // 60 fps: threshold ~4.17 ms
    var d = p.update(0, .{ .rtt_us = 2_000, .frame_interval_us = fi });
    try testing.expectEqual(Mode.nack, d.mode);
    try testing.expect(d.nack);
    try testing.expectEqual(@as(f64, 0), d.overhead);
    // Just over the threshold but inside the hysteresis band: stay.
    d = p.update(1_000, .{ .rtt_us = 4_500, .frame_interval_us = fi });
    try testing.expectEqual(Mode.nack, d.mode);
    d = p.update(2_000, .{ .rtt_us = 30_000, .frame_interval_us = fi });
    try testing.expectEqual(Mode.fec, d.mode);
    try testing.expect(d.nack); // 30 ms: retransmits still land in time
    // Unknown RTT keeps the mode; a dip right after the switch is held by the dwell.
    try testing.expectEqual(Mode.fec, p.update(3_000, .{ .rtt_us = 0, .frame_interval_us = fi }).mode);
    try testing.expectEqual(Mode.fec, p.update(1_000_000, .{ .rtt_us = 1_000, .frame_interval_us = fi }).mode);
    try testing.expectEqual(Mode.nack, p.update(2_100_000, .{ .rtt_us = 1_000, .frame_interval_us = fi }).mode);
    // At 30 fps the threshold doubles.
    p = Policy.init(.{});
    try testing.expectEqual(Mode.nack, p.update(0, .{ .rtt_us = 7_000, .frame_interval_us = 33_333 }).mode);
    try testing.expectEqual(Mode.fec, p.update(0, .{ .rtt_us = 150_000, .frame_interval_us = 33_333 }).mode);
    try testing.expect(!p.update(0, .{ .rtt_us = 150_000, .frame_interval_us = 33_333 }).nack);
}

test "FEC overhead follows measured loss" {
    var p = Policy.init(.{});
    const in: Inputs = .{ .rtt_us = 40_000, .frame_interval_us = 16_667 };
    var d = p.update(0, in);
    try testing.expectEqual(Mode.fec, d.mode);
    try testing.expectEqual(p.cfg.initial_loss, d.loss); // no loss measured yet
    try testing.expect(d.overhead > 0);
    var t: u64 = 0;
    for (0..20) |_| {
        t += 250_000;
        p.onCounts(t, 1000, 50);
    }
    d = p.update(t, in);
    try testing.expectApproxEqAbs(@as(f64, 0.05), d.loss, 0.001);
    try testing.expect(d.overhead > 0.1 and d.overhead <= 0.3);
    try testing.expectEqual(p.parity[32], parityFor(32, d.loss, p.cfg));
    for (0..20) |_| {
        t += 250_000;
        p.onCounts(t, 1000, 400);
    }
    try testing.expectEqual(@as(f64, 10.0 / 32.0), p.update(t, in).overhead); // capped
    // Loss stops: parity decays back to zero over some seconds.
    for (0..200) |_| {
        t += 250_000;
        p.onCounts(t, 1000, 0);
    }
    try testing.expectEqual(@as(f64, 0), p.update(t, in).overhead);
}

test "relay mode: FEC off, caps on, back to RTT choice when direct" {
    var p = Policy.init(.{});
    const fi: u64 = 16_667;
    var t: u64 = 0;
    for (0..10) |_| {
        t += 250_000;
        p.onCounts(t, 1000, 100);
    }
    try testing.expect(p.update(t, .{ .rtt_us = 50_000, .frame_interval_us = fi }).overhead > 0);
    var d = p.update(t + 1, .{ .rtt_us = 50_000, .frame_interval_us = fi, .relayed = true });
    try testing.expectEqual(Mode.relay, d.mode);
    try testing.expectEqual(@as(f64, 0), d.overhead);
    try testing.expect(std.mem.allEqual(u8, &p.parity, 0));
    try testing.expectEqual(Caps{ .max_bitrate_bps = 6_000_000, .max_height = 720, .relayed = true }, d.caps);
    // Direct again: the RTT decides at once, no dwell.
    d = p.update(t + 2, .{ .rtt_us = 2_000, .frame_interval_us = fi });
    try testing.expectEqual(Mode.nack, d.mode);
    try testing.expectEqual(Caps{}, d.caps);
}
