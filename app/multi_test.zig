//! Multi-user sessions end to end over the in-process sim (app/multisim.zig).
const std = @import("std");
const multisim = @import("multisim.zig");

const testing = std.testing;

fn runShow(o: multisim.Options) !multisim.Result {
    return multisim.run(testing.allocator, o, null);
}

fn show(r: *const multisim.Result) void {
    var buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    r.print(&w) catch {};
    std.debug.print("{s}", .{w.buffered()});
}

test "two clients on a LAN: one encode, both see it, only the owner types" {
    const r = try runShow(.{ .seed = 1, .seconds = 3, .clients = &.{ .{ .name = "Alice" }, .{ .name = "Bob" } } });
    errdefer show(&r);
    // The first frame, and an IDR for whichever client's hello came second (it has no
    // reference to refresh from).
    try testing.expect(r.host.keyframes <= 2);
    try testing.expectEqual(@as(u64, 0), r.host.refreshes);
    for (r.clients[0..2]) |c| {
        try testing.expect(c.presented * 100 >= 3 * 60 * 95);
        try testing.expectEqual(@as(u64, 0), c.freezes);
        try testing.expectEqual(@as(u64, 0), c.corrupt);
        try testing.expectEqual(@as(u64, 0), c.unreadable);
        try testing.expectEqualStrings("closed", c.end);
        try testing.expectEqual(@as(u8, 2), c.members_seen);
    }
    try testing.expect(r.clients[0].have_input and !r.clients[1].have_input);
    try testing.expectEqualStrings("2 here  input: Alice (you)", r.clients[0].presenceText());
    try testing.expectEqualStrings("2 here  input: Alice", r.clients[1].presenceText());
    // Alice's keys arrive in order; Bob's are acked and dropped.
    try testing.expectEqual(@as(u64, 0), r.host.keys_wrong);
    try testing.expect(r.host.keys * 100 >= r.clients[0].input_sent * 95);
    try testing.expect(r.host.inputs_dropped > 0);
}

/// A client on a good path: no freeze, (almost) every frame, nothing corrupt, and no gap
/// longer than `max_gap_us` (one lost frame's recovery takes the frame timeout plus an RTT).
fn expectCleanGap(c: *const multisim.ClientResult, seconds: u32, max_gap_us: i64) !void {
    try testing.expectEqual(@as(u64, 0), c.freezes);
    try testing.expect(c.presented * 100 >= @as(u64, seconds) * 60 * 95);
    try testing.expectEqual(@as(u64, 0), c.corrupt);
    try testing.expectEqual(@as(u64, 0), c.unreadable);
    try testing.expect(c.longest_gap_us < max_gap_us);
}

fn expectClean(c: *const multisim.ClientResult, seconds: u32) !void {
    return expectCleanGap(c, seconds, 100_000);
}

test "four clients, one lossy and one relayed: the lossy one does not freeze the others" {
    for (1..3) |seed| {
        const r = try runShow(.{
            .seed = seed,
            .seconds = 6,
            .loss_policy = true,
            .clients = &.{
                .{ .name = "LAN 1" },
                .{ .name = "LAN 2" },
                // 120 ms RTT with 5% loss: NACK cannot help, so it loses frames and asks for
                // recovery frames all the time.
                .{ .name = "Lossy", .profile = .longhaul },
                .{ .name = "Relayed", .relayed = true },
            },
        });
        errdefer show(&r);
        try expectClean(&r.clients[0], 6);
        try expectClean(&r.clients[1], 6);
        // 50 ms RTT through the relay: a frame it loses takes ~190 ms to repair.
        try expectCleanGap(&r.clients[3], 6, 250_000);
        // The lossy client freezes now and then, and recovers: FEC (the loss policy) for
        // most losses, LTR refreshes for the rest.
        const lossy = r.clients[2];
        try testing.expect(lossy.parity_shards > 0);
        // Same bar as the single-client long-haul test: under the 500 ms freeze gate.
        try testing.expect(lossy.longest_gap_us < 500_000);
        try testing.expect(lossy.presented * 100 >= 6 * 60 * 60);
        try testing.expectEqual(@as(u64, 0), lossy.corrupt);
        // Recovery frames are LTR refreshes every member decodes; the only IDRs are the
        // joins (each client whose hello came after the first frame).
        try testing.expect(r.host.refreshes > 0);
        try testing.expect(r.host.keyframes <= 4);
        try testing.expect(r.host.acks_held > 0);
        try testing.expectEqualStrings("4 here  input: LAN 1", r.clients[3].presenceText());
    }
}

test "without the ack intersection a refresh can reference a frame the lossy client lost" {
    var corrupt: u64 = 0;
    for (1..4) |seed| {
        const r = try runShow(.{ .seed = seed, .seconds = 6, .intersect_acks = false, .clients = &.{
            .{ .name = "LAN" },
            .{ .name = "Lossy", .profile = .longhaul },
        } });
        corrupt += r.clients[1].missing_ref;
        // The LAN client is never hurt: every refresh references something it acked.
        try testing.expectEqual(@as(u64, 0), r.clients[0].corrupt);
    }
    try testing.expect(corrupt > 0);
}

