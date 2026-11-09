//! macOS host backend: ScreenCaptureKit capture and system audio, VideoToolbox encode,
//! CGEvent input, behind the platform interface (platform/api.zig). The Objective-C side
//! is in the .m files next to this one; Zig sees only mh.h.
//!
//!   Capture        SCStream on a display, newest-frame mailbox. `Image.gpu` is the
//!                  frame's CVPixelBufferRef (IOSurface-backed), NV12 by default.
//!                  captured_us is SCK's display time, never later than arrival.
//!   Encoder        VideoToolbox. Default: the low-latency encoder with long-term
//!                  references, RealTime on, ExpectedFrameRate 1000 (S7b). Falls back to
//!                  the regular encoder (no LTR) when the low-latency one is missing.
//!   AudioSource    SCStream system audio, 48 kHz f32, this process excluded.
//!   InputInjector  CGEvent: keys by virtual key code (HID map in keymap.zig), buttons,
//!                  wheel, relative and absolute motion.
//!
//! Permissions: capture and audio need Screen Recording, injection needs Accessibility.
//! Without them capture/audio start fails (logged) and injected events are dropped by the
//! system; `screenCaptureAllowed` and `postEventAllowed` check without prompting.
//!
//! Rate ladder (core/rate/ladder.zig): `Encoder.configure` keeps the VideoToolbox session
//! when only bitrate or frame rate change and makes a new one for a new size (expect a
//! keyframe). Frames of another size than configured are scaled on the way in, so a plain
//! `configure` is enough; `Host.applyRung` also resizes the capture so SCK does the scaling.
const std = @import("std");
const api = @import("platform");
const core = @import("core");
pub const c = @import("mh_c");
pub const keymap = @import("keymap.zig");

const log = std.log.scoped(.mac_host);

pub fn nowUs() api.Micros {
    return c.mh_now_us();
}

pub const clock = api.clockFn(nowUs);

pub fn screenCaptureAllowed() bool {
    return c.mh_screen_capture_allowed() != 0;
}

pub fn postEventAllowed() bool {
    return c.mh_post_event_allowed() != 0;
}

pub fn inVm() bool {
    return c.mh_is_vm() != 0;
}

pub fn lastError() []const u8 {
    return std.mem.span(c.mh_last_error());
}

/// Maps an mh.h status to the platform error, logging the message.
pub fn check(what: []const u8, rc: c_int) api.Error!void {
    if (rc >= 0) return;
    log.err("{s}: {s}", .{ what, lastError() });
    return switch (rc) {
        c.MH_ERR_PERMISSION, c.MH_ERR_UNSUPPORTED => error.Unsupported,
        c.MH_ERR_CLOSED => error.Closed,
        c.MH_ERR_NOMEM => error.OutOfMemory,
        c.MH_ERR_DEVICE_LOST => error.DeviceLost,
        c.MH_ERR_CODEC => error.CodecFailed,
        else => error.BackendFailed,
    };
}

fn fmtToC(f: api.PixelFormat) api.Error!u32 {
    return switch (f) {
        .bgra8 => c.MH_FMT_BGRA,
        .nv12 => c.MH_FMT_NV12,
        else => error.Unsupported,
    };
}

fn fmtFromC(f: u32) api.PixelFormat {
    return if (f == c.MH_FMT_NV12) .nv12 else .bgra8;
}

// ---------------------------------------------------------------------------
// Capture

