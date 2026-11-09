//! macOS client backend: `openClient` returns the platform interface's
//! `ClientBackend` (platform/api.zig) on top of the Objective-C side in macc.h.
//!
//!   Decoder     VideoToolbox H.264/HEVC, real-time, synchronous (one access unit
//!               in, its picture out); hardware when the machine has it.
//!               Output: NV12 IOSurface-backed CVPixelBufferRef in `Image.gpu`.
//!   Presenter   CAMetalLayer with two drawables, display sync off in lowest-latency
//!               mode; NV12 -> RGB in a fragment shader through CVMetalTextureCache
//!               (no copy); the latency overlay drawn on the CPU
//!               (platform/client/common) and drawn 1:1 over the corner.
//!               Without a window: an offscreen texture (tests, headless).
//!   AudioSink   CoreAudio AUHAL default output, f32, small device I/O buffer,
//!               fed from a lock-free ring.
//!   InputSource NSEvent keyboard, mouse and scroll from the window's view;
//!               gamepads through GameController.framework
//!               (platform/client/gamepad/gamecontroller.zig).
//!
//! AppKit runs on the main thread. `open` may be called from any thread, but then
//! the main thread must run its run loop ([NSApp run]) or call `pumpEvents`, and
//! `InputSource.poll` pumps events itself when called on the main thread.

const std = @import("std");
const api = @import("platform");
const overlay = @import("client_overlay");
const nsinput = @import("nsinput.zig");

pub const gamepad = @import("client_gamepad");

pub const c = @import("macc_c");

const log = std.log.scoped(.client_macos);

pub const Options = struct {
    /// Hardware decode when the machine has it (VideoToolbox falls back to software).
    hardware_decode: bool = true,
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "moonsec",
    visible: bool = true,
    /// No window: present into an offscreen texture of width x height (tests, headless).
    offscreen: bool = false,
    /// Keep drawables readable for `macc_presenter_read_pixel` (tests).
    readback: bool = false,
    /// Gamepads through GameController.framework.
    gamepads: bool = true,
    /// Audio ring size in frames (rounded up to a power of two).
    audio_ring_frames: u32 = 1024,
    overlay_style: overlay.Style = .{},
    /// How often the overlay image is redrawn from the latest snapshot.
    overlay_interval_us: api.Micros = 100_000,
};

pub fn nowUs() api.Micros {
    return @intCast(c.macc_now_ns() / 1000);
}

pub const clock: api.Clock = api.clockFn(nowUs);

pub fn pumpEvents() void {
    c.macc_pump_events();
}

fn statusFail(what: []const u8, st: i32) api.Error {
    log.err("{s}: status {d}", .{ what, st });
    return switch (st) {
        c.MACC_E_UNSUPPORTED, c.MACC_E_NO_DEVICE => error.Unsupported,
        c.MACC_E_CLOSED => error.Closed,
        // kVTInvalidSessionErr after the retry, kVTVideoDecoderMalfunctionErr.
        -12903, -12911 => error.DeviceLost,
        else => error.BackendFailed,
    };
}

fn ok(what: []const u8, st: i32) api.Error!void {
    if (st != c.MACC_OK) return statusFail(what, st);
}

// ---------------------------------------------------------------------------
// Decoder

