//! Windows client backend tests. They run on the windows-2022 CI runner, which has no
//! GPU and no audio device: decode is Media Foundation's software path, present runs
//! on WARP, and the audio test skips (saying so) when there is no endpoint.
//! `zig build check-win` cross-compiles them from any host; `zig build test-win`
//! runs them on Windows.

const std = @import("std");
const api = @import("platform");
const core = @import("core");
const win = @import("win");
const client = @import("client_windows");
const c = client.c;

const testing = std.testing;

/// 6 frames of a solid 0x3060C0 picture, 128x96, H.264 baseline, no B-frames, SPS/PPS
/// on every frame (ffmpeg -f lavfi color=c=0x3060C0 ... -c:v libx264 -tune zerolatency).
/// Decoded NV12 is Y 96, U 177, V 100.
const solid_h264 = @embedFile("testdata/solid_128x96.h264");
const solid_yuv = [3]u8{ 96, 177, 100 };
const solid_rgb = [3]u8{ 0x30, 0x60, 0xC0 };

/// Splits an Annex B stream into access units: a new one starts at a parameter set,
/// SEI or AUD that follows a slice, or at a slice with first_mb_in_slice = 0 that
/// follows a slice.
fn splitAccessUnits(stream: []const u8, out: [][]const u8) usize {
    var starts: [64]usize = undefined;
    var types: [64]u8 = undefined;
    var first_mb0: [64]bool = undefined;
    var n_nal: usize = 0;
    var i: usize = 0;
    while (i + 3 < stream.len) : (i += 1) {
        if (stream[i] == 0 and stream[i + 1] == 0 and stream[i + 2] == 1) {
            const start = if (i > 0 and stream[i - 1] == 0) i - 1 else i;
            starts[n_nal] = start;
            types[n_nal] = stream[i + 3] & 0x1F;
            first_mb0[n_nal] = i + 4 < stream.len and stream[i + 4] & 0x80 != 0;
            n_nal += 1;
            i += 3;
        }
    }
    var n: usize = 0;
    var au_start: usize = 0;
    var prev_slice = false;
    for (0..n_nal) |k| {
        const t = types[k];
        const is_slice = t == 1 or t == 5;
        const boundary = prev_slice and ((t >= 6 and t <= 9) or (is_slice and first_mb0[k]));
        if (boundary) {
            out[n] = stream[au_start..starts[k]];
            n += 1;
            au_start = starts[k];
        }
        prev_slice = is_slice;
    }
    out[n] = stream[au_start..];
    return n + 1;
}

fn near(a: u8, b: u8, tol: u8) bool {
    return @max(a, b) - @min(a, b) <= tol;
}

test "split the test stream into 6 access units" {
    var aus: [16][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 6), splitAccessUnits(solid_h264, &aus));
}

fn warp() !win.D3d {
    return client.createDevice(.warp, 0);
}

test "software H.264 decode: one picture per access unit, right pixels" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d3d = try warp();
    defer d3d.destroy();

    var dec: ?*c.mswc_decoder = null;
    try win.check(c.mswc_decoder_create(client.d3dPtr(d3d), c.MSWC_CODEC_H264, 0, &dec));
    defer c.mswc_decoder_destroy(dec);
    try testing.expectEqual(@as(c_int, 0), c.mswc_decoder_is_hardware(dec));

    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(solid_h264, &aus);
    var pictures: usize = 0;
    for (aus[0..n], 0..) |au, i| {
        var f: c.mswc_frame = undefined;
        var got: c_int = 0;
        try win.check(c.mswc_decoder_decode(dec, au.ptr, au.len, @intCast(i), &f, &got));
        // Low-latency mode: the picture comes out of the call that fed it.
        try testing.expect(got != 0);
        defer c.mswc_decoder_release_frame(dec, &f);
        try testing.expectEqual(@as(i64, @intCast(i)), f.pts);
        try testing.expectEqual(@as(u32, 128), f.width);
        try testing.expectEqual(@as(u32, 96), f.height);
        var yuv: [3]u8 = undefined;
        try win.check(c.mswc_frame_read_nv12(client.d3dPtr(d3d), &f, 64, 48, &yuv));
        for (yuv, solid_yuv) |got_v, want| try testing.expect(near(got_v, want, 2));
        pictures += 1;
    }
    try testing.expectEqual(n, pictures);
}

