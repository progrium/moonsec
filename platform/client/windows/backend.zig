//! Windows client backend: `openClient` returns the platform interface's
//! `ClientBackend` (platform/api.zig) on top of the C side in mswc.h.
//!
//!   Decoder     Media Foundation H.264/HEVC MFT, low-latency mode; D3D11VA through
//!               a DXGI device manager on a hardware device, software otherwise.
//!               Output: NV12 ID3D11Texture2D (+ array slice) in `Image.gpu`.
//!   Presenter   Flip-model swapchain, waitable object, max frame latency 1,
//!               tearing in lowest-latency mode; video-processor NV12 -> BGRA;
//!               the latency overlay drawn on the CPU (platform/client/common).
//!   AudioSink   WASAPI shared mode, f32; IAudioClient3's smallest period when the
//!               mix format allows it.
//!   InputSource Raw Input keyboard and mouse from the window's own thread.
//!
//! Decoder and presenter share one D3D11 device (multithread-protected), so decoded
//! textures go to the presenter without a copy.

const std = @import("std");
const api = @import("platform");
const win = @import("win");
const overlay = @import("client_overlay");
const rawinput = @import("rawinput.zig");

pub const c = @import("mswc_c");

const log = std.log.scoped(.client_windows);

pub const Options = struct {
    driver: win.Driver = .hardware,
    adapter_index: u32 = 0,
    /// Hardware decode (D3D11VA) when the device and MFT allow it.
    hardware_decode: bool = true,
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "moonsec",
    visible: bool = true,
    raw_input: bool = true,
    /// Raw Input while the window is in the background too (tests use it).
    input_sink: bool = false,
    overlay_style: overlay.Style = .{},
    /// How often the overlay image is redrawn from the latest snapshot.
    overlay_interval_us: api.Micros = 100_000,
};

pub fn nowUs() api.Micros {
    return @intCast(win.qpcNs() / 1000);
}

pub const clock: api.Clock = api.clockFn(nowUs);

fn hrFail(what: []const u8, hr: i32) api.Error {
    win.last_hr = hr;
    log.err("{s}: {f}", .{ what, win.fmtHr(hr) });
    const u: u32 = @bitCast(hr);
    return switch (u) {
        0x887A0005, 0x887A0006, 0x887A0007, 0x887A0020 => error.DeviceLost, // removed, hung, reset, driver internal
        0x8007000E => error.OutOfMemory,
        0xC00D5212 => error.Unsupported, // MF_E_TOPO_CODEC_NOT_FOUND
        0x80070490 => error.Unsupported, // E_NOTFOUND (no audio endpoint)
        else => error.BackendFailed,
    };
}

/// mswc.h includes msw.h, so translate-c gives it its own msw_d3d opaque type.
pub fn d3dPtr(d: win.D3d) *c.msw_d3d {
    return @ptrCast(d.handle);
}

/// The client's D3D11 device. Video support (D3D11_CREATE_DEVICE_VIDEO_SUPPORT) is
/// needed for D3D11VA through Media Foundation; WARP refuses the flag, and its video
/// processor and the software decode path work without it, so fall back.
pub fn createDevice(driver: win.Driver, adapter_index: u32) win.Error!win.D3d {
    return win.D3d.create(.{ .driver = driver, .adapter_index = adapter_index, .video = true }) catch |e| {
        log.info("D3D11 device without video support ({f})", .{win.fmtHr(win.last_hr)});
        return win.D3d.create(.{ .driver = driver, .adapter_index = adapter_index }) catch return e;
    };
}

fn ok(what: []const u8, hr: i32) api.Error!void {
    if (hr < 0) return hrFail(what, hr);
}

// ---------------------------------------------------------------------------
// Decoder

