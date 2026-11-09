//! Linux client backend: `openClient` returns the platform interface's `ClientBackend`
//! (platform/api.zig) on top of the C side in mlc.h.
//!
//!   Decoder     libavcodec H.264/HEVC/AV1. VAAPI (on a DRM render node) when a device
//!               opens and has the codec, software otherwise; low-delay flags and slice
//!               threads only, so each access unit's picture comes out of its own call.
//!               The passthrough codec (the synthetic host) goes to the synthetic
//!               decoder, so this client plays against `moonsec peer ... host` too.
//!               Output: `Image.gpu` is the decoder's `*mlc_frame` (a VAAPI surface or
//!               its own NV12/I420 planes); passthrough pictures are BGRA in `Image.cpu`.
//!   Presenter   Wayland xdg_toplevel with an EGL/GLES 3 surface. VAAPI surfaces are
//!               imported as dma-buf EGLImages (no copy); software planes are uploaded
//!               as R8/RG8 textures; a shader does YUV -> RGB (BT.601/709, limited/full).
//!               Lowest latency: swap interval 0 and the tearing-control async hint;
//!               smooth: swap interval 1. The latency overlay is drawn on top.
//!   AudioSink   PipeWire playback stream, f32, fed from a ring (mlc_audio.c).
//!   InputSource Keyboard and mouse from evdev (evdev.zig), only while the window has
//!               keyboard focus (held keys are released when it loses it); the window's
//!               close button is `.quit`.
//!
//! The clock is CLOCK_MONOTONIC.

const std = @import("std");
const api = @import("platform");
const overlay = @import("client_overlay");
const synthetic = @import("synthetic");
pub const evdev = @import("evdev.zig");
pub const uinput = @import("uinput.zig");

pub const c = @import("mlc_c");

const log = std.log.scoped(.client_linux);
const pattern = api.pattern;

pub const Options = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "moonsec",
    /// VAAPI decode when a device opens and has the codec.
    hardware_decode: bool = true,
    /// DRM render node for VAAPI (null: libavcodec picks the first).
    va_device: ?[:0]const u8 = null,
    /// Read keyboard and mouse from evdev.
    evdev: bool = true,
    /// Take the evdev devices exclusively while the window has focus (EVIOCGRAB), so the
    /// desktop doesn't also act on the keys. Off for a windowed client.
    grab: bool = false,
    /// Read every presented picture back from the GL back buffer and decode the test
    /// pattern from it (synthetic host only): the end-to-end check in CI.
    verify_pattern: bool = false,
    /// PipeWire ring and the graph quantum to ask for.
    audio_ring_ms: u32 = 200,
    audio_quantum: u32 = 256,
    overlay_style: overlay.Style = .{},
    /// How often the overlay image is redrawn from the latest snapshot.
    overlay_interval_us: api.Micros = 100_000,
};

pub fn nowUs() api.Micros {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(api.Micros, ts.sec) * 1_000_000 + @divTrunc(@as(api.Micros, ts.nsec), 1000);
}

pub const clock: api.Clock = api.clockFn(nowUs);

fn fail(what: []const u8, rc: c_int) api.Error {
    // A missing device or codec is the caller's to handle (tests skip, the app falls back).
    if (rc == c.MLC_E_UNSUPPORTED or rc == c.MLC_E_NODEVICE)
        log.warn("{s}: {s}", .{ what, std.mem.span(c.mlc_last_error()) })
    else
        log.err("{s}: {s}", .{ what, std.mem.span(c.mlc_last_error()) });
    return switch (rc) {
        c.MLC_E_UNSUPPORTED => error.Unsupported,
        c.MLC_E_NOMEM => error.OutOfMemory,
        c.MLC_E_CLOSED => error.Closed,
        c.MLC_E_NODEVICE => error.DeviceLost,
        c.MLC_E_CODEC => error.CodecFailed,
        else => error.BackendFailed,
    };
}

fn ok(what: []const u8, rc: c_int) api.Error!void {
    if (rc < 0) return fail(what, rc);
}

