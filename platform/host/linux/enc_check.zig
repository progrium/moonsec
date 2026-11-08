//! moonsec-enc-check: the Linux encoder check (`zig build linux-enc-check -- [options]`).
//!
//! Drives a Linux host encoder through losses and long-term-reference recovery and
//! decodes what a client would have received with libavcodec (platform/client/linux):
//!
//!   - desktop-like content (a static page of noisy "text", a window sliding 4 px per
//!     frame, the measurement test pattern with its stamp) so an IDR costs several P frames;
//!   - every `--loss-every` frames, `--burst` frames are lost; the client stays frozen
//!     (feeds nothing) until the host's refresh, which comes `--rtt` frames after the loss;
//!   - the client acks each long-term token it decodes, `--rtt` frames later.
//!
//! It passes when (with long-term references, the default `--expect ltr`): the encoder
//! reports them, no IDR follows the first, every forced refresh comes back marked as one,
//! the largest refresh is at most `--max-refresh-ratio` of a steady-state IDR (forced after
//! the run, not counted), no decoded picture carries another frame's stamp (a wrong
//! reference shows up as one), every recovery picture's stamp reads, and at most 2% of the
//! other pictures have a stamp too degraded to read (the one-frame VBV is strict).
//! `--expect idr` is for encoders without long-term references (the software one): each
//! recovery is an IDR and the stamps still decode.
//!
//! Exit status: 0 pass, 1 fail, 2 when the encoder cannot be opened on this machine.
//! The tests (test.zig) run the same scenario on the software encoder.
const std = @import("std");
const api = @import("platform");
const enc_mod = @import("host_linux_enc");
const client = @import("client_linux");
const mlc = client.c;
const pattern = api.pattern;

pub const Expect = enum { ltr, idr };

pub const Options = struct {
    kind: enc_mod.Kind = .auto,
    device: ?[:0]const u8 = null,
    codec: api.Codec = .h264,
    width: u32 = 1280,
    height: u32 = 720,
    fps: u32 = 60,
    bitrate_bps: u64 = 12_000_000,
    slices: u8 = 1,
    frames: u32 = 300,
    loss_every: u32 = 47,
    burst: u32 = 2,
    rtt: u32 = 3,
    expect: Expect = .ltr,
    max_refresh_ratio: f64 = 0.5,
    verbose: bool = false,
};

pub const Report = struct {
    frames: u32 = 0,
    losses: u32 = 0,
    refreshes: u32 = 0,
    refreshes_marked: u32 = 0,
    idrs_after_first: u32 = 0,
    dropped: u32 = 0,
    decoded: u32 = 0,
    stamp_failures: u32 = 0,
    unreadable: u32 = 0,
    recovery_unreadable: u32 = 0,
    decode_failures: u32 = 0,
    first_idr_bytes: usize = 0,
    steady_idr_bytes: usize = 0,
    max_refresh_bytes: usize = 0,
    p_bytes_total: u64 = 0,
    p_frames: u32 = 0,
    ltr: bool = false,
    describe: []const u8 = "",

    pub fn meanP(r: Report) f64 {
        return if (r.p_frames == 0) 0 else @as(f64, @floatFromInt(r.p_bytes_total)) / @as(f64, @floatFromInt(r.p_frames));
    }

    pub fn passed(r: Report, o: Options) bool {
        if (r.decode_failures != 0 or r.stamp_failures != 0 or r.recovery_unreadable != 0 or r.decoded == 0) return false;
        if (r.unreadable * 50 > r.decoded) return false;
        switch (o.expect) {
            .ltr => {
                if (!r.ltr or r.idrs_after_first != 0 or r.refreshes_marked != r.refreshes) return false;
                if (r.refreshes > 0 and r.steady_idr_bytes > 0 and
                    @as(f64, @floatFromInt(r.max_refresh_bytes)) > o.max_refresh_ratio * @as(f64, @floatFromInt(r.steady_idr_bytes))) return false;
            },
            .idr => if (r.losses > 0 and r.idrs_after_first == 0) return false,
        }
        return true;
    }

    pub fn print(r: Report, o: Options) void {
        std.debug.print(
            \\encoder:            {s}
            \\long-term refs:     {s}
            \\frames:             {d} ({d} dropped by the encoder)
            \\losses:             {d}, refreshes {d} ({d} marked as refreshes), IDRs after the first {d}
            \\client decoded:     {d} pictures, {d} wrong stamps, {d} unreadable ({d} on recovery), {d} decode errors
            \\sizes:              first IDR {d} B, steady-state IDR {d} B, largest refresh {d} B, mean P {d:.0} B
            \\
        , .{
            r.describe,         if (r.ltr) "yes" else "no",
            r.frames,           r.dropped,
            r.losses,           r.refreshes,
            r.refreshes_marked, r.idrs_after_first,
            r.decoded,          r.stamp_failures,
            r.unreadable,       r.recovery_unreadable,
            r.decode_failures,  r.first_idr_bytes,
            r.steady_idr_bytes, r.max_refresh_bytes,
            r.meanP(),
        });
        if (o.expect == .ltr and r.steady_idr_bytes > 0)
            std.debug.print("refresh / IDR:      {d:.2} (limit {d:.2})\n", .{ @as(f64, @floatFromInt(r.max_refresh_bytes)) / @as(f64, @floatFromInt(r.steady_idr_bytes)), o.max_refresh_ratio });
    }
};

