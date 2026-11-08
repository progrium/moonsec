//! Recovery gate tests on the synthetic backend (zig build test-recovery).
const std = @import("std");
const run = @import("recovery_run");
const synthetic = @import("synthetic.zig");

const testing = std.testing;

fn cfgFor(expect: run.Expect, ltr: bool) run.Config {
    return .{
        .codec = .passthrough,
        .width = 320,
        .height = 180,
        .bitrate_bps = 1_000_000,
        .frames = 900,
        .loss = 0.02,
        .ltr = ltr,
        .expect = expect,
        // The synthetic encoder sizes a refresh at 0.75x an IDR.
        .max_refresh_ratio = 0.8,
    };
}

fn runOnce(cfg: run.Config) !run.Result {
    const be = try synthetic.Backend.open(testing.allocator, cfg.width, cfg.height);
    defer be.close();
    return run.run(testing.allocator, be.hb.encoder, be.source(), be.cb.decoder, cfg, null, null);
}

test "LTR recovery: no IDR after the first, every freeze recovered, decoder happy" {
    const cfg = cfgFor(.ltr, true);
    const r = try runOnce(cfg);
    const v = run.verdict(&r, cfg);
    for (v.list()) |why| std.debug.print("fail: {s}\n", .{why});
    try testing.expect(v.pass);
    try testing.expect(r.loss_events >= 5);
    try testing.expectEqual(@as(u64, 0), r.later_idrs);
    try testing.expectEqual(@as(u64, 0), r.decode_errors);
    try testing.expect(r.refresh_sizes.n >= r.loss_events / 2);
    try testing.expect(r.calibration_idr_bytes > r.refresh_sizes.max);
    // A freeze lasts about RTT + a frame or two, not seconds.
    try testing.expect(r.freeze_max_us < 200_000);
}

test "without LTR every loss recovers through an IDR, and the LTR gate fails" {
    const idr_cfg = cfgFor(.idr, false);
    const r = try runOnce(idr_cfg);
    const v = run.verdict(&r, idr_cfg);
    for (v.list()) |why| std.debug.print("fail: {s}\n", .{why});
    try testing.expect(v.pass);
    try testing.expect(r.host.recovery_idrs >= 1);
    try testing.expectEqual(@as(u64, 0), r.refresh_sizes.n);
    try testing.expect(!run.verdict(&r, cfgFor(.ltr, false)).pass);
}

test "bursts and a long RTT still recover; runs are deterministic" {
    var cfg = cfgFor(.ltr, true);
    cfg.burst = 4;
    cfg.rtt_us = 120_000;
    cfg.seed = 7;
    const a = try runOnce(cfg);
    const b = try runOnce(cfg);
    try testing.expect(run.verdict(&a, cfg).pass);
    try testing.expectEqual(a.lost, b.lost);
    try testing.expectEqual(a.refresh_sizes.sum, b.refresh_sizes.sum);
    try testing.expectEqual(a.freeze_total_us, b.freeze_total_us);
}

test "a tiny refresh limit fails the gate" {
    var cfg = cfgFor(.ltr, true);
    cfg.max_refresh_ratio = 0.1;
    const r = try runOnce(cfg);
    try testing.expect(!run.verdict(&r, cfg).pass);
}

test {
    _ = @import("content.zig");
}
