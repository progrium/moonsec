//! The apps end to end over the in-process sim, in virtual time.
const std = @import("std");
const simrun = @import("simrun.zig");

test {
    _ = @import("wire.zig");
}

fn expectPass(o: simrun.Options) !simrun.Result {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const r = try simrun.run(std.testing.allocator, o, null);
    if (r.failure(o)) |why| {
        try r.print(&w);
        std.debug.print("seed {d} {s}: {s}\n{s}", .{ o.seed, @tagName(o.profile), why, w.buffered() });
        return error.RunFailed;
    }
    return r;
}

test "stream over a clean sim path" {
    const r = try expectPass(.{ .profile = .clean, .seconds = 3 });
    try std.testing.expectEqual(@as(u64, 1), r.host.keyframes);
    try std.testing.expectEqual(@as(u64, 0), r.client.lost);
    // 1 ms each way plus encode/decode in zero virtual time: under 5 ms.
    try std.testing.expect(r.client.total_p99_us < 5_000);
    // Audio: every frame decoded and the sink never ran dry; at most the slot after the
    // host's last frame, as the client closes, is concealed.
    try std.testing.expect(r.client.audio.concealed <= 1);
    try std.testing.expectEqual(@as(u64, 0), r.client.audio.underruns);
    try std.testing.expect(r.client.audio.decoded >= 290);
}

test "stream over the LAN profile recovers every loss with NACKs" {
    for (1..3) |seed| {
        const r = try expectPass(.{ .seed = seed, .profile = .lan, .seconds = 5 });
        try std.testing.expect(r.host.retransmits > 0);
        try std.testing.expect(r.sim_losses > 0);
    }
}

test "stream over the lossy WAN profile" {
    const r = try expectPass(.{ .seed = 7, .profile = .wan, .seconds = 5 });
    try std.testing.expect(r.host.retransmits > 0);
}

test "loss policy: NACK on the LAN, no parity" {
    const r = try expectPass(.{ .seed = 2, .profile = .lan, .seconds = 4, .loss_policy = true });
    try std.testing.expectEqual(@as(u64, 0), r.host.parity_shards);
    try std.testing.expect(r.host.retransmits > 0);
}

test "loss policy: FEC on the WAN profile" {
    const r = try expectPass(.{ .seed = 7, .profile = .wan, .seconds = 5, .loss_policy = true });
    try std.testing.expect(r.host.parity_shards > 0);
    // Small groups (a ~5-shard slice at this bitrate) round up to more than 30%.
    try std.testing.expect(r.host.parity_shards * 100 <= (r.host.shards - r.host.parity_shards) * 45);
}

test "loss policy: FEC keeps a 120 ms RTT, 5% loss path under the 500 ms freeze gate" {
    // NACK cannot help here (a retransmit lands after the 100 ms frame timeout), so
    // without the policy nearly every frame is lost. With it, what is left is groups that
    // lost more than their parity: at this bitrate a slice is ~5 shards, so a group gets
    // 2 parity shards and ~1.5% of frames still need an LTR refresh, an RTT of freeze.
    for (1..3) |seed| {
        const r = try simrun.run(std.testing.allocator, .{ .seed = seed, .profile = .longhaul, .seconds = 6, .loss_policy = true }, null);
        try std.testing.expect(r.host.parity_shards > 0);
        try std.testing.expectEqual(@as(u64, 0), r.host.retransmits);
        try std.testing.expect(r.client.longest_gap_us < 500_000);
        try std.testing.expect(r.client.presented * 100 >= r.expectedFrames(60) * 70);
        try std.testing.expectEqual(@as(u64, 0), r.client.corrupt);
        try std.testing.expectEqual(@as(u64, 0), r.client.unreadable);
    }
    const r = try simrun.run(std.testing.allocator, .{ .seed = 1, .profile = .longhaul, .seconds = 6 }, null);
    try std.testing.expect(r.client.presented * 100 < r.expectedFrames(60) * 25);
}

test "runs are deterministic" {
    const a = try simrun.run(std.testing.allocator, .{ .seed = 5, .seconds = 2 }, null);
    const b = try simrun.run(std.testing.allocator, .{ .seed = 5, .seconds = 2 }, null);
    try std.testing.expectEqual(a.host.retransmits, b.host.retransmits);
    try std.testing.expectEqual(a.client.presented, b.client.presented);
    try std.testing.expectEqual(a.client.total_p99_us, b.client.total_p99_us);
}

test "an outage loses frames and recovery brings the picture back" {
    const o: simrun.Options = .{ .seed = 3, .profile = .lan, .seconds = 4, .outage_at_us = 2_000_000, .outage_us = 400_000 };
    const r = try simrun.run(std.testing.allocator, o, null);
    // The outage is a freeze by definition; after it the stream resumes from an LTR refresh.
    try std.testing.expectEqual(@as(u64, 1), r.client.freezes);
    try std.testing.expect(r.client.lost > 0);
    try std.testing.expect(r.host.refreshes + r.host.keyframes > 1);
    try std.testing.expect(r.client.longest_gap_us < 700_000);
    try std.testing.expect(r.client.presented > 3 * 60);
    try std.testing.expectEqual(@as(u64, 0), r.client.corrupt);
    try std.testing.expectEqual(@as(u64, 0), r.client.unreadable);
    // Audio conceals through the outage and plays on: the sink never runs dry.
    try std.testing.expect(r.client.audio.concealed > 0);
    try std.testing.expectEqual(@as(u64, 0), r.client.audio.underruns);
    try std.testing.expect(r.client.audio.decoded > 300);
}