test "decoder rejects garbage without wedging" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d3d = try warp();
    defer d3d.destroy();
    var dec: ?*c.mswc_decoder = null;
    try win.check(c.mswc_decoder_create(client.d3dPtr(d3d), c.MSWC_CODEC_H264, 0, &dec));
    defer c.mswc_decoder_destroy(dec);

    // A slice with no parameter sets: no picture (an error or nothing).
    const junk = [_]u8{ 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0x33, 0xff, 0x12, 0x34 };
    var f: c.mswc_frame = undefined;
    var got: c_int = 0;
    _ = c.mswc_decoder_decode(dec, &junk, junk.len, 0, &f, &got);
    if (got != 0) c.mswc_decoder_release_frame(dec, &f);
    try win.check(c.mswc_decoder_flush(dec));

    // A clean stream afterwards decodes.
    var aus: [16][]const u8 = undefined;
    _ = splitAccessUnits(solid_h264, &aus);
    try win.check(c.mswc_decoder_decode(dec, aus[0].ptr, aus[0].len, 1, &f, &got));
    try testing.expect(got != 0);
    c.mswc_decoder_release_frame(dec, &f);
}

test "flip-model swapchain on WARP: waitable, colour conversion, overlay" {
    try swapchainTest(0);
    try swapchainTest(c.MSWC_PRESENTER_SHADER);
}

fn checkHr(what: []const u8, hr: i32) !void {
    if (hr < 0) {
        std.debug.print("{s}: {f}\n", .{ what, win.fmtHr(hr) });
        return error.Win32;
    }
}

