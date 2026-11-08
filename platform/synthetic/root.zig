//! The synthetic backend: the platform interface with no OS behind it, so the host and
//! client apps run end to end on any machine (CI, the sim, Linux over iroh).
//!
//!   Capture        renders the test pattern (platform/pattern.zig) stamped with the
//!                  capture clock and frame number, at the configured rate.
//!   Encoder        the passthrough codec: each access unit carries the pattern's stamp,
//!                  a CRC-32 of the pixels, reference bookkeeping (IDR, P, LTR, LTR
//!                  refresh) and deterministic filler that sizes it to the bitrate.
//!   Decoder        checks the filler, enforces references the way a real decoder does
//!                  (a P frame after a gap fails, a refresh needs its LTR), re-renders the
//!                  pattern and checks it against the CRC.
//!   Presenter      reads the stamp back from the pixels, so every presented frame is
//!                  verified end to end; counts presents and unreadable frames.
//!   InputSource    a scripted key press/release every `input_interval_us` and some motion.
//!   InputInjector  checks the keys arrive in the script's order.
//!
//! No audio (the Opus stage brings its own test source).
const std = @import("std");
const api = @import("platform");
const pattern = api.pattern;

const Micros = api.Micros;

/// Sleeps the calling thread. Null in virtual time, where nothing may block.
pub const Sleeper = ?*const fn (ctx: ?*anyopaque, us: Micros) void;

// ---------------------------------------------------------------------------
// Passthrough access unit

pub const magic: u32 = 0x5450_534d; // "MSPT"
pub const header_len = 56;

pub const AuFlags = packed struct(u8) {
    keyframe: bool = false,
    ltr: bool = false,
    refresh: bool = false,
    _r: u5 = 0,
};

pub const AuHeader = struct {
    flags: AuFlags,
    width: u32,
    height: u32,
    stamp: pattern.Stamp,
    /// Encoder's count of emitted frames.
    seq: u32,
    /// Seq of the frame this one references (itself for a keyframe).
    ref: u32,
    pixel_crc: u32,
    total_len: u32,
    ltr_token: u64,

    pub fn encode(h: AuHeader, out: *[header_len]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], magic, .little);
        out[4] = @bitCast(h.flags);
        std.mem.writeInt(u32, out[8..12], h.width, .little);
        std.mem.writeInt(u32, out[12..16], h.height, .little);
        std.mem.writeInt(u64, out[16..24], h.stamp.time_us, .little);
        std.mem.writeInt(u32, out[24..28], h.stamp.frame, .little);
        std.mem.writeInt(u32, out[28..32], h.seq, .little);
        std.mem.writeInt(u32, out[32..36], h.ref, .little);
        std.mem.writeInt(u32, out[36..40], h.pixel_crc, .little);
        std.mem.writeInt(u32, out[40..44], h.total_len, .little);
        std.mem.writeInt(u64, out[48..56], h.ltr_token, .little);
    }

    pub fn decode(b: []const u8) ?AuHeader {
        if (b.len < header_len or std.mem.readInt(u32, b[0..4], .little) != magic) return null;
        return .{
            .flags = @bitCast(b[4]),
            .width = std.mem.readInt(u32, b[8..12], .little),
            .height = std.mem.readInt(u32, b[12..16], .little),
            .stamp = .{ .time_us = std.mem.readInt(u64, b[16..24], .little), .frame = std.mem.readInt(u32, b[24..28], .little) },
            .seq = std.mem.readInt(u32, b[28..32], .little),
            .ref = std.mem.readInt(u32, b[32..36], .little),
            .pixel_crc = std.mem.readInt(u32, b[36..40], .little),
            .total_len = std.mem.readInt(u32, b[40..44], .little),
            .ltr_token = std.mem.readInt(u64, b[48..56], .little),
        };
    }
};

fn filler(seq: u32, out: []u8) void {
    var prng = std.Random.DefaultPrng.init(0x5eed_0000 ^ @as(u64, seq) *% 0x9e3779b97f4a7c15);
    prng.random().bytes(out);
}

