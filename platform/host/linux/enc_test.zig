//! Linux host encoder tests (`zig build test-linux-enc`). They need libavcodec with libx264
//! (Ubuntu's has it) and run anywhere; there is no GPU in CI or the cloud, so:
//!
//!   - the long-term-reference machinery the VAAPI encoder relies on (the planner and the
//!     H.264/HEVC parameter sets and slice headers in h26x.c) is checked through the
//!     PCM-and-skip test encoders (testenc.c) and libavcodec's decoders, picture for
//!     picture, through losses and recovery;
//!   - the software encoder runs end to end: a lossless round trip compared bit for bit,
//!     and the loss/recovery scenario of enc_check.zig at a real bitrate;
//!   - VAAPI and NVENC are built, and their "not available" paths are tested. On a machine
//!     with a VAAPI encoder the VAAPI test runs the enc_check scenario on it instead.
const std = @import("std");
const api = @import("platform");
const enc_mod = @import("host_linux_enc");
const client = @import("client_linux");
const check = @import("enc_check.zig");
const c = enc_mod.c;
const mlc = client.c;

const testing = std.testing;
const gpa = testing.allocator;

// ---------------------------------------------------------------------------
// Test encoders: the VAAPI headers and planner through a real decoder

const Picture = struct {
    w: u32,
    h: u32,
    y: []u8,
    u: []u8,
    v: []u8,

    fn init(w: u32, h: u32) !Picture {
        const y = try gpa.alloc(u8, w * h);
        errdefer gpa.free(y);
        const u = try gpa.alloc(u8, w * h / 4);
        errdefer gpa.free(u);
        return .{ .w = w, .h = h, .y = y, .u = u, .v = try gpa.alloc(u8, w * h / 4) };
    }
    fn deinit(p: *Picture) void {
        gpa.free(p.y);
        gpa.free(p.u);
        gpa.free(p.v);
    }
    fn copyFrom(p: *Picture, o: *const Picture) void {
        @memcpy(p.y, o.y);
        @memcpy(p.u, o.u);
        @memcpy(p.v, o.v);
    }
    /// New random content in 16x16 block (bx, by).
    fn paint(p: *Picture, rnd: std.Random, bx: u32, by: u32) void {
        for (0..16) |r| rnd.bytes(p.y[(by * 16 + r) * p.w + bx * 16 ..][0..16]);
        for (0..8) |r| {
            rnd.bytes(p.u[(by * 8 + r) * (p.w / 2) + bx * 8 ..][0..8]);
            rnd.bytes(p.v[(by * 8 + r) * (p.w / 2) + bx * 8 ..][0..8]);
        }
    }
    fn matches(p: *const Picture, f: *const mlc.mlc_frame) bool {
        if (f.width != p.w or f.height != p.h or f.kind != mlc.MLC_FRAME_I420) return false;
        for (0..p.h) |r| if (!std.mem.eql(u8, f.planes[0][r * f.strides[0] ..][0..p.w], p.y[r * p.w ..][0..p.w])) return false;
        for (0..p.h / 2) |r| {
            if (!std.mem.eql(u8, f.planes[1][r * f.strides[1] ..][0 .. p.w / 2], p.u[r * p.w / 2 ..][0 .. p.w / 2])) return false;
            if (!std.mem.eql(u8, f.planes[2][r * f.strides[2] ..][0 .. p.w / 2], p.v[r * p.w / 2 ..][0 .. p.w / 2])) return false;
        }
        return true;
    }
};

