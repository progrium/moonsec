//! Linux host backend, capture and audio: the platform interface's `Capture` and
//! `AudioSource` (platform/api.zig) on top of the C side in mlh.h. Input injection and the
//! encoders come from their own workstreams; `HostBackend` bundles are put together there.
//!
//!   Capture       xdg-desktop-portal ScreenCast (works on GNOME, KDE and wlroots
//!                 compositors, and is the only way a sandboxed or Wayland app may see
//!                 the screen), then the portal's PipeWire node as a video stream.
//!                 dma-buf when `Options.modifiers` is given and the compositor can
//!                 (`Image.gpu` is a `*const c.mlh_dmabuf`, frames stay on the GPU),
//!                 memfd/shared memory otherwise (`Image.cpu`, bgra8). The pointer comes
//!                 as metadata (`CapturedFrame.cursor`) unless `cfg.cursor` asks for it
//!                 in the picture. A newest-frame mailbox: frames that came while the
//!                 app was busy are dropped, not queued.
//!   AudioSource   A PipeWire capture stream on the default sink's monitor
//!                 (stream.capture.sink), f32 at 48 kHz.
//!
//! Unattended hosts: with `Options.token_path` set, the portal's restore token is stored
//! there after each start (tokens are single use by the spec, so the latest is kept) and
//! passed back on the next, with persist mode "until revoked", so the user approves
//! once and a restarted host captures without a dialog. Keep it next to the host's keys
//! (`tokenPath`).
//!
//! Frame times: `captured_us` is the producer's buffer timestamp when it is on our clock
//! (CLOCK_MONOTONIC, not after arrival), else the arrival time in the process callback.
//! PipeWire screen streams send nothing while the screen is static (damage-driven), so
//! the app keeps the stream alive with `repeatLast`, as on the other hosts.
const std = @import("std");
const api = @import("platform");
pub const c = @import("mlh_c");

const log = std.log.scoped(.host_linux);

pub fn nowUs() api.Micros {
    return c.mlh_now_us();
}

pub const clock = api.clockFn(nowUs);

pub fn lastError() []const u8 {
    return std.mem.span(c.mlh_last_error());
}

/// Maps an mlh.h status to the platform error, logging the message.
pub fn check(what: []const u8, rc: c_int) api.Error!void {
    if (rc >= 0) return;
    // Missing pieces (no portal, no PipeWire, the user said no) are a warning: the app
    // decides whether that is fatal.
    switch (rc) {
        c.MLH_E_UNSUPPORTED, c.MLH_E_NODEVICE, c.MLH_E_DENIED => log.warn("{s}: {s}", .{ what, lastError() }),
        else => log.err("{s}: {s}", .{ what, lastError() }),
    }
    return switch (rc) {
        c.MLH_E_UNSUPPORTED, c.MLH_E_NODEVICE, c.MLH_E_DENIED => error.Unsupported,
        c.MLH_E_CLOSED => error.Closed,
        c.MLH_E_NOMEM => error.OutOfMemory,
        c.MLH_E_LOST => error.DeviceLost,
        else => error.BackendFailed,
    };
}

/// The restore token's file in a host state directory (app/pairing.zig's, next to
/// `identity.key`). Caller frees.
pub fn tokenPath(gpa: std.mem.Allocator, state_dir: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/screencast.token", .{state_dir}, 0);
}

// ---------------------------------------------------------------------------
// Capture

pub const Persist = enum(u32) {
    none = c.MLH_PERSIST_NONE,
    /// While this process runs.
    transient = c.MLH_PERSIST_TRANSIENT,
    /// Until the user revokes it (needs `token_path` to be useful).
    permanent = c.MLH_PERSIST_PERMANENT,
};

pub const Options = struct {
    /// Where the portal's restore token lives (read before, written after each start).
    token_path: ?[:0]const u8 = null,
    persist: Persist = .permanent,
    /// DRM format modifiers the encoder can import; empty: memory frames only. For an
    /// encoder that maps linear buffers, `&.{c.MLH_MOD_LINEAR}`.
    modifiers: []const u64 = &.{},
    /// Let the user pick several monitors in the portal dialog (one stream each);
    /// `CaptureConfig.display` then indexes them. Off: one monitor.
    multiple: bool = false,
    /// How long `start` waits for the user to answer the portal's dialog.
    dialog_timeout_ms: u32 = 5 * 60 * 1000,
    /// How long `start` waits for PipeWire's format.
    format_timeout_ms: u32 = 5000,
};