pub const Decoder = struct {
    d3d: win.D3d,
    hardware: bool,
    codecs: api.CodecSet,
    dec: ?*c.mswc_decoder = null,
    codec: api.Codec = .h264,
    held: ?c.mswc_frame = null,

    pub fn caps(d: *Decoder) api.DecoderCaps {
        return .{ .codecs = d.codecs, .gpu_output = true };
    }

    pub fn configure(d: *Decoder, cfg: api.DecoderConfig) api.Error!void {
        const codec: u32 = switch (cfg.codec) {
            .h264 => c.MSWC_CODEC_H264,
            .hevc => c.MSWC_CODEC_HEVC,
            else => return error.Unsupported,
        };
        d.close();
        var h: ?*c.mswc_decoder = null;
        try ok("mswc_decoder_create", c.mswc_decoder_create(d3dPtr(d.d3d), codec, @intFromBool(d.hardware), &h));
        d.dec = h;
        d.codec = cfg.codec;
        log.info("decoder: {s} {s}", .{ @tagName(cfg.codec), if (c.mswc_decoder_is_hardware(h) != 0) "D3D11VA" else "software" });
    }

    pub fn isHardware(d: *const Decoder) bool {
        return if (d.dec) |h| c.mswc_decoder_is_hardware(h) != 0 else false;
    }

    pub fn decode(d: *Decoder, au: *const api.AccessUnit) api.Error!?api.DecodedFrame {
        std.debug.assert(d.held == null); // release before the next decode
        const h = d.dec orelse return error.BackendFailed;
        if (au.codec != d.codec) return error.Unsupported;
        var f: c.mswc_frame = undefined;
        var got: c_int = 0;
        const hr = c.mswc_decoder_decode(h, au.data.ptr, au.data.len, au.frame_id, &f, &got);
        if (hr < 0) {
            const e = hrFail("decode", hr);
            if (e == error.BackendFailed) {
                // The MFT can be left mid-picture; start clean for the recovery frame.
                _ = c.mswc_decoder_flush(h);
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
                .format = .nv12,
                .gpu = f.texture,
                .gpu_index = f.index,
            },
            .decoded_us = nowUs(),
        };
    }

    pub fn release(d: *Decoder, _: *const api.DecodedFrame) void {
        if (d.held) |*f| {
            c.mswc_decoder_release_frame(d.dec, f);
            d.held = null;
        }
    }

    fn close(d: *Decoder) void {
        if (d.held) |*f| c.mswc_decoder_release_frame(d.dec, f);
        d.held = null;
        if (d.dec) |h| c.mswc_decoder_destroy(h);
        d.dec = null;
    }

    pub fn deinit(d: *Decoder) void {
        d.close();
    }
};

/// Which codecs this machine's Media Foundation can decode (a decoder MFT exists).
pub fn probeCodecs(d3d: win.D3d) api.CodecSet {
    var set: api.CodecSet = .{};
    inline for (.{ .{ "h264", c.MSWC_CODEC_H264 }, .{ "hevc", c.MSWC_CODEC_HEVC } }) |e| {
        var h: ?*c.mswc_decoder = null;
        if (c.mswc_decoder_create(d3dPtr(d3d), e[1], 0, &h) >= 0) {
            c.mswc_decoder_destroy(h);
            @field(set, e[0]) = true;
        }
    }
    return set;
}

// ---------------------------------------------------------------------------
// Presenter

