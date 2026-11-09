//! Linux host encoders behind the platform interface's `Encoder` (platform/api.zig), on
//! top of the C side in mlh_enc.h.
//!
//!   vaapi     libva loaded at run time; H.264 and HEVC; long-term references when the
//!             driver takes packed headers (we write them: h26x.c), else IDR recovery.
//!   nvenc     libcuda and libnvidia-encode loaded at run time (enc_nv.c over enc_nvenc.c,
//!             on the NVENC core shared with the Windows host); H.264 and HEVC; long-term
//!             references. `device` is a CUDA ordinal for it. Compile-only so far.
//!   software  libavcodec's libx264 (or OpenH264) with zerolatency settings; IDR recovery.
//!   auto      the first of vaapi, nvenc, software that opens.
//!
//! Input: `Image.gpu`, when set, is a `*const c.mlh_dmabuf` (the Linux capture backend's
//! dma-buf frame; XRGB8888/ARGB8888 or NV12); otherwise `Image.cpu` holds BGRA or NV12.
//! The clock is CLOCK_MONOTONIC.
const std = @import("std");
const api = @import("platform");

pub const c = @import("mlh_c");

const log = std.log.scoped(.host_linux);

pub const Kind = enum { auto, vaapi, nvenc, software };

pub const Options = struct {
    kind: Kind = .auto,
    /// DRM render node for VAAPI; null tries /dev/dri/renderD128 and up.
    device: ?[:0]const u8 = null,
};

pub fn nowUs() api.Micros {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(api.Micros, ts.sec) * 1_000_000 + @divTrunc(@as(api.Micros, ts.nsec), 1000);
}

pub const clock: api.Clock = api.clockFn(nowUs);

pub fn mapError(what: []const u8, rc: c_int) api.Error {
    const e: api.Error = switch (rc) {
        c.MLH_E_UNSUPPORTED, c.MLH_E_NOTFOUND => error.Unsupported,
        c.MLH_E_NOMEM => error.OutOfMemory,
        c.MLH_E_DEVICE_LOST => error.DeviceLost,
        c.MLH_E_CODEC => error.CodecFailed,
        else => error.BackendFailed,
    };
    // A missing backend is expected on most machines; the caller falls back.
    if (e == error.Unsupported) log.info("{s}: {s}", .{ what, std.mem.span(c.mlh_last_error()) }) else log.err("{s}: {s}", .{ what, std.mem.span(c.mlh_last_error()) });
    return e;
}

fn ckind(k: Kind) u32 {
    return switch (k) {
        .vaapi => c.MLH_ENC_VAAPI,
        .nvenc => c.MLH_ENC_NVENC,
        .software, .auto => c.MLH_ENC_SOFTWARE,
    };
}

const formats_nv12 = [_]api.PixelFormat{ .bgra8, .nv12 };
const formats_bgra = [_]api.PixelFormat{.bgra8};

