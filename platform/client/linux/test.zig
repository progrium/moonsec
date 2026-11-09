//! Linux client backend tests (`zig build test-linux`). CI runs them on ubuntu-24.04
//! under a headless Weston (Mesa llvmpipe), a PipeWire daemon with a null sink and
//! /dev/uinput; there is no GPU, so VAAPI falls back to software and is compile-only.
//!
//! Without a Wayland display, PipeWire or uinput a test skips and says so, unless
//! MOONSEC_REQUIRE=wayland,pipewire,uinput (CI) names it: then it fails.

const std = @import("std");
const api = @import("platform");
const core = @import("core");
const client = @import("client_linux");
const uinput = client.uinput;
const c = client.c;
const evdev = client.evdev;

const testing = std.testing;

/// 6 frames of a solid 0x3060C0 picture, 128x96, no B-frames, parameter sets on every
/// frame (the Windows client's test streams). Decoded YUV is 96, 177, 100 (BT.601).
const solid_h264 = @embedFile("testdata/solid_128x96.h264");
const solid_h265 = @embedFile("testdata/solid_128x96.h265");
const solid_yuv = [3]u8{ 96, 177, 100 };
const solid_rgb = [3]u8{ 0x30, 0x60, 0xC0 };

fn required(what: []const u8) bool {
    const v = std.c.getenv("MOONSEC_REQUIRE") orelse return false;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(v), ',');
    while (it.next()) |w| if (std.mem.eql(u8, w, what)) return true;
    return false;
}

fn skip(what: []const u8, why: []const u8) error{ SkipZigTest, TestUnexpectedResult } {
    if (required(what)) {
        std.debug.print("{s} required but unavailable: {s}\n", .{ what, why });
        return error.TestUnexpectedResult;
    }
    std.debug.print("no {s} ({s}): skipping\n", .{ what, why });
    return error.SkipZigTest;
}

/// Splits an Annex B stream into access units: a new one starts at a parameter set, SEI
/// or AUD that follows a slice, or at a slice that starts a picture. `hevc` picks the
/// NAL header layout. (The Windows client tests split H.264 the same way.)
fn splitAccessUnits(stream: []const u8, hevc: bool, out: [][]const u8) usize {
    var n: usize = 0;
    var au_start: usize = 0;
    var prev_slice = false;
    var i: usize = 0;
    while (i + 3 < stream.len) : (i += 1) {
        if (!(stream[i] == 0 and stream[i + 1] == 0 and stream[i + 2] == 1)) continue;
        const start = if (i > 0 and stream[i - 1] == 0) i - 1 else i;
        var is_slice: bool = undefined;
        var first: bool = undefined;
        var prefix: bool = undefined;
        if (hevc) {
            const t = (stream[i + 3] >> 1) & 0x3F;
            is_slice = t <= 21;
            first = i + 5 < stream.len and stream[i + 5] & 0x80 != 0; // first_slice_segment_in_pic_flag
            prefix = t >= 32 and t <= 40; // VPS SPS PPS AUD SEI...
        } else {
            const t = stream[i + 3] & 0x1F;
            is_slice = t == 1 or t == 5;
            first = i + 4 < stream.len and stream[i + 4] & 0x80 != 0; // first_mb_in_slice = 0
            prefix = t >= 6 and t <= 9;
        }
        if (prev_slice and (prefix or (is_slice and first))) {
            out[n] = stream[au_start..start];
            n += 1;
            au_start = start;
        }
        if (is_slice) prev_slice = true else if (prefix) prev_slice = false;
        i += 3;
    }
    out[n] = stream[au_start..];
    return n + 1;
}

fn near(a: u8, b: u8, tol: u8) bool {
    return @max(a, b) - @min(a, b) <= tol;
}

test "split the test streams into 6 access units" {
    var aus: [16][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 6), splitAccessUnits(solid_h264, false, &aus));
    try testing.expectEqual(@as(usize, 6), splitAccessUnits(solid_h265, true, &aus));
}

