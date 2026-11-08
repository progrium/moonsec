//! macOS host backend tests (zig build test-mac). The encoder tests run anywhere
//! VideoToolbox does, including the macos-15 CI runner (a VM: they take whatever encoder
//! VideoToolbox gives it and say which). Capture and audio need Screen Recording and
//! injection needs Accessibility; without them those tests skip. Set MOONSEC_REQUIRE to a
//! comma list (capture, audio, input, hardware, ltr) to turn those skips into failures.
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
    start_us: i64 = 0,

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

    /// The next frame, as capture would hand it out: paced at 60 fps in real time, since
    /// a real-time encoder may drop frames that come faster than their timestamps.
    fn next(s: *Source) !api.CapturedFrame {
        const pb = s.bufs[s.n % s.bufs.len];
        try ok(c.mh_pixel_buffer_fill(pb, s.n, @intFromBool(s.noise)));
        if (s.n == 0) s.start_us = host.nowUs();
        const due = s.start_us + @as(i64, s.n) * 16_667;
        while (host.nowUs() < due) std.atomic.spinLoopHint();
        s.n += 1;
        return .{
            .image = .{ .width = s.width, .height = s.height, .format = .nv12, .gpu = pb },
            .seq = s.n,
            .capture_start_us = due,
            .captured_us = due,
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
    // The low-latency encoder explicitly: it is the only one with LTR (S8), and in a VM
    // `auto` picks the regular one.
    var e = host.Encoder.create(.{ .mode = .low_latency }) catch return skip("ltr", "no low-latency encoder");
    defer e.deinit();
    if (!e.ltr) return skip("ltr", "the low-latency encoder refused EnableLTR");
    const codec: api.Codec = if (e.codecs.hevc) .hevc else .h264;
    try e.configure(.{ .codec = codec, .width = 640, .height = 360, .fps = 60, .bitrate_bps = 4_000_000, .ltr = true });
    var src = try Source.init(640, 360, c.MH_FMT_NV12, false);
    defer src.deinit();

    // S8's scenario: the client acks each frame's token 3 frames later; from frame 30 it
    // loses everything (acks nothing) until the refresh; the host hears at frame 38 and
    // asks for an LTR refresh on every frame until one comes out (the encoder may drop
    // a frame, and the app then asks again, as core/recovery does).
    const total = 72;
    const lost_from = 30;
    const detect_at = 38;
    const ack_delay = 3;
    var aus: [total]?[]u8 = @splat(null);
    defer for (aus) |a| if (a) |buf| testing.allocator.free(buf);
    var tokens: [total]?u64 = @splat(null);
    var refresh_at: ?usize = null;
    var refresh_key = false;
    var refresh_flag = false;
    var drops: u32 = 0;
    for (0..total) |i| {
        var acks: [1]u64 = undefined;
        var n_acks: usize = 0;
        if (i >= ack_delay) {
            const j = i - ack_delay;
            const lost = j >= lost_from and (refresh_at == null or j < refresh_at.?);
            if (tokens[j]) |t| {
                if (!lost) {
                    acks[0] = t;
                    n_acks = 1;
                }
            }
        }
        const want_refresh = i >= detect_at and refresh_at == null;
        const f = try src.next();
        const out = (try e.encode(&f, .{ .force = if (want_refresh) .ltr_refresh else .none, .acked_ltr_tokens = acks[0..n_acks] })) orelse {
            drops += 1;
            continue;
        };
        aus[i] = try testing.allocator.dupe(u8, out.slices[0]);
        tokens[i] = out.ltr_token;
        if (want_refresh) {
            refresh_at = i;
            refresh_key = out.keyframe;
            refresh_flag = out.ltr_refresh;
        }
    }
    var with_tokens: usize = 0;
    for (tokens) |t| with_tokens += @intFromBool(t != null);
    const info = e.info();
    std.debug.print("LTR ({s}, {s}): {d} frames carried tokens, {d} dropped by the encoder; refresh at {?d}: {s}, {d} B\n", .{
        @tagName(codec),
        std.mem.sliceTo(&info.encoder_id, 0),
        with_tokens,
        drops,
        refresh_at,
        if (refresh_key) "IDR" else "P",
        if (refresh_at) |r| aus[r].?.len else 0,
    });
    try testing.expect(with_tokens > 0);
    const rf = refresh_at orelse return error.NoRefreshFrame;
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
    var matched: u32 = 0;
    for (aus, 0..) |maybe, i| {
        const au = maybe orelse continue;
        var ha: u64 = 0;
        try testing.expectEqual(@as(c_int, 0), c.mh_dec_decode(full, au.ptr, au.len, &ha));
        if (i >= lost_from and i < rf) continue;
        var hb: u64 = 0;
        const st = c.mh_dec_decode(lossy, au.ptr, au.len, &hb);
        if (i >= rf) {
            if (st != 0 or ha != hb) {
                std.debug.print("frame {d}: lossy decode {d}, hash match {}\n", .{ i, st, ha == hb });
                return error.NotRecovered;
            }
            matched += 1;
        }
    }
    std.debug.print("LTR: {d} frames from the refresh on decode bit-exact on the lossy stream\n", .{matched});
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

fn cursorReaches(want_x: f64, want_y: f64) bool {
    const deadline = host.nowUs() + 1_000_000;
    var x: f64 = 0;
    var y: f64 = 0;
    while (host.nowUs() < deadline) {
        c.mh_input_cursor(&x, &y);
        if (@abs(x - want_x) <= 2 and @abs(y - want_y) <= 2) return true;
        spinUs(5_000);
    }
    std.debug.print("cursor at {d:.0},{d:.0}, wanted {d:.0},{d:.0}\n", .{ x, y, want_x, want_y });
    return false;
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
    // CGEventPost is asynchronous: wait for the cursor to get there.
    if (!cursorReaches(bx + bw / 2, by + bh / 2))
        return skip("input", "events were posted but the cursor did not move (no HID event delivery here)");
    try inj.inject(.{ .motion = .{ .dx = 10, .dy = -5 } });
    try testing.expect(cursorReaches(bx + bw / 2 + 10, by + bh / 2 - 5));
    // A shift tap and an unmapped key are not errors.
    try inj.inject(.{ .key = .{ .code = 0xE1, .down = true, .time = 0 } });
    try inj.inject(.{ .key = .{ .code = 0xE1, .down = false, .time = 0 } });
    try inj.inject(.{ .key = .{ .code = 0x01, .down = true, .time = 0 } });
    try testing.expectEqual(@as(u32, 1), inj.unmapped);
    try testing.expectEqual(@as(u32, 0), inj.failed);
}