// ---------------------------------------------------------------------------
// Decoder

pub const Decoder = struct {
    codecs: api.CodecSet,
    hardware: bool,
    va_device: ?[:0]const u8,
    dec: ?*c.mlc_decoder = null,
    codec: api.Codec = .h264,
    held: ?c.mlc_frame = null,
    /// The passthrough codec (synthetic host).
    pass: synthetic.Decoder,
    pass_out: bool = false,

    pub fn caps(d: *Decoder) api.DecoderCaps {
        return .{ .codecs = d.codecs, .gpu_output = true, .cpu_output = true, .coded = probeFormats(d.codecs, d.pass.formats) };
    }

    pub fn configure(d: *Decoder, cfg: api.DecoderConfig) api.Error!void {
        d.close();
        d.codec = cfg.codec;
        if (cfg.codec == .passthrough) return d.pass.configure(cfg);
        const codec: u32 = switch (cfg.codec) {
            .h264 => c.MLC_CODEC_H264,
            .hevc => c.MLC_CODEC_HEVC,
            .av1 => c.MLC_CODEC_AV1,
            else => return error.Unsupported,
        };
        if (!d.codecs.has(cfg.codec)) return error.Unsupported;
        if (!probeFormats(d.codecs, .{}).get(@intFromEnum(cfg.codec)).supports(cfg.format)) return error.Unsupported;
        var h: ?*c.mlc_decoder = null;
        try ok("mlc_decoder_create", c.mlc_decoder_create(codec, @intFromBool(d.hardware), if (d.va_device) |p| p.ptr else null, &h));
        d.dec = h;
        log.info("decoder: {s} {s}", .{ @tagName(cfg.codec), if (c.mlc_decoder_is_hardware(h) != 0) "VAAPI" else "software" });
    }

    pub fn isHardware(d: *const Decoder) bool {
        return if (d.dec) |h| c.mlc_decoder_is_hardware(h) != 0 else false;
    }

    pub fn decode(d: *Decoder, au: *const api.AccessUnit) api.Error!?api.DecodedFrame {
        std.debug.assert(d.held == null and !d.pass_out); // release before the next decode
        if (au.codec != d.codec) return error.Unsupported;
        if (d.codec == .passthrough) {
            const f = try d.pass.decode(au) orelse return null;
            d.pass_out = true;
            return f;
        }
        const h = d.dec orelse return error.BackendFailed;
        var f: c.mlc_frame = undefined;
        var got: c_int = 0;
        const rc = c.mlc_decoder_decode(h, au.data.ptr, au.data.len, au.frame_id, &f, &got);
        if (rc < 0) {
            const e = fail("decode", rc);
            if (e == error.CodecFailed or e == error.BackendFailed) {
                // Start clean for the recovery frame.
                _ = c.mlc_decoder_flush(h);
                return error.CodecFailed;
            }
            return e;
        }
        if (got == 0) return null;
        d.held = f;
        return .{
            .frame_id = @truncate(@as(u64, @bitCast(f.pts))),
            .image = .{
                .width = f.width,
                .height = f.height,
                .format = switch (f.kind) {
                    c.MLC_FRAME_I444 => if (f.bit_depth > 8) .i444_16 else .i444,
                    c.MLC_FRAME_P010 => .p010,
                    else => if (f.bit_depth > 8) .p010 else .nv12,
                },
                .color = if (f.transfer == c.MLC_TRANSFER_PQ) .hdr10 else .sdr_bt709,
                .gpu = &d.held.?,
            },
            .decoded_us = nowUs(),
        };
    }

    pub fn release(d: *Decoder, f: *const api.DecodedFrame) void {
        if (d.pass_out) {
            d.pass.release(f);
            d.pass_out = false;
        }
        if (d.held) |*h| {
            c.mlc_decoder_release_frame(d.dec, h);
            d.held = null;
        }
    }

    fn close(d: *Decoder) void {
        if (d.held) |*f| c.mlc_decoder_release_frame(d.dec, f);
        d.held = null;
        if (d.dec) |h| c.mlc_decoder_destroy(h);
        d.dec = null;
        d.pass_out = false;
    }

    pub fn deinit(d: *Decoder) void {
        d.close();
        d.pass.deinit();
    }
};

