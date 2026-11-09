//! macOS client backend tests. They run on the macos-15 CI runner (an Apple Silicon
//! VM): VideoToolbox decodes in software there when the VM has no hardware decoder,
//! Metal runs on the VM's paravirtual GPU, presenting into an offscreen texture and
//! a CAMetalLayer that is in no window. The window and audio tests skip (saying so)
//! when there is no window server or no output device. `zig build test-mac` runs them
//! on a Mac.

const std = @import("std");
const api = @import("platform");
const core = @import("core");
const client = @import("client_macos");
const c = client.c;

const testing = std.testing;

/// 6 frames of a solid 0x3060C0 picture, 128x96, no B-frames, parameter sets on
/// every keyframe (the same streams as the Windows client's tests). Decoded NV12 is
/// Y 96, U 177, V 100 (BT.709, video range).
const solid_h264 = @embedFile("testdata/solid_128x96.h264");
const solid_h265 = @embedFile("testdata/solid_128x96.h265");
const solid_yuv = [3]u8{ 96, 177, 100 };
const solid_rgb = [3]u8{ 0x30, 0x60, 0xC0 };

const Codec = enum { h264, hevc };

/// Splits an Annex B stream into access units: a new one starts at a parameter set,
/// SEI or AUD that follows a slice, or at the first slice of a picture that follows
/// a slice.
fn splitAccessUnits(codec: Codec, stream: []const u8, out: [][]const u8) usize {
    var starts: [64]usize = undefined;
    var is_slice: [64]bool = undefined;
    var first: [64]bool = undefined;
    var is_prefix: [64]bool = undefined;
    var n_nal: usize = 0;
    var i: usize = 0;
    while (i + 5 < stream.len) : (i += 1) {
        if (stream[i] == 0 and stream[i + 1] == 0 and stream[i + 2] == 1) {
            starts[n_nal] = if (i > 0 and stream[i - 1] == 0) i - 1 else i;
            switch (codec) {
                .h264 => {
                    const t = stream[i + 3] & 0x1F;
                    is_slice[n_nal] = t == 1 or t == 5;
                    first[n_nal] = stream[i + 4] & 0x80 != 0;
                    is_prefix[n_nal] = t >= 6 and t <= 9;
                },
                .hevc => {
                    const t = (stream[i + 3] >> 1) & 0x3F;
                    is_slice[n_nal] = t < 32;
                    first[n_nal] = stream[i + 5] & 0x80 != 0;
                    is_prefix[n_nal] = (t >= 32 and t <= 35) or t == 39;
                },
            }
            n_nal += 1;
            i += 3;
        }
    }
    var n: usize = 0;
    var au_start: usize = 0;
    var prev_slice = false;
    for (0..n_nal) |k| {
        if (prev_slice and (is_prefix[k] or (is_slice[k] and first[k]))) {
            out[n] = stream[au_start..starts[k]];
            n += 1;
            au_start = starts[k];
        }
        prev_slice = is_slice[k];
    }
    out[n] = stream[au_start..];
    return n + 1;
}

fn near(a: u8, b: u8, tol: u8) bool {
    return @max(a, b) - @min(a, b) <= tol;
}

fn check(what: []const u8, st: i32) !void {
    if (st != c.MACC_OK) {
        std.debug.print("{s}: status {d}\n", .{ what, st });
        return error.MacStatus;
    }
}

test "split the test streams into 6 access units" {
    var aus: [16][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 6), splitAccessUnits(.h264, solid_h264, &aus));
    try testing.expectEqual(@as(usize, 6), splitAccessUnits(.hevc, solid_h265, &aus));
}

