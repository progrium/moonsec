//! Windows host backend: Desktop Duplication capture, NVENC (loaded at run time) or the
//! Media Foundation software H.264 encoder, WASAPI loopback audio and SendInput, behind
//! the platform interface (platform/api.zig).
//!
//! On a GPU-less machine (the windows-2022 CI runner) open with `.driver = .warp` and
//! `.encoder = .mf_software`: capture then has no outputs to duplicate, and the encoder
//! still runs on textures the caller fills.
const std = @import("std");
const api = @import("platform");
const core = @import("core");
const win = @import("win");
pub const c = @import("host_win_c");

const log = std.log.scoped(.win_host);

pub const EncoderKind = enum {
    /// NVENC when an NVIDIA driver is there, else Media Foundation.
    auto,
    nvenc,
    mf_software,
};

pub const Options = struct {
    driver: win.Driver = .hardware,
    /// DXGI adapter for the device; capture duplicates outputs of this adapter.
    adapter: u32 = 0,
    encoder: EncoderKind = .auto,
    /// Open WASAPI loopback; the bundle's `audio` is null when there is no render device.
    audio: bool = true,
    input: bool = true,
    /// D3D11 debug layer (needs the Graphics Tools optional feature).
    debug: bool = false,
};

pub fn nowUs() api.Micros {
    return @intCast(win.qpcNs() / 1000);
}

pub const clock = api.clockFn(nowUs);

fn hrError(what: []const u8, hr: i32) api.Error {
    const code: u32 = @bitCast(hr);
    const e: api.Error = switch (code) {
        0x8007000E => error.OutOfMemory,
        0x887A0005, 0x887A0007, 0x887A0026 => error.DeviceLost, // device removed / reset / access lost
        0x887A0002, 0x887A0004, 0x80070490, 0x80004001 => error.Unsupported, // unsupported / not found / not implemented
        else => error.BackendFailed,
    };
    // Missing hardware (no output to duplicate, no encoder) is expected on some machines
    // and the caller decides what to do; only real failures are logged as errors.
    if (e == error.Unsupported) log.warn("{s}: {f}", .{ what, win.fmtHr(hr) }) else log.err("{s}: {f}", .{ what, win.fmtHr(hr) });
    return e;
}

/// The device as host_win.h's msw_d3d (a separate translation of the same C type).
pub fn dev(d: win.D3d) *c.msw_d3d {
    return @ptrCast(d.handle);
}

fn ok(hr: i32) bool {
    return hr >= 0;
}

// ---------------------------------------------------------------------------
// Capture

pub const Capture = struct {
    d3d: win.D3d,
    dup: ?*c.msw_dup = null,
    cfg: api.CaptureConfig = .{},
    seq: u64 = 0,
    have_last: bool = false,
    last: api.CapturedFrame = undefined,
    width: u32 = 0,
    height: u32 = 0,
    /// The output's rectangle on the virtual desktop, for absolute pointer moves.
    rect: [4]i32 = .{ 0, 0, 0, 0 },

    pub fn start(self: *Capture, cfg: api.CaptureConfig) api.Error!api.Size {
        self.stop();
        self.cfg = cfg;
        var dup: ?*c.msw_dup = null;
        const hr = c.msw_dup_create(dev(self.d3d), cfg.display, &dup);
        if (!ok(hr)) return hrError("DuplicateOutput", hr);
        self.dup = dup;
        c.msw_dup_size(dup, &self.width, &self.height);
        c.msw_dup_desktop_rect(dup, &self.rect[0], &self.rect[1], &self.rect[2], &self.rect[3]);
        return .{ .width = self.width, .height = self.height };
    }

    pub fn acquire(self: *Capture, timeout_us: api.Micros) api.Error!?api.CapturedFrame {
        const dup = self.dup orelse return error.Closed;
        const start_us = nowUs();
        const deadline = start_us + @max(timeout_us, 0);
        while (true) {
            const left = deadline - nowUs();
            const ms: u32 = if (left <= 0) 0 else @intCast(@min(@divFloor(left + 999, 1000), std.math.maxInt(u32)));
            var f: c.msw_dup_frame = undefined;
            const hr = c.msw_dup_acquire(dup, ms, &f);
            const code: u32 = @bitCast(hr);
            if (code == 0x887A0027) return null; // DXGI_ERROR_WAIT_TIMEOUT
            if (code == 0x887A0026) {
                // Access lost (mode change, UAC prompt, fullscreen switch): duplicate again.
                log.info("desktop duplication access lost; recreating", .{});
                c.msw_dup_destroy(dup);
                self.dup = null;
                _ = try self.start(self.cfg);
                return null;
            }
            if (!ok(hr)) return hrError("AcquireNextFrame", hr);
            if (f.present_ns == 0) {
                // Only the pointer moved.
                if (nowUs() >= deadline) return null;
                continue;
            }
            self.seq += 1;
            self.last = .{
                .image = .{ .width = f.width, .height = f.height, .format = .bgra8, .gpu = f.texture },
                .seq = self.seq,
                .capture_start_us = start_us,
                .captured_us = @intCast(f.present_ns / 1000),
            };
            self.have_last = true;
            return self.last;
        }
    }

    pub fn repeatLast(self: *Capture) api.Error!?api.CapturedFrame {
        if (!self.have_last) return null;
        var f = self.last;
        f.repeat = true;
        f.capture_start_us = nowUs();
        return f;
    }

    pub fn release(_: *Capture, _: *const api.CapturedFrame) void {
        // The copy texture stays ours; nothing is held from DXGI between calls.
    }

    pub fn stop(self: *Capture) void {
        if (self.dup) |d| c.msw_dup_destroy(d);
        self.dup = null;
        self.have_last = false;
    }
};

