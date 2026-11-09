//! Windows host backend tests (zig build test-win). They run on the GPU-less windows-2022
//! runner: WARP for the device, Media Foundation's software encoder, and skips for
//! hardware that is not there. Set MOONSEC_REQUIRE to a comma list (dup, mf, nvenc, audio,
//! input) to turn those skips into failures; CI requires what its runner has.
const std = @import("std");
const api = @import("platform");
const win = @import("win");
const host = @import("host");
const c = host.c;

const testing = std.testing;

fn required(feature: []const u8) bool {
    const v = std.c.getenv("MOONSEC_REQUIRE") orelse return false;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(v), ',');
    while (it.next()) |f| if (std.mem.eql(u8, std.mem.trim(u8, f, " "), feature)) return true;
    return false;
}

/// Prints why a test is skipped; fails instead when MOONSEC_REQUIRE names the feature.
fn skip(feature: []const u8, why: []const u8, hr: i32) !void {
    std.debug.print("skip {s}: {s} {f}\n", .{ feature, why, win.fmtHr(hr) });
    if (required(feature)) return error.RequiredFeatureMissing;
    return error.SkipZigTest;
}

fn hrOk(hr: i32) !void {
    if (hr < 0) {
        std.debug.print("HRESULT {f}\n", .{win.fmtHr(hr)});
        return error.Win32;
    }
}

const NalTypes = struct {
    types: [32]u8 = undefined,
    n: usize = 0,
    fn has(self: *const NalTypes, t: u8) bool {
        return std.mem.indexOfScalar(u8, self.types[0..self.n], t) != null;
    }
};

fn h264Nals(data: []const u8) NalTypes {
    var r: NalTypes = .{};
    var it = host.nextNal(data, 0);
    while (it) |nal| : (it = host.nextNal(data, nal.payload)) {
        if (r.n < r.types.len) {
            r.types[r.n] = nal.type & 0x1f;
            r.n += 1;
        }
    }
    return r;
}

test {
    _ = host;
}

test "HID usages map to scan codes" {
    try testing.expectEqual(@as(u32, 0x1E), c.msw_hid_to_scancode(0x04)); // a
    try testing.expectEqual(@as(u32, 0x1C), c.msw_hid_to_scancode(0x28)); // enter
    try testing.expectEqual(@as(u32, 0x148), c.msw_hid_to_scancode(0x52)); // up (E0)
    try testing.expectEqual(@as(u32, 0x11D), c.msw_hid_to_scancode(0xE4)); // right ctrl (E0)
    try testing.expectEqual(@as(u32, 0), c.msw_hid_to_scancode(0x01));
    // Every usage from a to right GUI that is mapped has a distinct scan code.
    var seen = std.StaticBitSet(512).initEmpty();
    var u: u16 = 0x04;
    while (u <= 0xE7) : (u += 1) {
        const sc = c.msw_hid_to_scancode(u);
        if (sc == 0 or u == 0x32 or u == 0x53 or u == 0x48) continue; // # aliases \ ; numlock/pause share 0x45
        try testing.expect(!seen.isSet(sc));
        seen.set(sc);
    }
}

test "Desktop Duplication delivers BGRA frames" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d = try win.D3d.create(.{ .driver = .hardware });
    defer d.destroy();
    var dup: ?*c.msw_dup = null;
    const hr = c.msw_dup_create(host.dev(d), 0, &dup);
    if (hr < 0) return skip("dup", "no output to duplicate on adapter 0:", hr);
    defer c.msw_dup_destroy(dup);
    var w: u32 = 0;
    var h: u32 = 0;
    c.msw_dup_size(dup, &w, &h);
    std.debug.print("duplicating {d}x{d}\n", .{ w, h });
    try testing.expect(w > 0 and h > 0);
    // The first acquire always returns the current desktop image.
    var f: c.msw_dup_frame = undefined;
    var got = false;
    for (0..20) |_| {
        const r = c.msw_dup_acquire(dup, 100, &f);
        if (@as(u32, @bitCast(r)) == 0x887A0027) continue;
        try hrOk(r);
        if (f.present_ns != 0) {
            got = true;
            break;
        }
    }
    try testing.expect(got);
    try testing.expectEqual(w, f.width);
    const px = try testing.allocator.alloc(u8, @as(usize, w) * h * 4);
    defer testing.allocator.free(px);
    try hrOk(c.msw_texture_read(host.dev(d), f.texture, 0, px.ptr, w * 4));
    // A desktop is opaque.
    try testing.expectEqual(@as(u8, 0xFF), px[3]);
}

