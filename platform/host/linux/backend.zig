//! The Linux host's `HostBackend` (platform/api.zig) for `moonsec ... host --host linux`:
//! `open` puts the pieces together.
//!
//!   Capture       synthetic test pattern for now; the ScreenCast capture (host.zig) is
//!                 wired in together with the encoders (encoder.zig), since the synthetic
//!                 encoder only carries the pattern.
//!   Encoder       synthetic passthrough for now; `.auto` will try VAAPI, then libx264.
//!   AudioSource   synthetic tone for now; host.zig's PipeWire source joins with capture.
//!   InputInjector uinput keyboard, mouse, absolute pointer and gamepads (input.zig).
//!   Clock         CLOCK_MONOTONIC.
//!
//! Without a usable /dev/uinput the host logs why and how to fix it, and streams without
//! input, unless `require_input` is set.
const std = @import("std");
const api = @import("platform");
const synthetic = @import("synthetic");

const host = @import("host.zig");
pub const input = host.input;
const ui = host.uinput;

const log = std.log.scoped(.host_linux);

pub const clock = host.clock;

/// Screen capture backends, best first.
pub const CaptureKind = enum {
    // portal (host.zig's Capture): next, with the encoders.
    synthetic,
};

/// Encoders, in the order `.auto` tries them.
pub const EncoderKind = enum {
    auto,
    // vaapi, software (encoder.zig): next.
    synthetic,
};

/// `.auto`'s order. VAAPI and the software encoder go ahead of synthetic when wired in.
pub const encoder_order = [_]EncoderKind{.synthetic};

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
};

pub const OpenError = error{ OutOfMemory, Unsupported, NoInput };

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
    };

    pub fn backend(h: *Host) api.HostBackend {
        const sb = h.synth.backend();
        h.capture = .{ .inner = sb.capture, .host = h };
        return .{
            .clock = clock,
            .capture = api.bind(api.Capture, OutputCapture, &h.capture),
            .encoder = sb.encoder,
            .audio = if (h.with_audio) sb.audio else null,
            .input = if (h.injector) |*j| api.bind(api.InputInjector, input.Injector, j) else null,
            .deinit_ptr = h,
            .deinitFn = deinitHost,
        };
    }

    /// What was chosen, for logs and reports.
    pub fn describe(h: *const Host, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("capture {s}, encoder {s}, audio {s}, input ", .{ @tagName(h.capture_kind), @tagName(h.encoder_kind), if (h.with_audio) "synthetic" else "off" });
        if (h.injector != null) try w.writeAll("uinput") else if (h.input_error) |e| try w.print("none ({s})", .{@errorName(e)}) else try w.writeAll("off");
    }

    fn deinitHost(p: ?*anyopaque) void {
        const h: *Host = @ptrCast(@alignCast(p.?));
        if (h.injector) |*j| j.deinit();
        h.synth.backend().deinit();
        h.gpa.destroy(h);
    }
};

pub fn open(gpa: std.mem.Allocator, o: Options) OpenError!*Host {
    const encoder_kind: EncoderKind = switch (o.encoder) {
        .auto => encoder_order[0],
        else => |k| k,
    };
    const synth = synthetic.openHost(gpa, .{ .clock = clock, .sleeper = o.sleeper, .sleep_ctx = o.sleep_ctx, .width = o.width, .height = o.height, .audio = o.audio }) catch return error.OutOfMemory;
    errdefer synth.backend().deinit();
    const h = try gpa.create(Host);
    h.* = .{ .gpa = gpa, .synth = synth, .capture_kind = o.capture, .encoder_kind = encoder_kind, .with_audio = o.audio };
    if (o.input) {
        if (input.Injector.init(o.opener)) |j| h.injector = j else |e| {
            h.input_error = e;
            logInputError(e);
            if (o.require_input) {
                gpa.destroy(h);
                return error.NoInput;
            }
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