fn decodeTest(codec: Codec, hardware: bool) !void {
    const stream = if (codec == .h264) solid_h264 else solid_h265;
    var dec: ?*c.macc_decoder = null;
    try check("macc_decoder_create", c.macc_decoder_create(if (codec == .h264) c.MACC_CODEC_H264 else c.MACC_CODEC_HEVC, @intFromBool(hardware), &dec));
    defer c.macc_decoder_destroy(dec);

    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(codec, stream, &aus);
    for (aus[0..n], 0..) |au, i| {
        var f: c.macc_frame = undefined;
        var got: c_int = 0;
        try check("macc_decoder_decode", c.macc_decoder_decode(dec, au.ptr, au.len, @intCast(i), &f, &got));
        // Synchronous decode: the picture comes out of the call that fed it.
        try testing.expect(got != 0);
        defer c.macc_decoder_release_frame(dec, &f);
        try testing.expectEqual(@as(i64, @intCast(i)), f.pts);
        try testing.expectEqual(@as(u32, 128), f.width);
        try testing.expectEqual(@as(u32, 96), f.height);
        var yuv: [3]u8 = undefined;
        try check("macc_frame_read_nv12", c.macc_frame_read_nv12(&f, 64, 48, &yuv));
        for (yuv, solid_yuv) |got_v, want| try testing.expect(near(got_v, want, 2));
    }
    std.debug.print("{s} decode ({s} requested): {s}\n", .{
        @tagName(codec),
        if (hardware) "hardware" else "software",
        if (c.macc_decoder_is_hardware(dec) != 0) "hardware" else "software",
    });
}

test "VideoToolbox H.264 decode: one picture per access unit, right pixels" {
    try decodeTest(.h264, true);
    try decodeTest(.h264, false);
}

test "VideoToolbox HEVC decode: one picture per access unit, right pixels" {
    try decodeTest(.hevc, true);
}