// ---------------------------------------------------------------------------
// Encoder

pub const max_slices = 8;

pub const Encoder = struct {
    enc: *c.msw_enc,
    kind: EncoderKind,
    caps_: c.msw_enc_caps = undefined,
    cfg: ?api.EncoderConfig = null,
    slices: [max_slices][]const u8 = undefined,

    pub fn create(d3d: win.D3d, kind: EncoderKind) api.Error!Encoder {
        const kinds: []const EncoderKind = switch (kind) {
            .auto => &.{ .nvenc, .mf_software },
            else => &.{kind},
        };
        var last_hr: i32 = 0;
        for (kinds) |k| {
            var e: ?*c.msw_enc = null;
            const ck: c.msw_enc_kind = if (k == .nvenc) c.MSW_ENC_NVENC else c.MSW_ENC_MF_SOFTWARE;
            last_hr = c.msw_enc_create(dev(d3d), ck, &e);
            if (ok(last_hr)) {
                var self: Encoder = .{ .enc = e.?, .kind = k };
                c.msw_enc_caps_get(e, &self.caps_);
                log.info("encoder: {s}", .{@tagName(k)});
                return self;
            }
            log.info("encoder {s} unavailable: {f}", .{ @tagName(k), win.fmtHr(last_hr) });
        }
        return hrError("no video encoder", last_hr);
    }

    pub fn caps(self: *Encoder) api.EncoderCaps {
        return .{
            .codecs = .{ .h264 = self.caps_.h264 != 0, .hevc = self.caps_.hevc != 0 },
            .ltr = self.caps_.ltr != 0,
            .max_slices = @intCast(@min(self.caps_.max_slices, max_slices)),
            .gpu_input = self.caps_.gpu_input != 0,
            .cpu_input = false,
        };
    }

    pub fn configure(self: *Encoder, cfg: api.EncoderConfig) api.Error!void {
        const codec: u32 = switch (cfg.codec) {
            .h264 => c.MSW_CODEC_H264,
            .hevc => c.MSW_CODEC_HEVC,
            else => return error.Unsupported,
        };
        const cc: c.msw_enc_config = .{
            .codec = codec,
            .width = cfg.width,
            .height = cfg.height,
            .fps = cfg.fps,
            .bitrate_bps = cfg.bitrate_bps,
            .slices = @min(@max(cfg.slices, 1), self.caps().max_slices),
            .ltr = @intFromBool(cfg.ltr),
        };
        const hr = c.msw_enc_configure(self.enc, &cc);
        if (!ok(hr)) return hrError("encoder configure", hr);
        self.cfg = cfg;
    }

    pub fn encode(self: *Encoder, frame: *const api.CapturedFrame, params: api.EncodeParams) api.Error!?api.EncodedFrame {
        const cfg = self.cfg orelse return error.BackendFailed;
        const tex = frame.image.gpu orelse return error.Unsupported;
        if (frame.image.format != .bgra8) return error.Unsupported;
        const start_us = nowUs();
        const p: c.msw_enc_params = .{
            .force = switch (params.force) {
                .none => c.MSW_FORCE_NONE,
                .ltr_refresh => c.MSW_FORCE_LTR_REFRESH,
                .idr => c.MSW_FORCE_IDR,
            },
            .bitrate_bps = params.bitrate_bps,
            .acked_ltr_tokens = if (params.acked_ltr_tokens.len > 0) params.acked_ltr_tokens.ptr else null,
            .acked_ltr_count = @intCast(params.acked_ltr_tokens.len),
        };
        var out: c.msw_enc_output = undefined;
        const hr = c.msw_enc_encode(self.enc, tex, frame.image.gpu_index, @intCast(@max(frame.captured_us, 0)), &p, &out);
        if (!ok(hr)) return switch (hrError("encode", hr)) {
            error.BackendFailed => error.CodecFailed,
            else => |e| e,
        };
        if (out.dropped != 0 or out.len == 0) return null;
        const data = out.data[0..out.len];
        return .{
            // At most the configured count: an encoder may cut more slices than asked
            // (Media Foundation's software encoder cuts one per worker thread).
            .slices = splitSlices(cfg.codec, data, self.slices[0..@min(@max(cfg.slices, 1), max_slices)]),
            .keyframe = out.keyframe != 0,
            .ltr_token = if (out.has_ltr_token != 0) out.ltr_token else null,
            .ltr_refresh = out.ltr_refresh != 0,
            .encode_start_us = start_us,
            .encoded_us = nowUs(),
        };
    }

    pub fn deinit(self: *Encoder) void {
        c.msw_enc_destroy(self.enc);
    }
};

