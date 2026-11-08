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
}
