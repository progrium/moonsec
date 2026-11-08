//! macOS host backend tests (zig build test-mac). The encoder tests run anywhere
//! VideoToolbox does, including the macos-15 CI runner (a VM: they take whatever encoder
//! VideoToolbox gives it and say which). Capture and audio need Screen Recording and
//! injection needs Accessibility; without them those tests skip. Set MOONSEC_REQUIRE to a
//! comma list (capture, audio, input, hardware, ltr, vdisplay) to turn those skips into failures.
const std = @import("std");
const api = @import("platform");
const core = @import("core");
const host = @import("host");
const c = host.c;

const testing = std.testing;

fn required(feature: []const u8) bool {
    const v = std.c.getenv("MOONSEC_REQUIRE") orelse return false;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(v), ',');
    while (it.next()) |f| if (std.mem.eql(u8, std.mem.trim(u8, f, " "), feature)) return true;
    return false;
}

fn skip(feature: []const u8, why: []const u8) !void {
    std.debug.print("skip {s}: {s}\n", .{ feature, why });
    if (required(feature)) return error.RequiredFeatureMissing;
    return error.SkipZigTest;
}

fn ok(rc: c_int) !void {
    if (rc != c.MH_OK) {
        std.debug.print("mh status {d}: {s}\n", .{ rc, host.lastError() });
        return error.MacHost;
    }
}

fn spinUs(us: i64) void {
    const end = host.nowUs() + us;
    while (host.nowUs() < end) std.atomic.spinLoopHint();
}

// ---------------------------------------------------------------------------
// Annex B helpers

const Nals = struct {
    types: [32]u8 = undefined,
    n: usize = 0,

    fn has(self: *const Nals, t: u8) bool {
        return std.mem.indexOfScalar(u8, self.types[0..self.n], t) != null;
    }
};

fn nalTypes(codec: api.Codec, data: []const u8) Nals {
    var r: Nals = .{};
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
            const h = data[i + 3];
            if (r.n < r.types.len) {
                r.types[r.n] = if (codec == .hevc) (h >> 1) & 0x3f else h & 0x1f;
                r.n += 1;
            }
            i += 3;
        }
    }
    return r;
}

fn sps(codec: api.Codec) u8 {
    return if (codec == .hevc) 33 else 7;
}

/// A test source: a ring of IOSurface pixel buffers with moving content.
const Source = struct {
    bufs: [4]?*anyopaque = @splat(null),
    width: u32,
    height: u32,
    n: u32 = 0,
    noise: bool = false,

    fn init(width: u32, height: u32, format: u32, noise: bool) !Source {
        var s: Source = .{ .width = width, .height = height, .noise = noise };
        for (&s.bufs) |*b| {
            b.* = c.mh_pixel_buffer_create(width, height, format) orelse return error.MacHost;
        }
        return s;
    }

    fn deinit(s: *Source) void {
        for (s.bufs) |b| c.mh_cf_release(b);
    }

    /// The next frame, as capture would hand it out.
    fn next(s: *Source) !api.CapturedFrame {
        const pb = s.bufs[s.n % s.bufs.len];
        try ok(c.mh_pixel_buffer_fill(pb, s.n, @intFromBool(s.noise)));
        s.n += 1;
        const now = host.nowUs();
        return .{
            .image = .{ .width = s.width, .height = s.height, .format = .nv12, .gpu = pb },
            .seq = s.n,
            .capture_start_us = now,
            .captured_us = now + @as(i64, s.n) * 16_667, // 60 fps timestamps
        };
    }
};

fn openEncoder() !host.Encoder {
    const hw = required("hardware");
    return host.Encoder.create(.{ .require_hardware = hw }) catch |e| {
        std.debug.print("no VideoToolbox encoder: {s}\n", .{host.lastError()});
        return e;
    };
}

// ---------------------------------------------------------------------------
// Tests

test {
    _ = host;
}

test "clock is mach_absolute_time in microseconds" {
    const a = host.nowUs();
    spinUs(2000);
    const b = host.nowUs();
    try testing.expect(b - a >= 2000 and b - a < 1_000_000);
    try testing.expectEqual(@as(i64, 0), c.mh_ticks_to_us(0));
}

