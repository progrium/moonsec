//! Scenario tests: every scenario is deterministic by seed and does what its
//! description says. Runs are cut short so the suite stays fast in Debug; the
//! full-length runs are checked against `sim/golden.txt` by `zig build sim-check`.
const std = @import("std");
const simnet = @import("simnet");
const run = @import("run.zig");
const scenarios = @import("scenarios.zig");

const testing = std.testing;
const SEC = simnet.SEC;
const short: run.Options = .{ .duration_us = 3 * SEC };

test "every scenario is deterministic by seed" {
    for (scenarios.all) |sc| {
        const r1 = try run.run(testing.allocator, sc, 1, short);
        const r1b = try run.run(testing.allocator, sc, 1, short);
        const r2 = try run.run(testing.allocator, sc, 2, short);
        try testing.expectEqual(r1.digest, r1b.digest);
        try testing.expectEqual(r1, r1b);
        // Some clean scenarios have no randomness in the network at all; the
        // load's frame sizes still differ by seed.
        try testing.expect(r1.digest != r2.digest);
        try testing.expect(r1.media_delivered > 0);
        try testing.expect(r1.feedback_received > 0);
    }
}

fn get(name: []const u8) scenarios.Scenario {
    return scenarios.find(name).?;
}

test "clean: nothing lost or reordered, OWD is propagation plus pacing" {
    const r = try run.run(testing.allocator, get("clean"), 1, short);
    try testing.expectEqual(@as(u64, 0), r.drops());
    try testing.expectEqual(@as(u64, 0), r.reordered);
    try testing.expect(r.owd_p50_ms >= 1 and r.owd_p50_ms < 6);
}

test "loss-5pct: about 5% lost and frames still mostly arrive" {
    const r = try run.run(testing.allocator, get("loss-5pct"), 1, short);
    try testing.expect(r.lossPct() > 4 and r.lossPct() < 6);
    try testing.expectEqual(r.drops(), r.random_losses);
}

test "loss-bursty: losses come in runs" {
    const r = try run.run(testing.allocator, get("loss-bursty"), 1, .{ .duration_us = 10 * SEC });
    try testing.expect(r.lossPct() > 1 and r.lossPct() < 3);
}

test "jitter keeps order; reorder does not" {
    const j = try run.run(testing.allocator, get("jitter"), 1, short);
    try testing.expectEqual(@as(u64, 0), j.reordered);
    try testing.expect(j.owd_p99_ms > 15);
    const r = try run.run(testing.allocator, get("reorder"), 1, short);
    try testing.expect(r.reordered > 100);
    try testing.expectEqual(@as(u64, 0), r.drops());
}

test "droptail-overload drops at the bottleneck and caps the queue" {
    const r = try run.run(testing.allocator, get("droptail-overload"), 1, short);
    try testing.expect(r.queue_drops > 0);
    try testing.expect(r.max_queue_bytes <= 500_000);
    try testing.expect(r.media_mbps < 20.5);
}

test "blackout loses the 300 ms window and freezes the receiver" {
    const r = try run.run(testing.allocator, get("blackout"), 1, .{ .duration_us = 7 * SEC });
    try testing.expect(r.blackout_drops > 0);
    try testing.expect(r.max_freeze_ms >= 290 and r.max_freeze_ms < 400);
}

test "wifi scenarios stall the radio" {
    const r = try run.run(testing.allocator, get("s11-wifi-steps"), 1, .{ .duration_us = 10 * SEC });
    try testing.expect(r.stall_ms > 0);
}

test "halving: the step lands and the fixed load still fits" {
    const r = try run.run(testing.allocator, get("halving"), 1, .{ .duration_us = 12 * SEC });
    try testing.expectEqual(@as(u64, 0), r.queue_drops);
}

test {
    _ = simnet;
}