test "decoder rejects garbage without wedging" {
    var dec: ?*c.macc_decoder = null;
    try check("macc_decoder_create", c.macc_decoder_create(c.MACC_CODEC_H264, 1, &dec));
    defer c.macc_decoder_destroy(dec);

    // A slice with no parameter sets: an error, no picture.
    const junk = [_]u8{ 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0x33, 0xff, 0x12, 0x34 };
    var f: c.macc_frame = undefined;
    var got: c_int = 0;
    try testing.expectEqual(@as(i32, c.MACC_E_BAD_STREAM), c.macc_decoder_decode(dec, &junk, junk.len, 0, &f, &got));
    try testing.expectEqual(@as(c_int, 0), got);
    c.macc_decoder_flush(dec);

    // A clean stream afterwards decodes.
    var aus: [16][]const u8 = undefined;
    _ = splitAccessUnits(.h264, solid_h264, &aus);
    try check("decode", c.macc_decoder_decode(dec, aus[0].ptr, aus[0].len, 1, &f, &got));
    try testing.expect(got != 0);
    c.macc_decoder_release_frame(dec, &f);

    // Garbage after the parameter sets are known: a decode error or no picture, and
    // the next keyframe still decodes.
    const bad_slice = [_]u8{ 0, 0, 0, 1, 0x41, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    _ = c.macc_decoder_decode(dec, &bad_slice, bad_slice.len, 2, &f, &got);
    if (got != 0) c.macc_decoder_release_frame(dec, &f);
    c.macc_decoder_flush(dec);
    try check("decode after garbage", c.macc_decoder_decode(dec, aus[0].ptr, aus[0].len, 3, &f, &got));
    try testing.expect(got != 0);
    c.macc_decoder_release_frame(dec, &f);
}

/// Decodes the H.264 stream and draws each frame into `pr`, checking the centre
/// pixel and the overlay corner, alternating present modes.
fn presentFrames(pr: ?*c.macc_presenter) !void {
    var dec: ?*c.macc_decoder = null;
    try check("macc_decoder_create", c.macc_decoder_create(c.MACC_CODEC_H264, 1, &dec));
    defer c.macc_decoder_destroy(dec);
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(.h264, solid_h264, &aus);

    var pw: u32 = 0;
    var ph: u32 = 0;
    c.macc_presenter_size(pr, &pw, &ph);

    var overlay_px: [8 * 4]u32 = @splat(0xFF00FF00);
    var last_ns: u64 = 0;
    for (aus[0..n], 0..) |au, i| {
        var f: c.macc_frame = undefined;
        var got: c_int = 0;
        try check("decode", c.macc_decoder_decode(dec, au.ptr, au.len, @intCast(i), &f, &got));
        try testing.expect(got != 0);
        defer c.macc_decoder_release_frame(dec, &f);

        if (i == 2) try check("set_overlay", c.macc_presenter_set_overlay(pr, &overlay_px, 8, 4, 8));
        c.macc_presenter_set_mode(pr, if (i % 2 == 0) c.MACC_PRESENT_LOWEST_LATENCY else c.MACC_PRESENT_SMOOTH);
        try check("draw", c.macc_presenter_draw(pr, &f, 1000));

        var px: u32 = 0;
        // 128x96 letterboxed into a 4:3 target: fills it.
        try check("read_pixel", c.macc_presenter_read_pixel(pr, pw / 2, ph / 2, &px));
        const rgb = [3]u8{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
        for (rgb, solid_rgb) |got_v, want| {
            if (!near(got_v, want, 12)) {
                std.debug.print("centre pixel 0x{X:0>8}, want ~0x{X:0>2}{X:0>2}{X:0>2}\n", .{ px, solid_rgb[0], solid_rgb[1], solid_rgb[2] });
                return error.TestUnexpectedResult;
            }
        }
        try check("read_pixel", c.macc_presenter_read_pixel(pr, 2, 2, &px));
        if (i >= 2) {
            try testing.expectEqual(@as(u32, 0x00FF00), px & 0xFFFFFF); // overlay drawn over the corner
        } else {
            try testing.expect(px & 0xFFFFFF != 0x00FF00);
        }
        var ns: u64 = 0;
        try check("present", c.macc_presenter_present(pr, &ns));
        try testing.expect(ns >= last_ns);
        last_ns = ns;
    }

    // Hiding the overlay; no frame clears to black.
    try check("set_overlay", c.macc_presenter_set_overlay(pr, null, 0, 0, 0));
    try check("draw", c.macc_presenter_draw(pr, null, 1000));
    var px: u32 = 0;
    try check("read_pixel", c.macc_presenter_read_pixel(pr, 2, 2, &px));
    try testing.expectEqual(@as(u32, 0), px & 0xFFFFFF);
    var ns: u64 = 0;
    try check("present", c.macc_presenter_present(pr, &ns));
}

fn createPresenter(win: ?*c.macc_window, w: u32, h: u32, flags: u32) !?*c.macc_presenter {
    var pr: ?*c.macc_presenter = null;
    const st = c.macc_presenter_create(win, w, h, flags, &pr);
    if (st == c.MACC_E_NO_DEVICE) {
        std.debug.print("no Metal device: skipping\n", .{});
        return error.SkipZigTest;
    }
    try check("macc_presenter_create", st);
    std.debug.print("Metal device: {s}\n", .{std.mem.span(c.macc_presenter_device_name(pr))});
    return pr;
}

test "Metal offscreen present: colour conversion, letterbox, overlay" {
    const pr = try createPresenter(null, 320, 240, 0);
    defer c.macc_presenter_destroy(pr);
    try testing.expectEqual(@as(c_int, 0), c.macc_presenter_uses_layer(pr));
    try presentFrames(pr);

    // A wider target letterboxes: black bars left and right.
    const wide = try createPresenter(null, 400, 240, 0);
    defer c.macc_presenter_destroy(wide);
    var dec: ?*c.macc_decoder = null;
    try check("macc_decoder_create", c.macc_decoder_create(c.MACC_CODEC_H264, 1, &dec));
    defer c.macc_decoder_destroy(dec);
    var aus: [16][]const u8 = undefined;
    _ = splitAccessUnits(.h264, solid_h264, &aus);
    var f: c.macc_frame = undefined;
    var got: c_int = 0;
    try check("decode", c.macc_decoder_decode(dec, aus[0].ptr, aus[0].len, 0, &f, &got));
    defer c.macc_decoder_release_frame(dec, &f);
    try check("draw", c.macc_presenter_draw(wide, &f, 1000));
    var px: u32 = 0;
    try check("read_pixel", c.macc_presenter_read_pixel(wide, 10, 120, &px));
    try testing.expectEqual(@as(u32, 0), px & 0xFFFFFF);
    try check("read_pixel", c.macc_presenter_read_pixel(wide, 200, 120, &px));
    try testing.expect(near(@truncate(px >> 16), solid_rgb[0], 12));
    var ns: u64 = 0;
    try check("present", c.macc_presenter_present(wide, &ns));
}

test "Metal present through a CAMetalLayer outside any window" {
    const pr = try createPresenter(null, 320, 240, c.MACC_PRESENTER_DETACHED_LAYER | c.MACC_PRESENTER_READBACK);
    defer c.macc_presenter_destroy(pr);
    try testing.expectEqual(@as(c_int, 1), c.macc_presenter_uses_layer(pr));
    try presentFrames(pr);
}

fn createWindow(w: u32, h: u32) !?*c.macc_window {
    var win: ?*c.macc_window = null;
    const st = c.macc_window_create(w, h, "moonsec test", c.MACC_WINDOW_VISIBLE, &win);
    if (st == c.MACC_E_NO_WINDOW) {
        std.debug.print("no window server: skipping\n", .{});
        return error.SkipZigTest;
    }
    try check("macc_window_create", st);
    return win;
}

test "Metal present into a window's CAMetalLayer" {
    const win = try createWindow(320, 240);
    defer c.macc_window_destroy(win);
    c.macc_pump_events();
    const pr = try createPresenter(win, 0, 0, c.MACC_PRESENTER_READBACK);
    defer c.macc_presenter_destroy(pr);
    var pw: u32 = 0;
    var ph: u32 = 0;
    c.macc_presenter_size(pr, &pw, &ph);
    std.debug.print("window drawable {d}x{d}\n", .{ pw, ph });
    // 320x240 points at any backing scale: still 4:3.
    try testing.expectEqual(pw * 3, ph * 4);
    try presentFrames(pr);
}

test "NSEvent input: keys, modifiers and motion through the view" {
    const win = try createWindow(64, 64);
    defer c.macc_window_destroy(win);

    try testing.expect(c.macc_window_inject(win, c.MACC_EV_KEY_DOWN, 0x00, 0, 0, 0) != 0); // A
    try testing.expect(c.macc_window_inject(win, c.MACC_EV_KEY_UP, 0x00, 0, 0, 0) != 0);
    try testing.expect(c.macc_window_inject(win, c.MACC_EV_FLAGS_CHANGED, 0x38, 0x20102, 0, 0) != 0); // Shift down
    try testing.expect(c.macc_window_inject(win, c.MACC_EV_FLAGS_CHANGED, 0x38, 0x100, 0, 0) != 0); // Shift up
    try testing.expect(c.macc_window_inject(win, c.MACC_EV_MOUSE_MOVE, 0, 0, 7, -3) != 0);

    var src: client.InputSource = .{ .window = win };
    var evs: [16]api.InputEvent = undefined;
    const n = try src.poll(&evs);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(api.InputEvent.What{ .key = .{ .code = 0x04, .down = true } }, evs[0].what);
    try testing.expectEqual(api.InputEvent.What{ .key = .{ .code = 0x04, .down = false } }, evs[1].what);
    try testing.expectEqual(api.InputEvent.What{ .key = .{ .code = 0xE1, .down = true } }, evs[2].what);
    try testing.expectEqual(api.InputEvent.What{ .key = .{ .code = 0xE1, .down = false } }, evs[3].what);
    try testing.expectEqual(api.InputEvent.What{ .move_rel = .{ .dx = 7, .dy = -3 } }, evs[4].what);
    for (evs[0..n]) |e| try testing.expect(e.time_us > 0);
    try testing.expectEqual(@as(usize, 0), try src.poll(&evs));
}

test "CoreAudio output: open, write, drain" {
    var a: ?*c.macc_audio = null;
    const st = c.macc_audio_open(48_000, 2, 1024, &a);
    if (st == c.MACC_E_NO_DEVICE) {
        std.debug.print("no audio output device on this machine: skipping\n", .{});
        return error.SkipZigTest;
    }
    try check("macc_audio_open", st);
    defer c.macc_audio_close(a);
    var ring: u32 = 0;
    var io: u32 = 0;
    var lat: u32 = 0;
    c.macc_audio_info(a, &ring, &io, &lat);
    std.debug.print("audio: ring {d} frames, device I/O {d} frames, device latency {d} frames\n", .{ ring, io, lat });
    try testing.expectEqual(@as(u32, 1024), ring);

    // 10 ms of a 440 Hz tone.
    var pcm: [480 * 2]f32 = undefined;
    for (0..480) |i| {
        const v: f32 = 0.1 * @sin(@as(f32, @floatFromInt(i)) * 2 * std.math.pi * 440 / 48_000);
        pcm[2 * i] = v;
        pcm[2 * i + 1] = v;
    }
    var written: u32 = 0;
    try check("write", c.macc_audio_write(a, &pcm, 480, &written));
    try testing.expectEqual(@as(u32, 480), written);
    try testing.expect(c.macc_audio_queued(a) <= 480);
    // Writing far more than fits accepts only what fits, and never blocks.
    var big: [48_000 * 2]f32 = @splat(0);
    try check("write", c.macc_audio_write(a, &big, 48_000, &written));
    try testing.expect(written <= ring);
    try testing.expect(c.macc_audio_queued(a) <= ring);
    // The device drains the ring.
    const deadline = client.nowUs() + 2_000_000;
    while (c.macc_audio_queued(a) > 0 and client.nowUs() < deadline) std.Thread.yield() catch {};
    std.debug.print("audio: {d} frames left after draining, {d} underrun\n", .{ c.macc_audio_queued(a), c.macc_audio_underrun_frames(a) });
}

test "openClient: the bundle through the platform interface (offscreen)" {
    const be = client.openClient(testing.allocator, .{ .offscreen = true, .width = 256, .height = 192 }) catch |e| switch (e) {
        error.NoDevice => return error.SkipZigTest,
        else => return e,
    };
    defer be.deinit();

    const t0 = be.clock.now();
    try testing.expect(t0 > 0);
    try testing.expect(be.decoder.caps().codecs.h264);
    try testing.expect(be.decoder.caps().gpu_output);

    try be.decoder.configure(.{ .codec = .h264, .width = 128, .height = 96 });
    try be.presenter.configure(.{ .width = 256, .height = 192, .mode = .lowest_latency });

    var tel = core.telemetry.Telemetry(64).init();
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(.h264, solid_h264, &aus);
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
    std.debug.print("VideoToolbox + Metal offscreen: decode p50 {d} us, present p50 {d} us\n", .{ snap.stage(.decode).p50, snap.stage(.present).p50 });

    // No window, no input.
    var evs: [8]api.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 0), try be.input.?.poll(&evs));

    // An unsupported codec is reported as such.
    try testing.expectError(error.Unsupported, be.decoder.configure(.{ .codec = .av1, .width = 1, .height = 1 }));
}

test "openClient with a window" {
    const be = client.openClient(testing.allocator, .{ .width = 256, .height = 192, .title = "moonsec bundle test" }) catch |e| switch (e) {
        error.NoWindow, error.NoDevice => return error.SkipZigTest,
        else => return e,
    };
    defer be.deinit();
    try be.decoder.configure(.{ .codec = .hevc, .width = 128, .height = 96 });
    var aus: [16][]const u8 = undefined;
    const n = splitAccessUnits(.hevc, solid_h265, &aus);
    for (aus[0..n], 0..) |au, i| {
        const fr = (try be.decoder.decode(&.{ .codec = .hevc, .frame_id = @intCast(i), .data = au, .keyframe = i == 0, .capture_us = 0, .received_us = be.clock.now() })) orelse return error.TestUnexpectedResult;
        defer be.decoder.release(&fr);
        _ = try be.presenter.present(&fr, null);
        client.pumpEvents();
    }
}