test "VideoToolbox: which encoders this machine has" {
    var buf: [8192]u8 = undefined;
    const n = c.mh_enc_list(&buf, buf.len);
    std.debug.print("\nVTCopyVideoEncoderList:\n{s}", .{buf[0..n]});
    const Row = struct { name: []const u8, mode: u32, hw: u32 };
    const rows = [_]Row{
        .{ .name = "low-latency, hardware", .mode = c.MH_ENC_LOW_LATENCY, .hw = 1 },
        .{ .name = "low-latency, any", .mode = c.MH_ENC_LOW_LATENCY, .hw = 0 },
        .{ .name = "regular, hardware", .mode = c.MH_ENC_REGULAR, .hw = 1 },
        .{ .name = "regular, any", .mode = c.MH_ENC_REGULAR, .hw = 0 },
    };
    std.debug.print("session probes (640x360):\n", .{});
    for (rows) |r| {
        const o: c.mh_enc_options = .{ .mode = r.mode, .require_hw = r.hw, .expected_fps = 1000 };
        for ([_]u32{ c.MH_CODEC_H264, c.MH_CODEC_HEVC }) |codec| {
            for ([_]u32{ 0, 1 }) |ltr| {
                if (ltr == 1 and r.mode == c.MH_ENC_REGULAR) continue;
                var info: c.mh_enc_info = undefined;
                const rc = c.mh_enc_probe(&o, codec, ltr, &info);
                const cname = if (codec == c.MH_CODEC_HEVC) "HEVC " else "H.264";
                if (rc == c.MH_OK) {
                    std.debug.print("  {s} {s}{s}: ok, {s}, {s}\n", .{ r.name, cname, if (ltr == 1) " +LTR" else "", std.mem.sliceTo(&info.encoder_id, 0), if (info.hardware != 0) "hardware" else "software" });
                } else {
                    std.debug.print("  {s} {s}{s}: no ({s})\n", .{ r.name, cname, if (ltr == 1) " +LTR" else "", host.lastError() });
                }
            }
        }
    }
    var e = try openEncoder();
    defer e.deinit();
    std.debug.print("chosen: {s} on {s}; ltr {}\n", .{ @tagName(e.mode), if (e.hardware) "hardware" else "software", e.ltr });
    if (!e.hardware) try skip("hardware", "VideoToolbox has only a software encoder here");
}

fn encodeAndDecode(codec: api.Codec) !void {
    var e = try openEncoder();
    defer e.deinit();
    if (!e.codecs.has(codec)) return skip(@tagName(codec), "encoder lacks the codec");
    try e.configure(.{ .codec = codec, .width = 640, .height = 360, .fps = 60, .bitrate_bps = 4_000_000, .ltr = e.ltr });
    var src = try Source.init(640, 360, c.MH_FMT_NV12, false);
    defer src.deinit();
    var dec: ?*c.mh_dec = null;
    try ok(c.mh_dec_create(if (codec == .hevc) c.MH_CODEC_HEVC else c.MH_CODEC_H264, &dec));
    defer c.mh_dec_destroy(dec);
    var encoded: u32 = 0;
    var keyframes: u32 = 0;
    var max_us: i64 = 0;
    for (0..60) |i| {
        const f = try src.next();
        const out = (try e.encode(&f, .{})) orelse continue;
        encoded += 1;
        max_us = @max(max_us, out.encoded_us - out.encode_start_us);
        try testing.expectEqual(@as(usize, 1), out.slices.len);
        const au = out.slices[0];
        try testing.expect(au.len > 4 and std.mem.eql(u8, au[0..4], &.{ 0, 0, 0, 1 }));
        const nals = nalTypes(codec, au);
        if (i == 0) {
            try testing.expect(out.keyframe);
            try testing.expect(nals.has(sps(codec)));
        }
        if (out.keyframe) keyframes += 1;
        try testing.expectEqual(out.keyframe, nals.has(sps(codec)));
        var hash: u64 = 0;
        const st = c.mh_dec_decode(dec, au.ptr, au.len, &hash);
        if (st != 0) {
            std.debug.print("decode of frame {d} failed: {d}\n", .{ i, st });
            return error.DecodeFailed;
        }
    }
    std.debug.print("{s}: {d}/60 frames, {d} keyframes, slowest encode {d} us ({s})\n", .{ @tagName(codec), encoded, keyframes, max_us, std.mem.sliceTo(&e.info().encoder_id, 0) });
    try testing.expect(encoded >= 50);
    // No periodic keyframes.
    try testing.expectEqual(@as(u32, 1), keyframes);
}

