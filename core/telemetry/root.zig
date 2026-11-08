//! Per-frame stage timing and rolling statistics for the latency overlay.
//!
//! Every stage reports its time: the host stamps capture and encode on its
//! own clock (they travel in the video header), the client stamps receive,
//! decode and present on its clock. Stages that cross the network need the
//! host/client clock offset (`clock.Estimate.offsetAt`); without one, the
//! network and end-to-end figures are left out rather than guessed.
//!
//! The types here are `extern` so the C ABI (`telemetry_*`) can hand them out
//! as they are. Sans-I/O: nothing reads a clock; all times are microseconds.

const std = @import("std");

pub const Micros = i64;

pub const Stage = enum(u8) {
    /// Capture API latency: capture start to frame available (host).
    capture,
    /// Frame available to encoded (host).
    encode,
    /// Encoded to fully received, including packetization and pacing (cross-clock).
    network,
    /// Received to decoded (client).
    decode,
    /// Decoded to presented (client).
    present,
    /// Capture to present: the glass-to-glass estimate (cross-clock).
    total,
    /// Input event captured on the client to injected on the host (cross-clock).
    input,

    pub const count = @typeInfo(Stage).@"enum".fields.len;
};

/// Timestamps of one video frame. Host fields are on the host clock, client
/// fields on the client clock; any may be missing.
pub const FrameTimes = struct {
    frame_id: u32,
    capture_start: ?Micros = null,
    captured: ?Micros = null,
    encoded: ?Micros = null,
    received: ?Micros = null,
    decoded: ?Micros = null,
    presented: ?Micros = null,
};

pub const no_value: Micros = std.math.minInt(Micros);

/// Stage durations of one frame; `no_value` where a stage is unknown.
pub const Breakdown = extern struct {
    frame_id: u32 = 0,
    us: [Stage.count]Micros = .{no_value} ** Stage.count,

    pub fn get(b: Breakdown, s: Stage) ?Micros {
        const v = b.us[@intFromEnum(s)];
        return if (v == no_value) null else v;
    }
};

fn set(b: *Breakdown, s: Stage, v: ?Micros) void {
    if (v) |x| b.us[@intFromEnum(s)] = x;
}

fn toLocal(host: ?Micros, host_minus_client: Micros) ?Micros {
    return if (host) |x| x - host_minus_client else null;
}

fn diff(a: ?Micros, b: ?Micros) ?Micros {
    return if (a != null and b != null) a.? - b.? else null;
}

/// Stage durations for one frame. `host_minus_client` is the clock offset at
/// about the time the frame was received (null: unknown).
pub fn breakdown(f: FrameTimes, host_minus_client: ?Micros) Breakdown {
    var b: Breakdown = .{ .frame_id = f.frame_id };
    set(&b, .capture, diff(f.captured, f.capture_start));
    set(&b, .encode, diff(f.encoded, f.captured));
    set(&b, .decode, diff(f.decoded, f.received));
    set(&b, .present, diff(f.presented, f.decoded));
    if (host_minus_client) |off| {
        set(&b, .network, diff(f.received, toLocal(f.encoded, off)));
        set(&b, .total, diff(f.presented, toLocal(f.capture_start orelse f.captured, off)));
    }
    return b;
}

pub const StageStats = extern struct {
    /// Samples in the window.
    count: u32 = 0,
    min: Micros = 0,
    mean: Micros = 0,
    p50: Micros = 0,
    p95: Micros = 0,
    p99: Micros = 0,
    max: Micros = 0,
};

pub const Counters = extern struct {
    /// Frames recorded.
    frames: u64 = 0,
    /// Frames recorded without a present time (dropped or skipped).
    frames_not_presented: u64 = 0,
    /// Input events recorded.
    inputs: u64 = 0,
};

pub const Snapshot = extern struct {
    stages: [Stage.count]StageStats = .{StageStats{}} ** Stage.count,
    /// The most recent frame, for a per-frame overlay line.
    last: Breakdown = .{},
    counters: Counters = .{},

    pub fn stage(s: *const Snapshot, st: Stage) StageStats {
        return s.stages[@intFromEnum(st)];
    }
};

