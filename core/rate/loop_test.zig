//! Closed-loop sanity tests: the controller driving a paced 60 fps sender
//! through one wired droptail bottleneck. The full scenario matrix lives in
//! the sim harness; these only pin the behaviours S11 relies on.
const std = @import("std");
const Controller = @import("controller.zig").Controller;
const Config = @import("controller.zig").Config;
const Arrival = @import("history.zig").Arrival;

const Link = struct {
    /// (time_us, bps) capacity steps.
    steps: []const [2]f64,
    one_way_us: i64 = 10_000,
    qlimit: u32 = 500_000,
    clock_offset: i64 = 987_000_000,

    fn cap(l: Link, t: i64) f64 {
        var c = l.steps[0][1];
        for (l.steps) |s| if (@as(f64, @floatFromInt(t)) >= s[0]) {
            c = s[1];
        };
        return c;
    }
};

const Sample = struct { t: i64, target: f64, pacing: f64, queue_us: i64 };

/// Runs `dur_us` and records one sample per 100 ms.
fn run(gpa: std.mem.Allocator, link: Link, cfg: Config, dur_us: i64, samples: *std.ArrayList(Sample)) !void {
    const c = try gpa.create(Controller);
    defer gpa.destroy(c);
    c.reset(cfg);

    var rng = std.Random.DefaultPrng.init(1);
    const r = rng.random();
    // in-flight: arrival records waiting for the next feedback
    var pending: std.ArrayList(Arrival) = .empty;
    defer pending.deinit(gpa);
    // bottleneck queue: departure times and sizes of queued packets
    var q_dep: std.ArrayList(struct { dep: i64, size: u32 }) = .empty;
    defer q_dep.deinit(gpa);
    var q_head: usize = 0;
    var q_bytes: u32 = 0;
    var last_dep: i64 = 0;

    var seq: u64 = 0;
    var frame: u32 = 0;
    var pacer_next: i64 = 0;
    var next_fb: i64 = 5_000;
    var next_sample: i64 = 0;
    var t: i64 = 0;
    var last_queue: i64 = 0;
    // Feedback batches in flight on the reverse path: (arrive_at, batch).
    var fb_q: std.ArrayList(struct { at: i64, items: []Arrival }) = .empty;
    defer {
        for (fb_q.items) |b| gpa.free(b.items);
        fb_q.deinit(gpa);
    }

    while (t < dur_us) : (t += 16_667) {
        // Feedback that has reached the sender by the frame time.
        while (fb_q.items.len > 0 and fb_q.items[0].at <= t) {
            const b = fb_q.orderedRemove(0);
            c.onArrivals(b.at, b.items);
            gpa.free(b.items);
        }
        while (next_sample <= t) : (next_sample += 100_000) {
            try samples.append(gpa, .{ .t = next_sample, .target = c.targetBps(), .pacing = c.pacingBps(), .queue_us = last_queue });
        }
        // One frame: lognormal size, 4x scene change every 3 s.
        var bytes = c.encoderBps() / 8.0 / 60.0 * @exp(0.25 * r.floatNorm(f64) - 0.03);
        if (frame % 180 == 0 and frame > 0) bytes *= 4;
        const n: u32 = @max(1, @as(u32, @intFromFloat(@ceil(bytes / 1200))));
        var left: u32 = @intFromFloat(@max(bytes, 100));
        const pace = c.pacingBps();
        for (0..n) |k| {
            const sz: u32 = if (k + 1 == n) @max(left, 100) else 1200;
            left -|= sz;
            const send = @max(t, pacer_next);
            pacer_next = @max(pacer_next, send - 2_000) + @as(i64, @intFromFloat(@as(f64, @floatFromInt(sz)) * 8e6 / pace));
            c.onSent(seq, send, sz, frame, k + 1 == n);
            // bottleneck
            const arr_q = send + @divTrunc(link.one_way_us, 2);
            while (q_head < q_dep.items.len and q_dep.items[q_head].dep <= arr_q) : (q_head += 1) q_bytes -= q_dep.items[q_head].size;
            var recv: i64 = -1;
            if (q_bytes + sz <= link.qlimit) {
                const dep = @max(arr_q, last_dep) + @as(i64, @intFromFloat(@as(f64, @floatFromInt(sz)) * 8e6 / link.cap(arr_q)));
                last_dep = dep;
                try q_dep.append(gpa, .{ .dep = dep, .size = sz });
                q_bytes += sz;
                recv = dep + @divTrunc(link.one_way_us, 2);
                last_queue = dep - arr_q;
            }
            // feedback: the receiver batches every 5 ms of its own clock
            while (recv >= 0 and recv >= next_fb) {
                if (pending.items.len > 0) {
                    try fb_q.append(gpa, .{ .at = next_fb + link.one_way_us, .items = try gpa.dupe(Arrival, pending.items) });
                    pending.clearRetainingCapacity();
                }
                next_fb += 5_000;
            }
            try pending.append(gpa, .{ .seq = seq, .recv_us = if (recv >= 0) recv + link.clock_offset else -1 });
            seq += 1;
        }
        frame += 1;
    }
}