/// The coded formats per codec libavcodec decodes and the presenter draws (4:4:4 and
/// 10-bit, HDR10 tone-mapped to SDR), and the synthetic decoder's for passthrough.
pub fn probeFormats(codecs: api.CodecSet, passthrough: api.Formats) api.FormatCaps {
    var f: api.FormatCaps = .{};
    if (codecs.h264) f.h264 = @bitCast(@as(u8, @truncate(c.mlc_decoder_formats(c.MLC_CODEC_H264))));
    if (codecs.hevc) f.hevc = @bitCast(@as(u8, @truncate(c.mlc_decoder_formats(c.MLC_CODEC_HEVC))));
    if (codecs.av1) f.av1 = @bitCast(@as(u8, @truncate(c.mlc_decoder_formats(c.MLC_CODEC_AV1))));
    if (codecs.passthrough) f.passthrough = passthrough;
    return f;
}

/// The codecs this libavcodec can decode, plus passthrough.
pub fn probeCodecs() api.CodecSet {
    return .{
        .h264 = c.mlc_decoder_supported(c.MLC_CODEC_H264) != 0,
        .hevc = c.mlc_decoder_supported(c.MLC_CODEC_HEVC) != 0,
        .av1 = c.mlc_decoder_supported(c.MLC_CODEC_AV1) != 0,
        .passthrough = true,
    };
}

// ---------------------------------------------------------------------------
// Presenter