fn encodeSequence(d: win.D3d, kind: c.msw_enc_kind, codec: u32, ltr: bool) !void {
    var e: ?*c.msw_enc = null;
    const hr = c.msw_enc_create(host.dev(d), kind, &e);
    if (hr < 0) return skip(if (kind == c.MSW_ENC_NVENC) "nvenc" else "mf", "encoder unavailable:", hr);
    defer c.msw_enc_destroy(e);
    var caps: c.msw_enc_caps = undefined;
    c.msw_enc_caps_get(e, &caps);
    const w: u32 = 640;
    const h: u32 = 360;
    const cfg: c.msw_enc_config = .{ .codec = codec, .width = w, .height = h, .fps = 60, .bitrate_bps = 2_000_000, .slices = 1, .ltr = @intFromBool(ltr and caps.ltr != 0) };
    try hrOk(c.msw_enc_configure(e, &cfg));
    var tex: ?*anyopaque = null;
    try hrOk(c.msw_texture_create(host.dev(d), w, h, 0xFF204060, &tex));
    defer c.msw_texture_release(tex);

    var sizes: [40]usize = undefined;
    var keyframes: u32 = 0;
    var produced: u32 = 0;
    for (0..40) |i| {
        // Fresh noise every frame, so every frame is limited by the bitrate.
        try hrOk(c.msw_texture_noise(host.dev(d), tex, @intCast(i + 1)));
        var p: c.msw_enc_params = .{ .force = c.MSW_FORCE_NONE, .bitrate_bps = 0, .acked_ltr_tokens = null, .acked_ltr_count = 0 };
        if (i == 15) p.bitrate_bps = 500_000; // per-frame bitrate change: must not cost an IDR
        if (i == 30) p.force = c.MSW_FORCE_IDR;
        var out: c.msw_enc_output = undefined;
        const t0 = win.qpcNs();
        try hrOk(c.msw_enc_encode(e, tex, 0, @as(u64, i) * 16_667, &p, &out));
        const dt = win.qpcNs() - t0;
        sizes[i] = out.len;
        if (out.dropped != 0) {
            std.debug.print("frame {d}: dropped\n", .{i});
            continue;
        }
        produced += 1;
        const nals = h264Nals(out.data[0..out.len]);
        const idr = if (codec == c.MSW_CODEC_H264) nals.has(5) else out.keyframe != 0;
        if (idr) keyframes += 1;
        if (i < 3 or i == 15 or i == 16 or i == 30 or i == 31)
            std.debug.print("frame {d}: {d} bytes keyframe={d} idr={} nals={any} ltr={d}:{d} {d} us\n", .{ i, out.len, out.keyframe, idr, nals.types[0..nals.n], out.has_ltr_token, out.ltr_token, dt / 1000 });
        if (i == 0) {
            try testing.expect(idr);
            if (codec == c.MSW_CODEC_H264) try testing.expect(nals.has(7) and nals.has(8));
        } else if (i == 30) {
            try testing.expect(idr);
        } else {
            try testing.expect(!idr);
        }
    }
    try testing.expectEqual(@as(u32, 40), produced);
    try testing.expectEqual(@as(u32, 2), keyframes);
    // The lower bitrate shows up as smaller frames (frames 20..29 vs 5..14).
    var hi: usize = 0;
    var lo: usize = 0;
    for (5..15) |i| hi += sizes[i];
    for (20..30) |i| lo += sizes[i];
    std.debug.print("P-frame bytes at 2 Mbit/s: {d}, at 0.5 Mbit/s: {d}\n", .{ hi / 10, lo / 10 });
    try testing.expect(lo < hi);
}

test "Media Foundation software H.264 on WARP: keyframes, bitrate change, forced IDR" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d = try win.D3d.create(.{ .driver = .warp });
    defer d.destroy();
    try encodeSequence(d, c.MSW_ENC_MF_SOFTWARE, c.MSW_CODEC_H264, false);
}

test "NVENC H.264 and HEVC with LTR (NVIDIA GPU only)" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d = try win.D3d.create(.{ .driver = .hardware });
    defer d.destroy();
    try encodeSequence(d, c.MSW_ENC_NVENC, c.MSW_CODEC_H264, true);
    try encodeSequence(d, c.MSW_ENC_NVENC, c.MSW_CODEC_HEVC, true);
}

test "WASAPI loopback opens and reads" {
    const com = try win.ComThread.init();
    defer com.deinit();
    var lb: ?*c.msw_loopback = null;
    const hr = c.msw_loopback_create(2, &lb);
    if (hr < 0) return skip("audio", "no render endpoint:", hr);
    defer c.msw_loopback_destroy(lb);
    try hrOk(c.msw_loopback_start(lb));
    var buf: [2 * 960]f32 = undefined;
    var frames: u32 = 0;
    var t: u64 = 0;
    // Nothing is playing, so loopback may deliver nothing; it must not fail.
    try hrOk(c.msw_loopback_read(lb, &buf, 960, 50, &frames, &t));
    std.debug.print("loopback: {d} frames in 50 ms\n", .{frames});
    c.msw_loopback_stop(lb);
}

const POINT = extern struct { x: i32, y: i32 };
extern "user32" fn GetCursorPos(p: *POINT) callconv(.winapi) c_int;
extern "user32" fn SetCursorPos(x: c_int, y: c_int) callconv(.winapi) c_int;
extern "user32" fn GetAsyncKeyState(vk: c_int) callconv(.winapi) i16;