pub const Capture = struct {
    opts: Options,
    portal: ?*c.mlh_portal = null,
    cap: ?*c.mlh_capture = null,
    cfg: api.CaptureConfig = .{},
    stream: c.mlh_stream_info = std.mem.zeroes(c.mlh_stream_info),
    size: api.Size = .{ .width = 0, .height = 0 },
    /// The C frame behind the frame that is out (for release).
    out: ?c.mlh_frame = null,
    /// Polls the portal's bus for a closed session about every second.
    next_poll_us: api.Micros = 0,

    pub fn init(opts: Options) Capture {
        return .{ .opts = opts };
    }

    pub fn deinit(self: *Capture) void {
        self.stop();
    }

    pub fn start(self: *Capture, cfg: api.CaptureConfig) api.Error!api.Size {
        self.stop();
        errdefer self.stop();
        var token_buf: [512]u8 = undefined;
        var token: ?[*:0]const u8 = null;
        if (self.opts.token_path) |p| {
            if (c.mlh_token_load(p.ptr, &token_buf, token_buf.len) == c.MLH_OK) token = @ptrCast(&token_buf);
        }
        const po: c.mlh_portal_options = .{
            .restore_token = token,
            .persist_mode = @intFromEnum(self.opts.persist),
            .cursor_mode = if (cfg.cursor) c.MLH_CURSOR_EMBEDDED else c.MLH_CURSOR_METADATA,
            .multiple = @intFromBool(self.opts.multiple),
            .timeout_ms = self.opts.dialog_timeout_ms,
        };
        var p: ?*c.mlh_portal = null;
        try check("ScreenCast portal", c.mlh_portal_open(&po, &p));
        self.portal = p;
        if (self.opts.token_path) |path| {
            if (c.mlh_portal_restore_token(p)) |t| {
                if (c.mlh_token_store(path.ptr, t) < 0) log.warn("restore token not saved: {s}", .{lastError()});
            } else if (self.opts.persist != .none) {
                log.info("the portal gave no restore token (ScreenCast v{d}); the next start will ask again", .{c.mlh_portal_version(p)});
            }
        }
        const n = c.mlh_portal_stream_count(p);
        // One stream per chosen monitor; until Capture.displays (#37) maps ids, `display`
        // is an index and anything past the end is the first.
        const idx: u32 = if (cfg.display < n) cfg.display else 0;
        _ = c.mlh_portal_stream(p, idx, &self.stream);
        var fd: c_int = -1;
        try check("OpenPipeWireRemote", c.mlh_portal_pipewire_fd(p, &fd));
        const cc: c.mlh_capture_config = .{
            .fd = fd,
            .node_id = self.stream.node_id,
            .fps = cfg.fps,
            .modifiers = if (self.opts.modifiers.len > 0) self.opts.modifiers.ptr else null,
            .n_modifiers = @intCast(self.opts.modifiers.len),
            .cursor_meta = @intFromBool(c.mlh_portal_cursor_mode(p) == c.MLH_CURSOR_METADATA),
            .timeout_ms = self.opts.format_timeout_ms,
        };
        var h: ?*c.mlh_capture = null;
        try check("PipeWire capture", c.mlh_capture_start(&cc, &h));
        self.cap = h;
        var w: u32 = 0;
        var ht: u32 = 0;
        c.mlh_capture_size(h, &w, &ht);
        self.cfg = cfg;
        self.size = .{ .width = w, .height = ht };
        self.next_poll_us = nowUs() + std.time.us_per_s;
        return self.size;
    }

    fn toFrame(self: *Capture, f: *const c.mlh_frame, start_us: api.Micros) api.CapturedFrame {
        var img: api.Image = .{ .width = f.width, .height = f.height, .format = .bgra8 };
        if (f.data != null and f.height > 0) {
            const d = f.data.?;
            const len = @as(usize, f.stride) * (f.height - 1) + @as(usize, f.width) * 4;
            img.cpu = .{ .data = d[0..len], .stride = f.stride };
        }
        if (f.kind == c.MLH_FRAME_DMABUF) img.gpu = @ptrCast(@constCast(f.dmabuf));
        var out: api.CapturedFrame = .{
            .image = img,
            .seq = f.seq,
            .capture_start_us = @min(start_us, f.arrived_us),
            .captured_us = f.pts_us,
            .repeat = f.repeat != 0,
        };
        if (f.has_cursor != 0) {
            const cur = f.cursor;
            out.cursor = .{
                .visible = cur.visible != 0,
                .x = cur.x,
                .y = cur.y,
                .hot_x = cur.hot_x,
                .hot_y = cur.hot_y,
                .serial = cur.serial,
                .bitmap = if (cur.bitmap) |b| .{
                    .width = cur.width,
                    .height = cur.height,
                    .format = .bgra8,
                    .cpu = .{ .data = b[0 .. @as(usize, cur.stride) * cur.height], .stride = cur.stride },
                } else null,
            };
        }
        _ = self;
        return out;
    }

    fn pollPortal(self: *Capture) api.Error!void {
        const now = nowUs();
        if (now < self.next_poll_us) return;
        self.next_poll_us = now + std.time.us_per_s;
        if (self.portal) |p| try check("ScreenCast session", c.mlh_portal_poll(p));
    }

    /// A new picture, or a repeat of the last one with the cursor moved (`repeat` set).
    pub fn acquire(self: *Capture, timeout_us: api.Micros) api.Error!?api.CapturedFrame {
        const h = self.cap orelse return error.Closed;
        std.debug.assert(self.out == null);
        try self.pollPortal();
        const start_us = nowUs();
        var f: c.mlh_frame = undefined;
        const rc = c.mlh_capture_acquire(h, timeout_us, &f);
        if (rc == c.MLH_TIMEOUT) return null;
        try check("capture acquire", rc);
        self.out = f;
        return self.toFrame(&f, start_us);
    }

    pub fn repeatLast(self: *Capture) api.Error!?api.CapturedFrame {
        const h = self.cap orelse return error.Closed;
        std.debug.assert(self.out == null);
        const start_us = nowUs();
        var f: c.mlh_frame = undefined;
        const rc = c.mlh_capture_repeat(h, &f);
        if (rc == c.MLH_TIMEOUT) return null;
        try check("capture repeat", rc);
        self.out = f;
        var fr = self.toFrame(&f, start_us);
        fr.capture_start_us = start_us;
        fr.captured_us = start_us;
        return fr;
    }

    pub fn release(self: *Capture, _: *const api.CapturedFrame) void {
        if (self.out) |*f| {
            if (self.cap) |h| c.mlh_capture_release(h, f);
        }
        self.out = null;
    }

    pub fn stop(self: *Capture) void {
        self.release(undefined);
        if (self.cap) |h| c.mlh_capture_destroy(h);
        self.cap = null;
        if (self.portal) |p| c.mlh_portal_close(p);
        self.portal = null;
    }

    pub fn stats(self: *Capture) c.mlh_capture_stats {
        var s: c.mlh_capture_stats = std.mem.zeroes(c.mlh_capture_stats);
        if (self.cap) |h| c.mlh_capture_get_stats(h, &s);
        return s;
    }

    /// The portal stream being captured (its node, position and size in the desktop).
    pub fn streamInfo(self: *const Capture) c.mlh_stream_info {
        return self.stream;
    }

    pub fn portalVersion(self: *const Capture) u32 {
        return if (self.portal) |p| c.mlh_portal_version(p) else 0;
    }

    pub fn cursorMode(self: *const Capture) u32 {
        return if (self.portal) |p| c.mlh_portal_cursor_mode(p) else 0;
    }

    pub fn iface(self: *Capture) api.Capture {
        return api.bind(api.Capture, Capture, self);
    }
};