pub const Capture = struct {
    cap: *c.mh_capture,
    format: api.PixelFormat = .nv12,
    queue_depth: u32 = 6,
    cfg: api.CaptureConfig = .{},
    started: bool = false,
    size: api.Size = .{ .width = 0, .height = 0 },
    /// Our own reference to the newest frame, for `repeatLast`.
    last: ?api.CapturedFrame = null,
    /// Restarts after the stream stopped under us.
    restarts: u32 = 0,

    pub fn create(format: api.PixelFormat) api.Error!Capture {
        _ = try fmtToC(format);
        var h: ?*c.mh_capture = null;
        try check("mh_capture_create", c.mh_capture_create(&h));
        return .{ .cap = h.?, .format = format };
    }

    pub fn destroy(self: *Capture) void {
        self.stop();
        c.mh_capture_destroy(self.cap);
    }

    pub fn start(self: *Capture, cfg: api.CaptureConfig) api.Error!api.Size {
        self.stop();
        const cc: c.mh_capture_config = .{
            .display = cfg.display,
            .fps = cfg.fps,
            .width = cfg.width,
            .height = cfg.height,
            .cursor = @intFromBool(cfg.cursor),
            .format = try fmtToC(self.format),
            .queue_depth = self.queue_depth,
        };
        var w: u32 = 0;
        var h: u32 = 0;
        check("ScreenCaptureKit start", c.mh_capture_start(self.cap, &cc, &w, &h)) catch |e| {
            if (!screenCaptureAllowed()) log.err("grant Screen Recording to this app (System Settings > Privacy & Security)", .{});
            return e;
        };
        self.cfg = cfg;
        self.started = true;
        self.size = .{ .width = w, .height = h };
        return self.size;
    }

    pub fn acquire(self: *Capture, timeout_us: api.Micros) api.Error!?api.CapturedFrame {
        if (!self.started) return error.Closed;
        const start_us = nowUs();
        var f: c.mh_frame = undefined;
        const rc = c.mh_capture_acquire(self.cap, timeout_us, &f);
        if (rc == c.MH_TIMEOUT) return null;
        if (rc == c.MH_ERR_DEVICE_LOST) {
            // The stream stopped (display reconfigured, sleep): start it again once and
            // report no frame; a second failure is the app's to handle.
            log.info("capture stream stopped ({s}); restarting", .{lastError()});
            self.restarts += 1;
            _ = try self.start(self.cfg);
            return null;
        }
        try check("capture acquire", rc);
        const frame: api.CapturedFrame = .{
            .image = .{ .width = f.width, .height = f.height, .format = fmtFromC(f.format), .gpu = f.pixel_buffer },
            .seq = f.seq,
            .capture_start_us = @min(start_us, f.arrived_us),
            .captured_us = f.captured_us,
        };
        self.setLast(frame);
        return frame;
    }

    fn setLast(self: *Capture, f: api.CapturedFrame) void {
        if (self.last) |l| c.mh_cf_release(l.image.gpu);
        _ = c.mh_cf_retain(f.image.gpu);
        self.last = f;
    }

    pub fn repeatLast(self: *Capture) api.Error!?api.CapturedFrame {
        var f = self.last orelse return null;
        _ = c.mh_cf_retain(f.image.gpu);
        f.repeat = true;
        f.capture_start_us = nowUs();
        return f;
    }

    pub fn release(_: *Capture, frame: *const api.CapturedFrame) void {
        c.mh_cf_release(frame.image.gpu);
    }

    pub fn stop(self: *Capture) void {
        if (self.last) |l| c.mh_cf_release(l.image.gpu);
        self.last = null;
        if (self.started) c.mh_capture_stop(self.cap);
        self.started = false;
    }

    /// Resizes the running stream (rate ladder); 0 keeps a value.
    pub fn resize(self: *Capture, width: u32, height: u32, fps: u32) api.Error!void {
        if (!self.started) return error.Closed;
        try check("capture resize", c.mh_capture_update(self.cap, width, height, fps));
        if (width != 0) self.cfg.width = width;
        if (height != 0) self.cfg.height = height;
        if (fps != 0) self.cfg.fps = fps;
        if (width != 0 and height != 0) self.size = .{ .width = width & ~@as(u32, 1), .height = height & ~@as(u32, 1) };
    }

    pub fn stats(self: *Capture) c.mh_capture_stats {
        var s: c.mh_capture_stats = undefined;
        c.mh_capture_get_stats(self.cap, &s);
        return s;
    }
};

// ---------------------------------------------------------------------------
// Encoder

pub const EncoderMode = enum {
    /// The low-latency encoder with LTR, else the regular one.
    auto,
    low_latency,
    regular,
};

pub const EncoderOptions = struct {
    mode: EncoderMode = .auto,
    /// Fail rather than use a software encoder.
    require_hardware: bool = false,
    /// ExpectedFrameRate on the low-latency path (S7b: 1000).
    expected_fps: u32 = 1000,
};