pub const Presenter = struct {
    gpa: std.mem.Allocator,
    window: *c.mlc_window,
    mode: api.PresentMode = .lowest_latency,
    windowed: bool = true,
    style: overlay.Style,
    overlay_interval_us: api.Micros,
    overlay_due: api.Micros = 0,
    overlay_shown: bool = false,
    canvas: []u32,
    canvas_w: u32,
    canvas_h: u32,
    verify: bool,
    readback: []u8 = &.{},
    /// Stamp read back from the last presented picture (verify mode).
    last_stamp: ?pattern.Stamp = null,
    stats: struct { presents: u64 = 0, verified: u64 = 0, unreadable: u64 = 0, unscaled_skipped: u64 = 0 } = .{},
    fps_window_start: api.Micros = 0,
    fps_count: u32 = 0,
    fps: ?f32 = null,

    pub fn configure(p: *Presenter, cfg: api.PresenterConfig) api.Error!void {
        p.mode = cfg.mode;
        try ok("mode", c.mlc_window_set_mode(p.window, switch (cfg.mode) {
            .lowest_latency => c.MLC_PRESENT_LOWEST_LATENCY,
            .smooth => c.MLC_PRESENT_SMOOTH,
        }));
        if (cfg.windowed != p.windowed) {
            c.mlc_window_set_fullscreen(p.window, @intFromBool(!cfg.windowed));
            p.windowed = cfg.windowed;
        }
        // Size the window to the stream; the compositor may still dictate another.
        if (cfg.windowed and cfg.width > 0 and cfg.height > 0) c.mlc_window_resize(p.window, cfg.width, cfg.height);
        if (c.mlc_window_dispatch(p.window) == c.MLC_E_CLOSED) return error.Closed;
    }

    pub fn present(p: *Presenter, frame: *const api.DecodedFrame, ov: ?*const api.Overlay) api.Error!api.Presented {
        if (c.mlc_window_dispatch(p.window) == c.MLC_E_CLOSED) return error.Closed;
        try p.updateOverlay(ov);

        const img = frame.image;
        var f: c.mlc_frame = std.mem.zeroes(c.mlc_frame);
        if (img.gpu) |h| {
            // Our own decoder's frame (see Decoder.decode).
            f = @as(*const c.mlc_frame, @ptrCast(@alignCast(h))).*;
        } else if (img.cpu) |cpu| switch (img.format) {
            .bgra8 => {
                f.kind = c.MLC_FRAME_BGRA;
                f.planes[0] = cpu.data.ptr;
                f.strides[0] = cpu.stride;
            },
            .nv12 => {
                f.kind = c.MLC_FRAME_NV12;
                f.planes[0] = cpu.data.ptr;
                f.planes[1] = cpu.data.ptr + @as(usize, img.height) * cpu.stride;
                f.strides[0] = cpu.stride;
                f.strides[1] = cpu.stride;
                f.bt709 = @intFromBool(img.height >= 720);
            },
            else => return error.Unsupported,
        } else return error.Unsupported;
        f.width = img.width;
        f.height = img.height;

        try ok("draw", c.mlc_window_draw(p.window, &f));
        if (p.verify) p.verifyPattern(img.width, img.height);
        try ok("overlay", c.mlc_window_draw_overlay(p.window));
        try ok("present", c.mlc_window_present(p.window));
        const now = nowUs();
        p.countFrame(now);
        p.stats.presents += 1;
        return .{ .presented_us = now };
    }

    /// Reads the drawn picture back and decodes the stamp, when it was drawn 1:1.
    fn verifyPattern(p: *Presenter, w: u32, h: u32) void {
        var ww: u32 = 0;
        var wh: u32 = 0;
        c.mlc_window_size(p.window, &ww, &wh);
        if (ww != w or wh != h) {
            p.stats.unscaled_skipped += 1;
            p.last_stamp = null;
            return;
        }
        const need = @as(usize, w) * h * 4;
        if (p.readback.len < need) {
            if (p.readback.len > 0) p.gpa.free(p.readback);
            p.readback = p.gpa.alloc(u8, need) catch {
                p.readback = &.{};
                return;
            };
        }
        if (c.mlc_window_read(p.window, 0, 0, w, h, p.readback.ptr, w * 4) < 0) {
            p.stats.unreadable += 1;
            p.last_stamp = null;
            return;
        }
        p.last_stamp = pattern.read(p.readback[0..need], w, h, w * 4);
        if (p.last_stamp == null) p.stats.unreadable += 1 else p.stats.verified += 1;
    }

    fn countFrame(p: *Presenter, now: api.Micros) void {
        if (p.fps_count == 0) p.fps_window_start = now;
        p.fps_count += 1;
        const span = now - p.fps_window_start;
        if (span >= 1_000_000) {
            p.fps = @as(f32, @floatFromInt(p.fps_count - 1)) * 1e6 / @as(f32, @floatFromInt(span));
            p.fps_count = 1;
            p.fps_window_start = now;
        }
    }

    fn updateOverlay(p: *Presenter, ov: ?*const api.Overlay) api.Error!void {
        const o = ov orelse {
            if (p.overlay_shown) try ok("overlay", c.mlc_window_set_overlay(p.window, null, 0, 0, 0));
            p.overlay_shown = false;
            return;
        };
        const now = nowUs();
        if (p.overlay_shown and now < p.overlay_due) return;
        p.overlay_due = now + p.overlay_interval_us;
        const canvas: overlay.Canvas = .{ .pixels = p.canvas, .width = p.canvas_w, .height = p.canvas_h, .stride = p.canvas_w };
        const r = overlay.render(canvas, &o.telemetry, overlay.Status.from(o, p.fps), p.style);
        try ok("overlay", c.mlc_window_set_overlay(p.window, p.canvas.ptr, r.w, r.h, p.canvas_w));
        p.overlay_shown = true;
    }

    pub fn deinit(p: *Presenter) void {
        _ = p;
    }
};

// ---------------------------------------------------------------------------
// Audio