pub const Decoder = struct {
    hardware: bool,
    dec: ?*c.macc_decoder = null,
    codec: api.Codec = .h264,
    held: ?c.macc_frame = null,

    pub fn caps(_: *Decoder) api.DecoderCaps {
        // VideoToolbox has software H.264 and HEVC decoders on every macOS we run on.
        return .{ .codecs = .{ .h264 = true, .hevc = true }, .gpu_output = true };
    }

    pub fn configure(d: *Decoder, cfg: api.DecoderConfig) api.Error!void {
        const codec: u32 = switch (cfg.codec) {
            .h264 => c.MACC_CODEC_H264,
            .hevc => c.MACC_CODEC_HEVC,
            else => return error.Unsupported,
        };
        d.close();
        var h: ?*c.macc_decoder = null;
        try ok("macc_decoder_create", c.macc_decoder_create(codec, @intFromBool(d.hardware), &h));
        d.dec = h;
        d.codec = cfg.codec;
        log.info("decoder: {s}", .{@tagName(cfg.codec)});
    }

    /// Known after the first decoded access unit.
    pub fn isHardware(d: *const Decoder) bool {
        return if (d.dec) |h| c.macc_decoder_is_hardware(h) != 0 else false;
    }

    pub fn decode(d: *Decoder, au: *const api.AccessUnit) api.Error!?api.DecodedFrame {
        std.debug.assert(d.held == null); // release before the next decode
        const h = d.dec orelse return error.BackendFailed;
        if (au.codec != d.codec) return error.Unsupported;
        var f: c.macc_frame = undefined;
        var got: c_int = 0;
        const st = c.macc_decoder_decode(h, au.data.ptr, au.data.len, au.frame_id, &f, &got);
        if (st != c.MACC_OK) {
            const e = statusFail("decode", st);
            if (e == error.BackendFailed) {
                // Start clean for the recovery frame.
                c.macc_decoder_flush(h);
                return error.CodecFailed;
            }
            return e;
        }
        if (got == 0) return null;
        d.held = f;
        return .{
            .frame_id = @truncate(@as(u64, @bitCast(f.pts))),
            .image = .{ .width = f.width, .height = f.height, .format = .nv12, .gpu = f.pixel_buffer },
            .decoded_us = nowUs(),
        };
    }

    pub fn release(d: *Decoder, _: *const api.DecodedFrame) void {
        if (d.held) |*f| {
            c.macc_decoder_release_frame(d.dec, f);
            d.held = null;
        }
    }

    fn close(d: *Decoder) void {
        if (d.held) |*f| c.macc_decoder_release_frame(d.dec, f);
        d.held = null;
        if (d.dec) |h| c.macc_decoder_destroy(h);
        d.dec = null;
    }

    pub fn deinit(d: *Decoder) void {
        d.close();
    }
};

// ---------------------------------------------------------------------------
// Presenter

pub const Presenter = struct {
    pr: *c.macc_presenter,
    window: ?*c.macc_window,
    mode: api.PresentMode = .lowest_latency,
    windowed: bool = true,
    style: overlay.Style,
    overlay_interval_us: api.Micros,
    overlay_due: api.Micros = 0,
    overlay_shown: bool = false,
    canvas: []u32,
    canvas_w: u32,
    canvas_h: u32,
    fps_window_start: api.Micros = 0,
    fps_count: u32 = 0,
    fps: ?f32 = null,

    pub fn configure(p: *Presenter, cfg: api.PresenterConfig) api.Error!void {
        p.mode = cfg.mode;
        c.macc_presenter_set_mode(p.pr, switch (cfg.mode) {
            .lowest_latency => c.MACC_PRESENT_LOWEST_LATENCY,
            .smooth => c.MACC_PRESENT_SMOOTH,
        });
        if (p.window) |w| if (cfg.windowed != p.windowed) {
            c.macc_window_set_fullscreen(w, @intFromBool(!cfg.windowed));
            p.windowed = cfg.windowed;
        };
    }

    pub fn present(p: *Presenter, frame: *const api.DecodedFrame, ov: ?*const api.Overlay) api.Error!api.Presented {
        if (p.window) |w| if (c.macc_window_open(w) == 0) return error.Closed;
        c.macc_presenter_sync_size(p.pr);
        try p.updateOverlay(ov);

        const img = frame.image;
        const pb = img.gpu orelse return error.Unsupported;
        if (img.format != .nv12) return error.Unsupported;
        var f = std.mem.zeroes(c.macc_frame);
        f.pixel_buffer = pb;
        f.width = img.width;
        f.height = img.height;

        try ok("draw", c.macc_presenter_draw(p.pr, &f, 100));
        var ns: u64 = 0;
        try ok("present", c.macc_presenter_present(p.pr, &ns));
        const at: api.Micros = @intCast(ns / 1000);
        p.countFrame(at);
        return .{ .presented_us = at };
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
            if (p.overlay_shown) try ok("overlay", c.macc_presenter_set_overlay(p.pr, null, 0, 0, 0));
            p.overlay_shown = false;
            return;
        };
        const now = nowUs();
        if (p.overlay_shown and now < p.overlay_due) return;
        p.overlay_due = now + p.overlay_interval_us;
        const canvas: overlay.Canvas = .{ .pixels = p.canvas, .width = p.canvas_w, .height = p.canvas_h, .stride = p.canvas_w };
        const r = overlay.render(canvas, &o.telemetry, overlay.Status.from(o, p.fps), p.style);
        try ok("overlay", c.macc_presenter_set_overlay(p.pr, p.canvas.ptr, r.w, r.h, p.canvas_w));
        p.overlay_shown = true;
    }

    pub fn deinit(p: *Presenter) void {
        _ = p;
    }
};