fn swapchainTest(flags: u32) !void {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d3d = try warp();
    defer d3d.destroy();

    var w: ?*c.mswc_window = null;
    try win.check(c.mswc_window_create(320, 240, "moonsec test", c.MSWC_WINDOW_VISIBLE, &w));
    defer c.mswc_window_destroy(w);
    var pr: ?*c.mswc_presenter = null;
    try checkHr("mswc_presenter_create", c.mswc_presenter_create(client.d3dPtr(d3d), w, flags, &pr));
    defer c.mswc_presenter_destroy(pr);
    std.debug.print("swapchain: tearing {s}, {s}\n", .{
        if (c.mswc_presenter_tearing(pr) != 0) "supported" else "not supported",
        if (c.mswc_presenter_uses_shader(pr) != 0) "pixel shader" else "video processor",
    });

    var dec: ?*c.mswc_decoder = null;
    try win.check(c.mswc_decoder_create(client.d3dPtr(d3d), c.MSWC_CODEC_H264, 0, &dec));
    defer c.mswc_decoder_destroy(dec);
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(solid_h264, &aus);

    var pw: u32 = 0;
    var ph: u32 = 0;
    c.mswc_presenter_size(pr, &pw, &ph);
    try testing.expectEqual(@as(u32, 320), pw);
    try testing.expectEqual(@as(u32, 240), ph);

    var overlay_px: [8 * 4]u32 = @splat(0xFF00FF00);
    for (aus[0..n], 0..) |au, i| {
        const wr = c.mswc_presenter_wait(pr, 1000);
        try testing.expect(wr >= 0);
        var f: c.mswc_frame = undefined;
        var got: c_int = 0;
        try win.check(c.mswc_decoder_decode(dec, au.ptr, au.len, @intCast(i), &f, &got));
        try testing.expect(got != 0);
        defer c.mswc_decoder_release_frame(dec, &f);

        if (i == 2) try win.check(c.mswc_presenter_set_overlay(pr, &overlay_px, 8, 4, 8));
        try checkHr("mswc_presenter_draw", c.mswc_presenter_draw(pr, &f));

        var px: u32 = 0;
        // 128x96 letterboxed into 320x240: same 4:3 aspect, fills the buffer.
        try win.check(c.mswc_presenter_read_pixel(pr, 160, 120, &px));
        const rgb = [3]u8{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
        for (rgb, solid_rgb) |got_v, want| {
            if (!near(got_v, want, 12)) {
                std.debug.print("centre pixel 0x{X:0>8}, want ~0x{X:0>2}{X:0>2}{X:0>2}\n", .{ px, want, solid_rgb[1], solid_rgb[2] });
                return error.TestUnexpectedResult;
            }
        }
        try win.check(c.mswc_presenter_read_pixel(pr, 2, 2, &px));
        if (i >= 2) {
            try testing.expectEqual(@as(u32, 0x00FF00), px & 0xFFFFFF); // overlay copied over the corner
        } else {
            try testing.expect(px & 0xFFFFFF != 0x00FF00);
        }
        try checkHr("mswc_presenter_present", c.mswc_presenter_present(pr, if (i % 2 == 0) c.MSWC_PRESENT_LOWEST_LATENCY else c.MSWC_PRESENT_SMOOTH));
    }

    // Hiding the overlay.
    try win.check(c.mswc_presenter_set_overlay(pr, null, 0, 0, 0));
    try win.check(c.mswc_presenter_draw(pr, null));
    var px: u32 = 0;
    try win.check(c.mswc_presenter_read_pixel(pr, 2, 2, &px));
    try testing.expectEqual(@as(u32, 0), px & 0xFFFFFF); // cleared to black
}

test "Raw Input: a SendInput key arrives as HID usage down then up" {
    const com = try win.ComThread.init();
    defer com.deinit();
    var w: ?*c.mswc_window = null;
    try win.check(c.mswc_window_create(64, 64, "moonsec input test", c.MSWC_WINDOW_VISIBLE | c.MSWC_WINDOW_RAW_INPUT | c.MSWC_WINDOW_INPUT_SINK, &w));
    defer c.mswc_window_destroy(w);

    if (c.mswc_send_key(0x1E, 0, 0) == 0) {
        std.debug.print("SendInput blocked (no interactive desktop): skipping\n", .{});
        return error.SkipZigTest;
    }
    _ = c.mswc_send_key(0x1E, 0, 1);

    var src: client.InputSource = .{ .window = w.? };
    var evs: [16]api.InputEvent = undefined;
    var keys: [4]api.InputEvent = undefined;
    var nk: usize = 0;
    const deadline = client.nowUs() + 2_000_000;
    while (nk < 2 and client.nowUs() < deadline) {
        const n = try src.poll(&evs);
        for (evs[0..n]) |e| if (e.what == .key and nk < keys.len) {
            keys[nk] = e;
            nk += 1;
        };
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(@as(usize, 2), nk);
    try testing.expectEqual(@as(u16, 0x04), keys[0].what.key.code);
    try testing.expect(keys[0].what.key.down);
    try testing.expectEqual(@as(u16, 0x04), keys[1].what.key.code);
    try testing.expect(!keys[1].what.key.down);
    try testing.expect(keys[0].time_us <= keys[1].time_us);
}

test "WASAPI output: open, write, drain" {
    const com = try win.ComThread.init();
    defer com.deinit();
    var a: ?*c.mswc_audio = null;
    const hr = c.mswc_audio_open(48_000, 2, &a);
    if (hr == win.hrCode(c.MSW_E_NOTFOUND)) {
        std.debug.print("no audio endpoint on this machine: skipping\n", .{});
        return error.SkipZigTest;
    }
    try win.check(hr);
    defer c.mswc_audio_close(a);
    var frames: u32 = 0;
    var period: i64 = 0;
    var low: c_int = 0;
    c.mswc_audio_info(a, &frames, &period, &low);
    std.debug.print("audio: buffer {d} frames, period {d} us, IAudioClient3 {d}\n", .{ frames, @divTrunc(period, 10), low });
    try testing.expect(frames > 0);

    // 10 ms of a 440 Hz tone.
    var pcm: [480 * 2]f32 = undefined;
    for (0..480) |i| {
        const v: f32 = 0.1 * @sin(@as(f32, @floatFromInt(i)) * 2 * std.math.pi * 440 / 48_000);
        pcm[2 * i] = v;
        pcm[2 * i + 1] = v;
    }
    var written: u32 = 0;
    try win.check(c.mswc_audio_write(a, &pcm, 480, &written));
    try testing.expect(written > 0);
    var q: u32 = 0;
    try win.check(c.mswc_audio_queued(a, &q));
    try testing.expect(q > 0 and q <= frames);
    // Writing far more than fits accepts only what fits, and never blocks.
    var big: [48_000 * 2]f32 = @splat(0);
    try win.check(c.mswc_audio_write(a, &big, 48_000, &written));
    try testing.expect(written <= frames);
}

test "openClient: the bundle through the platform interface" {
    const be = try client.openClient(testing.allocator, .{ .driver = .warp, .width = 256, .height = 192, .title = "moonsec bundle test" });
    defer be.deinit();

    const t0 = be.clock.now();
    try testing.expect(t0 > 0);
    try testing.expect(be.decoder.caps().codecs.h264);
    try testing.expect(be.decoder.caps().gpu_output);

    try be.decoder.configure(.{ .codec = .h264, .width = 128, .height = 96 });
    try be.presenter.configure(.{ .width = 256, .height = 192, .mode = .lowest_latency });

    var tel = core.telemetry.Telemetry(64).init();
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(solid_h264, &aus);
    for (aus[0..n], 0..) |au, i| {
        const recv = be.clock.now();
        const fr = (try be.decoder.decode(&.{
            .codec = .h264,
            .frame_id = @intCast(100 + i),
            .data = au,
            .keyframe = i == 0,
            .capture_us = 0,
            .received_us = recv,
        })) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, @intCast(100 + i)), fr.frame_id);
        try testing.expectEqual(api.PixelFormat.nv12, fr.image.format);
        try testing.expect(fr.image.gpu != null);
        try testing.expect(fr.decoded_us >= recv);

        const ov: api.Overlay = .{ .telemetry = tel.snapshot(), .bitrate_bps = 20_000_000 };
        const shown = try be.presenter.present(&fr, &ov);
        be.decoder.release(&fr);
        try testing.expect(shown.presented_us >= fr.decoded_us);
        tel.record(.{ .frame_id = fr.frame_id, .received = recv, .decoded = fr.decoded_us, .presented = shown.presented_us }, null);
    }
    const snap = tel.snapshot();
    try testing.expectEqual(@as(u64, n), snap.counters.frames);
    std.debug.print("WARP + software decode: decode p50 {d} us, present p50 {d} us\n", .{ snap.stage(.decode).p50, snap.stage(.present).p50 });

    var evs: [8]api.InputEvent = undefined;
    _ = try be.input.?.poll(&evs);

    // An unsupported codec is reported as such.
    try testing.expectError(error.Unsupported, be.decoder.configure(.{ .codec = .av1, .width = 1, .height = 1 }));
}

test "XInput: loads, and the input source polls pads alongside Raw Input" {
    var pads = client.gamepad.xinput.Source.open(client.clock);
    defer pads.close();
    // xinput1_4.dll ships with Windows 8 and later, Server editions included.
    try testing.expect(pads.available());
    try testing.expectEqualStrings("xinput1_4.dll", pads.dll);
    var evs: [8]api.InputEvent = undefined;
    // Runners have no controllers; any event must be a pad event in a valid slot.
    const n = try pads.poll(&evs);
    for (evs[0..n]) |e| try testing.expect(e.what == .pad and e.what.pad.index < 4);
}