// ---------------------------------------------------------------------------
// Content

pub const Content = struct {
    w: u32,
    h: u32,
    page: []u8,
    px: []u8,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Content {
        const page = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(page);
        const px = try gpa.alloc(u8, page.len);
        // A page of "text": rows of short dark strokes on white, seeded so runs match.
        var prng = std.Random.DefaultPrng.init(0x7e57);
        const rnd = prng.random();
        @memset(page, 0xF0);
        var y: u32 = 4;
        while (y + 10 < h) : (y += 14) {
            var x: u32 = 6;
            while (x + 8 < w) {
                const glyph_w = rnd.intRangeAtMost(u32, 3, 7);
                const shade: u8 = rnd.intRangeAtMost(u8, 0x10, 0x60);
                for (0..10) |dy| for (0..glyph_w) |dx| {
                    if (rnd.boolean()) {
                        const i = ((y + dy) * w + x + dx) * 4;
                        page[i] = shade;
                        page[i + 1] = shade;
                        page[i + 2] = shade +% 0x10;
                    }
                };
                x += glyph_w + rnd.intRangeAtMost(u32, 1, 4);
            }
        }
        return .{ .w = w, .h = h, .page = page, .px = px };
    }

    pub fn deinit(c: *Content, gpa: std.mem.Allocator) void {
        gpa.free(c.page);
        gpa.free(c.px);
    }

    /// The pattern's rectangle: top left, at most 512x192 (the stamp needs 128x64).
    pub fn patternRect(c: Content) struct { w: u32, h: u32 } {
        return .{ .w = @min(c.w, 512), .h = @min(c.h / 2, 192) };
    }

    /// Draws frame `n` with stamp `s`.
    pub fn draw(c: *Content, n: u32, s: pattern.Stamp) void {
        @memcpy(c.px, c.page);
        // A window of the page sliding right 4 px per frame, in the lower half.
        const win_w = c.w / 3;
        const win_h = c.h / 3;
        const wy = c.h / 2 + 8;
        if (wy + win_h <= c.h) {
            const off = (n * 4) % (c.w - win_w + 1);
            for (0..win_h) |r| {
                const src = c.page[((r + 16) % c.h) * c.w * 4 ..][0 .. win_w * 4];
                const dst = c.px[((wy + r) * c.w + off) * 4 ..][0 .. win_w * 4];
                @memcpy(dst, src);
            }
        }
        const pr = c.patternRect();
        pattern.render(c.px, pr.w, pr.h, c.w * 4, s);
    }
};

