//! Host/client clock offset from round trips.
//!
//! The client sends a `Ping` stamped with its own clock (t1). The host stamps
//! when it got the ping (t2) and when it sends the `Pong` (t3), both on the host
//! clock. The client stamps the pong's arrival (t4). Each round trip gives
//!
//!     offset = ((t2 - t1) + (t3 - t4)) / 2      host clock minus client clock
//!     rtt    = (t4 - t1) - (t3 - t2)            network time only
//!
//! The offset of one round trip is off by at most rtt/2, and by much less when
//! the two directions saw the same delay. Queueing only adds delay, so the
//! estimator keeps a 60 s window, takes the fastest round trip of each second,
//! drops those far above the best path, and weights the rest by how close
//! they came. A ridge-regularised line through them gives the skew (clock rate
//! difference, in ppm, which itself may drift); the offset is the weighted
//! mean of the skew-corrected recent samples. A route change to a longer path
//! is detected and rebases the filter. A constant path asymmetry cannot be
//! seen from round trips at all; it shows up as a fixed bias.
//!
//! Sans-I/O: every function takes timestamps in; nothing reads a clock. All
//! times are microseconds on a monotonic clock (`Micros`).

const std = @import("std");

pub const Micros = i64;

pub const us_per_ms: Micros = 1000;
pub const us_per_s: Micros = 1_000_000;

// ---------------------------------------------------------------------------
// Messages

/// Message kinds on the control-fast stream (`proto.StreamId.control_fast`),
/// carried in the envelope's kind byte. Numbered from 16 to stay clear of the
/// kinds proto defines itself.
pub const Kind = enum(u8) {
    /// Client to host.
    clock_ping = 16,
    /// Host to client.
    clock_pong = 17,
    _,
};

pub const Ping = struct {
    seq: u32,
    /// Client clock when the ping was sent.
    t1: Micros,

    pub const wire_len = 12;

    pub fn encode(p: Ping, buf: *[wire_len]u8) void {
        std.mem.writeInt(u32, buf[0..4], p.seq, .little);
        std.mem.writeInt(i64, buf[4..12], p.t1, .little);
    }

    pub fn decode(buf: []const u8) error{ Truncated, InvalidMessage }!Ping {
        if (buf.len < wire_len) return error.Truncated;
        if (buf.len > wire_len) return error.InvalidMessage;
        return .{
            .seq = std.mem.readInt(u32, buf[0..4], .little),
            .t1 = std.mem.readInt(i64, buf[4..12], .little),
        };
    }
};

pub const Pong = struct {
    seq: u32,
    /// Echo of the ping's t1 (client clock).
    t1: Micros,
    /// Host clock when the ping arrived.
    t2: Micros,
    /// Host clock when the pong was sent.
    t3: Micros,

    pub const wire_len = 28;

    pub fn encode(p: Pong, buf: *[wire_len]u8) void {
        std.mem.writeInt(u32, buf[0..4], p.seq, .little);
        std.mem.writeInt(i64, buf[4..12], p.t1, .little);
        std.mem.writeInt(i64, buf[12..20], p.t2, .little);
        std.mem.writeInt(i64, buf[20..28], p.t3, .little);
    }

    pub fn decode(buf: []const u8) error{ Truncated, InvalidMessage }!Pong {
        if (buf.len < wire_len) return error.Truncated;
        if (buf.len > wire_len) return error.InvalidMessage;
        return .{
            .seq = std.mem.readInt(u32, buf[0..4], .little),
            .t1 = std.mem.readInt(i64, buf[4..12], .little),
            .t2 = std.mem.readInt(i64, buf[12..20], .little),
            .t3 = std.mem.readInt(i64, buf[20..28], .little),
        };
    }
};

/// Host side: answer a ping. `recv` and `send` are host clock times.
pub fn respond(ping: Ping, recv: Micros, send: Micros) Pong {
    return .{ .seq = ping.seq, .t1 = ping.t1, .t2 = recv, .t3 = send };
}

// ---------------------------------------------------------------------------
// Samples

pub const Sample = struct {
    /// Client clock at the middle of the round trip.
    at: Micros,
    /// Host clock minus client clock.
    offset: Micros,
    rtt: Micros,
};