/// 60 frames, one or two blocks change per frame; long-term marks every 15 frames. Frames
/// 29-31 are lost (30 was marked long-term); the client acks what it decodes two frames
/// later and the host refreshes at 33 against the newest acked reference (frame 15), then
/// carries on. Every picture the client decodes must equal the host's, bit for bit.
fn ltrScenario(codec: u32) !void {
    const w = 64;
    const h = 48;
    const bw = w / 16;
    const bh = h / 16;
    var t: ?*c.mlh_testenc = null;
    try testing.expectEqual(@as(c_int, 0), c.mlh_testenc_create(codec, w, h, 1, &t));
    defer c.mlh_testenc_destroy(t);
    var dec: ?*mlc.mlc_decoder = null;
    try testing.expectEqual(@as(c_int, 0), mlc.mlc_decoder_create(if (codec == c.MLH_CODEC_HEVC) mlc.MLC_CODEC_HEVC else mlc.MLC_CODEC_H264, 0, null, &dec));
    defer mlc.mlc_decoder_destroy(dec);

    var prng = std.Random.DefaultPrng.init(codec);
    const rnd = prng.random();
    var host = try Picture.init(w, h);
    defer host.deinit();
    // Pictures of frames marked long-term, by token.
    var marked: std.AutoHashMap(u64, Picture) = .init(gpa);
    defer {
        var it = marked.valueIterator();
        while (it.next()) |p| p.deinit();
        marked.deinit();
    }
    for (0..bh) |by| for (0..bw) |bx| host.paint(rnd, @intCast(bx), @intCast(by));

    var pending: std.ArrayList(struct { at: u32, token: u64 }) = .empty;
    defer pending.deinit(gpa);
    var acked: std.ArrayList(u64) = .empty;
    defer acked.deinit(gpa);
    var newest_acked: u64 = 0;
    var marks: u32 = 0;
    var refresh_ref: u64 = 0;

    var n: u32 = 0;
    while (n < 60) : (n += 1) {
        var changed = [_]u8{0} ** (bw * bh);
        const force: u32 = if (n == 33) c.MLH_FORCE_LTR_REFRESH else c.MLH_FORCE_NONE;
        if (force == c.MLH_FORCE_LTR_REFRESH) {
            // The refresh predicts from the newest acked picture: the host's picture is
            // that one plus this frame's changes.
            host.copyFrom(marked.getPtr(newest_acked).?);
            refresh_ref = newest_acked;
        }
        if (n > 0) {
            const k = (n * 5) % (bw * bh);
            changed[k] = 1;
            host.paint(rnd, @intCast(k % bw), @intCast(k / bw));
            if (n % 3 == 0) {
                const k2 = (k + 7) % (bw * bh);
                changed[k2] = 1;
                host.paint(rnd, @intCast(k2 % bw), @intCast(k2 / bw));
            }
        }
        acked.clearRetainingCapacity();
        var i: usize = 0;
        while (i < pending.items.len) {
            if (pending.items[i].at <= n) {
                try acked.append(gpa, pending.items[i].token);
                newest_acked = @max(newest_acked, pending.items[i].token);
                _ = pending.swapRemove(i);
            } else i += 1;
        }
        const p: c.mlh_enc_params = .{
            .force = force,
            .bitrate_bps = 0,
            .acked_ltr_tokens = if (acked.items.len > 0) acked.items.ptr else null,
            .acked_ltr_count = @intCast(acked.items.len),
        };
        var out: c.mlh_enc_output = undefined;
        try testing.expectEqual(@as(c_int, 0), c.mlh_testenc_encode(t, host.y.ptr, host.u.ptr, host.v.ptr, &changed, &p, &out));
        try testing.expectEqual(n == 0, out.keyframe != 0); // never an IDR after the first
        try testing.expectEqual(n == 33, out.ltr_refresh != 0);
        if (out.has_ltr_token != 0) {
            marks += 1;
            var snap = try Picture.init(w, h);
            snap.copyFrom(&host);
            try marked.put(out.ltr_token, snap);
        }
        if (n >= 29 and n <= 32) continue; // lost (29-31), and 32 waits for the refresh
        var f: mlc.mlc_frame = undefined;
        var got: c_int = 0;
        try testing.expectEqual(@as(c_int, 0), mlc.mlc_decoder_decode(dec, out.data, out.len, n, &f, &got));
        try testing.expect(got != 0);
        defer mlc.mlc_decoder_release_frame(dec, &f);
        if (!host.matches(&f)) {
            std.debug.print("frame {d}: decoded picture differs from the host's\n", .{n});
            return error.TestUnexpectedResult;
        }
        if (out.has_ltr_token != 0) try pending.append(gpa, .{ .at = n + 2, .token = out.ltr_token });
    }
    try testing.expectEqual(@as(u64, 16), refresh_ref); // frame 15 (token 16): frame 30's mark was lost
    try testing.expect(marks >= 5); // frames 0, 15, 30, 33 (the refresh), 48
}

test "H.264 headers and planner: long-term marking, loss, refresh, bit exact through libavcodec" {
    try ltrScenario(c.MLH_CODEC_H264);
}

test "HEVC headers and planner: long-term RPS, loss, refresh, bit exact through libavcodec" {
    try ltrScenario(c.MLH_CODEC_HEVC);
}

