//! The platform interface: what every OS backend implements so the host and client apps
//! can run on it (docs/design.md, "Platform backends"). The session spine (app/) drives
//! these objects; it never learns which OS, GPU API or codec library is underneath.
//!
//! Host:   Capture -> Encoder -> (session, PacketPipe) ; AudioSource ; InputInjector
//! Client: (PacketPipe, session) -> Decoder -> Presenter ; AudioSink ; InputSource
//!
//! Each object is a type-erased `{ ptr, vtable }` pair like `PacketPipe`. `bind(T, &impl)`
//! builds one from any type with the right methods, so a backend writes plain methods
//! and never touches a vtable.
//!
//! Rules every backend follows:
//!   - Threads. Each object is used from one thread at a time (the app gives each
//!     pipeline stage its own thread). Calls may block where the doc says so; nothing
//!     else blocks. Objects of one bundle may be called from different threads at once
//!     (capture on the capture thread while the encoder runs on the encode thread).
//!   - Time. Every timestamp a backend returns is microseconds on the bundle's `Clock`,
//!     the same monotonic clock the session uses (QueryPerformanceCounter on Windows,
//!     mach_absolute_time on macOS, CLOCK_MONOTONIC on Linux).
//!   - Memory. A backend owns every buffer it hands out. A returned frame or slice is
//!     valid until the matching `release`, or until the next call on that object where
//!     there is no `release`. Callers own the buffers they pass in.
//!   - Errors. `Error` below; a backend logs details itself. `DeviceLost` means the app
//!     should tear the bundle down and open it again (GPU reset, display mode change).
//!
//! Stable from Phase 2 on: add fields with defaults and new optional methods at the end
//! of a vtable; don't change or reorder what is here.
const std = @import("std");
const core = @import("core");

pub const Micros = i64;

pub const Error = error{
    /// The backend cannot do this (codec, format, resolution, feature).
    Unsupported,
    /// The device went away or was reset; reopen the bundle.
    DeviceLost,
    /// The encoder or decoder rejected this frame. For a decoder, this is the
    /// "decode failed" that freezes the client until a recovery frame (core/recovery).
    CodecFailed,
    /// The backend was stopped or its window closed.
    Closed,
    OutOfMemory,
    /// Anything else; the backend has logged why.
    BackendFailed,
};

/// The bundle's monotonic clock. `now` is cheap and callable from any thread.
pub const Clock = struct {
    ptr: ?*anyopaque = null,
    nowFn: *const fn (ptr: ?*anyopaque) Micros,

    pub fn now(c: Clock) Micros {
        return c.nowFn(c.ptr);
    }
};

// ---------------------------------------------------------------------------
// Images and codecs

pub const Codec = enum(u8) {
    h264 = 1,
    hevc = 2,
    av1 = 3,
    /// The synthetic backend's codec (platform/synthetic): carries the test pattern's
    /// parameters, a checksum and filler sized to the bitrate. For tests and the sim.
    passthrough = 250,
    _,
};

pub const CodecSet = packed struct(u8) {
    h264: bool = false,
    hevc: bool = false,
    av1: bool = false,
    passthrough: bool = false,
    _reserved: u4 = 0,

    pub fn has(s: CodecSet, c: Codec) bool {
        return switch (c) {
            .h264 => s.h264,
            .hevc => s.hevc,
            .av1 => s.av1,
            .passthrough => s.passthrough,
            _ => false,
        };
    }
};

pub const PixelFormat = enum(u8) {
    /// 8-bit B, G, R, A in memory order (DXGI_FORMAT_B8G8R8A8_UNORM, kCVPixelFormatType_32BGRA).
    bgra8 = 1,
    /// 8-bit 4:2:0, Y plane then interleaved UV.
    nv12 = 2,
    /// 10-bit 4:2:0 in 16-bit words.
    p010 = 3,
    _,
};

