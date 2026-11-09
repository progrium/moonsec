//! The apps end to end over the in-process sim, in virtual time.
const std = @import("std");
const simrun = @import("simrun.zig");

test {
    _ = @import("wire.zig");
    _ = @import("host_session.zig");
    _ = @import("keystore.zig");
    _ = @import("pairing.zig");
    _ = @import("multi_test.zig");
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

test "clipboard sync over the control channel: both ways, no echo, start content kept" {
    var cs: simrun.ClipScript = .{
        .host_start = "host had this",
        .client_start = "client had this",
        .copies = &.{
            .{ .at_us = 500_000, .client = true, .text = "copied on the client" },
            .{ .at_us = 1_000_000, .client = false, .text = "copied on the host ✓" },
        },
    };
    _ = try expectPass(.{ .seed = 1, .profile = .lan, .seconds = 2, .clipboard = &cs });
    try std.testing.expectEqualStrings("copied on the host ✓", cs.host());
    try std.testing.expectEqualStrings("copied on the host ✓", cs.client());
    try std.testing.expectEqual(@as(u64, 1), cs.host_sent);
    try std.testing.expectEqual(@as(u64, 1), cs.client_sent);
    try std.testing.expectEqual(@as(u64, 1), cs.host_writes);
    try std.testing.expectEqual(@as(u64, 1), cs.client_writes);
    // Each side read back the copy it was given and did not send it again.
    try std.testing.expectEqual(@as(u64, 2), cs.echoes);
    try std.testing.expectEqual(@as(u64, 1), cs.host_ups);
}

test "clipboard: a copy made while the connection is down arrives after the reconnect" {
    var cs: simrun.ClipScript = .{
        .copies = &.{
            .{ .at_us = 500_000, .client = false, .text = "before" },
            .{ .at_us = 2_500_000, .client = true, .text = "made while dropped" },
        },
    };
    const r = try runPath(.{ .seed = 5, .profile = .lan, .seconds = 7, .clipboard = &cs, .path = .{ .drops = &.{.{ .at_us = 2_000_000, .outage_us = 1_000_000 }} } });
    try std.testing.expectEqual(@as(u64, 1), r.client.reconnects);
    try std.testing.expectEqual(@as(u64, 2), cs.host_ups);
    try std.testing.expectEqualStrings("made while dropped", cs.host());
    try std.testing.expectEqualStrings("made while dropped", cs.client());
}

// --- Displays and mid-stream configs (Phase 5) -------------------------------

const two_displays = [_]@import("platform").Size{ .{ .width = 320, .height = 180 }, .{ .width = 256, .height = 192 }, .{ .width = 400, .height = 160 } };

fn printRun(r: simrun.Result) void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    r.print(&w) catch {};
    std.debug.print("{s}  host: reconfigures {d}, display switches {d}, mode changes {d}, resends {d}, stream {d}x{d}@{d} display {d}; client: configs {d}, decoder reconfigures {d}, displays {d}, presented {d}x{d}\n", .{ w.buffered(), r.host.reconfigures, r.host.display_switches, r.host.mode_changes, r.host.config_resends, r.host.width, r.host.height, r.host.fps, r.host.display, r.client.config_changes, r.client.decoder_reconfigures, r.client.displays, r.client.width, r.client.height });
}

test "the client switches displays mid-stream" {
    const o: simrun.Options = .{ .seed = 1, .profile = .lan, .seconds = 5, .displays = &two_displays, .display_events = &.{
        .{ .at_us = 1_500_000, .what = .{ .select = .{ .display = 1 } } },
        .{ .at_us = 3_000_000, .what = .{ .select = .{ .display = 2 } } },
    } };
    const r = try expectPass(o);
    errdefer printRun(r);
    try std.testing.expectEqual(@as(usize, 3), r.client.displays);
    try std.testing.expectEqual(@as(u64, 2), r.host.display_switches);
    try std.testing.expectEqual(@as(u64, 2), r.client.config_changes);
    try std.testing.expectEqual(@as(u64, 2), r.client.decoder_reconfigures);
    try std.testing.expectEqual(@as(u32, 2), r.host.display);
    try std.testing.expectEqual(@as(u32, 400), r.client.width);
    try std.testing.expectEqual(@as(u32, 160), r.client.height);
    // One IDR to start and one per switch; no recovery IDRs on a LAN.
    try std.testing.expectEqual(@as(u64, 3), r.host.keyframes);
    try std.testing.expectEqual(@as(u64, 0), r.client.decode_errors);
}