test "H.264 test encoder without long-term references: a refresh is an IDR" {
    var t: ?*c.mlh_testenc = null;
    try testing.expectEqual(@as(c_int, 0), c.mlh_testenc_create(c.MLH_CODEC_H264, 32, 32, 0, &t));
    defer c.mlh_testenc_destroy(t);
    var pic = try Picture.init(32, 32);
    defer pic.deinit();
    @memset(pic.y, 100);
    @memset(pic.u, 128);
    @memset(pic.v, 128);
    const changed = [_]u8{0} ** 4;
    var out: c.mlh_enc_output = undefined;
    for (0..4) |n| {
        const p: c.mlh_enc_params = .{ .force = if (n == 2) c.MLH_FORCE_LTR_REFRESH else c.MLH_FORCE_NONE, .bitrate_bps = 0, .acked_ltr_tokens = null, .acked_ltr_count = 0 };
        try testing.expectEqual(@as(c_int, 0), c.mlh_testenc_encode(t, pic.y.ptr, pic.u.ptr, pic.v.ptr, &changed, &p, &out));
        try testing.expectEqual(n == 0 or n == 2, out.keyframe != 0);
        try testing.expectEqual(@as(u32, 0), out.has_ltr_token);
    }
}

// ---------------------------------------------------------------------------
// Software encoder

fn decoder(codec: u32) !*mlc.mlc_decoder {
    var dec: ?*mlc.mlc_decoder = null;
    try testing.expectEqual(@as(c_int, 0), mlc.mlc_decoder_create(codec, 0, null, &dec));
    return dec.?;
}

test "software encoder: lossless round trip is bit exact, slices, keyframes on request" {
    const w = 128;
    const h = 96;
    var e: ?*c.mlh_enc = null;
    try testing.expectEqual(@as(c_int, 0), c.mlh_enc_create(c.MLH_ENC_SOFTWARE, null, &e));
    defer c.mlh_enc_destroy(e);
    std.debug.print("{s}\n", .{c.mlh_enc_describe(e)});
    var caps: c.mlh_enc_caps = undefined;
    c.mlh_enc_caps_get(e, &caps);
    try testing.expectEqual(@as(u32, 0), caps.ltr);
    const cfg: c.mlh_enc_config = .{ .codec = c.MLH_CODEC_H264, .width = w, .height = h, .fps = 60, .bitrate_bps = 2_000_000, .slices = 2, .ltr = 1, .lossless = 1 };
    try testing.expectEqual(@as(c_int, 0), c.mlh_enc_configure(e, &cfg));
    const dec = try decoder(mlc.MLC_CODEC_H264);
    defer mlc.mlc_decoder_destroy(dec);

    var bgra: [w * h * 4]u8 = undefined;
    var want = try Picture.init(w, h);
    defer want.deinit();
    for (0..12) |n| {
        api.pattern.render(&bgra, w, h, w * 4, .{ .time_us = 5_000_000 + n * 16_667, .frame = @intCast(n) });
        c.mlh_bgra_to_i420(&bgra, w * 4, w, h, want.y.ptr, want.u.ptr, want.v.ptr);
        const in: c.mlh_enc_input = .{ .dmabuf = null, .data = &bgra, .stride = w * 4, .format = c.MLH_FMT_BGRA, .width = w, .height = h };
        const force: u32 = switch (n) {
            5 => c.MLH_FORCE_IDR,
            8 => c.MLH_FORCE_LTR_REFRESH, // no long-term references: an IDR
            else => c.MLH_FORCE_NONE,
        };
        const p: c.mlh_enc_params = .{ .force = force, .bitrate_bps = 0, .acked_ltr_tokens = null, .acked_ltr_count = 0 };
        var out: c.mlh_enc_output = undefined;
        try testing.expectEqual(@as(c_int, 0), c.mlh_enc_encode(e, &in, 0, &p, &out));
        try testing.expectEqual(@as(u32, 0), out.dropped); // zerolatency: every frame comes out of its own call
        try testing.expectEqual(n == 0 or n == 5 or n == 8, out.keyframe != 0);
        try testing.expectEqual(@as(u32, 2), out.num_slices);
        try testing.expectEqual(@as(u32, 0), out.has_ltr_token);
        var f: mlc.mlc_frame = undefined;
        var got: c_int = 0;
        try testing.expectEqual(@as(c_int, 0), mlc.mlc_decoder_decode(dec, out.data, out.len, @intCast(n), &f, &got));
        try testing.expect(got != 0);
        defer mlc.mlc_decoder_release_frame(dec, &f);
        try testing.expect(want.matches(&f));
    }
}