/// One round trip as a sample, or null if the timestamps are impossible
/// (negative rtt, host time going backwards, or values that do not fit in a
/// Micros). t2 and t3 come from the network, so the arithmetic is done wide.
pub fn sampleOf(pong: Pong, t4: Micros) ?Sample {
    if (pong.t3 < pong.t2 or t4 < pong.t1) return null;
    const t1: i128 = pong.t1;
    const t2: i128 = pong.t2;
    const t3: i128 = pong.t3;
    const t4w: i128 = t4;
    const rtt = (t4w - t1) - (t3 - t2);
    if (rtt < 0) return null;
    const offset = @divFloor((t2 - t1) + (t3 - t4w), 2);
    const at = t1 + @divFloor(t4w - t1, 2);
    return .{
        .at = std.math.cast(Micros, at) orelse return null,
        .offset = std.math.cast(Micros, offset) orelse return null,
        .rtt = std.math.cast(Micros, rtt) orelse return null,
    };
}

// ---------------------------------------------------------------------------
// Estimator

pub const Config = struct {
    /// Samples older than this (client clock, relative to the newest) are dropped.
    max_age: Micros = 60 * us_per_s,
    /// The window is cut into buckets this long; each bucket contributes its
    /// lowest-rtt sample. Queueing only ever adds delay, so the fastest round
    /// trip in a bucket is the one with the least asymmetry, and spreading the
    /// chosen samples over the whole window keeps the skew fit well posed.
    bucket: Micros = 1 * us_per_s,
    /// If the best rtt of the newest `baseline_buckets` exceeds the window's
    /// best by more than max(route_change_min, min_rtt / route_change_div),
    /// the path is taken to have changed and the newest buckets set the
    /// baseline instead.
    baseline_buckets: usize = 8,
    route_change_min: Micros = 5 * us_per_ms,
    route_change_div: Micros = 2,
    /// Buckets whose rtt exceeds the baseline by more than this many noise
    /// floors are left out of the fit, but the best `keep_min` always stay.
    select_floors: f64 = 3,
    keep_min: usize = 4,
    /// The skew is fitted only once the chosen samples span this long.
    skew_min_span: Micros = 8 * us_per_s,
    /// The offset comes from chosen samples at most this old (skew-corrected).
    offset_window: Micros = 30 * us_per_s,
    /// Prior on the skew (standard deviation, ppm). A short or noisy window
    /// cannot tell skew from jitter, so the fitted slope is shrunk toward
    /// zero in proportion to how little the window can resolve it (ridge
    /// regression). Each clock is typically within 100 ppm, so their
    /// difference within 200.
    skew_prior_ppm: f64 = 200,
    /// Floor on a sample's offset error, as a fraction of the baseline rtt
    /// (never below 50 µs): asymmetry that no rtt can reveal. It sets the
    /// weights and the selection cutoff, so that a few lucky samples cannot
    /// claim more precision than the path allows.
    noise_floor_rtt_div: f64 = 32,
    /// Skews beyond this are treated as noise and clamped (1000 ppm = 1 ms/s;
    /// real oscillators are within about 100 ppm).
    max_skew_ppm: f64 = 1000,
};

pub const Estimate = struct {
    /// Offset (host minus client) at client time `ref`.
    offset: f64,
    /// d(offset)/d(client time); 1e-6 is 1 ppm.
    skew: f64,
    ref: Micros,
    /// Half the rtt of the best sample used: the offset is off by at most
    /// this much plus any constant path asymmetry.
    error_bound: Micros,
    /// Samples (bucket minima) behind the estimate.
    samples: u32,
    /// Whether the window resolves the skew (false: it is still mostly the
    /// prior, e.g. right after start).
    skew_fitted: bool,

    /// Host minus client offset at client time `local`.
    pub fn offsetAt(e: Estimate, local: Micros) Micros {
        const dt: f64 = @floatFromInt(local - e.ref);
        return @intFromFloat(@round(e.offset + e.skew * dt));
    }

    /// Client clock time to host clock time.
    pub fn localToHost(e: Estimate, local: Micros) Micros {
        return local + e.offsetAt(local);
    }

    /// Host clock time to client clock time.
    pub fn hostToLocal(e: Estimate, host: Micros) Micros {
        // local = host - offset(local); two fixed-point steps are exact to
        // well under a microsecond for any sane skew.
        const guess = host - e.offsetAt(host - @as(Micros, @intFromFloat(@round(e.offset))));
        return host - e.offsetAt(guess);
    }

    /// One-way delay of something sent at host time `host_sent` and received
    /// at client time `local_recv`.
    pub fn oneWay(e: Estimate, host_sent: Micros, local_recv: Micros) Micros {
        return local_recv - e.hostToLocal(host_sent);
    }
};