/// A picture: on the GPU (`gpu`, a backend-specific handle such as an ID3D11Texture2D*,
/// IOSurfaceRef or VASurfaceID), in memory (`cpu`), or both. Encoders and presenters say
/// which they take in their caps; the app pairs backends that agree.
pub const Image = struct {
    width: u32,
    height: u32,
    format: PixelFormat = .bgra8,
    gpu: ?*anyopaque = null,
    /// Subresource or array slice of `gpu` (Desktop Duplication and D3D11VA use arrays).
    gpu_index: u32 = 0,
    cpu: ?Cpu = null,

    pub const Cpu = struct {
        /// The first plane; for nv12/p010 the UV plane follows at `height * stride`.
        data: []const u8,
        stride: u32,
    };
};

// ---------------------------------------------------------------------------
// Host: capture

pub const CaptureConfig = struct {
    /// Display index (0 = primary).
    display: u32 = 0,
    /// Frames per second the app wants; a backend may deliver fewer when nothing changes.
    fps: u32 = 60,
    /// Draw the cursor into the frame. Desktop mode leaves it off and the client draws it.
    cursor: bool = false,
    /// Preferred size, 0 = the display's own. A backend may ignore it.
    width: u32 = 0,
    height: u32 = 0,
};

pub const CapturedFrame = struct {
    image: Image,
    /// Counts frames the backend produced (repeats keep the original's).
    seq: u64,
    /// When the backend started waiting for or grabbing this frame.
    capture_start_us: Micros,
    /// When the frame was ready (Desktop Duplication's LastPresentTime when it has one).
    captured_us: Micros,
    /// Returned by `repeatLast`: the same picture as before.
    repeat: bool = false,
};

/// Screen capture. Used from the capture thread.
pub const Capture = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Start capturing; returns the frame size it will deliver.
        start: *const fn (ptr: *anyopaque, cfg: CaptureConfig) Error!Size,
        /// Wait up to `timeout_us` for a new frame; null when none came (nothing changed).
        /// Blocks. At most one frame is out at a time: `release` it before the next call.
        acquire: *const fn (ptr: *anyopaque, timeout_us: Micros) Error!?CapturedFrame,
        /// The last frame again (`repeat` set), for keeping a static screen streaming.
        /// Null when there is none or the backend kept no copy. Same release rule.
        repeatLast: *const fn (ptr: *anyopaque) Error!?CapturedFrame,
        release: *const fn (ptr: *anyopaque, frame: *const CapturedFrame) void,
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(c: Capture, cfg: CaptureConfig) Error!Size {
        return c.vtable.start(c.ptr, cfg);
    }
    pub fn acquire(c: Capture, timeout_us: Micros) Error!?CapturedFrame {
        return c.vtable.acquire(c.ptr, timeout_us);
    }
    pub fn repeatLast(c: Capture) Error!?CapturedFrame {
        return c.vtable.repeatLast(c.ptr);
    }
    pub fn release(c: Capture, f: *const CapturedFrame) void {
        c.vtable.release(c.ptr, f);
    }
    pub fn stop(c: Capture) void {
        c.vtable.stop(c.ptr);
    }
};

pub const Size = struct { width: u32, height: u32 };

// ---------------------------------------------------------------------------
// Host: encode

pub const EncoderCaps = struct {
    codecs: CodecSet,
    /// Long-term references (core/recovery refreshes against acked ones). Without them
    /// every recovery is an IDR.
    ltr: bool = false,
    /// Most slices per frame it can emit.
    max_slices: u8 = 1,
    /// Inputs it takes.
    gpu_input: bool = false,
    cpu_input: bool = false,
    /// Formats it takes (bgra8 at least, as capture delivers it).
    formats: []const PixelFormat = &.{.bgra8},
};

/// Session settings, from the design's "Encoder settings": no B-frames, no lookahead,
/// one-frame VBV, no periodic keyframes, `slices` slices per frame.
pub const EncoderConfig = struct {
    codec: Codec,
    width: u32,
    height: u32,
    fps: u32 = 60,
    bitrate_bps: u64,
    slices: u8 = 1,
    /// Mark long-term references (only when caps.ltr).
    ltr: bool = false,
};

