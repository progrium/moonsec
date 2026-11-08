//! Simulated clocks and network for the clock estimator: seeded skew, drift,
//! jitter, asymmetric queueing, loss and route changes.

const std = @import("std");
const clock = @import("root.zig");
const Micros = clock.Micros;
const us_per_s = clock.us_per_s;
const us_per_ms = clock.us_per_ms;

/// A clock that runs at (1 + skew) of true time from an arbitrary epoch.
/// `drift` changes the skew linearly over time (ppm per second of true time),
/// as a warming oscillator does.
const SimClock = struct {
    epoch: f64,
    skew_ppm: f64 = 0,
    drift_ppm_per_s: f64 = 0,

    fn read(c: SimClock, t_true: f64) Micros {
        const secs = t_true / 1e6;
        // Integral of (1 + (skew + drift * s) * 1e-6) over s.
        const elapsed = t_true + (c.skew_ppm * secs + 0.5 * c.drift_ppm_per_s * secs * secs) * 1e-6 * 1e6;
        return @intFromFloat(@round(c.epoch + elapsed));
    }
};

const Net = struct {
    /// Base one-way delays (true time, µs).
    up: f64,
    down: f64,
    /// Extra queueing delay, uniform in [0, jitter) each way.
    jitter_up: f64 = 0,
    jitter_down: f64 = 0,
    /// Probability a sample also gets a 20–200 ms spike on one side.
    spike_p: f64 = 0,
    loss_p: f64 = 0,
};

const Scenario = struct {
    seed: u64,
    duration_s: f64,
    client: SimClock,
    host: SimClock,
    net: Net,
    /// Optional route change: at this time the base delays become `net2`.
    change_at_s: ?f64 = null,
    net2: Net = undefined,
    /// After this much time, every check must hold.
    settle_s: f64,
    /// Max |estimated - true| offset at any check point after settling.
    max_err_us: f64,
    /// Max |estimated skew - true skew| in ppm at the end (null: not checked).
    /// The skew is a 60 s window average, so a drifting clock reads a few ppm
    /// behind, and on a jittery path tens of ppm of noise are expected; what
    /// matters is the offset bound, which these tests check every 100 ms.
    max_skew_err_ppm: ?f64 = null,
};

const Result = struct {
    worst_at_s: f64,
    worst_err_us: f64,
    final_skew_err_ppm: f64,
    samples: u32,
};

fn run(sc: Scenario) !Result {
    var prng = std.Random.DefaultPrng.init(sc.seed);
    const rnd = prng.random();

    var p = clock.Pinger.init(.{}, sc.client.read(0));
    var t: f64 = 0; // true time, µs
    const end = sc.duration_s * 1e6;
    var worst: f64 = 0;
    var worst_at: f64 = 0;
    const check_step: f64 = 100_000;
    var next_check: f64 = 0;

    while (t < end) {
        const net = if (sc.change_at_s) |c| (if (t >= c * 1e6) sc.net2 else sc.net) else sc.net;
        const now_c = sc.client.read(t);
        if (p.due(now_c)) {
            const ping = p.makePing(now_c);
            const lost = rnd.float(f64) < net.loss_p;
            if (!lost) {
                var up = net.up + rnd.float(f64) * net.jitter_up;
                var down = net.down + rnd.float(f64) * net.jitter_down;
                if (rnd.float(f64) < net.spike_p) {
                    const spike = 20_000 + rnd.float(f64) * 180_000;
                    if (rnd.boolean()) up += spike else down += spike;
                }
                const t_arrive = t + up;
                const t_reply = t_arrive + 100 + rnd.float(f64) * 400; // host turnaround
                const pong = clock.respond(ping, sc.host.read(t_arrive), sc.host.read(t_reply));
                if (rnd.float(f64) >= net.loss_p) {
                    _ = p.onPong(pong, sc.client.read(t_reply + down));
                }
            }
        }

        if (t >= next_check) {
            next_check += check_step;
            if (t >= sc.settle_s * 1e6) {
                const est = p.estimate() orelse return error.NoEstimate;
                const truth: f64 = @floatFromInt(sc.host.read(t) - now_c);
                const got: f64 = @floatFromInt(est.offsetAt(now_c));
                if (@abs(got - truth) > worst) {
                    worst = @abs(got - truth);
                    worst_at = t / 1e6;
                }
            }
        }
        t += 1000; // 1 ms steps of true time
    }

    const est = p.estimate().?;
    const secs = end / 1e6;
    // True relative skew at the end: d(host - client)/d(client).
    const hs = sc.host.skew_ppm + sc.host.drift_ppm_per_s * secs;
    const cs = sc.client.skew_ppm + sc.client.drift_ppm_per_s * secs;
    const true_skew_ppm = ((1 + hs * 1e-6) / (1 + cs * 1e-6) - 1) * 1e6;
    return .{
        .worst_at_s = worst_at,
        .worst_err_us = worst,
        .final_skew_err_ppm = @abs(est.skew * 1e6 - true_skew_ppm),
        .samples = est.samples,
    };
}

