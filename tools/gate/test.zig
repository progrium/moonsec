//! The gate session in one process over the simulated network, in virtual time:
//! the same code `zig build gate-sim` runs in two processes, checked fast and
//! deterministically on every `zig build test`.
const std = @import("std");
const simnet = @import("simnet");
const session = @import("session.zig");
const scenario = @import("scenario.zig");

fn run(seed: u64, cfg: session.Config, lossy: bool) !struct { host: session.Outcome, client: session.Outcome } {
    const gpa = std.testing.allocator;
    const net = try gpa.create(simnet.Net);
    defer gpa.destroy(net);
    try net.init(gpa, scenario.config(seed));
    defer net.deinit();

    var host = try session.Session.init(gpa, .host, cfg, net.pipeFor(.a));
    defer host.deinit();
    var client = try session.Session.init(gpa, .client, cfg, net.pipeFor(.b));
    defer client.deinit();

    var t: i64 = 0;
    var loss_on = false;
    while (!(host.done() and client.done())) : (t += 100) {
        if (lossy and !loss_on and t >= scenario.warmup_us) {
            scenario.startLoss(net);
            loss_on = true;
        }
        try net.runUntil(t);
        host.step(net.localTime(.a));
        client.step(net.localTime(.b));
        if (t > 120 * simnet.SEC) return error.Hung;
    }
    if (host.outcome != .passed or client.outcome != .passed) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try host.report(&w);
        try client.report(&w);
        std.debug.print("seed {d}:\n{s}", .{ seed, w.buffered() });
    }
    return .{ .host = host.outcome, .client = client.outcome };
}

test "gate session passes over the lossy, reordering sim path" {
    for (1..4) |seed| {
        const r = try run(seed, .{ .seed = seed }, true);
        try std.testing.expectEqual(session.Outcome.passed, r.host);
        try std.testing.expectEqual(session.Outcome.passed, r.client);
    }
}

test "gate session passes over a clean sim path" {
    const r = try run(9, .{ .seed = 9, .frames = 60, .input_events = 20 }, false);
    try std.testing.expectEqual(session.Outcome.passed, r.host);
    try std.testing.expectEqual(session.Outcome.passed, r.client);
}

test "gate session fails when the peers disagree on the run" {
    const gpa = std.testing.allocator;
    const net = try gpa.create(simnet.Net);
    defer gpa.destroy(net);
    try net.init(gpa, scenario.config(1));
    defer net.deinit();
    var host = try session.Session.init(gpa, .host, .{ .seed = 1 }, net.pipeFor(.a));
    defer host.deinit();
    var client = try session.Session.init(gpa, .client, .{ .seed = 2, .timeout_us = 2 * simnet.SEC }, net.pipeFor(.b));
    defer client.deinit();
    var t: i64 = 0;
    while (!(host.done() and client.done())) : (t += 100) {
        try net.runUntil(t);
        host.step(net.localTime(.a));
        client.step(net.localTime(.b));
    }
    try std.testing.expectEqual(session.Outcome.failed, host.outcome);
    try std.testing.expectEqual(session.Outcome.failed, client.outcome);
}