pub const Force = enum(u8) { none, ltr_refresh, idr };

/// Per-frame instructions, from `core.recovery.Host.nextEncode` and the rate controller.
pub const EncodeParams = struct {
    force: Force = .none,
    /// Long-term reference tokens the client acked since the previous frame
    /// (VideoToolbox AcknowledgedLTRTokens). Valid for this call only.
    acked_ltr_tokens: []const u64 = &.{},
    /// New target bitrate, applied from this frame on without a keyframe; 0 = unchanged.
    bitrate_bps: u64 = 0,
};

pub const EncodedFrame = struct {
    /// The access unit, one slice per entry, in order. Concatenated they are the
    /// bitstream the decoder takes (Annex B for H.264/HEVC). Valid until the next `encode`.
    slices: []const []const u8,
    keyframe: bool,
    /// Set when the encoder marked this frame a long-term reference.
    ltr_token: ?u64 = null,
    /// Set when this frame references only an acked long-term reference (the forced refresh).
    ltr_refresh: bool = false,
    /// When the encoder started on it and when it returned it.
    encode_start_us: Micros,
    encoded_us: Micros,
};

/// Video encoder. Used from the encode thread.
pub const Encoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        caps: *const fn (ptr: *anyopaque) EncoderCaps,
        configure: *const fn (ptr: *anyopaque, cfg: EncoderConfig) Error!void,
        /// Encode one frame. Blocks until the frame is out. Null when the encoder dropped it
        /// (S7b: low-latency encoders drop rather than overshoot); the app then calls
        /// `core.recovery.Host.onEncodeDropped`.
        encode: *const fn (ptr: *anyopaque, frame: *const CapturedFrame, params: EncodeParams) Error!?EncodedFrame,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn caps(e: Encoder) EncoderCaps {
        return e.vtable.caps(e.ptr);
    }
    pub fn configure(e: Encoder, cfg: EncoderConfig) Error!void {
        return e.vtable.configure(e.ptr, cfg);
    }
    pub fn encode(e: Encoder, f: *const CapturedFrame, p: EncodeParams) Error!?EncodedFrame {
        return e.vtable.encode(e.ptr, f, p);
    }
    pub fn deinit(e: Encoder) void {
        e.vtable.deinit(e.ptr);
    }
};

// ---------------------------------------------------------------------------
// Audio (both sides): 48 kHz, interleaved f32. The Opus stage converts to and from this.

pub const audio_rate = 48_000;

pub const AudioFormat = struct {
    rate: u32 = audio_rate,
    channels: u8 = 2,
};

pub const AudioChunk = struct {
    /// Frames (samples per channel) written to the caller's buffer.
    frames: usize,
    /// Clock time of the first frame.
    time_us: Micros,
};

/// Host audio capture (WASAPI loopback, ScreenCaptureKit audio, PipeWire). Audio thread.
pub const AudioSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, fmt: AudioFormat) Error!AudioFormat,
        /// Fill `out` (interleaved, `out.len / channels` frames at most), waiting up to
        /// `timeout_us` for the first frame. Blocks. frames = 0 on timeout.
        read: *const fn (ptr: *anyopaque, out: []f32, timeout_us: Micros) Error!AudioChunk,
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(a: AudioSource, f: AudioFormat) Error!AudioFormat {
        return a.vtable.start(a.ptr, f);
    }
    pub fn read(a: AudioSource, out: []f32, timeout_us: Micros) Error!AudioChunk {
        return a.vtable.read(a.ptr, out, timeout_us);
    }
    pub fn stop(a: AudioSource) void {
        a.vtable.stop(a.ptr);
    }
};