fn pixelCrc(px: []const u8) u32 {
    return std.hash.Crc32.hash(px);
}

fn stampTime(t: Micros) u64 {
    return @bitCast(t);
}

// ---------------------------------------------------------------------------
// Capture

pub const Capture = struct {
    gpa: std.mem.Allocator,
    clock: api.Clock,
    sleeper: Sleeper,
    sleep_ctx: ?*anyopaque,
    width: u32 = 0,
    height: u32 = 0,
    interval_us: Micros = 16_667,
    buf: []u8 = &.{},
    seq: u64 = 0,
    next_due: ?Micros = null,
    last: ?api.CapturedFrame = null,
    out: bool = false,
    default_size: api.Size,

    pub fn start(c: *Capture, cfg: api.CaptureConfig) api.Error!api.Size {
        c.width = if (cfg.width != 0) cfg.width else c.default_size.width;
        c.height = if (cfg.height != 0) cfg.height else c.default_size.height;
        if (c.width < pattern.min_width or c.height < pattern.min_height) return error.Unsupported;
        c.interval_us = @divTrunc(1_000_000, @as(Micros, @max(cfg.fps, 1)));
        if (c.buf.len > 0) c.gpa.free(c.buf);
        c.buf = c.gpa.alloc(u8, c.width * c.height * 4) catch return error.OutOfMemory;
        c.next_due = null;
        return .{ .width = c.width, .height = c.height };
    }

    pub fn acquire(c: *Capture, timeout_us: Micros) api.Error!?api.CapturedFrame {
        std.debug.assert(!c.out);
        if (c.buf.len == 0) return error.Closed;
        var now = c.clock.now();
        const due = c.next_due orelse now;
        if (now < due) {
            const s = c.sleeper orelse return null;
            if (due - now > timeout_us) {
                s(c.sleep_ctx, timeout_us);
                return null;
            }
            // Short sleeps: some hosts (macOS CI) overshoot long ones by many ms.
            while (now < due) {
                s(c.sleep_ctx, @min(due - now, 1000));
                now = c.clock.now();
            }
        }
        // Stay on the frame grid; skip slots we missed entirely.
        var next = due + c.interval_us;
        if (next <= now) next += (@divTrunc(now - next, c.interval_us) + 1) * c.interval_us;
        c.next_due = next;
        const start_us = now;
        pattern.render(c.buf, c.width, c.height, c.width * 4, .{ .time_us = stampTime(start_us), .frame = @truncate(c.seq) });
        const f: api.CapturedFrame = .{
            .image = .{ .width = c.width, .height = c.height, .cpu = .{ .data = c.buf, .stride = c.width * 4 } },
            .seq = c.seq,
            .capture_start_us = start_us,
            .captured_us = c.clock.now(),
        };
        c.seq += 1;
        c.last = f;
        c.out = true;
        return f;
    }

    pub fn repeatLast(c: *Capture) api.Error!?api.CapturedFrame {
        std.debug.assert(!c.out);
        var f = c.last orelse return null;
        f.repeat = true;
        c.out = true;
        return f;
    }

    pub fn release(c: *Capture, _: *const api.CapturedFrame) void {
        c.out = false;
    }

    pub fn stop(c: *Capture) void {
        if (c.buf.len > 0) c.gpa.free(c.buf);
        c.buf = &.{};
        c.last = null;
    }
};