// ---------------------------------------------------------------------------
// Client side: libavcodec decode and the stamp

pub const Decoder = struct {
    dec: *mlc.mlc_decoder,
    rgb: []u8,

    pub fn init(gpa: std.mem.Allocator, codec: api.Codec, w: u32, h: u32) !Decoder {
        var d: ?*mlc.mlc_decoder = null;
        const cc: u32 = switch (codec) {
            .h264 => mlc.MLC_CODEC_H264,
            .hevc => mlc.MLC_CODEC_HEVC,
            .av1 => mlc.MLC_CODEC_AV1,
            else => return error.Unsupported,
        };
        if (mlc.mlc_decoder_create(cc, 0, null, &d) != 0) return error.DecoderFailed;
        return .{ .dec = d.?, .rgb = try gpa.alloc(u8, @as(usize, w) * h * 4) };
    }

    pub fn deinit(d: *Decoder, gpa: std.mem.Allocator) void {
        mlc.mlc_decoder_destroy(d.dec);
        gpa.free(d.rgb);
    }

    /// Decodes one access unit and reads the stamp from `rect`; null when no picture came.
    pub fn decodeStamp(d: *Decoder, au: []const u8, pts: i64, rect_w: u32, rect_h: u32) !?pattern.Stamp {
        var f: mlc.mlc_frame = undefined;
        var got: c_int = 0;
        if (mlc.mlc_decoder_decode(d.dec, au.ptr, au.len, pts, &f, &got) != 0) return error.DecodeFailed;
        if (got == 0) return null;
        defer mlc.mlc_decoder_release_frame(d.dec, &f);
        yuvToBgra(&f, d.rgb, rect_w, rect_h);
        return pattern.read(d.rgb[0 .. @as(usize, rect_w) * rect_h * 4], rect_w, rect_h, rect_w * 4) orelse error.NoStamp;
    }
};

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// The top-left w x h of a decoded I420/NV12 picture as BGRA (BT.709 limited range).
pub fn yuvToBgra(f: *const mlc.mlc_frame, out: []u8, w: u32, h: u32) void {
    for (0..h) |y| for (0..w) |x| {
        const Y: i32 = f.planes[0][y * f.strides[0] + x];
        var U: i32 = undefined;
        var V: i32 = undefined;
        if (f.kind == mlc.MLC_FRAME_NV12) {
            U = f.planes[1][(y / 2) * f.strides[1] + (x / 2) * 2];
            V = f.planes[1][(y / 2) * f.strides[1] + (x / 2) * 2 + 1];
        } else {
            U = f.planes[1][(y / 2) * f.strides[1] + x / 2];
            V = f.planes[2][(y / 2) * f.strides[2] + x / 2];
        }
        const c = (Y - 16) * 298;
        const d = U - 128;
        const e = V - 128;
        const i = (y * w + x) * 4;
        out[i + 2] = clamp8((c + 459 * e + 128) >> 8);
        out[i + 1] = clamp8((c - 55 * d - 136 * e + 128) >> 8);
        out[i] = clamp8((c + 541 * d + 128) >> 8);
        out[i + 3] = 255;
    };
}

// ---------------------------------------------------------------------------
// The run

const Pending = struct { at: u32, token: u64 };