// ---------------------------------------------------------------------------
// Audio

pub const AudioOptions = struct {
    /// Ring between PipeWire's thread and the reader.
    ring_ms: u32 = 500,
    /// Graph quantum to ask for (frames at 48 kHz: 256 = 5.3 ms).
    quantum: u32 = 256,
    /// A node to capture instead of the default sink's monitor.
    target: ?[:0]const u8 = null,
};

pub const AudioSource = struct {
    opts: AudioOptions,
    a: ?*c.mlh_audio = null,
    channels: u8 = 2,

    pub fn init(opts: AudioOptions) AudioSource {
        return .{ .opts = opts };
    }

    pub fn start(s: *AudioSource, fmt: api.AudioFormat) api.Error!api.AudioFormat {
        s.stop();
        var h: ?*c.mlh_audio = null;
        try check("PipeWire audio capture", c.mlh_audio_open(fmt.rate, fmt.channels, s.opts.ring_ms, s.opts.quantum, if (s.opts.target) |t| t.ptr else null, &h));
        s.a = h;
        s.channels = fmt.channels;
        return fmt;
    }

    pub fn read(s: *AudioSource, out: []f32, timeout_us: api.Micros) api.Error!api.AudioChunk {
        const h = s.a orelse return error.Closed;
        var got: u32 = 0;
        var t: i64 = 0;
        const frames: u32 = @intCast(out.len / s.channels);
        try check("audio read", c.mlh_audio_read(h, out.ptr, frames, timeout_us, &got, &t));
        return .{ .frames = got, .time_us = if (got > 0) t else nowUs() };
    }

    pub fn stop(s: *AudioSource) void {
        if (s.a) |h| c.mlh_audio_close(h);
        s.a = null;
    }

    pub const Info = struct { streaming: bool, quantum: u32, overruns: u64, queued: u32 };

    pub fn info(s: *AudioSource) ?Info {
        const h = s.a orelse return null;
        var st: c_int = 0;
        var q: u32 = 0;
        var o: u64 = 0;
        var qd: u32 = 0;
        c.mlh_audio_info(h, &st, &q, &o, &qd);
        return .{ .streaming = st != 0, .quantum = q, .overruns = o, .queued = qd };
    }

    pub fn iface(s: *AudioSource) api.AudioSource {
        return api.bind(api.AudioSource, AudioSource, s);
    }
};

// ---------------------------------------------------------------------------
// Input injection and the HostBackend bundle

/// uinput keyboard, mouse, absolute pointer and gamepads (input.zig).
pub const input = @import("input.zig");
/// Event codes, the key table and uinput devices (platform/linux/uinput.zig).
pub const uinput = @import("linux_uinput");
/// The `HostBackend` for `--host linux` (backend.zig).
pub const backend = @import("backend.zig");