// ---------------------------------------------------------------------------
// Encoder

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    clock: api.Clock,
    cfg: ?api.EncoderConfig = null,
    buf: []u8 = &.{},
    slices: [16][]const u8 = undefined,
    seq: u32 = 0,
    last_seq: ?u32 = null,
    /// Long-term references marked and not yet invalidated by a keyframe: token -> seq.
    ltrs: [32]?struct { token: u64, seq: u32, acked: bool } = @splat(null),
    /// Mark every Nth frame as a long-term reference.
    ltr_interval: u32 = 30,
    /// Make a frame with seq in this set fail to "encode" (null): tests the drop path.
    drop_every: u32 = 0,
    stats: struct { frames: u64 = 0, keyframes: u64 = 0, refreshes: u64 = 0, dropped: u64 = 0, bytes: u64 = 0 } = .{},

    pub fn caps(_: *Encoder) api.EncoderCaps {
        return .{ .codecs = .{ .passthrough = true }, .ltr = true, .max_slices = 16, .cpu_input = true };
    }

    pub fn configure(e: *Encoder, cfg: api.EncoderConfig) api.Error!void {
        if (cfg.codec != .passthrough) return error.Unsupported;
        if (cfg.slices == 0 or cfg.slices > e.slices.len) return error.Unsupported;
        e.cfg = cfg;
    }

    fn frameBytes(e: *const Encoder, key: bool, refresh: bool) usize {
        const c = e.cfg.?;
        const mean: f64 = @as(f64, @floatFromInt(c.bitrate_bps)) / 8.0 / @as(f64, @floatFromInt(@max(c.fps, 1)));
        const mult: f64 = if (key) 2.0 else if (refresh) 1.5 else 1.0;
        return @max(header_len + 16, @as(usize, @intFromFloat(mean * mult)));
    }

    fn ltrOf(e: *Encoder, token: u64) ?usize {
        for (e.ltrs, 0..) |l, i| if (l) |x| if (x.token == token) return i;
        return null;
    }

    pub fn encode(e: *Encoder, f: *const api.CapturedFrame, p: api.EncodeParams) api.Error!?api.EncodedFrame {
        var c = e.cfg orelse return error.Closed;
        const t0 = e.clock.now();
        if (p.bitrate_bps != 0) {
            c.bitrate_bps = p.bitrate_bps;
            e.cfg = c;
        }
        for (p.acked_ltr_tokens) |tok| if (e.ltrOf(tok)) |i| {
            e.ltrs[i].?.acked = true;
        };
        if (e.drop_every != 0 and (e.stats.frames + e.stats.dropped + 1) % e.drop_every == 0) {
            e.stats.dropped += 1;
            return null;
        }
        const img = f.image.cpu orelse return error.Unsupported;
        if (f.image.width != c.width or f.image.height != c.height) return error.Unsupported;

        // Pick the reference.
        var key = e.last_seq == null or p.force == .idr;
        var refresh = false;
        var ref: u32 = e.last_seq orelse 0;
        if (!key and p.force == .ltr_refresh) {
            // Newest acked long-term reference.
            var best: ?u32 = null;
            for (e.ltrs) |l| if (l) |x| if (x.acked and (best == null or x.seq -% best.? < 1 << 31)) {
                best = x.seq;
            };
            if (best) |b| {
                ref = b;
                refresh = true;
            } else key = true;
        }
        const seq = e.seq;
        if (key) {
            ref = seq;
            e.ltrs = @splat(null);
        }
        const mark_ltr = key or seq % e.ltr_interval == 0;
        const token: u64 = if (mark_ltr) @as(u64, seq) + 1 else 0;
        if (mark_ltr) {
            // Replace the oldest slot.
            var slot: usize = 0;
            for (e.ltrs, 0..) |l, i| {
                if (l == null) {
                    slot = i;
                    break;
                }
                if (seq -% l.?.seq > seq -% e.ltrs[slot].?.seq) slot = i;
            }
            e.ltrs[slot] = .{ .token = token, .seq = seq, .acked = false };
        }

        const total = e.frameBytes(key, refresh);
        if (e.buf.len < total) {
            if (e.buf.len > 0) e.gpa.free(e.buf);
            e.buf = e.gpa.alloc(u8, @max(total, 64 * 1024)) catch return error.OutOfMemory;
        }
        const out = e.buf[0..total];
        const stride = c.width * 4;
        const rows = img.data[0 .. stride * c.height];
        const crc = if (img.stride == stride) pixelCrc(rows) else return error.Unsupported;
        const stamp = pattern.read(img.data, c.width, c.height, img.stride) orelse return error.CodecFailed;
        (AuHeader{
            .flags = .{ .keyframe = key, .ltr = mark_ltr, .refresh = refresh },
            .width = c.width,
            .height = c.height,
            .stamp = stamp,
            .seq = seq,
            .ref = ref,
            .pixel_crc = crc,
            .total_len = @intCast(total),
            .ltr_token = token,
        }).encode(out[0..header_len]);
        filler(seq, out[header_len..]);

        const n: usize = @min(c.slices, total / 64);
        const cut = total / @max(n, 1);
        for (0..@max(n, 1)) |i| {
            const lo = i * cut;
            const hi = if (i + 1 == @max(n, 1)) total else lo + cut;
            e.slices[i] = out[lo..hi];
        }
        e.seq +%= 1;
        e.last_seq = seq;
        e.stats.frames += 1;
        e.stats.bytes += total;
        if (key) e.stats.keyframes += 1;
        if (refresh) e.stats.refreshes += 1;
        return .{
            .slices = e.slices[0..@max(n, 1)],
            .keyframe = key,
            .ltr_token = if (mark_ltr) token else null,
            .ltr_refresh = refresh,
            .encode_start_us = t0,
            .encoded_us = e.clock.now(),
        };
    }

    pub fn deinit(e: *Encoder) void {
        if (e.buf.len > 0) e.gpa.free(e.buf);
        e.buf = &.{};
    }
};

