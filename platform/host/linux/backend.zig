//! The Linux host's `HostBackend` (platform/api.zig): `open` puts the pieces together.
//!
//!   Capture       `.portal`: the ScreenCast portal and its PipeWire stream (host.zig),
//!                 memory frames (bgra8). `.synthetic`: the test pattern.
//!   Encoder       `.auto`: with portal capture, the first of VAAPI, NVENC and the
//!                 software encoder that opens (encoder.zig); with synthetic capture, the
//!                 synthetic passthrough (the pattern rides it end to end). `.vaapi`,
//!                 `.software` force one; `.synthetic` only carries synthetic frames.
//!   AudioSource   `.portal` capture: the default sink's monitor over PipeWire
//!                 (host.zig), checked at open and left out when PipeWire is not there.
//!                 Synthetic capture: the synthetic tone.
//!   InputInjector uinput keyboard, mouse, absolute pointer and gamepads (input.zig).
//!   Clock         CLOCK_MONOTONIC.
//!
//! Without a usable /dev/uinput the host logs why and how to fix it, and streams without
//! input, unless `require_input` is set.
const std = @import("std");
const api = @import("platform");
const synthetic = @import("synthetic");
const enc_mod = @import("host_linux_enc");

const host = @import("host.zig");
pub const input = host.input;
const ui = host.uinput;

const log = std.log.scoped(.host_linux);

pub const clock = host.clock;

/// Screen capture backends.
pub const CaptureKind = enum {
    /// xdg-desktop-portal ScreenCast + PipeWire (host.zig).
    portal,
    /// The synthetic test pattern.
    synthetic,
};

/// Encoders. `.auto` depends on the capture (see the top of this file).
pub const EncoderKind = enum {
    auto,
    vaapi,
    nvenc,
    software,
    synthetic,
};

pub const Options = struct {
    capture: CaptureKind = .synthetic,
    encoder: EncoderKind = .auto,
    /// Synthetic capture: picture size.
    width: u32 = 1280,
    height: u32 = 720,
    /// Offer the audio source.
    audio: bool = true,
    /// Inject input through uinput.
    input: bool = true,
    /// Fail `open` when uinput is not usable, instead of streaming without input.
    require_input: bool = false,
    /// Synthetic capture and audio pace themselves with this (null: virtual time).
    sleeper: synthetic.Sleeper = null,
    sleep_ctx: ?*anyopaque = null,
    /// Creates the uinput devices (tests replace it).
    opener: input.Opener = input.Opener.uinput,
    /// Portal capture: where the restore token lives (host.tokenPath), so an unattended
    /// host asks the user once.
    token_path: ?[:0]const u8 = null,
    /// Portal capture: let the user share several monitors in the portal's dialog, which
    /// the host then lists as its displays and the client can switch between.
    multiple_displays: bool = true,
    /// DRM render node for VAAPI (null: the first that opens).
    va_device: ?[:0]const u8 = null,
};

pub const OpenError = error{ OutOfMemory, Unsupported, NoInput, NoEncoder };

pub const Host = struct {
    gpa: std.mem.Allocator,
    synth: *synthetic.Host,
    capture_kind: CaptureKind,
    encoder_kind: EncoderKind,
    injector: ?input.Injector = null,
    /// Why there is no injector, when there is none.
    input_error: ?ui.Error = null,
    with_audio: bool,
    capture: OutputCapture = undefined,
    /// Portal capture and PipeWire audio (capture_kind == .portal).
    portal: host.Capture = undefined,
    pw_audio: host.AudioSource = undefined,
    /// A real encoder (encoder_kind != .synthetic).
    enc: enc_mod.Encoder = undefined,
    token_path: ?[:0]u8 = null,

    /// The capture, which also tells the injector the output's size when it starts, so
    /// absolute positions land on the captured pixels.
    const OutputCapture = struct {
        inner: api.Capture,
        host: *Host,

        pub fn start(c: *OutputCapture, cfg: api.CaptureConfig) api.Error!api.Size {
            const size = try c.inner.start(cfg);
            if (c.host.injector) |*j| j.setOutput(size);
            return size;
        }
        pub fn acquire(c: *OutputCapture, timeout_us: api.Micros) api.Error!?api.CapturedFrame {
            return c.inner.acquire(timeout_us);
        }
        pub fn repeatLast(c: *OutputCapture) api.Error!?api.CapturedFrame {
            return c.inner.repeatLast();
        }
        pub fn release(c: *OutputCapture, f: *const api.CapturedFrame) void {
            c.inner.release(f);
        }
        pub fn stop(c: *OutputCapture) void {
            c.inner.stop();
        }
        pub fn displays(c: *OutputCapture, out: []api.DisplayInfo) api.Error!usize {
            return c.inner.displays(out);
        }
    };

    pub fn backend(h: *Host) api.HostBackend {
        const sb = h.synth.backend();
        const portal = h.capture_kind == .portal;
        h.capture = .{ .inner = if (portal) h.portal.iface() else sb.capture, .host = h };
        return .{
            .clock = clock,
            .capture = api.bind(api.Capture, OutputCapture, &h.capture),
            .encoder = if (h.encoder_kind == .synthetic) sb.encoder else api.bind(api.Encoder, enc_mod.Encoder, &h.enc),
            .audio = if (!h.with_audio) null else if (portal) h.pw_audio.iface() else sb.audio,
            .input = if (h.injector) |*j| api.bind(api.InputInjector, input.Injector, j) else null,
            .deinit_ptr = h,
            .deinitFn = deinitHost,
        };
    }

    /// What was chosen, for logs and reports.
    pub fn describe(h: *const Host, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("capture {s}, encoder {s}, audio {s}, input ", .{
            @tagName(h.capture_kind),
            if (h.encoder_kind == .synthetic) "synthetic" else h.enc.describe(),
            if (!h.with_audio) "off" else if (h.capture_kind == .portal) "pipewire" else "synthetic",
        });
        if (h.injector != null) try w.writeAll("uinput") else if (h.input_error) |e| try w.print("none ({s})", .{@errorName(e)}) else try w.writeAll("off");
    }

    fn deinitHost(p: ?*anyopaque) void {
        const h: *Host = @ptrCast(@alignCast(p.?));
        if (h.injector) |*j| j.deinit();
        if (h.capture_kind == .portal) {
            h.portal.deinit();
            h.pw_audio.stop();
        }
        if (h.encoder_kind != .synthetic) h.enc.deinit();
        if (h.token_path) |t| h.gpa.free(t);
        h.synth.backend().deinit();
        h.gpa.destroy(h);
    }
};