fn samplePlanes(f: *const c.mlc_frame, x: u32, y: u32) [3]u8 {
    const cy = f.planes[0][y * f.strides[0] + x];
    return switch (f.kind) {
        c.MLC_FRAME_I420 => .{ cy, f.planes[1][(y / 2) * f.strides[1] + x / 2], f.planes[2][(y / 2) * f.strides[2] + x / 2] },
        c.MLC_FRAME_NV12 => .{ cy, f.planes[1][(y / 2) * f.strides[1] + (x / 2) * 2], f.planes[1][(y / 2) * f.strides[1] + (x / 2) * 2 + 1] },
        else => .{ 0, 0, 0 },
    };
}

fn softwareDecode(codec: u32, stream: []const u8, hevc: bool, hardware: bool) !void {
    var dec: ?*c.mlc_decoder = null;
    try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_create(codec, @intFromBool(hardware), null, &dec));
    defer c.mlc_decoder_destroy(dec);
    // No GPU on the CI runners: asking for VAAPI must land on software, not fail.
    if (hardware and c.mlc_decoder_is_hardware(dec) != 0) {
        std.debug.print("VAAPI device present: hardware decode\n", .{});
        return;
    }
    try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_is_hardware(dec));
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(stream, hevc, &aus);
    for (aus[0..n], 0..) |au, i| {
        var f: c.mlc_frame = undefined;
        var got: c_int = 0;
        try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_decode(dec, au.ptr, au.len, @intCast(i), &f, &got));
        // Low delay: the picture comes out of the call that fed it.
        try testing.expect(got != 0);
        defer c.mlc_decoder_release_frame(dec, &f);
        try testing.expectEqual(@as(i64, @intCast(i)), f.pts);
        try testing.expectEqual(@as(u32, 128), f.width);
        try testing.expectEqual(@as(u32, 96), f.height);
        try testing.expect(f.kind == c.MLC_FRAME_I420 or f.kind == c.MLC_FRAME_NV12);
        try testing.expectEqual(@as(u8, 0), f.full_range);
        const yuv = samplePlanes(&f, 64, 48);
        for (yuv, solid_yuv) |got_v, want| try testing.expect(near(got_v, want, 2));
    }
}

test "software H.264 decode: one picture per access unit, right pixels" {
    try softwareDecode(c.MLC_CODEC_H264, solid_h264, false, false);
}

test "software HEVC decode" {
    try softwareDecode(c.MLC_CODEC_HEVC, solid_h265, true, false);
}

test "asking for VAAPI without a device falls back to software" {
    try softwareDecode(c.MLC_CODEC_H264, solid_h264, false, true);
}

test "decoder rejects garbage without wedging" {
    var dec: ?*c.mlc_decoder = null;
    try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_create(c.MLC_CODEC_H264, 0, null, &dec));
    defer c.mlc_decoder_destroy(dec);
    const junk = [_]u8{ 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0x33, 0xff, 0x12, 0x34 };
    var f: c.mlc_frame = undefined;
    var got: c_int = 0;
    _ = c.mlc_decoder_decode(dec, &junk, junk.len, 0, &f, &got);
    if (got != 0) c.mlc_decoder_release_frame(dec, &f);
    try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_flush(dec));
    var aus: [16][]const u8 = undefined;
    _ = splitAccessUnits(solid_h264, false, &aus);
    try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_decode(dec, aus[0].ptr, aus[0].len, 1, &f, &got));
    try testing.expect(got != 0);
    c.mlc_decoder_release_frame(dec, &f);
}

test "libavcodec has H.264 and HEVC" {
    const set = client.probeCodecs();
    try testing.expect(set.h264 and set.hevc and set.passthrough);
}

// ---------------------------------------------------------------------------
// Wayland / EGL

fn window(w: u32, h: u32) !*c.mlc_window {
    var win: ?*c.mlc_window = null;
    const rc = c.mlc_window_create(w, h, "moonsec test", &win);
    if (rc == c.MLC_E_NODEVICE) return skip("wayland", std.mem.span(c.mlc_last_error()));
    try testing.expectEqual(@as(c_int, 0), rc);
    return win.?;
}

fn readPixel(win: *c.mlc_window, x: u32, y: u32) ![3]u8 {
    var px: [4]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), c.mlc_window_read(win, x, y, 1, 1, &px, 4));
    return .{ px[2], px[1], px[0] }; // BGRA -> RGB
}