test "SendInput moves the pointer and holds a key" {
    var r: [4]i32 = undefined;
    c.msw_input_primary_rect(&r[0], &r[1], &r[2], &r[3]);
    std.debug.print("primary display {d}x{d}\n", .{ r[2], r[3] });
    if (SetCursorPos(10, 10) == 0) return skip("input", "SetCursorPos failed (no interactive desktop)", 0);
    const hr = c.msw_input_move_abs(32768, 32768, r[0], r[1], r[2], r[3]);
    if (hr < 0) return skip("input", "SendInput refused:", hr);
    var p: POINT = undefined;
    try testing.expect(GetCursorPos(&p) != 0);
    try testing.expect(@abs(p.x - @divTrunc(r[2], 2)) <= 1);
    try testing.expect(@abs(p.y - @divTrunc(r[3], 2)) <= 1);

    // Relative moves are subject to pointer acceleration; check direction only.
    try hrOk(c.msw_input_move_rel(-20, 0));
    var q: POINT = undefined;
    _ = GetCursorPos(&q);
    try testing.expect(q.x < p.x);

    // Left shift by scan code (HID 0xE1), observed through the async key state.
    const VK_LSHIFT = 0xA0;
    try hrOk(c.msw_input_key(0xE1, 1));
    const held = GetAsyncKeyState(VK_LSHIFT) < 0;
    try hrOk(c.msw_input_key(0xE1, 0));
    const released = GetAsyncKeyState(VK_LSHIFT) >= 0;
    try testing.expect(held and released);
}

test "openHost on WARP: the bundle encodes through the platform interface" {
    const b = try host.openHost(testing.allocator, .{ .driver = .warp, .encoder = .mf_software, .audio = true, .input = true });
    defer b.deinit();
    // WARP has no outputs, so capture cannot start there.
    try testing.expectError(error.Unsupported, b.capture.start(.{}));
    const caps = b.encoder.caps();
    try testing.expect(caps.codecs.has(.h264) and caps.gpu_input);
    try b.encoder.configure(.{ .codec = .h264, .width = 320, .height = 180, .bitrate_bps = 1_000_000 });

    // Feed it a texture on the bundle's own device.
    const self: *host.Host = @ptrCast(@alignCast(b.deinit_ptr.?));
    var tex: ?*anyopaque = null;
    try hrOk(c.msw_texture_create(host.dev(self.d3d), 320, 180, 0xFF00FF00, &tex));
    defer c.msw_texture_release(tex);
    const t0 = b.clock.now();
    const frame: api.CapturedFrame = .{ .image = .{ .width = 320, .height = 180, .gpu = tex }, .seq = 1, .capture_start_us = t0, .captured_us = t0 };
    const out = (try b.encoder.encode(&frame, .{})).?;
    try testing.expect(out.keyframe);
    try testing.expectEqual(@as(usize, 1), out.slices.len);
    try testing.expect(out.encoded_us >= out.encode_start_us and out.encode_start_us >= t0);
    const out2 = (try b.encoder.encode(&frame, .{ .force = .ltr_refresh })).?;
    // No LTR on the software encoder: a refresh is an IDR.
    try testing.expect(out2.keyframe and !out2.ltr_refresh);
    if (b.input) |inj| try inj.inject(.{ .pad = .{ .index = 0, .connected = true, .state = .{} } });
}

test "display list: the adapter's outputs, without a device" {
    var out: [16]api.DisplayInfo = undefined;
    const n = host.listDisplays(null, 0, &out) catch |e| return skip("dup", @errorName(e), 0);
    if (n == 0) return skip("dup", "no output attached to the desktop", 0);
    var primaries: usize = 0;
    for (out[0..n]) |d| {
        std.debug.print("display {d}: {s} {d}x{d} @ {d} mHz at {d},{d}{s}\n", .{ d.id, d.name(), d.width, d.height, d.refresh_mhz, d.x, d.y, if (d.primary) " (primary)" else "" });
        try testing.expect(d.width > 0 and d.height > 0);
        try testing.expect(d.name().len > 0);
        if (d.primary) primaries += 1;
    }
    try testing.expect(primaries <= 1);
}

test "display info: names are cut to fit and ids are output indexes" {
    var w = std.mem.zeroes(c.msw_display_info);
    w.index = 3;
    w.width = 2560;
    w.height = 1440;
    w.refresh_mhz = 143_973;
    w.x = -2560;
    w.primary = 1;
    const long = "A monitor with a very long EDID name";
    @memcpy(w.name[0..long.len], long);
    const d = host.displayInfo(&w);
    try testing.expectEqual(@as(u32, 3), d.id);
    try testing.expectEqual(@as(i32, -2560), d.x);
    try testing.expect(d.primary);
    try testing.expectEqualStrings(long[0..api.DisplayInfo.name_max], d.name());
}