pub const Encoder = struct {
    enc: *c.mh_enc,
    mode: EncoderMode,
    hardware: bool,
    codecs: api.CodecSet,
    ltr: bool,
    cfg: ?api.EncoderConfig = null,
    slice: [1][]const u8 = undefined,

    fn optsFor(mode: EncoderMode, hw: bool, o: EncoderOptions) c.mh_enc_options {
        return .{
            .mode = if (mode == .regular) c.MH_ENC_REGULAR else c.MH_ENC_LOW_LATENCY,
            .require_hw = @intFromBool(hw),
            .expected_fps = o.expected_fps,
        };
    }

    /// Picks the first encoder that VideoToolbox can make: low-latency then regular, each
    /// on hardware first, then (unless required) in software.
    pub fn create(o: EncoderOptions) api.Error!Encoder {
        // In a VM (the CI runners) the low-latency encoder runs in software and drops
        // most frames, while the regular one is the paravirtualized hardware encoder.
        // UsingHardwareAcceleratedVideoEncoder can't tell them apart: the low-latency
        // encoder reports "no" on real Apple silicon too (S7b), though it runs on AVE.
        const modes: []const EncoderMode = switch (o.mode) {
            .auto => if (inVm()) &.{ .regular, .low_latency } else &.{ .low_latency, .regular },
            else => &.{o.mode},
        };
        const hws: []const bool = if (o.require_hardware) &.{true} else &.{ true, false };
        for (modes) |m| {
            for (hws) |hw| {
                const co = optsFor(m, hw, o);
                var probe: c.mh_enc_info = undefined;
                const h264 = c.mh_enc_probe(&co, c.MH_CODEC_H264, 0, &probe) == c.MH_OK;
                const hevc = c.mh_enc_probe(&co, c.MH_CODEC_HEVC, 0, &probe) == c.MH_OK;
                if (!h264 and !hevc) {
                    log.info("encoder {s}{s}: {s}", .{ @tagName(m), if (hw) " (hardware)" else "", lastError() });
                    continue;
                }
                const ltr = m == .low_latency and c.mh_enc_probe(&co, if (h264) c.MH_CODEC_H264 else c.MH_CODEC_HEVC, 1, &probe) == c.MH_OK;
                var e: ?*c.mh_enc = null;
                try check("mh_enc_create", c.mh_enc_create(&co, &e));
                log.info("encoder: {s} ({s}, {s}), h264 {} hevc {} ltr {}", .{
                    @tagName(m),
                    std.mem.sliceTo(&probe.encoder_id, 0),
                    if (probe.hardware != 0) "hardware" else "software",
                    h264,
                    hevc,
                    ltr,
                });
                return .{ .enc = e.?, .mode = m, .hardware = probe.hardware != 0, .codecs = .{ .h264 = h264, .hevc = hevc }, .ltr = ltr };
            }
        }
        return error.Unsupported;
    }

    pub fn caps(self: *Encoder) api.EncoderCaps {
        return .{
            .codecs = self.codecs,
            .ltr = self.ltr,
            .max_slices = 1,
            .gpu_input = true,
            .formats = &.{ .nv12, .bgra8 },
        };
    }

    pub fn configure(self: *Encoder, cfg: api.EncoderConfig) api.Error!void {
        if (!self.codecs.has(cfg.codec)) return error.Unsupported;
        const cc: c.mh_enc_config = .{
            .codec = if (cfg.codec == .hevc) c.MH_CODEC_HEVC else c.MH_CODEC_H264,
            .width = cfg.width & ~@as(u32, 1),
            .height = cfg.height & ~@as(u32, 1),
            .fps = cfg.fps,
            .bitrate_bps = cfg.bitrate_bps,
            .ltr = @intFromBool(cfg.ltr and self.ltr),
        };
        try check("encoder configure", c.mh_enc_configure(self.enc, &cc));
        self.cfg = cfg;
    }

    pub fn encode(self: *Encoder, frame: *const api.CapturedFrame, params: api.EncodeParams) api.Error!?api.EncodedFrame {
        _ = self.cfg orelse return error.BackendFailed;
        const pb = frame.image.gpu orelse return error.Unsupported;
        const start_us = nowUs();
        const p: c.mh_enc_params = .{
            .force = switch (params.force) {
                .none => c.MH_FORCE_NONE,
                .ltr_refresh => c.MH_FORCE_LTR_REFRESH,
                .idr => c.MH_FORCE_IDR,
            },
            .bitrate_bps = params.bitrate_bps,
            .acked_ltr_tokens = if (params.acked_ltr_tokens.len > 0) params.acked_ltr_tokens.ptr else null,
            .acked_ltr_count = @intCast(params.acked_ltr_tokens.len),
        };
        var out: c.mh_enc_output = undefined;
        try check("encode", c.mh_enc_encode(self.enc, pb, frame.captured_us, &p, &out));
        if (params.bitrate_bps != 0) self.cfg.?.bitrate_bps = params.bitrate_bps;
        if (out.dropped != 0) return null;
        self.slice[0] = out.data[0..out.len];
        return .{
            .slices = &self.slice,
            .keyframe = out.keyframe != 0,
            .ltr_token = if (out.has_ltr_token != 0) out.ltr_token else null,
            .ltr_refresh = out.ltr_refresh != 0,
            .encode_start_us = start_us,
            .encoded_us = nowUs(),
        };
    }

    pub fn info(self: *Encoder) c.mh_enc_info {
        var i: c.mh_enc_info = undefined;
        c.mh_enc_get_info(self.enc, &i);
        return i;
    }

    pub fn deinit(self: *Encoder) void {
        c.mh_enc_destroy(self.enc);
    }
};