// ---------------------------------------------------------------------------
// Decoder

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    clock: api.Clock,
    cfg: ?api.DecoderConfig = null,
    buf: []u8 = &.{},
    check: []u8 = &.{},
    last_seq: ?u32 = null,
    /// Decoded long-term references (by seq).
    ltrs: [32]?u32 = @splat(null),
    ltr_next: usize = 0,
    out: bool = false,
    stats: struct { frames: u64 = 0, missing_ref: u64 = 0, corrupt: u64 = 0 } = .{},

    pub fn caps(_: *Decoder) api.DecoderCaps {
        return .{ .codecs = .{ .passthrough = true }, .cpu_output = true };
    }

    pub fn configure(d: *Decoder, cfg: api.DecoderConfig) api.Error!void {
        if (cfg.codec != .passthrough) return error.Unsupported;
        if (cfg.width < pattern.min_width or cfg.height < pattern.min_height) return error.Unsupported;
        d.freeBufs();
        d.buf = d.gpa.alloc(u8, cfg.width * cfg.height * 4) catch return error.OutOfMemory;
        d.check = d.gpa.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
        d.cfg = cfg;
        d.last_seq = null;
        d.ltrs = @splat(null);
    }

    fn haveLtr(d: *const Decoder, seq: u32) bool {
        for (d.ltrs) |l| if (l == seq) return true;
        return false;
    }

    pub fn decode(d: *Decoder, au: *const api.AccessUnit) api.Error!?api.DecodedFrame {
        std.debug.assert(!d.out);
        const c = d.cfg orelse return error.Closed;
        const h = AuHeader.decode(au.data) orelse {
            d.stats.corrupt += 1;
            return error.CodecFailed;
        };
        if (h.total_len != au.data.len or h.width != c.width or h.height != c.height or h.flags.keyframe != au.keyframe) {
            d.stats.corrupt += 1;
            return error.CodecFailed;
        }
        // Filler, in chunks.
        var off: usize = header_len;
        var prng = std.Random.DefaultPrng.init(0x5eed_0000 ^ @as(u64, h.seq) *% 0x9e3779b97f4a7c15);
        while (off < au.data.len) {
            const n = @min(d.check.len, au.data.len - off);
            prng.random().bytes(d.check[0..n]);
            if (!std.mem.eql(u8, d.check[0..n], au.data[off..][0..n])) {
                d.stats.corrupt += 1;
                return error.CodecFailed;
            }
            off += n;
        }
        // References, as a real decoder would hold them.
        const ok_ref = if (h.flags.keyframe)
            true
        else if (h.flags.refresh)
            d.haveLtr(h.ref)
        else
            d.last_seq != null and d.last_seq.? == h.ref;
        if (!ok_ref) {
            d.stats.missing_ref += 1;
            return error.CodecFailed;
        }
        if (h.flags.keyframe) d.ltrs = @splat(null);
        pattern.render(d.buf, c.width, c.height, c.width * 4, h.stamp);
        if (pixelCrc(d.buf) != h.pixel_crc) {
            d.stats.corrupt += 1;
            return error.CodecFailed;
        }
        d.last_seq = h.seq;
        if (h.flags.ltr) {
            d.ltrs[d.ltr_next] = h.seq;
            d.ltr_next = (d.ltr_next + 1) % d.ltrs.len;
        }
        d.stats.frames += 1;
        d.out = true;
        return .{
            .frame_id = au.frame_id,
            .image = .{ .width = c.width, .height = c.height, .cpu = .{ .data = d.buf, .stride = c.width * 4 } },
            .decoded_us = d.clock.now(),
        };
    }

    pub fn release(d: *Decoder, _: *const api.DecodedFrame) void {
        d.out = false;
    }

    fn freeBufs(d: *Decoder) void {
        if (d.buf.len > 0) d.gpa.free(d.buf);
        if (d.check.len > 0) d.gpa.free(d.check);
        d.buf = &.{};
        d.check = &.{};
    }

    pub fn deinit(d: *Decoder) void {
        d.freeBufs();
    }
};