pub const Encoder = struct {
    enc: *c.mlh_enc,
    kind: Kind,
    cfg: ?api.EncoderConfig = null,
    slices: [c.MLH_MAX_SLICES][]const u8 = undefined,

    pub fn create(opts: Options) api.Error!Encoder {
        const kinds: []const Kind = switch (opts.kind) {
            .auto => &.{ .vaapi, .nvenc, .software },
            else => &.{opts.kind},
        };
        var last: c_int = c.MLH_E_NOTFOUND;
        for (kinds) |k| {
            var e: ?*c.mlh_enc = null;
            last = c.mlh_enc_create(ckind(k), if (opts.device) |d| d.ptr else null, &e);
            if (last == c.MLH_OK) {
                log.info("encoder: {s}", .{std.mem.span(c.mlh_enc_describe(e))});
                return .{ .enc = e.?, .kind = k };
            }
            log.info("encoder {s} unavailable: {s}", .{ @tagName(k), std.mem.span(c.mlh_last_error()) });
        }
        return mapError("no video encoder", last);
    }

    pub fn describe(self: *const Encoder) []const u8 {
        return std.mem.span(c.mlh_enc_describe(self.enc));
    }

    pub fn caps(self: *Encoder) api.EncoderCaps {
        var cc: c.mlh_enc_caps = undefined;
        c.mlh_enc_caps_get(self.enc, &cc);
        return .{
            .codecs = .{ .h264 = cc.h264 != 0, .hevc = cc.hevc != 0, .av1 = cc.av1 != 0 },
            .ltr = cc.ltr != 0,
            .max_slices = @intCast(@min(@max(cc.max_slices, 1), c.MLH_MAX_SLICES)),
            .gpu_input = cc.gpu_input != 0,
            .cpu_input = cc.cpu_input != 0,
            .formats = if (cc.nv12_input != 0) &formats_nv12 else &formats_bgra,
        };
    }

    pub fn configure(self: *Encoder, cfg: api.EncoderConfig) api.Error!void {
        const codec: u32 = switch (cfg.codec) {
            .h264 => c.MLH_CODEC_H264,
            .hevc => c.MLH_CODEC_HEVC,
            .av1 => c.MLH_CODEC_AV1,
            else => return error.Unsupported,
        };
        // 8-bit 4:2:0 SDR only (caps.coded is empty, so that's all negotiation offers).
        if (!api.Formats.baseline.supports(cfg.format)) return error.Unsupported;
        const cc: c.mlh_enc_config = .{
            .codec = codec,
            .width = cfg.width,
            .height = cfg.height,
            .fps = cfg.fps,
            .bitrate_bps = cfg.bitrate_bps,
            .slices = @min(@max(cfg.slices, 1), self.caps().max_slices),
            .ltr = @intFromBool(cfg.ltr),
            .lossless = 0,
        };
        const rc = c.mlh_enc_configure(self.enc, &cc);
        if (rc != c.MLH_OK) return mapError("encoder configure", rc);
        self.cfg = cfg;
    }

    pub fn encode(self: *Encoder, frame: *const api.CapturedFrame, params: api.EncodeParams) api.Error!?api.EncodedFrame {
        const cfg = self.cfg orelse return error.BackendFailed;
        const img = frame.image;
        var in: c.mlh_enc_input = std.mem.zeroes(c.mlh_enc_input);
        in.width = img.width;
        in.height = img.height;
        if (img.gpu) |g| {
            in.dmabuf = @ptrCast(@alignCast(g));
        } else if (img.cpu) |cpu| {
            in.data = cpu.data.ptr;
            in.stride = cpu.stride;
            in.format = switch (img.format) {
                .bgra8 => c.MLH_FMT_BGRA,
                .nv12 => c.MLH_FMT_NV12,
                else => return error.Unsupported,
            };
        } else return error.Unsupported;
        const start_us = nowUs();
        const p: c.mlh_enc_params = .{
            .force = switch (params.force) {
                .none => c.MLH_FORCE_NONE,
                .ltr_refresh => c.MLH_FORCE_LTR_REFRESH,
                .idr => c.MLH_FORCE_IDR,
            },
            .bitrate_bps = params.bitrate_bps,
            .acked_ltr_tokens = if (params.acked_ltr_tokens.len > 0) params.acked_ltr_tokens.ptr else null,
            .acked_ltr_count = @intCast(params.acked_ltr_tokens.len),
        };
        var out: c.mlh_enc_output = undefined;
        const rc = c.mlh_enc_encode(self.enc, &in, @intCast(@max(frame.captured_us, 0)), &p, &out);
        if (rc != c.MLH_OK) return switch (mapError("encode", rc)) {
            error.BackendFailed => error.CodecFailed,
            else => |e| e,
        };
        if (out.dropped != 0 or out.len == 0) return null;
        return .{
            .slices = sliceView(out.data[0..out.len], out.slice_offsets[0..out.num_slices], @min(@max(cfg.slices, 1), c.MLH_MAX_SLICES), &self.slices),
            .keyframe = out.keyframe != 0,
            .ltr_token = if (out.has_ltr_token != 0) out.ltr_token else null,
            .ltr_refresh = out.ltr_refresh != 0,
            .encode_start_us = start_us,
            .encoded_us = nowUs(),
        };
    }

    pub fn deinit(self: *Encoder) void {
        c.mlh_enc_destroy(self.enc);
    }
};

/// Slices from the C side's offsets, at most `max` (an encoder may cut more than asked:
/// the extra ones are merged into the last).
pub fn sliceView(data: []const u8, offsets: []const u32, max: usize, out: [][]const u8) []const []const u8 {
    const n = @min(offsets.len, max, out.len);
    for (0..n) |i| {
        const end = if (i + 1 < n) offsets[i + 1] else data.len;
        out[i] = data[offsets[i]..end];
    }
    return out[0..n];
}

/// Opens an encoder and returns it as the platform interface's `Encoder`. The returned
/// object owns `storage`'s encoder; call `deinit` on the interface to close it.
pub fn open(storage: *Encoder, opts: Options) api.Error!api.Encoder {
    storage.* = try Encoder.create(opts);
    return api.bind(api.Encoder, Encoder, storage);
}

test sliceView {
    const data = "aaabbbcc";
    var out: [4][]const u8 = undefined;
    const s = sliceView(data, &.{ 0, 3, 6 }, 4, &out);
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqualStrings("cc", s[2]);
    const merged = sliceView(data, &.{ 0, 3, 6 }, 2, &out);
    try std.testing.expectEqualStrings("bbbcc", merged[1]);
}