// ---------------------------------------------------------------------------
// Audio

pub const Audio = struct {
    audio: *c.mh_audio,
    display: u32 = 0,
    channels: u8 = 2,
    started: bool = false,

    pub fn create(display: u32) api.Error!Audio {
        var h: ?*c.mh_audio = null;
        try check("mh_audio_create", c.mh_audio_create(&h));
        return .{ .audio = h.?, .display = display };
    }

    pub fn destroy(self: *Audio) void {
        c.mh_audio_destroy(self.audio);
    }

    pub fn start(self: *Audio, fmt: api.AudioFormat) api.Error!api.AudioFormat {
        if (fmt.rate != api.audio_rate or fmt.channels < 1 or fmt.channels > 2) return error.Unsupported;
        try check("ScreenCaptureKit audio start", c.mh_audio_start(self.audio, self.display, fmt.channels));
        self.channels = fmt.channels;
        self.started = true;
        return fmt;
    }

    pub fn read(self: *Audio, out: []f32, timeout_us: api.Micros) api.Error!api.AudioChunk {
        if (!self.started) return error.Closed;
        var frames: u32 = 0;
        var t: i64 = 0;
        const max: u32 = @intCast(@min(out.len / self.channels, std.math.maxInt(u32)));
        const rc = c.mh_audio_read(self.audio, out.ptr, max, timeout_us, &frames, &t);
        if (rc == c.MH_TIMEOUT) return .{ .frames = 0, .time_us = nowUs() };
        try check("audio read", rc);
        return .{ .frames = frames, .time_us = t };
    }

    pub fn stop(self: *Audio) void {
        if (self.started) c.mh_audio_stop(self.audio);
        self.started = false;
    }
};

// ---------------------------------------------------------------------------
// Input