/// Windowed per-bucket minimum-rtt filter with a linear fit for skew.
/// `capacity` bounds the samples kept; size it for `max_age` at the ping rate.
pub fn Estimator(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const max_buckets = 64;

        cfg: Config,
        buf: [capacity]Sample = undefined,
        head: usize = 0,
        len: usize = 0,
        current: ?Estimate = null,

        pub fn init(cfg: Config) Self {
            std.debug.assert(cfg.bucket > 0 and cfg.keep_min > 0);
            return .{ .cfg = cfg };
        }

        pub fn estimate(self: *const Self) ?Estimate {
            return self.current;
        }

        fn at(self: *const Self, i: usize) Sample {
            return self.buf[(self.head + capacity - self.len + i) % capacity];
        }

        pub fn add(self: *Self, s: Sample) void {
            self.buf[self.head] = s;
            self.head = (self.head + 1) % capacity;
            if (self.len < capacity) self.len += 1;
            var newest = s.at;
            for (0..self.len) |i| newest = @max(newest, self.at(i).at);
            // Expire by age relative to the newest sample.
            while (self.len > 1 and newest - self.at(0).at > self.cfg.max_age) self.len -= 1;
            self.recompute(newest);
        }

        fn recompute(self: *Self, now: Micros) void {
            // Lowest-rtt sample per bucket, buckets counted back from `now`.
            var best: [max_buckets]?Sample = .{null} ** max_buckets;
            for (0..self.len) |i| {
                const s = self.at(i);
                const k: usize = @intCast(@min(max_buckets - 1, @divFloor(@max(0, now - s.at), self.cfg.bucket)));
                if (best[k] == null or s.rtt < best[k].?.rtt) best[k] = s;
            }

            var xs: [max_buckets]f64 = undefined;
            var ys: [max_buckets]f64 = undefined;
            var rtts: [max_buckets]Micros = undefined;
            var n: usize = 0;
            var min_rtt: Micros = std.math.maxInt(Micros);
            // Baseline rtt: the best in the window, unless the newest buckets
            // all sit far above it. That is a route change to a longer path,
            // and judging new samples against the old path would leave every
            // one of them weighted as if it were queued.
            var recent_rtt: Micros = std.math.maxInt(Micros);
            for (best) |maybe| {
                const s = maybe orelse continue;
                min_rtt = @min(min_rtt, s.rtt);
                if (n < self.cfg.baseline_buckets) recent_rtt = @min(recent_rtt, s.rtt);
                xs[n] = @floatFromInt(s.at - now);
                ys[n] = @floatFromInt(s.offset);
                rtts[n] = s.rtt;
                n += 1;
            }
            std.debug.assert(n > 0);
            const step = @max(self.cfg.route_change_min, @divFloor(min_rtt, self.cfg.route_change_div));
            const base_rtt = if (recent_rtt - min_rtt > step) recent_rtt else min_rtt;

            // A sample's offset error is bounded by half its rtt excess over
            // the best path, plus a floor for asymmetry no rtt can reveal.
            // Queueing tends to sit on one side (a busy downlink), so these
            // errors share a sign and do not average out: keep only buckets
            // close to the baseline (always at least `keep_min`), then
            // weight what is left by its bound.
            const floor = @max(50.0, @as(f64, @floatFromInt(base_rtt)) / self.cfg.noise_floor_rtt_div);
            var excess: [max_buckets]f64 = undefined;
            for (0..n) |i| excess[i] = @floatFromInt(@max(0, rtts[i] - base_rtt));
            var sorted = excess;
            std.mem.sort(f64, sorted[0..n], {}, std.sort.asc(f64));
            const cutoff = @max(self.cfg.select_floors * floor, sorted[@min(n, self.cfg.keep_min) - 1]);
            var ws: [max_buckets]f64 = undefined;
            var m: usize = 0;
            for (0..n) |i| {
                if (excess[i] > cutoff) continue;
                const half = excess[i] / 2;
                xs[m] = xs[i];
                ys[m] = ys[i];
                ws[m] = 1 / (floor * floor + half * half);
                m += 1;
            }
            n = m;

            // Two timescales, as NTP does: the skew needs a long lever arm,
            // the offset wants the freshest good samples. Until the chosen
            // samples span `skew_min_span`, a fitted slope is mostly noise
            // that the extrapolation to `now` would amplify, so skew stays 0.
            var first: f64 = 0;
            for (xs[0..n]) |x| first = @min(first, x);
            var skew: f64 = 0;
            var resolved = false;
            if (-first >= @as(f64, @floatFromInt(self.cfg.skew_min_span))) {
                const sp = self.cfg.skew_prior_ppm * 1e-6;
                const fit = ridgeFit(xs[0..n], ys[0..n], ws[0..n], 0, 1 / (sp * sp));
                const max_skew = self.cfg.max_skew_ppm * 1e-6;
                skew = std.math.clamp(fit.slope, -max_skew, max_skew);
                resolved = fit.resolved > 0.5;
            }

            // Offset: weighted mean of skew-corrected offsets over the recent
            // part of the window, or over everything chosen if it is empty.
            const recent = -@as(f64, @floatFromInt(self.cfg.offset_window));
            var sw: f64 = 0;
            var swy: f64 = 0;
            for (0..2) |pass| {
                for (xs[0..n], ys[0..n], ws[0..n]) |x, y, w| {
                    if (pass == 0 and x < recent) continue;
                    sw += w;
                    swy += w * (y - skew * x);
                }
                if (sw > 0) break;
            }
            self.current = .{
                .offset = swy / sw,
                .skew = skew,
                .ref = now,
                .error_bound = @divFloor(min_rtt + 1, 2),
                .samples = @intCast(n),
                .skew_fitted = resolved,
            };
        }
    };
}