// ---------------------------------------------------------------------------
// Audio

pub const AudioSink = struct {
    a: ?*c.macc_audio = null,
    channels: u8 = 2,
    ring_frames: u32 = 1024,

    pub fn start(s: *AudioSink, fmt: api.AudioFormat) api.Error!api.AudioFormat {
        s.stop();
        var h: ?*c.macc_audio = null;
        try ok("macc_audio_open", c.macc_audio_open(fmt.rate, fmt.channels, s.ring_frames, &h));
        s.a = h;
        s.channels = fmt.channels;
        var ring: u32 = 0;
        var io: u32 = 0;
        var lat: u32 = 0;
        c.macc_audio_info(h, &ring, &io, &lat);
        log.info("audio out: {d} Hz x{d}, ring {d} frames, device I/O {d} frames, device latency {d} frames", .{ fmt.rate, fmt.channels, ring, io, lat });
        return fmt;
    }

    pub fn write(s: *AudioSink, pcm: []const f32) api.Error!usize {
        const h = s.a orelse return error.Closed;
        var n: u32 = 0;
        const frames: u32 = @intCast(pcm.len / s.channels);
        try ok("audio write", c.macc_audio_write(h, pcm.ptr, frames, &n));
        return n;
    }

    pub fn queued(s: *AudioSink) usize {
        const h = s.a orelse return 0;
        return c.macc_audio_queued(h);
    }

    pub fn stop(s: *AudioSink) void {
        if (s.a) |h| c.macc_audio_close(h);
        s.a = null;
    }
};

// ---------------------------------------------------------------------------
// Input

pub const InputSource = struct {
    window: ?*c.macc_window,
    state: nsinput.State = .{},
    raw: [64]c.macc_event = undefined,
    /// Events translated from a record that did not fit in the caller's buffer.
    pending: [nsinput.max_events]api.InputEvent = undefined,
    pending_n: usize = 0,
    /// GameController pads; with `Options.gamepads` off it reports none.
    pads: gamepad.gamecontroller.Source = .{ .clock = clock },

    pub fn poll(s: *InputSource, out: []api.InputEvent) api.Error!usize {
        var n = try s.pollWindow(out);
        // Pads keep their own queue, so whatever does not fit waits for the next poll.
        if (n < out.len) n += try s.pads.poll(out[n..]);
        return n;
    }

    fn pollWindow(s: *InputSource, out: []api.InputEvent) api.Error!usize {
        var n: usize = 0;
        while (n < out.len and s.pending_n > 0) {
            out[n] = s.pending[0];
            std.mem.copyForwards(api.InputEvent, s.pending[0 .. s.pending_n - 1], s.pending[1..s.pending_n]);
            s.pending_n -= 1;
            n += 1;
        }
        const w = s.window orelse return n;
        while (n < out.len and s.pending_n == 0) {
            const want = @min(s.raw.len, out.len - n);
            const got = c.macc_window_poll(w, &s.raw, want);
            if (got == 0) break;
            for (s.raw[0..got]) |r| {
                var whats: [nsinput.max_events]nsinput.What = undefined;
                const k = nsinput.translate(&s.state, record(r), &whats);
                const t: api.Micros = @intCast(r.time_ns / 1000);
                for (whats[0..k]) |wh| {
                    const e: api.InputEvent = .{ .time_us = t, .what = wh };
                    if (n < out.len) {
                        out[n] = e;
                        n += 1;
                    } else {
                        s.pending[s.pending_n] = e;
                        s.pending_n += 1;
                    }
                }
            }
        }
        return n;
    }
};

pub fn record(r: c.macc_event) nsinput.Record {
    return .{
        .kind = @enumFromInt(r.kind),
        .key_code = r.key_code,
        .modifier_flags = r.modifier_flags,
        .repeat = r.repeat != 0,
        .button = r.button,
        .dx = r.dx,
        .dy = r.dy,
        .precise = r.precise != 0,
        .inverted = r.inverted != 0,
    };
}