test "a client cap scales the stream, and a host mode change follows the display" {
    const o: simrun.Options = .{
        .seed = 2,
        .profile = .lan,
        .seconds = 5,
        .displays = &two_displays,
        .display_events = &.{
            // Same display, at most 160 wide and 30 fps: 160x90@30.
            .{ .at_us = 1_000_000, .what = .{ .select = .{ .display = @import("core").display.keep_display, .max_width = 160, .max_fps = 30 } } },
            // Back to its own size, then the display changes mode under the capture.
            .{ .at_us = 2_000_000, .what = .{ .select = .{ .display = 0 } } },
            .{ .at_us = 3_000_000, .what = .{ .mode = .{ .display = 0, .width = 240, .height = 160 } } },
        },
    };
    // Fewer frames at 30 fps for a second: hold this run to frames at the rates it had.
    const r = try simrun.run(std.testing.allocator, o, null);
    errdefer printRun(r);
    try std.testing.expectEqual(@as(u64, 3), r.host.reconfigures);
    try std.testing.expectEqual(@as(u64, 1), r.host.mode_changes);
    try std.testing.expectEqual(@as(u64, 0), r.host.display_switches);
    try std.testing.expectEqual(@as(u64, 3), r.client.config_changes);
    try std.testing.expectEqual(@as(u32, 240), r.client.width);
    try std.testing.expectEqual(@as(u32, 160), r.client.height);
    try std.testing.expectEqual(@as(u32, 60), r.host.fps);
    try std.testing.expectEqual(@as(u64, 0), r.client.corrupt);
    try std.testing.expectEqual(@as(u64, 0), r.client.unreadable);
    try std.testing.expectEqual(@as(u64, 0), r.client.decode_errors);
    try std.testing.expectEqual(@as(u64, 0), r.client.freezes);
    try std.testing.expect(r.client.presented >= (4 * 60 + 30) * 95 / 100);
}

test "a hotplugged display reaches the client's list" {
    const r = try expectPass(.{ .seed = 3, .profile = .lan, .seconds = 3, .displays = two_displays[0..2], .display_events = &.{
        .{ .at_us = 1_000_000, .what = .{ .hotplug = .{ .width = 200, .height = 100 } } },
    } });
    try std.testing.expectEqual(@as(usize, 3), r.client.displays);
    try std.testing.expectEqual(@as(u64, 0), r.host.reconfigures);
}

test "switches on a lossy WAN: configs and the IDR get through or are repaired" {
    for (1..4) |seed| {
        const r = try simrun.run(std.testing.allocator, .{ .seed = seed, .profile = .wan, .seconds = 6, .displays = &two_displays, .display_events = &.{
            .{ .at_us = 1_000_000, .what = .{ .select = .{ .display = 1 } } },
            .{ .at_us = 1_050_000, .what = .{ .select = .{ .display = 2 } } },
            .{ .at_us = 3_000_000, .what = .{ .select = .{ .display = 0 } } },
            .{ .at_us = 4_000_000, .what = .{ .mode = .{ .display = 0, .width = 256, .height = 144 } } },
        } }, null);
        errdefer printRun(r);
        try std.testing.expectEqual(@as(u32, 256), r.client.width);
        try std.testing.expectEqual(@as(u32, 144), r.client.height);
        try std.testing.expectEqual(@as(u64, 0), r.client.corrupt);
        try std.testing.expectEqual(@as(u64, 0), r.client.unreadable);
        try std.testing.expect(r.client.longest_gap_us < 300_000);
        try std.testing.expect(r.client.presented * 100 >= r.expectedFrames(60) * 90);
    }
}