fn expectScenario(name: []const u8, sc: Scenario) !void {
    // Every scenario runs over several seeds; the bound must hold on each.
    var seed: u64 = sc.seed;
    while (seed < sc.seed + 8) : (seed += 1) {
        var s = sc;
        s.seed = seed;
        const r = try run(s);
        if (r.worst_err_us > sc.max_err_us) {
            std.debug.print("{s} seed {d}: worst offset error {d:.0} us > {d:.0} us at {d:.1} s\n", .{ name, seed, r.worst_err_us, sc.max_err_us, r.worst_at_s });
            return error.OffsetError;
        }
        if (sc.max_skew_err_ppm) |m| if (r.final_skew_err_ppm > m) {
            std.debug.print("{s} seed {d}: skew error {d:.2} ppm > {d:.2} ppm\n", .{ name, seed, r.final_skew_err_ppm, m });
            return error.SkewError;
        };
    }
}

const big_epoch: f64 = 1.7e15; // ~54 years of µs, like a Unix-epoch clock

test "sim: fixed offset, clean LAN" {
    try expectScenario("clean LAN", .{
        .seed = 1,
        .duration_s = 20,
        .client = .{ .epoch = 5e9 },
        .host = .{ .epoch = big_epoch },
        .net = .{ .up = 300, .down = 300, .jitter_up = 100, .jitter_down = 100 },
        .settle_s = 1,
        .max_err_us = 100,
    });
}

test "sim: fixed offset, jittery internet path" {
    try expectScenario("jittery WAN", .{
        .seed = 100,
        .duration_s = 60,
        .client = .{ .epoch = 0 },
        .host = .{ .epoch = -3.2e11 },
        .net = .{ .up = 20_000, .down = 20_000, .jitter_up = 15_000, .jitter_down = 15_000, .spike_p = 0.05, .loss_p = 0.1 },
        .settle_s = 2,
        .max_err_us = 3_000,
    });
}

test "sim: one-sided queueing is filtered by min rtt" {
    // Downlink queue builds up to 40 ms; uplink clean. A plain average would
    // be ~10 ms off; the min-rtt filter keeps it to a couple of ms.
    try expectScenario("one-sided queue", .{
        .seed = 200,
        .duration_s = 60,
        .client = .{ .epoch = 1e12 },
        .host = .{ .epoch = 0 },
        .net = .{ .up = 15_000, .down = 15_000, .jitter_down = 40_000 },
        .settle_s = 5,
        .max_err_us = 3_000,
    });
}

test "sim: 100 ppm skew is tracked" {
    try expectScenario("skew 100ppm", .{
        .seed = 300,
        .duration_s = 180,
        .client = .{ .epoch = 0, .skew_ppm = -40 },
        .host = .{ .epoch = big_epoch, .skew_ppm = 60 },
        .net = .{ .up = 10_000, .down = 10_000, .jitter_up = 5_000, .jitter_down = 5_000, .loss_p = 0.05 },
        .settle_s = 10,
        .max_err_us = 1_000,
        .max_skew_err_ppm = 25,
    });
}

test "sim: extreme 800 ppm skew on a clean path" {
    try expectScenario("skew 800ppm", .{
        .seed = 400,
        .duration_s = 120,
        .client = .{ .epoch = 0 },
        .host = .{ .epoch = 7e9, .skew_ppm = 800 },
        .net = .{ .up = 1_000, .down = 1_000, .jitter_up = 300, .jitter_down = 300 },
        .settle_s = 10,
        .max_err_us = 300,
        .max_skew_err_ppm = 5,
    });
}

test "sim: drifting skew (warming oscillator)" {
    // Skew moves from 0 to 60 ppm over five minutes.
    try expectScenario("drift", .{
        .seed = 500,
        .duration_s = 300,
        .client = .{ .epoch = 0 },
        .host = .{ .epoch = big_epoch, .drift_ppm_per_s = 0.2 },
        .net = .{ .up = 8_000, .down = 8_000, .jitter_up = 4_000, .jitter_down = 4_000 },
        .settle_s = 10,
        .max_err_us = 1_000,
        .max_skew_err_ppm = 15,
    });
}

test "sim: route change keeps the offset" {
    // Symmetric jump from 5 ms to 60 ms each way at 30 s: offset unchanged,
    // and the old low-rtt samples must not pin a stale estimate.
    try expectScenario("route change", .{
        .seed = 600,
        .duration_s = 150,
        .client = .{ .epoch = 0, .skew_ppm = 30 },
        .host = .{ .epoch = 4e10 },
        .net = .{ .up = 5_000, .down = 5_000, .jitter_up = 2_000, .jitter_down = 2_000 },
        .change_at_s = 30,
        .net2 = .{ .up = 60_000, .down = 60_000, .jitter_up = 5_000, .jitter_down = 5_000 },
        .settle_s = 10,
        .max_err_us = 1_500,
        .max_skew_err_ppm = 25,
    });
}

test "sim: first estimate arrives within half a second" {
    var p = clock.Pinger.init(.{}, 0);
    var t: Micros = 0;
    while (p.estimate() == null and t < 500 * us_per_ms) : (t += us_per_ms) {
        if (p.due(t)) {
            const ping = p.makePing(t);
            _ = p.onPong(clock.respond(ping, t + 1_000_000 + 10 * us_per_ms, t + 1_000_000 + 10 * us_per_ms), t + 20 * us_per_ms);
        }
    }
    const est = p.estimate() orelse return error.NoEstimate;
    try std.testing.expect(@abs(est.offsetAt(t) - 1_000_000) < 100);
}