test "VideoToolbox H.264: Annex B out, decodes, one keyframe" {
    try encodeAndDecode(.h264);
}

test "VideoToolbox HEVC: Annex B out, decodes, one keyframe" {
    try encodeAndDecode(.hevc);
}

test "VideoToolbox: bitrate changes without a keyframe; IDR on request" {
    var e = try openEncoder();
    defer e.deinit();
    try e.configure(.{ .codec = .h264, .width = 640, .height = 360, .fps = 60, .bitrate_bps = 6_000_000 });
    var src = try Source.init(640, 360, c.MH_FMT_NV12, true);
    defer src.deinit();
    var bytes_hi: usize = 0;
    var bytes_lo: usize = 0;
    var n_hi: usize = 0;
    var n_lo: usize = 0;
    for (0..90) |i| {
        const f = try src.next();
        const p: api.EncodeParams = .{
            .bitrate_bps = if (i == 45) 1_000_000 else 0,
            .force = if (i == 89) .idr else .none,
        };
        const out = (try e.encode(&f, p)) orelse continue;
        if (i == 0) continue;
        if (i == 89) {
            try testing.expect(out.keyframe);
            continue;
        }
        try testing.expect(!out.keyframe);
        if (i >= 15 and i < 45) {
            bytes_hi += out.slices[0].len;
            n_hi += 1;
        } else if (i >= 60) {
            bytes_lo += out.slices[0].len;
            n_lo += 1;
        }
    }
    const hi = bytes_hi / @max(n_hi, 1);
    const lo = bytes_lo / @max(n_lo, 1);
    std.debug.print("mean frame at 6 Mbit/s {d} B, at 1 Mbit/s {d} B\n", .{ hi, lo });
    try testing.expect(lo * 2 < hi);
}

