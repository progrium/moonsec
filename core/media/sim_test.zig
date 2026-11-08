//! End-to-end: packetizer -> lossy, reordering channel -> receiver, with NACKs going
//! back over a lossy channel to the host's retransmit history. Every delivered frame
//! must be bit-exact; with NACK on, every frame must arrive under the loss we expect
//! NACK to cover.
//!
//! The channel is a small seeded model kept here so core/media does not depend on the
//! sim harness (item D); scenarios can move onto transport/sim.zig once it lands.
const std = @import("std");
const media = @import("root.zig");
const proto = @import("../proto/root.zig");

const Loss = union(enum) {
    none,
    uniform: f64,
    /// Gilbert-Elliott: per-packet chance to enter / leave the bad state, loss in each.
    burst: struct { p_enter: f64, p_leave: f64, good: f64, bad: f64 },
};

const Link = struct {
    one_way_us: u64,
    jitter_us: u64 = 0,
    loss: Loss = .none,
};

const Scenario = struct {
    seed: u64,
    frames: u32 = 600,
    fps: u32 = 60,
    max_frame: usize = 120_000,
    forward: Link,
    backward: Link,
    nack: bool = true,
    frame_timeout_us: u64 = 100_000,
};

const Result = struct {
    delivered: u32 = 0,
    lost: u32 = 0,
    packets: u64 = 0,
    retransmits: u64 = 0,
    nack_msgs: u64 = 0,
};

const InFlight = struct { arrive_us: u64, order: u64, data: []u8 };

const Channel = struct {
    gpa: std.mem.Allocator,
    link: Link,
    rnd: std.Random,
    bad: bool = false,
    q: std.ArrayList(InFlight) = .empty,
    order: u64 = 0,

    fn deinit(c: *Channel) void {
        for (c.q.items) |p| c.gpa.free(p.data);
        c.q.deinit(c.gpa);
    }

    fn dropped(c: *Channel) bool {
        return switch (c.link.loss) {
            .none => false,
            .uniform => |p| c.rnd.float(f64) < p,
            .burst => |b| blk: {
                if (c.bad) {
                    if (c.rnd.float(f64) < b.p_leave) c.bad = false;
                } else if (c.rnd.float(f64) < b.p_enter) c.bad = true;
                break :blk c.rnd.float(f64) < (if (c.bad) b.bad else b.good);
            },
        };
    }

    fn send(c: *Channel, data: []const u8, now_us: u64, lossless: bool) !void {
        if (c.dropped() and !lossless) return;
        const jitter = if (c.link.jitter_us > 0) c.rnd.uintAtMost(u64, c.link.jitter_us) else 0;
        try c.q.append(c.gpa, .{ .arrive_us = now_us + c.link.one_way_us + jitter, .order = c.order, .data = try c.gpa.dupe(u8, data) });
        c.order += 1;
    }

    /// Pop the earliest packet due by `now_us` (ties in send order). Caller frees it.
    fn recv(c: *Channel, now_us: u64) ?[]u8 {
        var best: ?usize = null;
        for (c.q.items, 0..) |p, i| {
            if (p.arrive_us > now_us) continue;
            if (best == null or p.arrive_us < c.q.items[best.?].arrive_us or
                (p.arrive_us == c.q.items[best.?].arrive_us and p.order < c.q.items[best.?].order)) best = i;
        }
        return if (best) |i| c.q.swapRemove(i).data else null;
    }
};