fn at(samples: []const Sample, t: i64) Sample {
    return samples[@intCast(@divTrunc(t, 100_000))];
}

test "ramps to the link, reacts to a drop and drains the queue" {
    const gpa = std.testing.allocator;
    var s: std.ArrayList(Sample) = .empty;
    defer s.deinit(gpa);
    const link = Link{ .steps = &.{ .{ 0, 50e6 }, .{ 10e6, 20e6 } } };
    try run(gpa, link, .{}, 16_000_000, &s);

    // Startup: 80% of 50 Mbit/s within 2 s (S11 wired: 1.6 s), with stock
    // GCC's 8%/s ramp that would take over 20 s.
    try std.testing.expect(at(s.items, 2_000_000).target > 0.8 * 50e6 * 0.85);
    // Steady state below the link.
    const steady = at(s.items, 9_000_000).target;
    try std.testing.expect(steady > 0.7 * 50e6 and steady < 50e6);
    // Pacing follows the train estimate, i.e. the link.
    try std.testing.expectApproxEqRel(@as(f64, 50e6), at(s.items, 9_000_000).pacing, 0.05);
    // Under the new capacity within 500 ms of the drop.
    try std.testing.expect(at(s.items, 10_500_000).target < 20e6);
    // Queue drained (< 20 ms) within 1.5 s.
    var t: i64 = 11_500_000;
    while (t < 16_000_000) : (t += 100_000) try std.testing.expect(at(s.items, t).queue_us < 20_000);
}

test "app_share scales the encoder rate without spiralling down" {
    const gpa = std.testing.allocator;
    var s: std.ArrayList(Sample) = .empty;
    defer s.deinit(gpa);
    const link = Link{ .steps = &.{.{ 0, 50e6 }} };
    try run(gpa, link, .{ .app_share = 0.6 }, 10_000_000, &s);
    // Target still tracks the link though the encoder sends 60% of it.
    const tgt = at(s.items, 9_000_000).target;
    try std.testing.expect(tgt > 0.7 * 50e6);
}

test "proto feedback message drives the controller" {
    const proto = @import("../proto/root.zig");
    const gpa = std.testing.allocator;
    const c = try gpa.create(Controller);
    defer gpa.destroy(c);
    c.reset(.{});
    // 4 packets of one frame; the third is lost.
    for (0..4) |i| c.onSent(i, @intCast(i * 100), 1200, 0, i == 3);
    const arrivals = [_]?u64{ 1_000_000, 1_000_400, null, 1_001_200 };
    var buf: [64]u8 = undefined;
    var e = proto.wire.Encoder.init(&buf);
    try (proto.Feedback{ .feedback_seq = 0, .base_seq = 0, .ref_time_us = 1_000_000, .arrivals = &arrivals }).encode(&e);
    var d = proto.wire.Decoder.init(e.written());
    c.onFeedbackMsg(50_000, try proto.Feedback.decode(&d));
    try std.testing.expectEqual(@as(u64, 4), c.history.next_expected);
    try std.testing.expectEqual(@as(u32, 1), c.gcc.win_lost);
    try std.testing.expectEqual(@as(u32, 4), c.gcc.win_sent);
}