test "EGL presenter on Wayland: software decode, YUV -> RGB, letterbox, overlay" {
    const win = try window(320, 240);
    defer c.mlc_window_destroy(win);
    std.debug.print("renderer: {s}, dma-buf import: {d}\n", .{ c.mlc_window_renderer(win), c.mlc_window_has_dmabuf(win) });
    var dec: ?*c.mlc_decoder = null;
    try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_create(c.MLC_CODEC_H264, 0, null, &dec));
    defer c.mlc_decoder_destroy(dec);
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(solid_h264, false, &aus);
    const overlay_px: [8 * 4]u32 = @splat(0xFF00FF00);
    for (aus[0..n], 0..) |au, i| {
        try testing.expect(c.mlc_window_dispatch(win) >= 0);
        _ = c.mlc_window_set_mode(win, if (i % 2 == 0) c.MLC_PRESENT_LOWEST_LATENCY else c.MLC_PRESENT_SMOOTH);
        var f: c.mlc_frame = undefined;
        var got: c_int = 0;
        try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_decode(dec, au.ptr, au.len, @intCast(i), &f, &got));
        try testing.expect(got != 0);
        defer c.mlc_decoder_release_frame(dec, &f);
        if (i == 2) try testing.expectEqual(@as(c_int, 0), c.mlc_window_set_overlay(win, &overlay_px, 8, 4, 8));
        try testing.expectEqual(@as(c_int, 0), c.mlc_window_draw(win, &f));
        try testing.expectEqual(@as(c_int, 0), c.mlc_window_draw_overlay(win));
        // 128x96 into 320x240: same 4:3 aspect, fills the window.
        const rgb = try readPixel(win, 160, 120);
        for (rgb, solid_rgb) |g, want| {
            if (!near(g, want, 6)) {
                std.debug.print("centre pixel {any}, want {any}\n", .{ rgb, solid_rgb });
                return error.TestUnexpectedResult;
            }
        }
        const corner = try readPixel(win, 2, 2);
        if (i >= 2) {
            try testing.expectEqualSlices(u8, &.{ 0, 0xFF, 0 }, &corner);
        } else {
            try testing.expect(!std.mem.eql(u8, &.{ 0, 0xFF, 0 }, &corner));
        }
        try testing.expectEqual(@as(c_int, 0), c.mlc_window_present(win));
    }
    // A 16:9 window letterboxes the 4:3 picture: black bars left and right.
    c.mlc_window_resize(win, 320, 180);
    try testing.expectEqual(@as(c_int, 0), c.mlc_window_set_overlay(win, null, 0, 0, 0));
    var f: c.mlc_frame = undefined;
    var got: c_int = 0;
    try testing.expectEqual(@as(c_int, 0), c.mlc_decoder_decode(dec, aus[0].ptr, aus[0].len, 9, &f, &got));
    defer c.mlc_decoder_release_frame(dec, &f);
    try testing.expectEqual(@as(c_int, 0), c.mlc_window_draw(win, &f));
    var ww: u32 = 0;
    var wh: u32 = 0;
    c.mlc_window_size(win, &ww, &wh);
    if (ww == 320 and wh == 180) {
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &(try readPixel(win, 5, 90)));
        const mid = try readPixel(win, 160, 90);
        try testing.expect(near(mid[2], 0xC0, 6));
    }
    try testing.expectEqual(@as(c_int, 0), c.mlc_window_present(win));
}