test "software encoder: loss and IDR recovery at a real bitrate, stamps decode on every picture" {
    var enc = try enc_mod.Encoder.create(.{ .kind = .software });
    defer enc.deinit();
    const o: check.Options = .{ .kind = .software, .width = 640, .height = 360, .bitrate_bps = 6_000_000, .frames = 120, .loss_every = 37, .expect = .idr };
    const r = try check.run(gpa, &enc, o);
    r.print(o);
    try testing.expect(r.passed(o));
    try testing.expectEqual(@as(u32, 3), r.losses);
    try testing.expectEqual(r.losses, r.idrs_after_first);
}

test "software encoder: a bitrate change takes effect without a keyframe" {
    var enc = try enc_mod.Encoder.create(.{ .kind = .software });
    defer enc.deinit();
    const w = 640;
    const h = 360;
    try enc.configure(.{ .codec = .h264, .width = w, .height = h, .bitrate_bps = 4_000_000 });
    var content = try check.Content.init(gpa, w, h);
    defer content.deinit(gpa);
    var before: usize = 0;
    var after: usize = 0;
    for (0..80) |n| {
        content.draw(@intCast(n), .{ .time_us = n * 16_667, .frame = @intCast(n) });
        const frame: api.CapturedFrame = .{ .image = .{ .width = w, .height = h, .cpu = .{ .data = content.px, .stride = w * 4 } }, .seq = n, .capture_start_us = 0, .captured_us = 0 };
        const ef = (try enc.encode(&frame, .{ .bitrate_bps = if (n == 40) 500_000 else 0 })).?;
        try testing.expectEqual(n == 0, ef.keyframe);
        var size: usize = 0;
        for (ef.slices) |s| size += s.len;
        if (n >= 20 and n < 40) before += size;
        if (n >= 60) after += size;
    }
    std.debug.print("mean frame: {d} B at 4 Mb/s, {d} B at 500 kb/s\n", .{ before / 20, after / 20 });
    try testing.expect(after * 3 < before);
}

test "software encoder: a linear dma-buf (memfd) is read like the same pixels in memory" {
    const w = 256;
    const h = 128;
    var bgra: [w * h * 4]u8 = undefined;
    api.pattern.render(&bgra, w, h, w * 4, .{ .time_us = 42, .frame = 7 });
    var want = try Picture.init(w, h);
    defer want.deinit();
    c.mlh_bgra_to_i420(&bgra, w * 4, w, h, want.y.ptr, want.u.ptr, want.v.ptr);
    const linux = std.os.linux;
    const rc_fd = linux.memfd_create("moonsec-test", 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc_fd));
    const fd: i32 = @intCast(rc_fd);
    defer _ = linux.close(fd);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, bgra.len)));
    try testing.expectEqual(@as(usize, bgra.len), linux.pwrite(fd, &bgra, bgra.len, 0));

    var e: ?*c.mlh_enc = null;
    try testing.expectEqual(@as(c_int, 0), c.mlh_enc_create(c.MLH_ENC_SOFTWARE, null, &e));
    defer c.mlh_enc_destroy(e);
    const cfg: c.mlh_enc_config = .{ .codec = c.MLH_CODEC_H264, .width = w, .height = h, .fps = 60, .bitrate_bps = 2_000_000, .slices = 1, .ltr = 0, .lossless = 1 };
    try testing.expectEqual(@as(c_int, 0), c.mlh_enc_configure(e, &cfg));
    var dma: c.mlh_dmabuf = std.mem.zeroes(c.mlh_dmabuf);
    dma.width = w;
    dma.height = h;
    dma.fourcc = 0x34325258; // XRGB8888 ('XR24')
    dma.modifier = 0; // linear
    dma.num_planes = 1;
    dma.fd[0] = fd;
    dma.pitch[0] = w * 4;
    const in: c.mlh_enc_input = .{ .dmabuf = &dma, .data = null, .stride = 0, .format = 0, .width = w, .height = h };
    const p: c.mlh_enc_params = .{ .force = 0, .bitrate_bps = 0, .acked_ltr_tokens = null, .acked_ltr_count = 0 };
    var out: c.mlh_enc_output = undefined;
    try testing.expectEqual(@as(c_int, 0), c.mlh_enc_encode(e, &in, 0, &p, &out));
    const dec = try decoder(mlc.MLC_CODEC_H264);
    defer mlc.mlc_decoder_destroy(dec);
    var f: mlc.mlc_frame = undefined;
    var got: c_int = 0;
    try testing.expectEqual(@as(c_int, 0), mlc.mlc_decoder_decode(dec, out.data, out.len, 0, &f, &got));
    try testing.expect(got != 0);
    defer mlc.mlc_decoder_release_frame(dec, &f);
    try testing.expect(want.matches(&f));

    // A tiled buffer is the GPU encoders' to import, not this one's to read.
    dma.modifier = 0x0100000000000001; // I915_FORMAT_MOD_X_TILED
    try testing.expectEqual(@as(c_int, c.MLH_E_UNSUPPORTED), c.mlh_enc_encode(e, &in, 0, &p, &out));
}