/// One NAL unit of an Annex B stream: `start` is the offset of its start code.
pub const Nal = struct { start: usize, payload: usize, type: u8 };

pub fn nextNal(data: []const u8, from: usize) ?Nal {
    var i = from;
    while (i + 3 <= data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0) {
            if (data[i + 2] == 1) return .{ .start = i, .payload = i + 3, .type = if (i + 3 < data.len) data[i + 3] else 0 };
            if (data[i + 2] == 0 and i + 3 < data.len and data[i + 3] == 1)
                return .{ .start = i, .payload = i + 4, .type = if (i + 4 < data.len) data[i + 4] else 0 };
        }
    }
    return null;
}

fn isVcl(codec: api.Codec, header: u8) bool {
    return switch (codec) {
        .h264 => switch (header & 0x1f) {
            1...5 => true,
            else => false,
        },
        .hevc => (header >> 1) & 0x3f < 32,
        else => false,
    };
}

/// Splits an Annex B access unit into slices: each VCL NAL starts a slice, and non-VCL
/// NALs (SPS, PPS, SEI, AUD) ride with the slice that follows them. Beyond `out.len`
/// slices the rest go in the last one.
pub fn splitSlices(codec: api.Codec, data: []const u8, out: [][]const u8) []const []const u8 {
    var n: usize = 0;
    var begin: usize = 0;
    var seen_vcl = false;
    var it = nextNal(data, 0);
    while (it) |nal| : (it = nextNal(data, nal.payload)) {
        if (!isVcl(codec, nal.type)) continue;
        if (seen_vcl and n + 1 < out.len) {
            // Non-VCL NALs between the previous slice and this one start this slice.
            out[n] = data[begin..nal.start];
            n += 1;
            begin = nal.start;
        }
        seen_vcl = true;
    }
    if (data.len > begin) {
        out[n] = data[begin..];
        n += 1;
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Audio

pub const Audio = struct {
    lb: ?*c.msw_loopback = null,
    channels: u8 = 2,

    pub fn start(self: *Audio, fmt: api.AudioFormat) api.Error!api.AudioFormat {
        if (fmt.rate != api.audio_rate) return error.Unsupported;
        self.stop();
        var lb: ?*c.msw_loopback = null;
        var hr = c.msw_loopback_create(fmt.channels, &lb);
        if (!ok(hr)) return hrError("WASAPI loopback", hr);
        hr = c.msw_loopback_start(lb);
        if (!ok(hr)) {
            c.msw_loopback_destroy(lb);
            return hrError("WASAPI start", hr);
        }
        self.lb = lb;
        self.channels = fmt.channels;
        return fmt;
    }

    pub fn read(self: *Audio, out: []f32, timeout_us: api.Micros) api.Error!api.AudioChunk {
        const lb = self.lb orelse return error.Closed;
        const max: u32 = @intCast(out.len / self.channels);
        const ms: u32 = @intCast(@divFloor(@max(timeout_us, 0) + 999, 1000));
        var frames: u32 = 0;
        var t_ns: u64 = 0;
        const hr = c.msw_loopback_read(lb, out.ptr, max, ms, &frames, &t_ns);
        if (!ok(hr)) return hrError("WASAPI read", hr);
        return .{ .frames = frames, .time_us = if (frames > 0) @intCast(t_ns / 1000) else nowUs() };
    }

    pub fn stop(self: *Audio) void {
        if (self.lb) |lb| {
            c.msw_loopback_stop(lb);
            c.msw_loopback_destroy(lb);
        }
        self.lb = null;
    }
};

// ---------------------------------------------------------------------------
// Input

pub const Injector = struct {
    /// Display rectangle for absolute moves (left, top, width, height); the captured
    /// output's when capture runs, else the primary display.
    capture: ?*const Capture = null,

    pub fn inject(self: *Injector, action: core.input.Action) api.Error!void {
        const hr: i32 = switch (action) {
            .key => |k| c.msw_input_key(k.code, @intFromBool(k.down)),
            .button => |b| c.msw_input_button(b.code, @intFromBool(b.down)),
            .scroll => |s| c.msw_input_scroll(s.dx, s.dy),
            .motion => |m| c.msw_input_move_rel(m.dx, m.dy),
            .abs => |a| blk: {
                var r: [4]i32 = .{ 0, 0, 0, 0 };
                if (self.capture) |cap| {
                    if (cap.dup != null) r = cap.rect;
                }
                if (r[2] <= 0) c.msw_input_primary_rect(&r[0], &r[1], &r[2], &r[3]);
                break :blk c.msw_input_move_abs(a.x, a.y, r[0], r[1], r[2], r[3]);
            },
            // A virtual gamepad needs a signed driver (docs/design.md); until then pads are dropped.
            .pad => 0,
        };
        if (!ok(hr)) {
            // Unmapped keys and UIPI refusals (elevated window focused) are not fatal.
            log.warn("SendInput: {f}", .{win.fmtHr(hr)});
        }
    }
};

// ---------------------------------------------------------------------------
// Bundle

pub const Host = struct {
    allocator: std.mem.Allocator,
    com: win.ComThread,
    d3d: win.D3d,
    capture: Capture,
    encoder: Encoder,
    audio: Audio = .{},
    injector: Injector = .{},

    fn deinitFn(p: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(p.?));
        self.capture.stop();
        self.audio.stop();
        self.encoder.deinit();
        self.d3d.destroy();
        self.com.deinit();
        self.allocator.destroy(self);
    }
};

/// Opens the Windows host bundle. COM is initialized (multithreaded) on the calling
/// thread and stays initialized until `deinit`; the pipeline threads join that apartment
/// implicitly.
pub fn openHost(allocator: std.mem.Allocator, opts: Options) (api.Error || win.Error)!api.HostBackend {
    const self = try allocator.create(Host);
    errdefer allocator.destroy(self);
    const com = try win.ComThread.init();
    errdefer com.deinit();
    const d3d = win.D3d.create(.{ .driver = opts.driver, .adapter_index = opts.adapter, .debug = opts.debug }) catch |e| {
        log.err("D3D11 device: {f}", .{win.fmtHr(win.last_hr)});
        return e;
    };
    errdefer d3d.destroy();
    const info = d3d.info();
    log.info("D3D11 on {s} (feature level 0x{X})", .{ win.adapterName(&info), info.feature_level });
    self.* = .{
        .allocator = allocator,
        .com = com,
        .d3d = d3d,
        .capture = .{ .d3d = d3d },
        .encoder = try Encoder.create(d3d, opts.encoder),
    };
    self.injector.capture = &self.capture;
    var audio: ?api.AudioSource = null;
    if (opts.audio) {
        // Probe for a render device now so a machine without one gets a null `audio`.
        var lb: ?*c.msw_loopback = null;
        const hr = c.msw_loopback_create(2, &lb);
        if (ok(hr)) {
            c.msw_loopback_destroy(lb);
            audio = api.bind(api.AudioSource, Audio, &self.audio);
        } else {
            log.info("no loopback audio: {f}", .{win.fmtHr(hr)});
        }
    }
    return .{
        .clock = clock,
        .capture = api.bind(api.Capture, Capture, &self.capture),
        .encoder = api.bind(api.Encoder, Encoder, &self.encoder),
        .audio = audio,
        .input = if (opts.input) api.bind(api.InputInjector, Injector, &self.injector) else null,
        .deinit_ptr = self,
        .deinitFn = Host.deinitFn,
    };
}

test "splitSlices groups parameter sets with the first slice" {
    const au = [_]u8{ 0, 0, 0, 1, 0x67, 0xAA, 0, 0, 0, 1, 0x68, 0xBB, 0, 0, 1, 0x65, 1, 2, 0, 0, 1, 0x65, 3, 4, 0, 0, 1, 0x06, 9, 0, 0, 1, 0x65, 5 };
    var buf: [8][]const u8 = undefined;
    const s = splitSlices(.h264, &au, &buf);
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(u8, 0x67), s[0][4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0x65, 3, 4 }, s[1]);
    try std.testing.expectEqual(@as(u8, 0x06), s[2][3]);
    var total: usize = 0;
    for (s) |x| total += x.len;
    try std.testing.expectEqual(au.len, total);
    var one: [1][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, au.len), splitSlices(.h264, &au, &one)[0].len);
}
