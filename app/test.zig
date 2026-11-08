//! The apps end to end over the in-process sim, in virtual time.
const std = @import("std");
const simrun = @import("simrun.zig");

test {
    _ = @import("wire.zig");
    _ = @import("keystore.zig");
    _ = @import("pairing.zig");
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

/// The run's report, printed when a check fails (the build runner fails a test that
/// writes to stderr otherwise).
fn printPath(r: simrun.Result) void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    r.print(&w) catch {};
    std.debug.print("{s}  host: path changes {d}, reconnects {d}, stall pauses {d} ({d} frames held); client: path changes {d}, reconnects {d} (asked {d})\n", .{ w.buffered(), r.host.path_changes, r.host.reconnects, r.host.stall_pauses, r.host.stall_frames, r.client.path_changes, r.client.reconnects, r.client.reconnect_requests });
}

fn runPath(o: simrun.Options) !simrun.Result {
    const r = try simrun.run(std.testing.allocator, o, null);
    errdefer printPath(r);
    try std.testing.expectEqual(@as(u64, 0), r.client.corrupt);
    try std.testing.expectEqual(@as(u64, 0), r.client.unreadable);
    // Keys older than the sender's 500 ms redundancy window are dropped by design, which
    // the synthetic injector's script check reads as out of order: only check without drops.
    if (o.path.?.drops.len == 0) try std.testing.expectEqual(@as(u64, 0), r.host.keys_wrong);
    try std.testing.expectEqualStrings("client_bye", r.host.end);
    try std.testing.expectEqualStrings("closed", r.client.end);
    return r;
}

test "an outage under the idle timeout holds video on the stall and resumes with a refresh" {
    // 1 s idle timeout: a 500 ms outage does not close the direct path.
    const r = try runPath(.{ .seed = 2, .profile = .lan, .seconds = 4, .path = .{ .idle_us = 1_000_000, .flaps = &.{.{ .at_us = 2_000_000, .outage_us = 500_000 }} } });
    errdefer printPath(r);
    try std.testing.expectEqual(@as(u64, 0), r.host.path_changes);
    try std.testing.expectEqual(@as(u64, 1), r.host.stall_pauses);
    // Held from 150 ms into the outage to its end: about 21 frames at 60 fps.
    try std.testing.expect(r.host.stall_frames >= 18 and r.host.stall_frames <= 24);
    try std.testing.expect(r.host.refreshes + r.host.keyframes >= 2);
    try std.testing.expect(r.client.longest_gap_us < 650_000);
    try std.testing.expect(r.client.presented > 3 * 60);
}

test "an outage over the idle timeout moves to the relay and back to the direct path" {
    const r = try runPath(.{ .seed = 3, .profile = .lan, .seconds = 6, .path = .{ .idle_us = 300_000, .flaps = &.{.{ .at_us = 2_000_000, .outage_us = 1_500_000 }} } });
    errdefer printPath(r);
    // direct -> relay at 300 ms, relay -> direct 500 ms after the outage.
    try std.testing.expectEqual(@as(u64, 2), r.host.path_changes);
    try std.testing.expectEqual(@as(u64, 2), r.client.path_changes);
    try std.testing.expectEqual(@as(u64, 1), r.host.stall_pauses);
    // The gap is about the idle timeout, not the outage: the relay carries the stream.
    try std.testing.expect(r.client.longest_gap_us < 500_000);
    try std.testing.expectEqual(@as(u64, 0), r.client.reconnect_requests);
    try std.testing.expect(r.client.presented > 5 * 60);
}

test "path flaps: five outages a second and a half apart" {
    var flaps: [5]simrun.pathsim.Outage = undefined;
    for (&flaps, 0..) |*f, i| f.* = .{ .at_us = 1_500_000 + @as(i64, @intCast(i)) * 1_500_000, .outage_us = 400_000 + @as(i64, @intCast(i % 2)) * 400_000 };
    const r = try runPath(.{ .seed = 4, .profile = .wan, .seconds = 10, .path = .{ .idle_us = 300_000, .repunch_us = 300_000, .flaps = &flaps } });
    errdefer printPath(r);
    try std.testing.expectEqual(@as(u64, 10), r.host.path_changes);
    try std.testing.expectEqual(@as(u64, 5), r.host.stall_pauses);
    try std.testing.expect(r.client.longest_gap_us < 600_000);
    try std.testing.expect(r.client.presented > 8 * 60);
}

test "a dropped connection: the client redials and the session carries on" {
    // Dead for 1 s; the client asks for a new connection after 2 s of silence, and the
    // new one is up 300 ms later.
    const r = try runPath(.{ .seed = 5, .profile = .lan, .seconds = 8, .path = .{ .drops = &.{.{ .at_us = 2_000_000, .outage_us = 1_000_000 }} } });
    errdefer printPath(r);
    try std.testing.expectEqual(@as(u64, 1), r.client.reconnects);
    try std.testing.expectEqual(@as(u64, 1), r.host.reconnects);
    try std.testing.expect(r.client.reconnect_requests >= 1);
    try std.testing.expect(r.client.longest_gap_us > 2_000_000 and r.client.longest_gap_us < 2_800_000);
    try std.testing.expect(r.client.presented > 5 * 60);
}

test "a drop longer than the 5 s peer timeout still reconnects" {
    const r = try runPath(.{ .seed = 6, .profile = .clean, .seconds = 12, .path = .{ .drops = &.{.{ .at_us = 2_000_000, .outage_us = 7_000_000 }} } });
    errdefer printPath(r);
    try std.testing.expectEqual(@as(u64, 1), r.client.reconnects);
    // Asked every 2 s while silent.
    try std.testing.expect(r.client.reconnect_requests >= 3);
    try std.testing.expect(r.client.presented > 4 * 60);
}