test "the rate ladder resizes the stream end to end" {
    // 960x540 at 60 fps needs ~1.55 Mbit/s before the ladder steps down. The downlink
    // drops from 4 to 1.2 Mbit/s at 3 s and comes back at 8 s; the ladder steps down to
    // 640x360 (and 45 fps), then back up rung by rung, each step a mid-stream config the
    // client's decoder follows.
    const r = try simrun.run(std.testing.allocator, .{
        .seed = 4,
        .profile = .clean,
        .seconds = 26,
        .width = 960,
        .height = 540,
        .bitrate_bps = 2_500_000,
        .rate_control = true,
        .audio = false,
        .downlink_queue_bytes = 60_000,
        .downlink_steps = &.{ .{ .t_us = 0, .bps = 4e6 }, .{ .t_us = 3_000_000, .bps = 1.2e6 }, .{ .t_us = 8_000_000, .bps = 4e6 } },
    }, null);
    errdefer printRun(r);
    try std.testing.expect(r.host.reconfigures >= 3);
    try std.testing.expectEqual(r.host.reconfigures, r.client.config_changes);
    // Every size change reconfigured the decoder (frame-rate-only steps need not).
    try std.testing.expect(r.client.decoder_reconfigures >= 2);
    try std.testing.expectEqual(@as(u64, 0), r.client.corrupt);
    try std.testing.expectEqual(@as(u64, 0), r.client.unreadable);
    // Back at the top by the end.
    try std.testing.expectEqual(@as(u32, 960), r.client.width);
    try std.testing.expectEqual(@as(u32, 540), r.client.height);
    try std.testing.expectEqual(@as(u32, 60), r.host.fps);
}

test "format negotiation: every combination of decoder formats, preferences and HDR streams" {
    const api = @import("platform");
    const fmt = api.format;
    // Client decoders from baseline-only to everything, both preferences, HDR source and
    // display on and off: the run must pass with the format `negotiate` predicts.
    const decoders = [_]api.Formats{
        api.Formats.baseline,
        .{ .yuv420_8 = true, .yuv444_8 = true },
        .{ .yuv420_8 = true, .yuv420_10 = true },
        .{ .yuv420_8 = true, .yuv420_10 = true, .hdr10 = true },
        .{ .yuv420_8 = true, .yuv444_8 = true, .yuv444_10 = true, .hdr10 = true },
        api.Formats.all,
    };
    var hdr_runs: u32 = 0;
    var yuv444_runs: u32 = 0;
    for (decoders) |dec| for ([_]bool{ false, true }) |y444| for ([_]bool{ false, true }) |ten| for ([_]bool{ false, true }) |hdr| {
        const o: simrun.Options = .{
            .profile = .clean,
            .seconds = 1,
            .audio = false,
            .input_interval_us = 0,
            .decoder_formats = dec,
            .yuv444 = y444,
            .ten_bit = ten,
            .hdr_source = if (hdr) api.HdrMetadata.default_hdr10 else null,
            .client_display = .{ .hdr10 = hdr, .peak_nits = 600 },
        };
        const r = try expectPass(o);
        const want = fmt.negotiate(.{
            .codecs = .of(&.{@intFromEnum(api.Codec.passthrough)}),
            .yuv444 = y444,
            .ten_bit = ten,
            .source_is_hdr = hdr,
            .source_hdr = o.hdr_source,
        }, .{ .passthrough = api.Formats.all }, .{ .passthrough = dec }, o.client_display).?.format;
        try std.testing.expect(r.host.format.eql(want));
        try std.testing.expect(r.client.format.eql(want));
        try std.testing.expectEqual(@as(u64, 1), r.host.keyframes);
        if (want.color == .hdr10) hdr_runs += 1;
        if (want.chroma == .yuv444) yuv444_runs += 1;
    };
    try std.testing.expect(hdr_runs >= 4 and yuv444_runs >= 4);
}

test "format negotiation: an encoder without 4:4:4 streams 4:2:0 to a client that wants it" {
    const r = try expectPass(.{ .profile = .clean, .seconds = 1, .audio = false, .input_interval_us = 0, .yuv444 = true, .encoder_formats = .{ .yuv420_8 = true, .yuv420_10 = true } });
    try std.testing.expect(r.host.format.eql(.{}));
}