pub const AudioSink = struct {
    a: ?*c.mlc_audio = null,
    channels: u8 = 2,
    ring_ms: u32,
    quantum: u32,

    pub fn start(s: *AudioSink, fmt: api.AudioFormat) api.Error!api.AudioFormat {
        s.stop();
        var h: ?*c.mlc_audio = null;
        try ok("mlc_audio_open", c.mlc_audio_open(fmt.rate, fmt.channels, s.ring_ms, s.quantum, "moonsec", &h));
        s.a = h;
        s.channels = fmt.channels;
        return fmt;
    }

    pub fn write(s: *AudioSink, pcm: []const f32) api.Error!usize {
        const h = s.a orelse return error.Closed;
        var n: u32 = 0;
        const frames: u32 = @intCast(pcm.len / s.channels);
        try ok("audio write", c.mlc_audio_write(h, pcm.ptr, frames, &n));
        return n;
    }

    pub fn queued(s: *AudioSink) usize {
        const h = s.a orelse return 0;
        return c.mlc_audio_queued(h);
    }

    pub const Info = struct { ring_frames: u32, quantum: u32, streaming: bool, underruns: u64 };

    pub fn info(s: *AudioSink) ?Info {
        const h = s.a orelse return null;
        var r: u32 = 0;
        var q: u32 = 0;
        var st: c_int = 0;
        var u: u64 = 0;
        c.mlc_audio_info(h, &r, &q, &st, &u);
        return .{ .ring_frames = r, .quantum = q, .streaming = st != 0, .underruns = u };
    }

    pub fn stop(s: *AudioSink) void {
        if (s.a) |h| c.mlc_audio_close(h);
        s.a = null;
    }
};

// ---------------------------------------------------------------------------
// Input

pub const InputSource = struct {
    window: *c.mlc_window,
    devices: ?evdev.Devices,
    grab: bool,
    held: evdev.Held = .{},
    focused: bool = true,
    quit_sent: bool = false,
    next_scan: api.Micros = 0,
    /// Events read but not yet handed out (a full `out`).
    pending: [64]api.InputEvent = undefined,
    pending_n: usize = 0,
    stats: struct { events: u64 = 0, dropped_unfocused: u64 = 0 } = .{},

    /// Rescan /dev/input for new devices this often.
    pub const scan_interval_us = 1_000_000;

    pub fn poll(s: *InputSource, out: []api.InputEvent) api.Error!usize {
        var n: usize = 0;
        const now = nowUs();
        if (!s.quit_sent and c.mlc_window_closed(s.window) != 0 and out.len > 0) {
            s.quit_sent = true;
            out[0] = .{ .time_us = now, .what = .quit };
            return 1;
        }
        while (n < out.len and s.pending_n > 0) {
            out[n] = s.pending[0];
            std.mem.copyForwards(api.InputEvent, s.pending[0 .. s.pending_n - 1], s.pending[1..s.pending_n]);
            s.pending_n -= 1;
            n += 1;
        }
        const devs = if (s.devices) |*d| d else return n;
        if (now >= s.next_scan) {
            _ = devs.scan();
            s.next_scan = now + scan_interval_us;
        }
        const focused = c.mlc_window_focused(s.window) != 0;
        if (focused != s.focused) {
            s.focused = focused;
            if (s.grab) devs.setGrabAll(focused);
            if (!focused) s.pending_n += s.held.releaseAll(now, s.pending[s.pending_n..]);
        }
        if (s.pending_n > 0) return n + s.drainPending(out[n..]);
        var buf: [64]api.InputEvent = undefined;
        const k = devs.read(&buf);
        for (buf[0..k]) |e| {
            if (!focused) {
                s.stats.dropped_unfocused += 1;
                continue;
            }
            s.held.note(e.what);
            s.stats.events += 1;
            if (n < out.len) {
                out[n] = e;
                n += 1;
            } else {
                s.pending[s.pending_n] = e;
                s.pending_n += 1;
            }
        }
        return n;
    }

    fn drainPending(s: *InputSource, out: []api.InputEvent) usize {
        const k = @min(out.len, s.pending_n);
        @memcpy(out[0..k], s.pending[0..k]);
        std.mem.copyForwards(api.InputEvent, s.pending[0 .. s.pending_n - k], s.pending[k..s.pending_n]);
        s.pending_n -= k;
        return k;
    }

    pub fn deinit(s: *InputSource) void {
        if (s.devices) |*d| d.deinit();
    }
};