fn run(gpa: std.mem.Allocator, sc: Scenario) !Result {
    var prng = std.Random.DefaultPrng.init(sc.seed);
    const rnd = prng.random();
    var fwd: Channel = .{ .gpa = gpa, .link = sc.forward, .rnd = rnd };
    defer fwd.deinit();
    var back: Channel = .{ .gpa = gpa, .link = sc.backward, .rnd = rnd };
    defer back.deinit();

    var pz: media.Packetizer = .{};
    var hist = try media.History.init(gpa, .{});
    defer hist.deinit(gpa);
    var rx = try media.Receiver.init(gpa, .{
        .reassembly = .{ .frame_timeout_us = sc.frame_timeout_us },
        .nack_enabled = sc.nack,
    });
    defer rx.deinit();

    const sent = try gpa.alloc(?[]u8, sc.frames);
    @memset(sent, null);
    defer {
        for (sent) |f| if (f) |b| gpa.free(b);
        gpa.free(sent);
    }
    const out = try gpa.alloc(u8, sc.max_frame);
    defer gpa.free(out);

    const rtt_us = sc.forward.one_way_us + sc.backward.one_way_us;
    const interval_us = 1_000_000 / sc.fps;
    const step_us = 250;
    // Channels are lossless until the first frame is out, so the receiver starts at frame 0.
    const warmup_us = sc.forward.one_way_us + sc.forward.jitter_us + 1_000;
    const end_us = @as(u64, sc.frames) * interval_us + sc.frame_timeout_us * 3;

    var res: Result = .{};
    var next_frame: u32 = 0;
    var pkt: [proto.max_datagram]u8 = undefined;
    var msg: [proto.max_datagram]u8 = undefined;
    var host_seq: u32 = 0; // transport-wide envelope seqs, one counter per direction
    var client_seq: u32 = 0;
    var now: u64 = 0;
    while (now <= end_us) : (now += step_us) {
        const lossless = now < warmup_us;
        // Host: encode a frame on schedule, in 1-4 slices, and send it.
        if (next_frame < sc.frames and now >= @as(u64, next_frame) * interval_us) {
            const size = rnd.intRangeAtMost(usize, 1, sc.max_frame);
            const data = try gpa.alloc(u8, size);
            rnd.bytes(data);
            sent[next_frame] = data;
            const slices = rnd.intRangeAtMost(u8, 1, 4);
            const cut = size / slices;
            for (0..slices) |s| {
                const lo = s * cut;
                const hi = if (s + 1 == slices) size else lo + cut;
                var it = try pz.slice(.{
                    .frame_id = next_frame,
                    .slice = @intCast(s),
                    .slice_count = slices,
                    .flags = .{ .keyframe = next_frame == 0 },
                    .capture_us = now,
                    .encode_done_us = now + 3_000,
                }, data[lo..hi]);
                while (it.next()) |shard| {
                    hist.record(shard, now);
                    try fwd.send(try proto.encodeVideoShard(&pkt, host_seq, shard.header, shard.payload), now, lossless);
                    host_seq +%= 1;
                    res.packets += 1;
                }
            }
            next_frame += 1;
        }
        // Host: answer NACKs.
        while (back.recv(now)) |m| {
            defer gpa.free(m);
            var it = (try media.nack.parse(try proto.decode(m))).?;
            while (it.next()) |seq| if (hist.resend(seq, now)) |shard| {
                try fwd.send(try proto.encodeVideoShard(&pkt, host_seq, shard.header, shard.payload), now, lossless);
                host_seq +%= 1;
                res.retransmits += 1;
            };
        }
        // Client: receive, deliver in order, check every byte.
        while (fwd.recv(now)) |p| {
            defer gpa.free(p);
            const v = (try proto.decode(p)).video_shard;
            const r = rx.onShard(v.header, v.payload, now);
            try std.testing.expect(r != .rejected and r != .out_of_memory);
        }
        while (rx.poll(now)) |ev| switch (ev) {
            .frame => |f| {
                try std.testing.expectEqual(res.delivered + res.lost, f.id);
                const want = sent[f.id].?;
                try std.testing.expectEqual(want.len, f.len);
                try std.testing.expectEqualSlices(u8, want, f.copyTo(out));
                try std.testing.expectEqual(f.id == 0, f.meta.flags.keyframe);
                try std.testing.expect(!f.meta.flags.retransmit);
                gpa.free(want);
                sent[f.id] = null;
                res.delivered += 1;
            },
            .lost => |l| {
                try std.testing.expectEqual(res.delivered + res.lost, l.id);
                res.lost += 1;
            },
        };
        if (try rx.nacks(now, rtt_us, client_seq, &msg)) |m| {
            client_seq +%= 1;
            try back.send(m, now, lossless);
            res.nack_msgs += 1;
        }
    }
    // Every frame is accounted for, in order.
    try std.testing.expectEqual(sc.frames, res.delivered + res.lost);
    return res;
}

/// Set to print each scenario's counts (kept off so test output stays clean).
const verbose = false;

fn report(name: []const u8, sc: Scenario, r: Result) void {
    if (!verbose) return;
    std.debug.print("{s} seed={d}: {d}/{d} frames delivered, {d} lost, {d} packets, {d} retransmits, {d} NACK msgs\n", .{
        name, sc.seed, r.delivered, sc.frames, r.lost, r.packets, r.retransmits, r.nack_msgs,
    });
}

test "clean link: every frame, no NACKs" {
    const sc: Scenario = .{ .seed = 1, .frames = 120, .forward = .{ .one_way_us = 5_000 }, .backward = .{ .one_way_us = 5_000 } };
    const r = try run(std.testing.allocator, sc);
    try std.testing.expectEqual(sc.frames, r.delivered);
    try std.testing.expectEqual(@as(u64, 0), r.nack_msgs);
}