test "VideoToolbox: long-term reference refresh recovers a loss without an IDR" {
    var e = try openEncoder();
    defer e.deinit();
    if (!e.ltr) return skip("ltr", "no low-latency encoder with LTR here");
    const codec: api.Codec = if (e.codecs.hevc) .hevc else .h264;
    try e.configure(.{ .codec = codec, .width = 640, .height = 360, .fps = 60, .bitrate_bps = 4_000_000, .ltr = true });
    var src = try Source.init(640, 360, c.MH_FMT_NV12, false);
    defer src.deinit();

    // S8's scenario: the client acks each frame's token 3 frames later; frames 30..34 are
    // lost (nothing acked from there until the refresh); the host hears at frame 38 and
    // forces an LTR refresh.
    const total = 60;
    const lost_from = 30;
    const refresh_at = 38;
    const ack_delay = 3;
    var aus: [total]?[]u8 = @splat(null);
    defer for (aus) |a| if (a) |b| testing.allocator.free(b);
    var tokens: [total]?u64 = @splat(null);
    var refresh_key = false;
    var refresh_flag = false;
    for (0..total) |i| {
        var acks: [4]u64 = undefined;
        var n_acks: usize = 0;
        if (i >= ack_delay) {
            const j = i - ack_delay;
            const dropped = j >= lost_from and j < refresh_at;
            if (tokens[j]) |t| {
                if (!dropped) {
                    acks[n_acks] = t;
                    n_acks += 1;
                }
            }
        }
        const f = try src.next();
        const out = (try e.encode(&f, .{ .force = if (i == refresh_at) .ltr_refresh else .none, .acked_ltr_tokens = acks[0..n_acks] })) orelse continue;
        aus[i] = try testing.allocator.dupe(u8, out.slices[0]);
        tokens[i] = out.ltr_token;
        if (i == refresh_at) {
            refresh_key = out.keyframe;
            refresh_flag = out.ltr_refresh;
        }
    }
    var with_tokens: usize = 0;
    for (tokens) |t| with_tokens += @intFromBool(t != null);
    std.debug.print("LTR ({s}): {d} frames carried tokens; refresh frame {s}, {d} B\n", .{ @tagName(codec), with_tokens, if (refresh_key) "IDR" else "P", if (aus[refresh_at]) |a| a.len else 0 });
    try testing.expect(with_tokens > 0);
    try testing.expect(aus[refresh_at] != null);
    try testing.expect(!refresh_key);
    try testing.expect(refresh_flag);

    // Decode the full stream and the client's (dropping from the loss until the refresh);
    // from the refresh on they must match bit for bit.
    const cc: u32 = if (codec == .hevc) c.MH_CODEC_HEVC else c.MH_CODEC_H264;
    var full: ?*c.mh_dec = null;
    var lossy: ?*c.mh_dec = null;
    try ok(c.mh_dec_create(cc, &full));
    defer c.mh_dec_destroy(full);
    try ok(c.mh_dec_create(cc, &lossy));
    defer c.mh_dec_destroy(lossy);
    for (aus, 0..) |maybe, i| {
        const au = maybe orelse continue;
        var ha: u64 = 0;
        try testing.expectEqual(@as(c_int, 0), c.mh_dec_decode(full, au.ptr, au.len, &ha));
        if (i >= lost_from and i < refresh_at) continue;
        var hb: u64 = 0;
        const st = c.mh_dec_decode(lossy, au.ptr, au.len, &hb);
        if (i >= refresh_at) {
            if (st != 0 or ha != hb) {
                std.debug.print("frame {d}: lossy decode {d}, hash match {}\n", .{ i, st, ha == hb });
                return error.NotRecovered;
            }
        }
    }
}

test "VideoToolbox: ladder reconfigure keeps the session for bitrate, scales mismatched frames" {
    var e = try openEncoder();
    defer e.deinit();
    try e.configure(.{ .codec = .h264, .width = 1280, .height = 720, .fps = 60, .bitrate_bps = 8_000_000 });
    var big = try Source.init(1280, 720, c.MH_FMT_BGRA, false);
    defer big.deinit();
    _ = try e.encode(&(try big.next()), .{});
    const s0 = e.info().sessions;
    // Bitrate and frame rate: same session, no keyframe.
    try e.configure(.{ .codec = .h264, .width = 1280, .height = 720, .fps = 30, .bitrate_bps = 3_000_000 });
    try testing.expectEqual(s0, e.info().sessions);
    if (try e.encode(&(try big.next()), .{})) |out| try testing.expect(!out.keyframe);
    // A ladder step down in size: a new session, fed the old capture size and scaled.
    try e.configure(.{ .codec = .h264, .width = 640, .height = 360, .fps = 30, .bitrate_bps = 1_500_000 });
    try testing.expectEqual(s0 + 1, e.info().sessions);
    var dec: ?*c.mh_dec = null;
    try ok(c.mh_dec_create(c.MH_CODEC_H264, &dec));
    defer c.mh_dec_destroy(dec);
    var got = false;
    for (0..5) |_| {
        const out = (try e.encode(&(try big.next()), .{})) orelse continue;
        if (!got) try testing.expect(out.keyframe);
        got = true;
        var h: u64 = 0;
        try testing.expectEqual(@as(c_int, 0), c.mh_dec_decode(dec, out.slices[0].ptr, out.slices[0].len, &h));
    }
    try testing.expect(got);
}