// ---------------------------------------------------------------------------
// Bundle

pub const Client = struct {
    gpa: std.mem.Allocator,
    window: ?*c.macc_window,
    decoder: Decoder,
    presenter: Presenter,
    audio: AudioSink = .{},
    input: InputSource,

    pub fn backend(cl: *Client) api.ClientBackend {
        return .{
            .clock = clock,
            .decoder = api.bind(api.Decoder, Decoder, &cl.decoder),
            .presenter = api.bind(api.Presenter, Presenter, &cl.presenter),
            .audio = api.bind(api.AudioSink, AudioSink, &cl.audio),
            .input = api.bind(api.InputSource, InputSource, &cl.input),
            .deinit_ptr = cl,
            .deinitFn = &deinitOpaque,
        };
    }

    fn deinitOpaque(p: ?*anyopaque) void {
        const cl: *Client = @ptrCast(@alignCast(p.?));
        cl.deinit();
    }

    pub fn deinit(cl: *Client) void {
        cl.input.pads.close();
        cl.audio.stop();
        cl.decoder.deinit();
        c.macc_presenter_destroy(cl.presenter.pr);
        if (cl.window) |w| c.macc_window_destroy(w);
        cl.gpa.free(cl.presenter.canvas);
        const gpa = cl.gpa;
        gpa.destroy(cl);
    }
};

pub const OpenError = error{ NoWindow, NoDevice, BackendFailed, OutOfMemory };

/// Opens the window (unless `offscreen`), the Metal presenter on the system default
/// device, and NSEvent input. The decoder is created on `Decoder.configure`, audio on
/// `AudioSink.start`.
pub fn open(gpa: std.mem.Allocator, opts: Options) OpenError!*Client {
    var w: ?*c.macc_window = null;
    if (!opts.offscreen) {
        const st = c.macc_window_create(opts.width, opts.height, opts.title.ptr, if (opts.visible) c.MACC_WINDOW_VISIBLE else 0, &w);
        if (st == c.MACC_E_NO_WINDOW) return error.NoWindow;
        if (st != c.MACC_OK) return error.BackendFailed;
    }
    errdefer if (w) |h| c.macc_window_destroy(h);

    var pr: ?*c.macc_presenter = null;
    const flags: u32 = if (opts.readback) c.MACC_PRESENTER_READBACK else 0;
    switch (c.macc_presenter_create(w, opts.width, opts.height, flags, &pr)) {
        c.MACC_OK => {},
        c.MACC_E_NO_DEVICE => return error.NoDevice,
        else => |st| {
            log.err("macc_presenter_create: status {d}", .{st});
            return error.BackendFailed;
        },
    }
    errdefer c.macc_presenter_destroy(pr);
    log.info("presenter: Metal on {s}, {s}", .{ std.mem.span(c.macc_presenter_device_name(pr)), if (w != null) "window" else "offscreen" });

    // The canvas is as large as the overlay the presenter can show.
    const cw = 1024;
    const ch = 512;
    const canvas = try gpa.alloc(u32, cw * ch);
    errdefer gpa.free(canvas);

    const cl = try gpa.create(Client);
    cl.* = .{
        .gpa = gpa,
        .window = w,
        .decoder = .{ .hardware = opts.hardware_decode },
        .presenter = .{
            .pr = pr.?,
            .window = w,
            .style = opts.overlay_style,
            .overlay_interval_us = opts.overlay_interval_us,
            .canvas = canvas,
            .canvas_w = cw,
            .canvas_h = ch,
        },
        .audio = .{ .ring_frames = opts.audio_ring_frames },
        .input = .{
            .window = w,
            .pads = if (opts.gamepads) gamepad.gamecontroller.Source.open(clock) catch .{ .clock = clock } else .{ .clock = clock },
        },
    };
    return cl;
}

/// The platform interface's entry point: `openClient(gpa, opts)`.
pub fn openClient(gpa: std.mem.Allocator, opts: Options) OpenError!api.ClientBackend {
    const cl = try open(gpa, opts);
    return cl.backend();
}

test {
    _ = nsinput;
}