/// Client audio output. Audio thread.
pub const AudioSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, fmt: AudioFormat) Error!AudioFormat,
        /// Queue interleaved samples; returns frames accepted (fewer when the device
        /// buffer is full). Never blocks.
        write: *const fn (ptr: *anyopaque, pcm: []const f32) Error!usize,
        /// Frames queued and not yet played, for the jitter buffer.
        queued: *const fn (ptr: *anyopaque) usize,
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(a: AudioSink, f: AudioFormat) Error!AudioFormat {
        return a.vtable.start(a.ptr, f);
    }
    pub fn write(a: AudioSink, pcm: []const f32) Error!usize {
        return a.vtable.write(a.ptr, pcm);
    }
    pub fn queued(a: AudioSink) usize {
        return a.vtable.queued(a.ptr);
    }
    pub fn stop(a: AudioSink) void {
        a.vtable.stop(a.ptr);
    }
};

// ---------------------------------------------------------------------------
// Host: input injection

/// Injects what `core.input.Receiver` decoded (SendInput, CGEvent, uinput). Network thread
/// or its own; must not block for long.
pub const InputInjector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        inject: *const fn (ptr: *anyopaque, action: core.input.Action) Error!void,
    };

    pub fn inject(i: InputInjector, a: core.input.Action) Error!void {
        return i.vtable.inject(i.ptr, a);
    }
};

// ---------------------------------------------------------------------------
// Client: decode

pub const DecoderConfig = struct {
    codec: Codec,
    width: u32,
    height: u32,
};

pub const DecoderCaps = struct {
    codecs: CodecSet,
    /// Output it produces; the presenter must take it.
    gpu_output: bool = false,
    cpu_output: bool = false,
};

/// One reassembled frame.
pub const AccessUnit = struct {
    codec: Codec,
    frame_id: u32,
    /// The whole bitstream of the frame (its slices concatenated). Valid for the call.
    data: []const u8,
    keyframe: bool,
    /// Host clock: capture time from the video header (for the overlay, not for pacing).
    capture_us: u64,
    /// Client clock: when the frame's last shard arrived.
    received_us: Micros,
};

pub const DecodedFrame = struct {
    frame_id: u32,
    image: Image,
    decoded_us: Micros,
};

/// Video decoder. Used from the decode thread (or the present thread when they are one).
pub const Decoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        caps: *const fn (ptr: *anyopaque) DecoderCaps,
        configure: *const fn (ptr: *anyopaque, cfg: DecoderConfig) Error!void,
        /// Decode one access unit. Blocks until done. Null when it produced no picture
        /// (not an error). `error.CodecFailed` marks the frame undecodable.
        /// At most one frame is out at a time: `release` it before the next call.
        decode: *const fn (ptr: *anyopaque, au: *const AccessUnit) Error!?DecodedFrame,
        release: *const fn (ptr: *anyopaque, frame: *const DecodedFrame) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn caps(d: Decoder) DecoderCaps {
        return d.vtable.caps(d.ptr);
    }
    pub fn configure(d: Decoder, cfg: DecoderConfig) Error!void {
        return d.vtable.configure(d.ptr, cfg);
    }
    pub fn decode(d: Decoder, au: *const AccessUnit) Error!?DecodedFrame {
        return d.vtable.decode(d.ptr, au);
    }
    pub fn release(d: Decoder, f: *const DecodedFrame) void {
        d.vtable.release(d.ptr, f);
    }
    pub fn deinit(d: Decoder) void {
        d.vtable.deinit(d.ptr);
    }
};

// ---------------------------------------------------------------------------
// Client: present

pub const PresentMode = enum(u8) {
    /// Present on decode; tearing/VRR allowed.
    lowest_latency,
    /// Pace to vsync.
    smooth,
};

pub const PresenterConfig = struct {
    width: u32,
    height: u32,
    mode: PresentMode = .lowest_latency,
    /// Start in a window (false: fullscreen).
    windowed: bool = true,
};