// ---------------------------------------------------------------------------
// Presenter

pub const Presenter = struct {
    clock: api.Clock,
    cfg: ?api.PresenterConfig = null,
    /// Stamp read back from the last presented picture.
    last_stamp: ?pattern.Stamp = null,
    stats: struct { presents: u64 = 0, unreadable: u64 = 0, overlays: u64 = 0 } = .{},

    pub fn configure(p: *Presenter, cfg: api.PresenterConfig) api.Error!void {
        p.cfg = cfg;
    }

    pub fn present(p: *Presenter, f: *const api.DecodedFrame, o: ?*const api.Overlay) api.Error!api.Presented {
        if (p.cfg == null) return error.Closed;
        const img = f.image.cpu orelse return error.Unsupported;
        if (pattern.read(img.data, f.image.width, f.image.height, img.stride)) |s| {
            p.last_stamp = s;
        } else {
            p.last_stamp = null;
            p.stats.unreadable += 1;
        }
        if (o != null) p.stats.overlays += 1;
        p.stats.presents += 1;
        return .{ .presented_us = p.clock.now() };
    }

    pub fn deinit(_: *Presenter) void {}
};

// ---------------------------------------------------------------------------
// Input

/// The `i`th scripted key event: HID usages 4.. (a, b, ...), press on even i, release on odd.
pub fn scriptKey(i: u64) struct { code: u16, down: bool } {
    return .{ .code = @intCast(4 + (i / 2) % 26), .down = i % 2 == 0 };
}

pub const InputSource = struct {
    clock: api.Clock,
    interval_us: Micros,
    /// Stop after this many key events (0: never).
    limit: u64 = 0,
    next_us: ?Micros = null,
    sent: u64 = 0,

    pub fn poll(s: *InputSource, out: []api.InputEvent) api.Error!usize {
        const now = s.clock.now();
        const due = s.next_us orelse {
            s.next_us = now + s.interval_us;
            return 0;
        };
        var n: usize = 0;
        if (now >= due and out.len >= 2 and (s.limit == 0 or s.sent < s.limit)) {
            const k = scriptKey(s.sent);
            out[0] = .{ .time_us = now, .what = .{ .key = .{ .code = k.code, .down = k.down } } };
            out[1] = .{ .time_us = now, .what = .{ .move_rel = .{ .dx = 3, .dy = -2 } } };
            n = 2;
            s.sent += 1;
            s.next_us = due + s.interval_us;
        }
        return n;
    }
};

pub const InputInjector = struct {
    keys: u64 = 0,
    wrong: u64 = 0,
    motion: [2]i64 = .{ 0, 0 },
    other: u64 = 0,

    pub fn inject(j: *InputInjector, a: @import("core").input.Action) api.Error!void {
        switch (a) {
            .key => |k| {
                const want = scriptKey(j.keys);
                if (k.code != want.code or k.down != want.down) j.wrong += 1;
                j.keys += 1;
            },
            .motion => |m| {
                j.motion[0] += m.dx;
                j.motion[1] += m.dy;
            },
            else => j.other += 1,
        }
    }
};