test "presenter: the test pattern survives the GL path bit for bit enough to read" {
    const be = client.openClient(testing.allocator, .{ .width = 320, .height = 180, .evdev = false, .verify_pattern = true }) catch |e| {
        if (e == error.DeviceLost) return skip("wayland", std.mem.span(c.mlc_last_error()));
        return e;
    };
    defer be.deinit();
    const cl: *client.Client = @ptrCast(@alignCast(be.deinit_ptr.?));
    try be.decoder.configure(.{ .codec = .passthrough, .width = 320, .height = 180 });
    try be.presenter.configure(.{ .width = 320, .height = 180 });

    // Real passthrough access units, from the synthetic encoder.
    const synthetic = @import("synthetic");
    var enc: synthetic.Encoder = .{ .gpa = testing.allocator, .clock = client.clock };
    defer enc.deinit();
    try enc.configure(.{ .codec = .passthrough, .width = 320, .height = 180, .bitrate_bps = 2_000_000 });
    var cap: synthetic.Capture = .{ .gpa = testing.allocator, .clock = client.clock, .sleeper = null, .sleep_ctx = null, .default_size = .{ .width = 320, .height = 180 } };
    _ = try cap.start(.{ .fps = 1000 });
    defer cap.stop();
    var tel = core.telemetry.Telemetry(64).init();
    var last_frame: ?u32 = null;
    for (0..5) |i| {
        const fr = (try cap.acquire(1_000_000)) orelse return error.TestUnexpectedResult;
        defer cap.release(&fr);
        const ef = (try enc.encode(&fr, .{ .force = if (i == 0) .idr else .none })) orelse return error.TestUnexpectedResult;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);
        for (ef.slices) |s| try bytes.appendSlice(testing.allocator, s);
        const df = (try be.decoder.decode(&.{ .codec = .passthrough, .frame_id = @intCast(i), .data = bytes.items, .keyframe = ef.keyframe, .capture_us = 0, .received_us = 0 })) orelse return error.TestUnexpectedResult;
        const ov: api.Overlay = .{ .telemetry = tel.snapshot() };
        const shown = try be.presenter.present(&df, &ov);
        be.decoder.release(&df);
        tel.record(.{ .frame_id = df.frame_id, .received = df.decoded_us, .decoded = df.decoded_us, .presented = shown.presented_us }, null);
        const stamp = cl.presenter.last_stamp orelse {
            std.debug.print("frame {d}: pattern unreadable after the GL path (presenter stats {any})\n", .{ i, cl.presenter.stats });
            return error.TestUnexpectedResult;
        };
        // Each picture carries the next frame number.
        if (last_frame) |lf| try testing.expectEqual(lf + 1, stamp.frame);
        last_frame = stamp.frame;
    }
    try testing.expectEqual(@as(u64, 5), cl.presenter.stats.verified);
}

test "openClient: H.264 through the platform interface" {
    const be = client.openClient(testing.allocator, .{ .width = 256, .height = 192, .title = "moonsec bundle test", .evdev = false }) catch |e| {
        if (e == error.DeviceLost) return skip("wayland", std.mem.span(c.mlc_last_error()));
        return e;
    };
    defer be.deinit();
    try testing.expect(be.clock.now() > 0);
    const caps = be.decoder.caps();
    try testing.expect(caps.codecs.h264 and caps.codecs.passthrough);
    try be.decoder.configure(.{ .codec = .h264, .width = 128, .height = 96 });
    try be.presenter.configure(.{ .width = 256, .height = 192, .mode = .lowest_latency });
    var tel = core.telemetry.Telemetry(64).init();
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(solid_h264, false, &aus);
    for (aus[0..n], 0..) |au, i| {
        const recv = be.clock.now();
        const fr = (try be.decoder.decode(&.{ .codec = .h264, .frame_id = @intCast(100 + i), .data = au, .keyframe = i == 0, .capture_us = 0, .received_us = recv })) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, @intCast(100 + i)), fr.frame_id);
        try testing.expect(fr.image.gpu != null);
        const ov: api.Overlay = .{ .telemetry = tel.snapshot(), .bitrate_bps = 20_000_000 };
        const shown = try be.presenter.present(&fr, &ov);
        be.decoder.release(&fr);
        try testing.expect(shown.presented_us >= fr.decoded_us);
        tel.record(.{ .frame_id = fr.frame_id, .received = recv, .decoded = fr.decoded_us, .presented = shown.presented_us }, null);
    }
    const snap = tel.snapshot();
    try testing.expectEqual(@as(u64, n), snap.counters.frames);
    std.debug.print("llvmpipe + software decode: decode p50 {d} us, present p50 {d} us\n", .{ snap.stage(.decode).p50, snap.stage(.present).p50 });
    try testing.expectError(error.Unsupported, be.decoder.configure(.{ .codec = @enumFromInt(77), .width = 1, .height = 1 }));
}

// ---------------------------------------------------------------------------
// PipeWire