const Fit = struct {
    slope: f64,
    mean_x: f64,
    mean_y: f64,
    /// How much of the slope came from the data rather than the prior (0..1).
    resolved: f64,
};

/// Weighted least squares line with a Gaussian prior on the slope (ridge).
/// `ws` are inverse variances; `lambda` is the inverse variance of the prior.
/// If the residuals show more scatter than the weights claim, the weights are
/// scaled down so the prior keeps its say.
fn ridgeFit(xs: []const f64, ys: []const f64, ws: []const f64, prior: f64, lambda: f64) Fit {
    var sw: f64 = 0;
    var swx: f64 = 0;
    var swy: f64 = 0;
    for (xs, ys, ws) |x, y, w| {
        sw += w;
        swx += w * x;
        swy += w * y;
    }
    const mx = swx / sw;
    const my = swy / sw;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (xs, ys, ws) |x, y, w| {
        sxx += w * (x - mx) * (x - mx);
        sxy += w * (x - mx) * (y - my);
    }
    var scale: f64 = 1;
    if (xs.len > 2 and sxx > 0) {
        const ols = sxy / sxx;
        var chi2: f64 = 0;
        for (xs, ys, ws) |x, y, w| {
            const r = y - (my + ols * (x - mx));
            chi2 += w * r * r;
        }
        scale = @max(1, chi2 / @as(f64, @floatFromInt(xs.len - 2)));
    }
    const a = sxx / scale;
    const slope = (sxy / scale + lambda * prior) / (a + lambda);
    return .{ .slope = slope, .mean_x = mx, .mean_y = my, .resolved = a / (a + lambda) };
}

// ---------------------------------------------------------------------------
// Client ping scheduler

pub const PingerConfig = struct {
    /// Pings sent `fast_interval` apart until this many samples arrived, so
    /// the first estimate lands quickly.
    fast_samples: u32 = 8,
    fast_interval: Micros = 50 * us_per_ms,
    /// Steady-state interval: 4 pings a second (about 160 B/s both ways)
    /// gives each bucket enough round trips to find a quiet one.
    interval: Micros = 250 * us_per_ms,
    estimator: Config = .{},
};