test "openHost: the bundle's encoder works through the platform interface" {
    const be = try host.openHost(testing.allocator, .{ .audio = false, .input = false });
    defer be.deinit();
    const caps = be.encoder.caps();
    try testing.expect(caps.codecs.h264 or caps.codecs.hevc);
    try testing.expect(caps.gpu_input);
    const codec: api.Codec = if (caps.codecs.h264) .h264 else .hevc;
    try be.encoder.configure(.{ .codec = codec, .width = 320, .height = 240, .bitrate_bps = 1_000_000, .ltr = caps.ltr });
    var src = try Source.init(320, 240, c.MH_FMT_NV12, false);
    defer src.deinit();
    const out = (try be.encoder.encode(&(try src.next()), .{})).?;
    try testing.expect(out.keyframe);
    try testing.expect(out.encoded_us >= out.encode_start_us);
    try testing.expect(be.clock.now() >= out.encoded_us);
    // Ladder hook on a bundle whose capture isn't running: the encoder takes the rung.
    try host.Host.fromBackend(be).applyRung(.{ .width = 160, .height = 120, .fps = 30 });
    try testing.expect((try be.encoder.encode(&(try src.next()), .{})).?.keyframe);
}

test "ScreenCaptureKit: display frames with timestamps" {
    if (!host.screenCaptureAllowed()) return skip("capture", "no Screen Recording permission");
    var cap = try host.Capture.create(.nv12);
    defer cap.destroy();
    const size = try cap.start(.{ .fps = 30, .width = 1280, .height = 720 });
    try testing.expectEqual(@as(u32, 1280), size.width);
    var frames: u32 = 0;
    var last_seq: u64 = 0;
    const deadline = host.nowUs() + 3_000_000;
    while (frames < 5 and host.nowUs() < deadline) {
        const f = (try cap.acquire(500_000)) orelse continue;
        defer cap.release(&f);
        const now = host.nowUs();
        try testing.expect(f.image.gpu != null);
        try testing.expectEqual(api.PixelFormat.nv12, f.image.format);
        try testing.expect(f.captured_us <= now);
        try testing.expect(now - f.captured_us < 1_000_000);
        try testing.expect(f.seq > last_seq);
        last_seq = f.seq;
        frames += 1;
    }
    const st = cap.stats();
    std.debug.print("capture: {d} acquired; SCK complete {d}, replaced {d}, stale {d}, late {d} (max {d} us), idle {d}\n", .{ frames, st.complete, st.replaced, st.stale, st.late, st.max_late_us, st.idle });
    // A static screen may produce one frame and then only idle ones.
    if (frames == 0) return error.NoFrames;
    const r = (try cap.repeatLast()).?;
    try testing.expect(r.repeat);
    cap.release(&r);
    try cap.resize(640, 360, 15);
    cap.stop();
}

test "ScreenCaptureKit: system audio" {
    if (!host.screenCaptureAllowed()) return skip("audio", "no Screen Recording permission");
    var a = try host.Audio.create(0);
    defer a.destroy();
    _ = try a.start(.{});
    defer a.stop();
    var buf: [960 * 2]f32 = undefined;
    var total: usize = 0;
    const deadline = host.nowUs() + 1_000_000;
    while (host.nowUs() < deadline) {
        const ch = try a.read(&buf, 100_000);
        if (ch.frames > 0) try testing.expect(ch.time_us <= host.nowUs());
        total += ch.frames;
    }
    std.debug.print("audio: {d} frames in 1 s\n", .{total});
}

test "CGEvent: absolute and relative pointer moves" {
    if (!host.postEventAllowed()) return skip("input", "no Accessibility permission");
    var inj = try host.Injector.create(0);
    defer inj.destroy();
    var bx: f64 = 0;
    var by: f64 = 0;
    var bw: f64 = 0;
    var bh: f64 = 0;
    try ok(c.mh_display_bounds(0, &bx, &by, &bw, &bh));
    try inj.inject(.{ .abs = .{ .x = 32768, .y = 32768 } });
    var x: f64 = 0;
    var y: f64 = 0;
    c.mh_input_cursor(&x, &y);
    try testing.expectApproxEqAbs(bx + bw / 2, x, 2);
    try testing.expectApproxEqAbs(by + bh / 2, y, 2);
    try inj.inject(.{ .motion = .{ .dx = 10, .dy = -5 } });
    c.mh_input_cursor(&x, &y);
    try testing.expectApproxEqAbs(bx + bw / 2 + 10, x, 2);
    try testing.expectApproxEqAbs(by + bh / 2 - 5, y, 2);
    // A shift tap and an unmapped key are not errors.
    try inj.inject(.{ .key = .{ .code = 0xE1, .down = true, .time = 0 } });
    try inj.inject(.{ .key = .{ .code = 0xE1, .down = false, .time = 0 } });
    try inj.inject(.{ .key = .{ .code = 0x01, .down = true, .time = 0 } });
    try testing.expectEqual(@as(u32, 1), inj.unmapped);
    try testing.expectEqual(@as(u32, 0), inj.failed);
}