pub const Presenter = struct {
    pr: *c.mswc_presenter,
    window: *c.mswc_window,
    mode: api.PresentMode = .lowest_latency,
    windowed: bool = true,
    style: overlay.Style,
    overlay_interval_us: api.Micros,
    overlay_due: api.Micros = 0,
    overlay_shown: bool = false,
    canvas: []u32,
    canvas_w: u32,
    canvas_h: u32,
    // Frame rate over the last second of presents.
    fps_window_start: api.Micros = 0,
    fps_count: u32 = 0,
    fps: ?f32 = null,

    pub fn configure(p: *Presenter, cfg: api.PresenterConfig) api.Error!void {
        p.mode = cfg.mode;
        if (cfg.windowed != p.windowed) {
            c.mswc_window_set_fullscreen(p.window, @intFromBool(!cfg.windowed));
            p.windowed = cfg.windowed;
        }
    }

    pub fn tearing(p: *const Presenter) bool {
        return c.mswc_presenter_tearing(p.pr) != 0;
    }

    pub fn present(p: *Presenter, frame: *const api.DecodedFrame, ov: ?*const api.Overlay) api.Error!api.Presented {
        if (c.mswc_window_open(p.window) == 0) return error.Closed;
        try ok("resize", c.mswc_presenter_sync_size(p.pr));
        // Wait until DXGI can take a frame without queueing it (max latency 1).
        const w = c.mswc_presenter_wait(p.pr, 100);
        if (w < 0 and w != win.hrCode(c.MSW_DXGI_ERROR_WAIT_TIMEOUT)) return hrFail("wait", w);

        try p.updateOverlay(ov);

        var f: c.mswc_frame = std.mem.zeroes(c.mswc_frame);
        const img = frame.image;
        if (img.gpu) |tex| {
            if (img.format != .nv12) return error.Unsupported;
            f.texture = tex;
            f.index = img.gpu_index;
            f.width = img.width;
            f.height = img.height;
        } else return error.Unsupported;

        try ok("draw", c.mswc_presenter_draw(p.pr, &f));
        try ok("present", c.mswc_presenter_present(p.pr, switch (p.mode) {
            .lowest_latency => c.MSWC_PRESENT_LOWEST_LATENCY,
            .smooth => c.MSWC_PRESENT_SMOOTH,
        }));
        const now = nowUs();
        p.countFrame(now);
        return .{ .presented_us = now };
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
            if (p.overlay_shown) try ok("overlay", c.mswc_presenter_set_overlay(p.pr, null, 0, 0, 0));
            p.overlay_shown = false;
            return;
        };
        const now = nowUs();
        if (p.overlay_shown and now < p.overlay_due) return;
        p.overlay_due = now + p.overlay_interval_us;
        const canvas: overlay.Canvas = .{ .pixels = p.canvas, .width = p.canvas_w, .height = p.canvas_h, .stride = p.canvas_w };
        const r = overlay.render(canvas, &o.telemetry, overlay.Status.from(o, p.fps), p.style);
        try ok("overlay", c.mswc_presenter_set_overlay(p.pr, p.canvas.ptr, r.w, r.h, p.canvas_w));
        p.overlay_shown = true;
    }

    pub fn deinit(p: *Presenter) void {
        _ = p;
    }
};

// ---------------------------------------------------------------------------
// Audio

pub const AudioSink = struct {
    a: ?*c.mswc_audio = null,
    channels: u8 = 2,

    pub fn start(s: *AudioSink, fmt: api.AudioFormat) api.Error!api.AudioFormat {
        s.stop();
        var h: ?*c.mswc_audio = null;
        try ok("mswc_audio_open", c.mswc_audio_open(fmt.rate, fmt.channels, &h));
        s.a = h;
        s.channels = fmt.channels;
        var frames: u32 = 0;
        var period: i64 = 0;
        var low: c_int = 0;
        c.mswc_audio_info(h, &frames, &period, &low);
        log.info("audio out: {d} Hz x{d}, buffer {d} frames, period {d} us{s}", .{ fmt.rate, fmt.channels, frames, @divTrunc(period, 10), if (low != 0) " (IAudioClient3)" else "" });
        return fmt;
    }

    pub fn write(s: *AudioSink, pcm: []const f32) api.Error!usize {
        const h = s.a orelse return error.Closed;
        var n: u32 = 0;
        const frames: u32 = @intCast(pcm.len / s.channels);
        try ok("audio write", c.mswc_audio_write(h, pcm.ptr, frames, &n));
        return n;
    }

    pub fn queued(s: *AudioSink) usize {
        const h = s.a orelse return 0;
        var n: u32 = 0;
        _ = c.mswc_audio_queued(h, &n);
        return n;
    }

    pub fn stop(s: *AudioSink) void {
        if (s.a) |h| c.mswc_audio_close(h);
        s.a = null;
    }
};

// ---------------------------------------------------------------------------
// Input