// ---------------------------------------------------------------------------
// Bundles

pub const Options = struct {
    clock: api.Clock,
    /// Null in virtual time.
    sleeper: Sleeper = null,
    sleep_ctx: ?*anyopaque = null,
    width: u32 = 640,
    height: u32 = 360,
    /// Client: a scripted key event this often (0: none).
    input_interval_us: Micros = 25_000,
    input_limit: u64 = 0,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    capture: Capture,
    encoder: Encoder,
    injector: InputInjector = .{},
    clock: api.Clock,

    pub fn backend(h: *Host) api.HostBackend {
        return .{
            .clock = h.clock,
            .capture = api.bind(api.Capture, Capture, &h.capture),
            .encoder = api.bind(api.Encoder, Encoder, &h.encoder),
            .input = api.bind(api.InputInjector, InputInjector, &h.injector),
            .deinit_ptr = h,
            .deinitFn = deinitHost,
        };
    }

    fn deinitHost(p: ?*anyopaque) void {
        const h: *Host = @ptrCast(@alignCast(p.?));
        h.capture.stop();
        h.encoder.deinit();
        h.gpa.destroy(h);
    }
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    decoder: Decoder,
    presenter: Presenter,
    input: InputSource,
    clock: api.Clock,
    with_input: bool,

    pub fn backend(c: *Client) api.ClientBackend {
        return .{
            .clock = c.clock,
            .decoder = api.bind(api.Decoder, Decoder, &c.decoder),
            .presenter = api.bind(api.Presenter, Presenter, &c.presenter),
            .input = if (c.with_input) api.bind(api.InputSource, InputSource, &c.input) else null,
            .deinit_ptr = c,
            .deinitFn = deinitClient,
        };
    }

    fn deinitClient(p: ?*anyopaque) void {
        const c: *Client = @ptrCast(@alignCast(p.?));
        c.decoder.deinit();
        c.gpa.destroy(c);
    }
};

/// The synthetic host. Keep the pointer to read its stats; `backend().deinit()` frees it.
pub fn openHost(gpa: std.mem.Allocator, o: Options) !*Host {
    const h = try gpa.create(Host);
    h.* = .{
        .gpa = gpa,
        .clock = o.clock,
        .capture = .{ .gpa = gpa, .clock = o.clock, .sleeper = o.sleeper, .sleep_ctx = o.sleep_ctx, .default_size = .{ .width = o.width, .height = o.height } },
        .encoder = .{ .gpa = gpa, .clock = o.clock },
    };
    return h;
}