/// What the latency overlay shows: every stage's rolling stats and the link.
pub const Overlay = struct {
    telemetry: core.telemetry.Snapshot,
    bitrate_bps: u64 = 0,
    pacing_bps: u64 = 0,
    rtt_us: Micros = 0,
    /// Share of video datagrams lost before NACK (0..1).
    loss: f32 = 0,
    relayed: bool = false,
    /// Freezes the freeze detector has counted.
    freezes: u32 = 0,
    /// False until the host/client clock offset is known (cross-clock stages are empty).
    clock_synced: bool = false,
};

pub const Presented = struct {
    /// When the frame reached the screen, or the best the API can tell
    /// (after Present/flip returned, or the vsync it was latched for).
    presented_us: Micros,
};

/// Window and swapchain. Used from the present thread.
pub const Presenter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        configure: *const fn (ptr: *anyopaque, cfg: PresenterConfig) Error!void,
        /// Show the frame (and the overlay, when given). Blocks in smooth mode until vsync.
        /// The caller releases `frame` to the decoder afterwards.
        present: *const fn (ptr: *anyopaque, frame: *const DecodedFrame, overlay: ?*const Overlay) Error!Presented,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn configure(p: Presenter, cfg: PresenterConfig) Error!void {
        return p.vtable.configure(p.ptr, cfg);
    }
    pub fn present(p: Presenter, f: *const DecodedFrame, o: ?*const Overlay) Error!Presented {
        return p.vtable.present(p.ptr, f, o);
    }
    pub fn deinit(p: Presenter) void {
        p.vtable.deinit(p.ptr);
    }
};

// ---------------------------------------------------------------------------
// Client: input capture

/// One local input event, in the terms `core.input.Sender` takes.
pub const InputEvent = struct {
    time_us: Micros,
    what: What,

    pub const What = union(enum) {
        /// USB HID keyboard usage.
        key: struct { code: u16, down: bool },
        /// Mouse button, 1-based.
        button: struct { code: u16, down: bool },
        /// 120 per wheel notch.
        scroll: struct { dx: i32, dy: i32 },
        /// Relative motion (raw input, pointer lock).
        move_rel: struct { dx: i32, dy: i32 },
        /// Absolute position, 0..65535 across the streamed display.
        move_abs: struct { x: u16, y: u16 },
        /// Gamepad state; null when it disconnected.
        pad: struct { index: u8, state: ?core.input.Gamepad },
        /// The user closed the window or asked to quit.
        quit,
    };
};

/// Local keyboard, mouse and gamepads (Raw Input, NSEvent, evdev/SDL). Polled from the
/// input or network thread; never blocks.
pub const InputSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copy pending events into `out`, oldest first; returns how many.
        poll: *const fn (ptr: *anyopaque, out: []InputEvent) Error!usize,
    };

    pub fn poll(i: InputSource, out: []InputEvent) Error!usize {
        return i.vtable.poll(i.ptr, out);
    }
};

// ---------------------------------------------------------------------------
// Bundles: what a backend's `open` function returns.

pub const HostBackend = struct {
    clock: Clock,
    capture: Capture,
    encoder: Encoder,
    audio: ?AudioSource = null,
    input: ?InputInjector = null,
    /// Frees everything the bundle owns. Called once, after every object is stopped.
    deinit_ptr: ?*anyopaque = null,
    deinitFn: ?*const fn (ptr: ?*anyopaque) void = null,

    pub fn deinit(b: HostBackend) void {
        if (b.deinitFn) |f| f(b.deinit_ptr);
    }
};

pub const ClientBackend = struct {
    clock: Clock,
    decoder: Decoder,
    presenter: Presenter,
    audio: ?AudioSink = null,
    input: ?InputSource = null,
    deinit_ptr: ?*anyopaque = null,
    deinitFn: ?*const fn (ptr: ?*anyopaque) void = null,

    pub fn deinit(b: ClientBackend) void {
        if (b.deinitFn) |f| f(b.deinit_ptr);
    }
};