/// Rolling window of the last `window` samples per stage.
pub fn Telemetry(comptime window: usize) type {
    return struct {
        const Self = @This();

        const Ring = struct {
            buf: [window]Micros = undefined,
            head: usize = 0,
            len: usize = 0,

            fn push(r: *Ring, v: Micros) void {
                r.buf[r.head] = v;
                r.head = (r.head + 1) % window;
                if (r.len < window) r.len += 1;
            }
        };

        rings: [Stage.count]Ring = .{Ring{}} ** Stage.count,
        last: Breakdown = .{},
        counters: Counters = .{},

        pub fn init() Self {
            return .{};
        }

        pub fn record(t: *Self, f: FrameTimes, host_minus_client: ?Micros) void {
            const b = breakdown(f, host_minus_client);
            t.counters.frames += 1;
            if (f.presented == null) t.counters.frames_not_presented += 1;
            for (b.us, 0..) |v, i| if (v != no_value) t.rings[i].push(v);
            t.last = b;
        }

        /// An input event captured at client time `client_time` and injected
        /// at host time `host_injected`.
        pub fn recordInput(t: *Self, client_time: Micros, host_injected: Micros, host_minus_client: Micros) void {
            t.counters.inputs += 1;
            t.rings[@intFromEnum(Stage.input)].push(host_injected - host_minus_client - client_time);
        }

        /// Statistics over the window. Sorts a copy of each stage's samples,
        /// so call it at overlay rate, not per frame.
        pub fn snapshot(t: *const Self) Snapshot {
            var s: Snapshot = .{ .last = t.last, .counters = t.counters };
            var tmp: [window]Micros = undefined;
            for (&t.rings, 0..) |*r, i| {
                if (r.len == 0) continue;
                const v = tmp[0..r.len];
                @memcpy(v, r.buf[0..r.len]);
                std.mem.sort(Micros, v, {}, std.sort.asc(Micros));
                var sum: i128 = 0;
                for (v) |x| sum += x;
                s.stages[i] = .{
                    .count = @intCast(r.len),
                    .min = v[0],
                    .mean = @intCast(@divFloor(sum, @as(i128, @intCast(r.len)))),
                    .p50 = percentile(v, 50),
                    .p95 = percentile(v, 95),
                    .p99 = percentile(v, 99),
                    .max = v[v.len - 1],
                };
            }
            return s;
        }

        pub fn reset(t: *Self) void {
            t.* = .{};
        }
    };
}

/// Nearest-rank percentile of sorted samples.
fn percentile(sorted: []const Micros, p: usize) Micros {
    const rank = (p * sorted.len + 99) / 100; // ceil(p/100 * n)
    return sorted[@max(rank, 1) - 1];
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "breakdown across clocks" {
    // Host clock is 1 s ahead of the client.
    const off: Micros = 1_000_000;
    const f: FrameTimes = .{
        .frame_id = 9,
        .capture_start = off + 0,
        .captured = off + 1_000,
        .encoded = off + 5_000,
        .received = 12_000,
        .decoded = 14_500,
        .presented = 16_000,
    };
    const b = breakdown(f, off);
    try testing.expectEqual(@as(u32, 9), b.frame_id);
    try testing.expectEqual(@as(?Micros, 1_000), b.get(.capture));
    try testing.expectEqual(@as(?Micros, 4_000), b.get(.encode));
    try testing.expectEqual(@as(?Micros, 7_000), b.get(.network));
    try testing.expectEqual(@as(?Micros, 2_500), b.get(.decode));
    try testing.expectEqual(@as(?Micros, 1_500), b.get(.present));
    try testing.expectEqual(@as(?Micros, 16_000), b.get(.total));
    try testing.expectEqual(@as(?Micros, null), b.get(.input));

    // Without an offset the cross-clock stages stay unknown.
    const nb = breakdown(f, null);
    try testing.expectEqual(@as(?Micros, null), nb.get(.network));
    try testing.expectEqual(@as(?Micros, null), nb.get(.total));
    try testing.expectEqual(@as(?Micros, 2_500), nb.get(.decode));
}

test "total falls back to the capture time when capture start is missing" {
    const b = breakdown(.{ .frame_id = 1, .captured = 100, .presented = 10_100 }, 0);
    try testing.expectEqual(@as(?Micros, 10_000), b.get(.total));
    try testing.expectEqual(@as(?Micros, null), b.get(.capture));
}

test "rolling stats and percentiles" {
    var t = Telemetry(100).init();
    // 200 frames with decode times 1..200 ms; the window keeps the last 100.
    for (1..201) |i| {
        const d: Micros = @intCast(i * 1000);
        t.record(.{ .frame_id = @intCast(i), .received = 0, .decoded = d, .presented = if (i % 10 == 0) null else d + 500 }, null);
    }
    const s = t.snapshot();
    const dec = s.stage(.decode);
    try testing.expectEqual(@as(u32, 100), dec.count);
    try testing.expectEqual(@as(Micros, 101_000), dec.min);
    try testing.expectEqual(@as(Micros, 200_000), dec.max);
    try testing.expectEqual(@as(Micros, 150_000), dec.p50);
    try testing.expectEqual(@as(Micros, 195_000), dec.p95);
    try testing.expectEqual(@as(Micros, 199_000), dec.p99);
    try testing.expectEqual(@as(Micros, 150_500), dec.mean);
    try testing.expectEqual(@as(u64, 200), s.counters.frames);
    try testing.expectEqual(@as(u64, 20), s.counters.frames_not_presented);
    try testing.expectEqual(@as(u32, 100), s.stage(.present).count); // 180 presented, window 100
    try testing.expectEqual(@as(u32, 0), s.stage(.network).count);
    try testing.expectEqual(@as(u32, 200), s.last.frame_id);
}

test "input latency across clocks" {
    var t = Telemetry(16).init();
    t.recordInput(1_000, 5_000_000 + 4_000, 5_000_000);
    t.recordInput(2_000, 5_000_000 + 7_000, 5_000_000);
    const s = t.snapshot();
    try testing.expectEqual(@as(Micros, 3_000), s.stage(.input).min);
    try testing.expectEqual(@as(Micros, 5_000), s.stage(.input).max);
    try testing.expectEqual(@as(u64, 2), s.counters.inputs);
    t.reset();
    try testing.expectEqual(@as(u32, 0), t.snapshot().stage(.input).count);
}