pub fn run(gpa: std.mem.Allocator, enc: *enc_mod.Encoder, o: Options) !Report {
    var r: Report = .{ .describe = enc.describe() };
    const caps = enc.caps();
    r.ltr = caps.ltr;
    try enc.configure(.{
        .codec = o.codec,
        .width = o.width,
        .height = o.height,
        .fps = o.fps,
        .bitrate_bps = o.bitrate_bps,
        .slices = o.slices,
        .ltr = caps.ltr,
    });
    var content = try Content.init(gpa, o.width, o.height);
    defer content.deinit(gpa);
    var dec = try Decoder.init(gpa, o.codec, o.width, o.height);
    defer dec.deinit(gpa);
    const pr = content.patternRect();

    var acks: std.ArrayList(Pending) = .empty;
    defer acks.deinit(gpa);
    var ready: std.ArrayList(u64) = .empty;
    defer ready.deinit(gpa);

    var frozen = false;
    var refresh_at: ?u32 = null;
    var lost_left: u32 = 0;
    var first = true;

    var n: u32 = 0;
    while (n < o.frames) : (n += 1) {
        // Acks that have arrived by now.
        ready.clearRetainingCapacity();
        var i: usize = 0;
        while (i < acks.items.len) {
            if (acks.items[i].at <= n) {
                try ready.append(gpa, acks.items[i].token);
                _ = acks.swapRemove(i);
            } else i += 1;
        }
        const stamp: pattern.Stamp = .{ .time_us = 1_000_000 + @as(u64, n) * 16_667, .frame = n };
        content.draw(n, stamp);
        const force: api.Force = if (refresh_at != null and refresh_at.? == n) blk: {
            r.refreshes += 1;
            break :blk if (caps.ltr) .ltr_refresh else .idr;
        } else .none;
        const frame: api.CapturedFrame = .{
            .image = .{ .width = o.width, .height = o.height, .cpu = .{ .data = content.px, .stride = o.width * 4 } },
            .seq = n,
            .capture_start_us = @intCast(stamp.time_us),
            .captured_us = @intCast(stamp.time_us),
        };
        const out = try enc.encode(&frame, .{ .force = force, .acked_ltr_tokens = ready.items });
        r.frames += 1;
        const ef = out orelse {
            r.dropped += 1;
            continue;
        };
        var size: usize = 0;
        for (ef.slices) |s| size += s.len;
        if (ef.keyframe) {
            if (first) r.first_idr_bytes = size else r.idrs_after_first += 1;
        } else if (force == .none) {
            r.p_bytes_total += size;
            r.p_frames += 1;
        }
        if (force != .none) {
            r.max_refresh_bytes = @max(r.max_refresh_bytes, size);
            if (ef.ltr_refresh) r.refreshes_marked += 1;
            refresh_at = null;
        }
        if (o.verbose) std.debug.print("frame {d}: {d} B{s}{s}{s}\n", .{ n, size, if (ef.keyframe) " IDR" else "", if (ef.ltr_refresh) " refresh" else "", if (ef.ltr_token != null) " LTR" else "" });
        first = false;

        // The network.
        if (o.loss_every > 0 and n > 0 and n % o.loss_every == 0) {
            lost_left = o.burst;
            r.losses += 1;
        }
        if (lost_left > 0) {
            lost_left -= 1;
            if (!frozen) {
                frozen = true;
                refresh_at = n + o.rtt;
            }
            continue;
        }
        // A frozen client waits for the recovery frame.
        if (frozen and !(ef.keyframe or ef.ltr_refresh)) continue;
        frozen = false;

        var au: std.ArrayList(u8) = .empty;
        defer au.deinit(gpa);
        for (ef.slices) |s| try au.appendSlice(gpa, s);
        const got = dec.decodeStamp(au.items, n, pr.w, pr.h) catch |e| {
            switch (e) {
                error.NoStamp => {
                    r.decoded += 1;
                    r.unreadable += 1;
                    if (ef.keyframe or ef.ltr_refresh) r.recovery_unreadable += 1;
                },
                else => r.decode_failures += 1,
            }
            if (o.verbose) std.debug.print("frame {d}: client {s}\n", .{ n, @errorName(e) });
            continue;
        };
        if (got) |s| {
            r.decoded += 1;
            if (s.frame != n) {
                r.stamp_failures += 1;
                if (o.verbose) std.debug.print("frame {d}: client read frame {d}\n", .{ n, s.frame });
            }
        }
        if (ef.ltr_token) |t| try acks.append(gpa, .{ .at = n + o.rtt, .token = t });
    }

    // A steady-state IDR to compare refreshes with (not counted above).
    content.draw(o.frames, .{ .time_us = 1_000_000 + @as(u64, o.frames) * 16_667, .frame = o.frames });
    const last: api.CapturedFrame = .{
        .image = .{ .width = o.width, .height = o.height, .cpu = .{ .data = content.px, .stride = o.width * 4 } },
        .seq = o.frames,
        .capture_start_us = 0,
        .captured_us = 0,
    };
    if (try enc.encode(&last, .{ .force = .idr })) |ef| {
        for (ef.slices) |s| r.steady_idr_bytes += s.len;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Command line

fn usage() noreturn {
    std.debug.print(
        \\usage: moonsec-enc-check [options]
        \\  --kind auto|vaapi|nvenc|software   encoder (default auto)
        \\  --device /dev/dri/renderD128       VAAPI render node (default: first that encodes)
        \\  --codec h264|hevc                  (default h264)
        \\  --size WxH                         (default 1280x720)
        \\  --bitrate BPS                      (default 8000000)
        \\  --slices N                         (default 1)
        \\  --frames N                         (default 300)
        \\  --loss-every N --burst N --rtt N   losses (default 47, 2, 3 frames)
        \\  --expect ltr|idr                   (default ltr; idr for encoders without long-term references)
        \\  --max-refresh-ratio R              largest refresh / steady-state IDR (default 0.5)
        \\  -v                                 one line per frame
        \\
    , .{});
    std.process.exit(2);
}

fn parseArgs(args: []const [:0]const u8) Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-v")) {
            o.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) usage();
        if (i + 1 >= args.len) usage();
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--kind")) {
            o.kind = std.meta.stringToEnum(enc_mod.Kind, v) orelse usage();
        } else if (std.mem.eql(u8, a, "--device")) {
            o.device = v;
        } else if (std.mem.eql(u8, a, "--codec")) {
            o.codec = if (std.mem.eql(u8, v, "h264")) .h264 else if (std.mem.eql(u8, v, "hevc")) .hevc else usage();
        } else if (std.mem.eql(u8, a, "--size")) {
            var it = std.mem.splitScalar(u8, v, 'x');
            o.width = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
            o.height = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--bitrate")) {
            o.bitrate_bps = std.fmt.parseInt(u64, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--slices")) {
            o.slices = std.fmt.parseInt(u8, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--frames")) {
            o.frames = std.fmt.parseInt(u32, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--loss-every")) {
            o.loss_every = std.fmt.parseInt(u32, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--burst")) {
            o.burst = std.fmt.parseInt(u32, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--rtt")) {
            o.rtt = std.fmt.parseInt(u32, v, 10) catch usage();
        } else if (std.mem.eql(u8, a, "--expect")) {
            o.expect = std.meta.stringToEnum(Expect, v) orelse usage();
        } else if (std.mem.eql(u8, a, "--max-refresh-ratio")) {
            o.max_refresh_ratio = std.fmt.parseFloat(f64, v) catch usage();
        } else usage();
    }
    return o;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const o = parseArgs(args);
    var enc = enc_mod.Encoder.create(.{ .kind = o.kind, .device = o.device }) catch |e| {
        std.debug.print("cannot open a {s} encoder: {s} ({s})\n", .{ @tagName(o.kind), @errorName(e), std.mem.span(enc_mod.c.mlh_last_error()) });
        std.process.exit(2);
    };
    defer enc.deinit();
    const r = run(gpa, &enc, o) catch |e| {
        std.debug.print("run failed: {s} ({s})\n", .{ @errorName(e), std.mem.span(enc_mod.c.mlh_last_error()) });
        std.process.exit(1);
    };
    r.print(o);
    const ok = r.passed(o);
    std.debug.print("\nresult: {s}\n", .{if (ok) "PASS" else "FAIL"});
    std.process.exit(if (ok) 0 else 1);
}