test "software encoder through the platform interface" {
    var storage: enc_mod.Encoder = undefined;
    const e = try enc_mod.open(&storage, .{ .kind = .software });
    defer e.deinit();
    const caps = e.caps();
    try testing.expect(caps.codecs.h264 and !caps.ltr and caps.cpu_input);
    try testing.expectError(error.Unsupported, e.configure(.{ .codec = .hevc, .width = 128, .height = 64, .bitrate_bps = 1_000_000 }));
    try testing.expectError(error.Unsupported, e.configure(.{ .codec = .h264, .width = 128, .height = 64, .bitrate_bps = 1_000_000, .format = .{ .bit_depth = 10 } }));
    try e.configure(.{ .codec = .h264, .width = 128, .height = 64, .bitrate_bps = 1_000_000, .slices = 2 });
    var px: [128 * 64 * 4]u8 = undefined;
    api.pattern.render(&px, 128, 64, 128 * 4, .{ .time_us = 1, .frame = 1 });
    const frame: api.CapturedFrame = .{ .image = .{ .width = 128, .height = 64, .cpu = .{ .data = &px, .stride = 128 * 4 } }, .seq = 1, .capture_start_us = 0, .captured_us = 0 };
    const ef = (try e.encode(&frame, .{})).?;
    try testing.expect(ef.keyframe);
    try testing.expectEqual(@as(usize, 2), ef.slices.len);
    try testing.expect(ef.encoded_us >= ef.encode_start_us);
}

// ---------------------------------------------------------------------------
// VAAPI and NVENC

test "VAAPI: not available without a GPU, or the recovery scenario on one" {
    var e: ?*c.mlh_enc = null;
    const rc = c.mlh_enc_create(c.MLH_ENC_VAAPI, null, &e);
    if (rc != c.MLH_OK) {
        // No libva, no render node, or no encode entrypoint (Mesa has no software
        // VAAPI encoder): a clean "not found" so `auto` falls through to software.
        try testing.expectEqual(@as(c_int, c.MLH_E_NOTFOUND), rc);
        try testing.expect(e == null);
        std.debug.print("VAAPI not available: {s}\n", .{c.mlh_last_error()});
        var auto = try enc_mod.Encoder.create(.{ .kind = .auto });
        defer auto.deinit();
        try testing.expect(auto.kind == .nvenc or auto.kind == .software);
        return;
    }
    c.mlh_enc_destroy(e);
    // A VAAPI encoder is here (a GPU machine): run the hardware check on it.
    var enc = try enc_mod.Encoder.create(.{ .kind = .vaapi });
    defer enc.deinit();
    const o: check.Options = .{ .kind = .vaapi, .frames = 150, .expect = if (enc.caps().ltr) .ltr else .idr };
    const r = try check.run(gpa, &enc, o);
    r.print(o);
    try testing.expect(r.passed(o));
}

test "VAAPI: a missing render node is not found" {
    var e: ?*c.mlh_enc = null;
    try testing.expectEqual(@as(c_int, c.MLH_E_NOTFOUND), c.mlh_enc_create(c.MLH_ENC_VAAPI, "/dev/dri/does-not-exist", &e));
}

test "NVENC: not available without an NVIDIA driver, or the recovery scenario with one" {
    var e: ?*c.mlh_enc = null;
    const rc = c.mlh_enc_create(c.MLH_ENC_NVENC, null, &e);
    if (rc != c.MLH_OK) {
        // No libcuda/libnvidia-encode or no NVENC GPU: "not found", so `auto` moves on.
        try testing.expectEqual(@as(c_int, c.MLH_E_NOTFOUND), rc);
        try testing.expect(e == null);
        std.debug.print("NVENC not available: {s}\n", .{c.mlh_last_error()});
        try testing.expectError(error.Unsupported, enc_mod.Encoder.create(.{ .kind = .nvenc }));
        return;
    }
    c.mlh_enc_destroy(e);
    // An NVIDIA GPU is here: run the hardware check on it.
    var enc = try enc_mod.Encoder.create(.{ .kind = .nvenc });
    defer enc.deinit();
    const o: check.Options = .{ .kind = .nvenc, .frames = 150, .expect = if (enc.caps().ltr) .ltr else .idr };
    const r = try check.run(gpa, &enc, o);
    r.print(o);
    try testing.expect(r.passed(o));
}