pub const Injector = struct {
    in: *c.mh_input,
    unmapped: u32 = 0,
    failed: u32 = 0,

    pub fn create(display: u32) api.Error!Injector {
        var h: ?*c.mh_input = null;
        try check("mh_input_create", c.mh_input_create(&h));
        c.mh_input_set_display(h, display);
        return .{ .in = h.? };
    }

    pub fn destroy(self: *Injector) void {
        c.mh_input_destroy(self.in);
    }

    pub fn inject(self: *Injector, action: core.input.Action) api.Error!void {
        const rc: c_int = switch (action) {
            .key => |k| blk: {
                const kc = keymap.toKeyCode(k.code) orelse {
                    self.unmapped += 1;
                    return;
                };
                break :blk c.mh_input_key(self.in, kc, @intFromBool(k.down));
            },
            .button => |b| c.mh_input_button(self.in, b.code, @intFromBool(b.down)),
            .scroll => |s| c.mh_input_scroll(self.in, s.dx, s.dy),
            .motion => |m| c.mh_input_move_rel(self.in, m.dx, m.dy),
            .abs => |a| c.mh_input_move_abs(self.in, a.x, a.y),
            // No virtual gamepad on macOS yet (design doc, Phase 4 gamepads); dropped.
            .pad => c.MH_OK,
        };
        if (rc < 0) {
            // Not fatal: an unknown button, or no Accessibility permission.
            self.failed += 1;
            log.warn("CGEvent: {s}", .{lastError()});
        }
    }
};

// ---------------------------------------------------------------------------
// Bundle

pub const Options = struct {
    /// Display for audio and absolute pointer moves; capture takes CaptureConfig.display.
    display: u32 = 0,
    /// What capture delivers. NV12 is VideoToolbox's native input (no conversion).
    pixel_format: api.PixelFormat = .nv12,
    encoder: EncoderOptions = .{},
    audio: bool = true,
    input: bool = true,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    capture: Capture,
    encoder: Encoder,
    audio: ?Audio = null,
    injector: ?Injector = null,

    fn deinitFn(p: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(p.?));
        self.capture.destroy();
        if (self.audio) |*a| {
            a.stop();
            a.destroy();
        }
        if (self.injector) |*i| i.destroy();
        self.encoder.deinit();
        self.allocator.destroy(self);
    }

    /// The Host behind a bundle this backend opened.
    pub fn fromBackend(be: api.HostBackend) *Host {
        std.debug.assert(be.deinitFn.? == &Host.deinitFn);
        return @ptrCast(@alignCast(be.deinit_ptr.?));
    }

    /// Applies a rate-ladder step (`HostSession.takeReconfigure`): the capture stream
    /// goes to the new size and rate, and the encoder is reconfigured with the same codec,
    /// bitrate and LTR setting. A size change makes a new session, so the next frame is
    /// a keyframe. Call from the capture/encode thread between frames.
    pub fn applyRung(self: *Host, r: core.rate.ladder.Rung) api.Error!void {
        var cfg = self.encoder.cfg orelse return error.BackendFailed;
        if (self.capture.started) self.capture.resize(r.width, r.height, r.fps) catch |e| {
            // The encoder scales instead.
            log.warn("capture resize to {d}x{d}@{d}: {s}", .{ r.width, r.height, r.fps, @errorName(e) });
        };
        cfg.width = r.width;
        cfg.height = r.height;
        cfg.fps = r.fps;
        try self.encoder.configure(cfg);
    }
};

/// Opens the macOS host bundle. Capture permission is checked when capture starts.
pub fn openHost(allocator: std.mem.Allocator, opts: Options) api.Error!api.HostBackend {
    const self = try allocator.create(Host);
    errdefer allocator.destroy(self);
    var capture = try Capture.create(opts.pixel_format);
    errdefer capture.destroy();
    var encoder = try Encoder.create(opts.encoder);
    errdefer encoder.deinit();
    self.* = .{ .allocator = allocator, .capture = capture, .encoder = encoder };
    if (opts.audio) self.audio = Audio.create(opts.display) catch null;
    if (opts.input) self.injector = Injector.create(opts.display) catch null;
    if (opts.input and !postEventAllowed()) log.warn("no Accessibility permission: injected input will be dropped", .{});
    return .{
        .clock = clock,
        .capture = api.bind(api.Capture, Capture, &self.capture),
        .encoder = api.bind(api.Encoder, Encoder, &self.encoder),
        .audio = if (self.audio) |*a| api.bind(api.AudioSource, Audio, a) else null,
        .input = if (self.injector) |*i| api.bind(api.InputInjector, Injector, i) else null,
        .deinit_ptr = self,
        .deinitFn = Host.deinitFn,
    };
}

test {
    _ = keymap;
}