test "a late joiner gets an IDR, a leaver releases the acks it held back" {
    const r = try runShow(.{ .seed = 3, .seconds = 5, .clients = &.{
        .{ .name = "First" },
        .{ .name = "Late", .join_at_us = 2_000_000 },
        .{ .name = "Gone", .profile = .longhaul, .leave_at_us = 1_500_000 },
    } });
    errdefer show(&r);
    try expectClean(&r.clients[0], 5);
    try testing.expectEqual(@as(u64, 0), r.clients[1].corrupt);
    try testing.expect(r.clients[1].presented * 100 >= 3 * 60 * 95);
    try testing.expectEqualStrings("closed", r.clients[2].end);
    try testing.expectEqual(@as(u64, 3), r.host.joins);
    try testing.expectEqual(@as(u64, 3), r.host.leaves);
    // The late joiner's view: two members (the leaver was gone before it joined).
    try testing.expectEqual(@as(u8, 2), r.clients[1].members_seen);
    try testing.expectEqual(@as(u8, 2), r.clients[0].members_seen);
    try testing.expect(r.host.keyframes >= 2 and r.host.keyframes <= 4);
}

test "input handoff: a guest asks, the owner gives, held keys are released" {
    const r = try runShow(.{
        .seed = 4,
        .seconds = 4,
        .clients = &.{
            .{ .name = "Owner" },
            .{ .name = "Guest" },
            .{ .name = "Viewer", .may_control = false },
        },
        .events = &.{
            .{ .request = .{ .at_us = 1_000_000, .client = 1 } },
            .{ .give = .{ .at_us = 2_000_013, .from = 0, .to = 1 } },
            // The viewer cannot be given input: refused, the guest keeps it.
            .{ .give = .{ .at_us = 3_000_000, .from = 1, .to = 2 } },
        },
    });
    errdefer show(&r);
    try testing.expect(!r.clients[0].have_input);
    try testing.expect(r.clients[1].have_input);
    try testing.expect(!r.clients[2].have_input);
    try testing.expectEqualStrings("3 here  input: Guest (you)", r.clients[1].presenceText());
    // Two seconds each of the owner's and the guest's keys; the viewer's are all dropped.
    try testing.expect(r.host.keys > 120);
    try testing.expect(r.host.inputs_dropped >= r.clients[2].input_sent);
    // The handoff at 2.000013 s lands between a press and its release (every 25 ms).
    try testing.expect(r.host.releases >= 1);
}

test "the host takes input back; view_only and everyone policies" {
    const r = try runShow(.{ .seed = 5, .seconds = 2, .clients = &.{ .{ .name = "A" }, .{ .name = "B" } }, .events = &.{.{ .host_take = .{ .at_us = 1_000_000 } }} });
    errdefer show(&r);
    try testing.expect(!r.clients[0].have_input and !r.clients[1].have_input);
    try testing.expectEqualStrings("2 here  input: host", r.clients[0].presenceText());

    const v = try runShow(.{ .seed = 5, .seconds = 2, .roster = .{ .policy = .view_only }, .clients = &.{ .{ .name = "A" }, .{ .name = "B" } } });
    try testing.expectEqual(@as(u64, 0), v.host.keys);
    try testing.expectEqualStrings("2 here  view only", v.clients[0].presenceText());

    const e = try runShow(.{ .seed = 5, .seconds = 2, .roster = .{ .policy = .everyone }, .clients = &.{ .{ .name = "A" }, .{ .name = "B" } } });
    try testing.expect(e.clients[0].have_input and e.clients[1].have_input);
    try testing.expectEqual(@as(u64, 0), e.host.inputs_dropped);
}

test "shared rate: the lowest rule follows the slowest client, a floor stops it" {
    const clients = [_]multisim.ClientSpec{ .{ .name = "Fast" }, .{ .name = "Slow", .bps = 5e6 } };
    const lo = try runShow(.{ .seed = 6, .seconds = 8, .rate_control = true, .bitrate_bps = 2_000_000, .clients = &clients });
    errdefer show(&lo);
    try testing.expect(lo.host.bitrate_bps < 5_000_000);
    try expectClean(&lo.clients[0], 8);
    const fl = try runShow(.{ .seed = 6, .seconds = 8, .rate_control = true, .bitrate_bps = 2_000_000, .rate = .{ .floor_bps = 6_000_000 }, .clients = &clients });
    try testing.expect(fl.host.bitrate_bps >= 6_000_000);
}

test "an older client without the multi-user feature still streams, with no roster" {
    const r = try runShow(.{ .seed = 7, .seconds = 2, .clients = &.{ .{ .name = "New" }, .{ .name = "Old", .multi_user = false } } });
    errdefer show(&r);
    try testing.expectEqual(@as(u64, 0), r.clients[1].rosters);
    try testing.expect(r.clients[0].rosters > 0);
    try testing.expect(r.clients[1].presented * 100 >= 2 * 60 * 95);
}