pub const InputSource = struct {
    window: *c.mswc_window,
    kb: rawinput.Keyboard = .{},
    raw: [64]c.mswc_raw = undefined,
    /// Events translated from a record that did not fit in the caller's buffer.
    pending: [rawinput.max_mouse_events]api.InputEvent = undefined,
    pending_n: usize = 0,

    pub fn poll(s: *InputSource, out: []api.InputEvent) api.Error!usize {
        var n: usize = 0;
        while (n < out.len and s.pending_n > 0) {
            out[n] = s.pending[0];
            std.mem.copyForwards(api.InputEvent, s.pending[0 .. s.pending_n - 1], s.pending[1..s.pending_n]);
            s.pending_n -= 1;
            n += 1;
        }
        while (n < out.len and s.pending_n == 0) {
            // Never take more records than could produce events for `out`.
            const want = @min(s.raw.len, out.len - n);
            const got = c.mswc_window_poll_raw(s.window, &s.raw, want);
            if (got == 0) break;
            for (s.raw[0..got]) |r| {
                var evs: [rawinput.max_mouse_events]api.InputEvent = undefined;
                const k = translate(&s.kb, r, &evs);
                for (evs[0..k]) |e| {
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

fn translate(kb: *rawinput.Keyboard, r: c.mswc_raw, out: *[rawinput.max_mouse_events]api.InputEvent) usize {
    const t: api.Micros = @intCast(r.time_ns / 1000);
    switch (r.kind) {
        c.MSWC_RAW_KEYBOARD => {
            const w = rawinput.keyboardEvent(kb, .{ .make_code = r.kb_make_code, .flags = r.kb_flags }) orelse return 0;
            out[0] = .{ .time_us = t, .what = w };
            return 1;
        },
        c.MSWC_RAW_MOUSE => {
            var ws: [rawinput.max_mouse_events]rawinput.What = undefined;
            const k = rawinput.mouseEvents(.{
                .flags = r.mouse_flags,
                .button_flags = r.mouse_button_flags,
                .button_data = r.mouse_button_data,
                .last_x = r.mouse_last_x,
                .last_y = r.mouse_last_y,
            }, &ws);
            for (ws[0..k], 0..) |w, i| out[i] = .{ .time_us = t, .what = w };
            return k;
        },
        c.MSWC_RAW_QUIT => {
            out[0] = .{ .time_us = t, .what = .quit };
            return 1;
        },
        else => return 0,
    }
}

// ---------------------------------------------------------------------------
// Bundle

pub const Client = struct {
    gpa: std.mem.Allocator,
    com: win.ComThread,
    d3d: win.D3d,
    window: *c.mswc_window,
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
        cl.audio.stop();
        cl.decoder.deinit();
        c.mswc_presenter_destroy(cl.presenter.pr);
        c.mswc_window_destroy(cl.window);
        cl.d3d.destroy();
        cl.gpa.free(cl.presenter.canvas);
        cl.com.deinit();
        const gpa = cl.gpa;
        gpa.destroy(cl);
    }
};

/// Opens the window, the shared D3D11 device, the swapchain and Raw Input. The
/// decoder is created on `Decoder.configure`, audio on `AudioSink.start`. COM is
/// initialized (MTA) on the calling thread; the decode, present and audio threads
/// must call `win.ComThread.init` themselves.
pub fn open(gpa: std.mem.Allocator, opts: Options) !*Client {
    const com = try win.ComThread.init();
    errdefer com.deinit();
    const d3d = try createDevice(opts.driver, opts.adapter_index);
    errdefer d3d.destroy();

    var flags: u32 = 0;
    if (opts.visible) flags |= c.MSWC_WINDOW_VISIBLE;
    if (opts.raw_input) flags |= c.MSWC_WINDOW_RAW_INPUT;
    if (opts.input_sink) flags |= c.MSWC_WINDOW_INPUT_SINK;
    var w: ?*c.mswc_window = null;
    try win.check(c.mswc_window_create(opts.width, opts.height, opts.title.ptr, flags, &w));
    errdefer c.mswc_window_destroy(w);

    var pr: ?*c.mswc_presenter = null;
    try win.check(c.mswc_presenter_create(d3dPtr(d3d), w, &pr));
    errdefer c.mswc_presenter_destroy(pr);

    // The canvas is as large as the overlay the presenter can show.
    const cw = 1024;
    const ch = 512;
    const canvas = try gpa.alloc(u32, cw * ch);
    errdefer gpa.free(canvas);

    const cl = try gpa.create(Client);
    cl.* = .{
        .gpa = gpa,
        .com = com,
        .d3d = d3d,
        .window = w.?,
        .decoder = .{
            .d3d = d3d,
            .hardware = opts.hardware_decode and opts.driver == .hardware,
            .codecs = probeCodecs(d3d),
        },
        .presenter = .{
            .pr = pr.?,
            .window = w.?,
            .style = opts.overlay_style,
            .overlay_interval_us = opts.overlay_interval_us,
            .canvas = canvas,
            .canvas_w = cw,
            .canvas_h = ch,
        },
        .input = .{ .window = w.? },
    };
    return cl;
}

/// The platform interface's entry point: `openClient(gpa, opts)`.
pub fn openClient(gpa: std.mem.Allocator, opts: Options) !api.ClientBackend {
    const cl = try open(gpa, opts);
    return cl.backend();
}

test {
    _ = rawinput;
}