test "PipeWire output: open, write, the graph drains it" {
    var a: ?*c.mlc_audio = null;
    const rc = c.mlc_audio_open(48_000, 2, 200, 256, "moonsec test", &a);
    if (rc == c.MLC_E_NODEVICE) return skip("pipewire", std.mem.span(c.mlc_last_error()));
    try testing.expectEqual(@as(c_int, 0), rc);
    defer c.mlc_audio_close(a);
    // 100 ms of a 440 Hz tone.
    var pcm: [4800 * 2]f32 = undefined;
    for (0..4800) |i| {
        const v: f32 = 0.1 * @sin(@as(f32, @floatFromInt(i)) * 2 * std.math.pi * 440 / 48_000);
        pcm[2 * i] = v;
        pcm[2 * i + 1] = v;
    }
    var written: u32 = 0;
    try testing.expectEqual(@as(c_int, 0), c.mlc_audio_write(a, &pcm, 4800, &written));
    try testing.expectEqual(@as(u32, 4800), written);
    try testing.expect(c.mlc_audio_queued(a) >= 4800);
    // More than the 200 ms ring takes only what fits, without blocking.
    var big: [48_000 * 2]f32 = @splat(0);
    try testing.expectEqual(@as(c_int, 0), c.mlc_audio_write(a, &big, 48_000, &written));
    try testing.expect(written <= 9600 - 4800);
    // The graph pulls it out at 48 kHz once linked.
    var ring: u32 = 0;
    var quantum: u32 = 0;
    var streaming: c_int = 0;
    var underruns: u64 = 0;
    const before = c.mlc_audio_queued(a);
    var waited: u32 = 0;
    while (waited < 2000 and c.mlc_audio_queued(a) + 2400 > before) : (waited += 10) uinput.sleepMs(10);
    c.mlc_audio_info(a, &ring, &quantum, &streaming, &underruns);
    std.debug.print("pipewire: ring {d} frames, quantum {d}, streaming {d}, queued {d} -> {d} in {d} ms\n", .{ ring, quantum, streaming, before, c.mlc_audio_queued(a), waited });
    if (streaming == 0) return skip("pipewire", "stream not linked to a sink");
    try testing.expect(c.mlc_audio_queued(a) + 2400 <= before);
}

// ---------------------------------------------------------------------------
// evdev through uinput

test "evdev: a uinput keyboard's keys and motion arrive as HID events" {
    const dev = uinput.Device.create("moonsec test keyboard") catch |e| return skip("uinput", @errorName(e));
    defer dev.destroy();
    var devs: evdev.Devices = .{};
    defer devs.deinit();
    _ = devs.scan();
    var found = false;
    for (devs.devs[0..devs.n]) |d| if (d.node == dev.node) {
        found = true;
    };
    if (!found) return skip("uinput", "the uinput device's node is not readable");
    const t0 = client.nowUs();
    dev.key(uinput.keyCode(0x04), true); // a
    dev.move(3, -2);
    dev.key(uinput.keyCode(0x04), false);
    dev.key(42, true); // left shift
    dev.key(42, false);
    var evs: [64]api.InputEvent = undefined;
    var got: [8]api.InputEvent = undefined;
    var n: usize = 0;
    const deadline = client.nowUs() + 2_000_000;
    while (n < 5 and client.nowUs() < deadline) {
        const k = devs.read(&evs);
        for (evs[0..k]) |e| if (n < got.len) {
            got[n] = e;
            n += 1;
        };
        uinput.sleepMs(1);
    }
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expect(got[0].what.key.code == 0x04 and got[0].what.key.down);
    try testing.expect(got[1].what.move_rel.dx == 3 and got[1].what.move_rel.dy == -2);
    try testing.expect(got[2].what.key.code == 0x04 and !got[2].what.key.down);
    try testing.expect(got[3].what.key.code == 0xE1 and got[3].what.key.down);
    // CLOCK_MONOTONIC timestamps, in order.
    try testing.expect(got[0].time_us >= t0 - 1000 and got[0].time_us <= client.nowUs());
    for (got[1..n], got[0 .. n - 1]) |b, a| try testing.expect(b.time_us >= a.time_us);
}

test {
    _ = evdev;
    _ = uinput;
}