// ---------------------------------------------------------------------------
// Bundle

pub const Client = struct {
    gpa: std.mem.Allocator,
    window: *c.mlc_window,
    decoder: Decoder,
    presenter: Presenter,
    audio: AudioSink,
    input: InputSource,

    pub fn backend(cl: *Client) api.ClientBackend {
        return .{
            .clock = clock,
            .decoder = api.bind(api.Decoder, Decoder, &cl.decoder),
            .presenter = api.bind(api.Presenter, Presenter, &cl.presenter),
            .audio = api.bind(api.AudioSink, AudioSink, &cl.audio),
            .input = api.bind(api.InputSource, InputSource, &cl.input),
            // SDR: the presenter tone-maps HDR10. Showing PQ as is needs the Wayland
            // colour-management protocol (wp_color_manager_v1) and a 10-bit surface.
            .display = .{},
            .deinit_ptr = cl,
            .deinitFn = &deinitOpaque,
        };
    }

    fn deinitOpaque(p: ?*anyopaque) void {
        const cl: *Client = @ptrCast(@alignCast(p.?));
        cl.deinit();
    }

    pub fn deinit(cl: *Client) void {
        cl.audio.stop();
        cl.input.deinit();
        cl.decoder.deinit();
        c.mlc_window_destroy(cl.window);
        cl.gpa.free(cl.presenter.canvas);
        if (cl.presenter.readback.len > 0) cl.gpa.free(cl.presenter.readback);
        const gpa = cl.gpa;
        gpa.destroy(cl);
    }
};

/// Opens the Wayland window and its EGL context and scans evdev. The decoder is created
/// on `Decoder.configure`, the PipeWire stream on `AudioSink.start`. Presenter calls make
/// the EGL context current on their own thread.
pub fn open(gpa: std.mem.Allocator, opts: Options) !*Client {
    var w: ?*c.mlc_window = null;
    const rc = c.mlc_window_create(opts.width, opts.height, opts.title.ptr, &w);
    if (rc < 0) return fail("mlc_window_create", rc);
    errdefer c.mlc_window_destroy(w);

    const cw = 1024;
    const ch = 512;
    const canvas = try gpa.alloc(u32, cw * ch);
    errdefer gpa.free(canvas);

    var devices: ?evdev.Devices = null;
    if (opts.evdev) {
        devices = .{};
        const n = devices.?.scan();
        if (n == 0) log.info("evdev: no keyboard or mouse yet (rescanning every {d} s)", .{InputSource.scan_interval_us / 1_000_000});
    }

    const cl = try gpa.create(Client);
    cl.* = .{
        .gpa = gpa,
        .window = w.?,
        .decoder = .{
            .codecs = probeCodecs(),
            .hardware = opts.hardware_decode,
            .va_device = opts.va_device,
            .pass = .{ .gpa = gpa, .clock = clock },
        },
        .presenter = .{
            .gpa = gpa,
            .window = w.?,
            .style = opts.overlay_style,
            .overlay_interval_us = opts.overlay_interval_us,
            .canvas = canvas,
            .canvas_w = cw,
            .canvas_h = ch,
            .verify = opts.verify_pattern,
        },
        .audio = .{ .ring_ms = opts.audio_ring_ms, .quantum = opts.audio_quantum },
        .input = .{ .window = w.?, .devices = devices, .grab = opts.grab },
    };
    return cl;
}

/// The platform interface's entry point: `openClient(gpa, opts)`.
pub fn openClient(gpa: std.mem.Allocator, opts: Options) !api.ClientBackend {
    const cl = try open(gpa, opts);
    return cl.backend();
}

test {
    _ = evdev;
    _ = uinput;
}