/// Client side: decides when to ping, matches pongs to pings and feeds the
/// estimator.
pub const Pinger = struct {
    const window = 512;
    const outstanding = 16;

    cfg: PingerConfig,
    est: Estimator(window),
    next_seq: u32 = 0,
    next_due: Micros,
    received: u32 = 0,
    sent: [outstanding]?Ping = .{null} ** outstanding,

    pub fn init(cfg: PingerConfig, now: Micros) Pinger {
        return .{ .cfg = cfg, .est = Estimator(window).init(cfg.estimator), .next_due = now };
    }

    pub fn due(p: *const Pinger, now: Micros) bool {
        return now >= p.next_due;
    }

    /// Micros until the next ping is due (0 if overdue).
    pub fn timeout(p: *const Pinger, now: Micros) Micros {
        return @max(0, p.next_due - now);
    }

    pub fn makePing(p: *Pinger, now: Micros) Ping {
        const ping: Ping = .{ .seq = p.next_seq, .t1 = now };
        p.sent[p.next_seq % outstanding] = ping;
        p.next_seq +%= 1;
        const iv = if (p.received < p.cfg.fast_samples) p.cfg.fast_interval else p.cfg.interval;
        p.next_due = now + iv;
        return ping;
    }

    /// Feed a pong received at client time `now`. Pongs that do not match an
    /// outstanding ping (stale, duplicated or forged) are ignored. Returns
    /// whether the pong was used.
    pub fn onPong(p: *Pinger, pong: Pong, now: Micros) bool {
        const slot = &p.sent[pong.seq % outstanding];
        const ping = slot.* orelse return false;
        if (ping.seq != pong.seq or ping.t1 != pong.t1) return false;
        slot.* = null;
        const s = sampleOf(pong, now) orelse return false;
        p.est.add(s);
        p.received +|= 1;
        return true;
    }

    pub fn estimate(p: *const Pinger) ?Estimate {
        return p.est.estimate();
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "sample math on a symmetric path" {
    // Host is 5 s ahead; 10 ms each way; host holds the ping for 1 ms.
    const pong = respond(.{ .seq = 1, .t1 = 1000 }, 1000 + 10_000 + 5_000_000, 1000 + 11_000 + 5_000_000);
    const s = sampleOf(pong, 1000 + 21_000).?;
    try testing.expectEqual(@as(Micros, 5_000_000), s.offset);
    try testing.expectEqual(@as(Micros, 20_000), s.rtt);
}

test "impossible samples are rejected" {
    try testing.expect(sampleOf(.{ .seq = 0, .t1 = 100, .t2 = 50, .t3 = 40 }, 200) == null);
    try testing.expect(sampleOf(.{ .seq = 0, .t1 = 100, .t2 = 0, .t3 = 500 }, 200) == null);
}

test "extreme host timestamps are dropped, not overflowed" {
    const max = std.math.maxInt(Micros);
    const min = std.math.minInt(Micros);
    try std.testing.expect(sampleOf(.{ .seq = 0, .t1 = 0, .t2 = min, .t3 = max }, 10) == null);
    try std.testing.expect(sampleOf(.{ .seq = 0, .t1 = min, .t2 = max, .t3 = max }, max) == null);
}

test "wire round trip" {
    var b1: [Ping.wire_len]u8 = undefined;
    const ping: Ping = .{ .seq = 7, .t1 = -42 };
    ping.encode(&b1);
    try testing.expectEqual(ping, try Ping.decode(&b1));
    var b2: [Pong.wire_len]u8 = undefined;
    const pong = respond(ping, 1 << 40, (1 << 40) + 3);
    pong.encode(&b2);
    try testing.expectEqual(pong, try Pong.decode(&b2));
    try testing.expectError(error.Truncated, Pong.decode(b2[0..10]));
    var long: [Ping.wire_len + 1]u8 = undefined;
    try testing.expectError(error.InvalidMessage, Ping.decode(&long));
}

test "pinger ignores unknown and duplicate pongs" {
    var p = Pinger.init(.{}, 0);
    const ping = p.makePing(0);
    const pong = respond(ping, 500, 600);
    try testing.expect(!p.onPong(.{ .seq = 99, .t1 = 0, .t2 = 1, .t3 = 2 }, 50));
    try testing.expect(p.onPong(pong, 1000));
    try testing.expect(!p.onPong(pong, 1000));
    try testing.expect(p.estimate() != null);
}

test "pinger interval goes from fast to steady" {
    var p = Pinger.init(.{}, 0);
    var now: Micros = 0;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try testing.expect(p.due(now));
        const ping = p.makePing(now);
        _ = p.onPong(respond(ping, now + 100, now + 100), now + 200);
        try testing.expectEqual(p.cfg.fast_interval, p.timeout(now));
        now += p.cfg.fast_interval;
    }
    _ = p.makePing(now);
    try testing.expectEqual(p.cfg.interval, p.timeout(now));
}

test "hostToLocal inverts localToHost under skew" {
    const e: Estimate = .{ .offset = 123_456_789, .skew = 250e-6, .ref = 10 * us_per_s, .error_bound = 0, .samples = 1, .skew_fitted = true };
    var t: Micros = 0;
    while (t < 3600 * us_per_s) : (t += 97 * us_per_s) {
        const back = e.hostToLocal(e.localToHost(t));
        try testing.expect(@abs(back - t) <= 1);
    }
}

test {
    _ = @import("sim_test.zig");
}