// ---------------------------------------------------------------------------
// bind: a vtable from a concrete type's methods.

/// `bind(Capture, MyCapture, &my_capture)` returns a `Capture` whose calls go to
/// `MyCapture.start(self: *MyCapture, ...)` and so on. Every vtable field must have a
/// method of the same name taking `*T` first; a missing one is a compile error.
pub fn bind(comptime Iface: type, comptime T: type, impl: *T) Iface {
    const V = Iface.VTable;
    const Gen = struct {
        const vtable: V = blk: {
            var v: V = undefined;
            for (@typeInfo(V).@"struct".fields) |f| {
                @field(v, f.name) = thunk(f.type, f.name);
            }
            break :blk v;
        };

        fn thunk(comptime Fp: type, comptime name: []const u8) Fp {
            const F = @typeInfo(@typeInfo(Fp).pointer.child).@"fn";
            const R = F.return_type.?;
            const P = F.params;
            if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " has no method " ++ name ++ " for " ++ @typeName(Iface));
            const m = @field(T, name);
            return switch (P.len) {
                1 => &struct {
                    fn f(p: *anyopaque) R {
                        return m(cast(p));
                    }
                }.f,
                2 => &struct {
                    fn f(p: *anyopaque, a: P[1].type.?) R {
                        return m(cast(p), a);
                    }
                }.f,
                3 => &struct {
                    fn f(p: *anyopaque, a: P[1].type.?, b: P[2].type.?) R {
                        return m(cast(p), a, b);
                    }
                }.f,
                else => @compileError("bind: unsupported arity"),
            };
        }

        fn cast(p: *anyopaque) *T {
            return @ptrCast(@alignCast(p));
        }
    };
    return .{ .ptr = impl, .vtable = &Gen.vtable };
}

/// A `Clock` from a plain function.
pub fn clockFn(comptime f: fn () Micros) Clock {
    return .{ .nowFn = &struct {
        fn now(_: ?*anyopaque) Micros {
            return f();
        }
    }.now };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "bind builds vtables from methods" {
    const Fake = struct {
        started: bool = false,
        released: u32 = 0,
        pixels: [16]u8 = @splat(7),

        pub fn start(s: *@This(), cfg: CaptureConfig) Error!Size {
            s.started = cfg.fps == 30;
            return .{ .width = 2, .height = 2 };
        }
        pub fn acquire(s: *@This(), timeout_us: Micros) Error!?CapturedFrame {
            if (timeout_us == 0) return null;
            return .{ .image = .{ .width = 2, .height = 2, .cpu = .{ .data = &s.pixels, .stride = 8 } }, .seq = 1, .capture_start_us = 1, .captured_us = 2 };
        }
        pub fn repeatLast(_: *@This()) Error!?CapturedFrame {
            return error.Unsupported;
        }
        pub fn release(s: *@This(), _: *const CapturedFrame) void {
            s.released += 1;
        }
        pub fn stop(s: *@This()) void {
            s.started = false;
        }
    };
    var f: Fake = .{};
    const c = bind(Capture, Fake, &f);
    const sz = try c.start(.{ .fps = 30 });
    try testing.expect(f.started);
    try testing.expectEqual(@as(u32, 2), sz.width);
    try testing.expectEqual(@as(?CapturedFrame, null), try c.acquire(0));
    const fr = (try c.acquire(1000)).?;
    try testing.expectEqual(@as(u8, 7), fr.image.cpu.?.data[3]);
    c.release(&fr);
    try testing.expectEqual(@as(u32, 1), f.released);
    try testing.expectError(error.Unsupported, c.repeatLast());
    c.stop();
    try testing.expect(!f.started);
}

test "codec sets" {
    const s: CodecSet = .{ .h264 = true, .passthrough = true };
    try testing.expect(s.has(.h264) and s.has(.passthrough) and !s.has(.hevc));
    try testing.expect(!s.has(@enumFromInt(99)));
}