fn encoderKind(k: EncoderKind) enc_mod.Kind {
    return switch (k) {
        .vaapi => .vaapi,
        .nvenc => .nvenc,
        .software => .software,
        .auto, .synthetic => .auto,
    };
}

pub fn open(gpa: std.mem.Allocator, o: Options) OpenError!*Host {
    const encoder_kind: EncoderKind = switch (o.encoder) {
        .auto => if (o.capture == .synthetic) .synthetic else .auto,
        else => |k| k,
    };
    if (encoder_kind == .synthetic and o.capture != .synthetic) {
        log.err("the synthetic encoder only carries the synthetic capture's frames", .{});
        return error.Unsupported;
    }
    const synth = synthetic.openHost(gpa, .{ .clock = clock, .sleeper = o.sleeper, .sleep_ctx = o.sleep_ctx, .width = o.width, .height = o.height, .audio = o.audio }) catch return error.OutOfMemory;
    errdefer synth.backend().deinit();
    const h = try gpa.create(Host);
    errdefer gpa.destroy(h);
    h.* = .{ .gpa = gpa, .synth = synth, .capture_kind = o.capture, .encoder_kind = encoder_kind, .with_audio = o.audio };
    if (encoder_kind != .synthetic) {
        h.enc = enc_mod.Encoder.create(.{ .kind = encoderKind(encoder_kind), .device = o.va_device }) catch return error.NoEncoder;
    }
    errdefer if (encoder_kind != .synthetic) h.enc.deinit();
    if (o.capture == .portal) {
        if (o.token_path) |t| h.token_path = try gpa.dupeZ(u8, t);
        h.portal = host.Capture.init(.{ .token_path = h.token_path, .multiple = o.multiple_displays });
        h.pw_audio = host.AudioSource.init(.{});
        // The app fails to start when its audio source does: check PipeWire now and
        // stream without audio when it is not there.
        if (o.audio) {
            if (h.pw_audio.start(.{})) |_| h.pw_audio.stop() else |e| {
                log.warn("audio: no PipeWire capture ({s}); streaming without audio", .{@errorName(e)});
                h.with_audio = false;
            }
        }
    }
    errdefer if (h.token_path) |t| gpa.free(t);
    if (o.input) {
        if (input.Injector.init(o.opener)) |j| h.injector = j else |e| {
            h.input_error = e;
            logInputError(e);
            if (o.require_input) return error.NoInput;
        }
    }
    return h;
}

/// Says what is wrong with /dev/uinput and how to fix it.
pub fn logInputError(e: ui.Error) void {
    switch (e) {
        error.NoUinput => log.warn("input: /dev/uinput is missing: load the module (`sudo modprobe uinput`; " ++
            "platform/host/linux/moonsec-uinput.conf loads it at boot). Streaming without input.", .{}),
        error.AccessDenied => log.warn("input: no write access to /dev/uinput: install platform/host/linux/60-moonsec-uinput.rules " ++
            "and add this user to the `moonsec` group (see platform/host/linux/README.md). Streaming without input.", .{}),
        error.SetupFailed, error.NoEventNode => log.warn("input: creating the uinput devices failed ({s}). Streaming without input.", .{@errorName(e)}),
    }
}