pub fn openClient(gpa: std.mem.Allocator, o: Options) !*Client {
    const c = try gpa.create(Client);
    c.* = .{
        .gpa = gpa,
        .clock = o.clock,
        .decoder = .{ .gpa = gpa, .clock = o.clock },
        .presenter = .{ .clock = o.clock },
        .input = .{ .clock = o.clock, .interval_us = @max(o.input_interval_us, 1), .limit = o.input_limit },
        .with_input = o.input_interval_us > 0,
    };
    return c;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

var test_now: Micros = 1_000_000;
fn testClock() Micros {
    return test_now;
}

fn auOf(ef: api.EncodedFrame, buf: []u8, id: u32) api.AccessUnit {
    var n: usize = 0;
    for (ef.slices) |s| {
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
    }
    return .{ .codec = .passthrough, .frame_id = id, .data = buf[0..n], .keyframe = ef.keyframe, .capture_us = 0, .received_us = 0 };
}

test "capture, encode, decode, present round trip with references" {
    const gpa = testing.allocator;
    const clock = api.clockFn(testClock);
    const h = try openHost(gpa, .{ .clock = clock, .width = 160, .height = 90 });
    const hb = h.backend();
    defer hb.deinit();
    const c = try openClient(gpa, .{ .clock = clock, .width = 160, .height = 90 });
    const cb = c.backend();
    defer cb.deinit();

    const sz = try hb.capture.start(.{ .fps = 60 });
    try hb.encoder.configure(.{ .codec = .passthrough, .width = sz.width, .height = sz.height, .bitrate_bps = 2_000_000, .slices = 3 });
    try cb.decoder.configure(.{ .codec = .passthrough, .width = sz.width, .height = sz.height });
    try cb.presenter.configure(.{ .width = sz.width, .height = sz.height });

    var aus: [8][16 * 1024]u8 = undefined;
    var lens: [8]api.AccessUnit = undefined;
    for (0..8) |i| {
        test_now += 16_667;
        const f = (try hb.capture.acquire(0)).?;
        const ef = (try hb.encoder.encode(&f, .{})).?;
        try testing.expectEqual(i == 0, ef.keyframe);
        try testing.expectEqual(@as(usize, 3), ef.slices.len);
        lens[i] = auOf(ef, &aus[i], @intCast(i));
        hb.capture.release(&f);
    }
    // In order: every frame decodes and its pattern reads back.
    for (0..3) |i| {
        const df = (try cb.decoder.decode(&lens[i])).?;
        _ = try cb.presenter.present(&df, null);
        cb.decoder.release(&df);
        try testing.expectEqual(@as(u32, @intCast(i)), c.presenter.last_stamp.?.frame);
    }
    // Skip frame 3: frame 4 references it and fails, like a real decoder after a gap.
    try testing.expectError(error.CodecFailed, cb.decoder.decode(&lens[4]));
    // A refresh against the acked LTR (frame 0) decodes.
    test_now += 16_667;
    const f = (try hb.capture.acquire(0)).?;
    const ef = (try hb.encoder.encode(&f, .{ .force = .ltr_refresh, .acked_ltr_tokens = &.{1} })).?;
    hb.capture.release(&f);
    try testing.expect(ef.ltr_refresh and !ef.keyframe);
    var rb: [16 * 1024]u8 = undefined;
    const au = auOf(ef, &rb, 8);
    const df = (try cb.decoder.decode(&au)).?;
    cb.decoder.release(&df);
    // Corrupt one filler byte: rejected.
    var bad = lens[5];
    aus[5][header_len + 3] ^= 1;
    bad.data = aus[5][0..lens[5].data.len];
    try testing.expectError(error.CodecFailed, cb.decoder.decode(&bad));
    try testing.expectEqual(@as(u64, 1), c.decoder.stats.corrupt);
    try testing.expectEqual(@as(u64, 1), c.decoder.stats.missing_ref);
}

test "capture keeps cadence and repeats" {
    const gpa = testing.allocator;
    const clock = api.clockFn(testClock);
    const h = try openHost(gpa, .{ .clock = clock, .width = 128, .height = 64 });
    const hb = h.backend();
    defer hb.deinit();
    _ = try hb.capture.start(.{ .fps = 50 });
    const a = (try hb.capture.acquire(0)).?;
    hb.capture.release(&a);
    // Not due yet, and no sleeper: nothing.
    try testing.expectEqual(@as(?api.CapturedFrame, null), try hb.capture.acquire(0));
    const r = (try hb.capture.repeatLast()).?;
    try testing.expect(r.repeat and r.seq == a.seq);
    hb.capture.release(&r);
    test_now += 20_000;
    const b = (try hb.capture.acquire(0)).?;
    try testing.expectEqual(@as(u64, 1), b.seq);
    hb.capture.release(&b);
}

test "scripted input reaches the injector in order" {
    const clock = api.clockFn(testClock);
    var src: InputSource = .{ .clock = clock, .interval_us = 10 };
    var inj: InputInjector = .{};
    var evs: [4]api.InputEvent = undefined;
    _ = try src.poll(&evs);
    for (0..6) |_| {
        test_now += 10;
        const n = try src.poll(&evs);
        for (evs[0..n]) |e| switch (e.what) {
            .key => |k| try inj.inject(.{ .key = .{ .code = k.code, .down = k.down, .time = e.time_us } }),
            else => {},
        };
    }
    try testing.expectEqual(@as(u64, 6), inj.keys);
    try testing.expectEqual(@as(u64, 0), inj.wrong);
}