test "reordering only: every frame" {
    for (1..4) |seed| {
        const sc: Scenario = .{ .seed = seed, .frames = 240, .forward = .{ .one_way_us = 5_000, .jitter_us = 4_000 }, .backward = .{ .one_way_us = 5_000 } };
        const r = try run(std.testing.allocator, sc);
        report("reorder", sc, r);
        try std.testing.expectEqual(sc.frames, r.delivered);
    }
}

test "5% loss both ways with reordering: NACK recovers every frame" {
    for (1..4) |seed| {
        const sc: Scenario = .{
            .seed = seed,
            .forward = .{ .one_way_us = 5_000, .jitter_us = 2_000, .loss = .{ .uniform = 0.05 } },
            .backward = .{ .one_way_us = 5_000, .jitter_us = 2_000, .loss = .{ .uniform = 0.05 } },
        };
        const r = try run(std.testing.allocator, sc);
        report("loss5", sc, r);
        try std.testing.expectEqual(sc.frames, r.delivered);
        try std.testing.expect(r.retransmits > 0);
    }
}

test "without NACK the same loss drops frames" {
    const sc: Scenario = .{
        .seed = 1,
        .frames = 120,
        .forward = .{ .one_way_us = 5_000, .jitter_us = 2_000, .loss = .{ .uniform = 0.05 } },
        .backward = .{ .one_way_us = 5_000 },
        .nack = false,
    };
    const r = try run(std.testing.allocator, sc);
    try std.testing.expect(r.lost > sc.frames / 2);
    try std.testing.expectEqual(@as(u64, 0), r.retransmits);
}

test "bursty loss: delivered frames stay bit-exact, most survive" {
    for (1..4) |seed| {
        const sc: Scenario = .{
            .seed = seed,
            .forward = .{ .one_way_us = 10_000, .jitter_us = 3_000, .loss = .{ .burst = .{ .p_enter = 0.005, .p_leave = 0.2, .good = 0.01, .bad = 0.6 } } },
            .backward = .{ .one_way_us = 10_000, .loss = .{ .uniform = 0.02 } },
        };
        const r = try run(std.testing.allocator, sc);
        report("burst", sc, r);
        try std.testing.expect(r.delivered * 100 >= sc.frames * 98);
    }
}

test "long RTT beyond the frame timeout loses frames but never corrupts them" {
    const sc: Scenario = .{
        .seed = 7,
        .frames = 120,
        .forward = .{ .one_way_us = 60_000, .loss = .{ .uniform = 0.05 } },
        .backward = .{ .one_way_us = 60_000 },
        .frame_timeout_us = 50_000,
    };
    const r = try run(std.testing.allocator, sc);
    report("longrtt", sc, r);
    try std.testing.expect(r.lost > 0);
}

test "media_seq and frame_id wrap" {
    // Start both counters just below the wrap point and drop one shard per frame.
    const gpa = std.testing.allocator;
    var pz: media.Packetizer = .{ .next_seq = 0xffffffff - 3 };
    var hist = try media.History.init(gpa, .{ .capacity = 64 });
    defer hist.deinit(gpa);
    var rx = try media.Receiver.init(gpa, .{ .nack = .{ .reorder_wait_us = 0 } });
    defer rx.deinit();
    var data: [5000]u8 = undefined;
    var out: [5000]u8 = undefined;
    var msg: [256]u8 = undefined;
    var id: u32 = 0xffffffff - 1;
    for (0..4) |i| {
        for (&data, 0..) |*b, j| b.* = @truncate(j *% (i + 3));
        var it = try pz.slice(.{ .frame_id = id, .slice = 0, .slice_count = 1 }, &data);
        var k: usize = 0;
        while (it.next()) |s| : (k += 1) {
            hist.record(s, 0);
            if (k != 2) _ = rx.onShard(s.header, s.payload, 0);
        }
        if (try rx.nacks(0, 0, 0, &msg)) |m| {
            var nit = (try media.nack.parse(try proto.decode(m))).?;
            while (nit.next()) |seq| {
                const s = hist.resend(seq, 0).?;
                try std.testing.expectEqual(media.reassembly.PushResult.stored, rx.onShard(s.header, s.payload, 0));
            }
        }
        id +%= 1;
    }
    var expect_id: u32 = 0xffffffff - 1;
    while (rx.poll(0)) |ev| : (expect_id +%= 1) {
        try std.testing.expectEqual(expect_id, ev.frame.id);
        try std.testing.expectEqual(data.len, ev.frame.copyTo(&out).len);
    }
    try std.testing.expectEqual(@as(u32, 2), expect_id);
}