// ---------------------------------------------------------------------------
// Virtual displays (CGVirtualDisplay, private API). Creating one needs no permission, so
// this runs on the CI runner; capturing it needs Screen Recording like any display.

test "CGVirtualDisplay: create, re-mode, remove" {
    if (c.mh_vdisplay_available() == 0) return skip("vdisplay", "CGVirtualDisplay classes not available on this macOS");
    const before = c.mh_display_count(0);
    var v: ?*c.mh_vdisplay = null;
    const rc = c.mh_vdisplay_create(1280, 720, 60, 3000, &v);
    if (rc != c.MH_OK) {
        std.debug.print("CGVirtualDisplay create failed ({d}): {s}\n", .{ rc, host.lastError() });
        return skip("vdisplay", "CGVirtualDisplay create failed");
    }
    const id = c.mh_vdisplay_id(v);
    var index: u32 = 0;
    try ok(c.mh_vdisplay_index(v, &index));
    std.debug.print("CGVirtualDisplay: id {d}, index {d}, displays {d} -> {d}\n", .{ id, index, before, c.mh_display_count(0) });
    try testing.expectEqual(before + 1, c.mh_display_count(0));
    try testing.expectEqual(before, c.mh_display_count(id));
    var w: u32 = 0;
    var h: u32 = 0;
    try ok(c.mh_display_pixels(index, &w, &h));
    try testing.expectEqual(@as(u32, 1280), w);
    try testing.expectEqual(@as(u32, 720), h);

    // A smaller mode fits the display as made; a larger one needs a new display.
    try ok(c.mh_vdisplay_set_mode(v, 1024, 576, 60));
    try ok(c.mh_display_pixels(index, &w, &h));
    try testing.expectEqual(@as(u32, 1024), w);
    try testing.expectEqual(@as(c_int, c.MH_ERR_UNSUPPORTED), c.mh_vdisplay_set_mode(v, 1920, 1080, 60));

    c.mh_vdisplay_destroy(v);
    try testing.expectEqual(before, c.mh_display_count(0));
}

test "virtual display: the backend captures it at the requested size" {
    if (c.mh_vdisplay_available() == 0) return skip("vdisplay", "CGVirtualDisplay classes not available on this macOS");
    if (!host.screenCaptureAllowed()) return skip("capture", "no Screen Recording permission (virtual display capture)");
    const be = try host.openHost(testing.allocator, .{ .audio = false, .input = false });
    defer be.deinit();
    const before = c.mh_display_count(0);
    const size = try be.capture.start(.{ .virtual_display = .always, .width = 1280, .height = 720, .fps = 60 });
    try testing.expectEqual(api.Size{ .width = 1280, .height = 720 }, size);
    const h = host.Host.fromBackend(be);
    try testing.expectEqual(api.virtual_display.Source.virtual, h.capture.source);
    try testing.expectEqual(before + 1, c.mh_display_count(0));
    var got: ?api.CapturedFrame = null;
    var tries: u32 = 0;
    while (got == null and tries < 20) : (tries += 1) got = try be.capture.acquire(100_000);
    if (got) |f| {
        try testing.expectEqual(@as(u32, 1280), f.image.width);
        be.capture.release(&f);
    } else std.debug.print("no frame from the virtual display in 2 s\n", .{});
    // A new size mid-session: larger than made, so a new display replaces it.
    const size2 = try be.capture.start(.{ .virtual_display = .always, .width = 1920, .height = 1080, .fps = 60 });
    try testing.expectEqual(api.Size{ .width = 1920, .height = 1080 }, size2);
    be.capture.stop();
    try testing.expectEqual(before, c.mh_display_count(0));
}
