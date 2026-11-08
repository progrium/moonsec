//! Session control messages on the control-fast stream (spec/wire-v0.md, "Session").
//!
//! Until the reliable QUIC control streams land, session setup runs on datagrams with
//! retries: the client repeats `hello` until it gets `config`, the host answers every
//! hello with the config, and either side repeats `bye` a few times when it leaves.
//! Kinds are numbered from 32, clear of proto's own (1–3) and clock sync (16–17).
const std = @import("std");
const core = @import("core");
const api = @import("platform");

const proto = core.proto;

pub const Kind = enum(u8) {
    /// Client to host: the host clock minus the client clock, as the client estimates it.
    clock_report = 18,
    hello = 32,
    config = 33,
    bye = 34,
    /// Host to client: `core.display.DisplayList`.
    display_list = 35,
    /// Client to host: `core.display.SelectDisplay`.
    select_display = 36,
    /// Client to host: `core.display.ConfigAck`.
    config_ack = 37,
    _,
};

pub const Hello = struct {
    /// Picked by the client per session; a hello with a new nonce is a new session.
    nonce: u32,
    codecs: api.CodecSet,
    max_width: u32 = 0,
    max_height: u32 = 0,

    pub const len = 16;

    pub fn encode(h: Hello, out: *[len]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], h.nonce, .little);
        out[4] = @bitCast(h.codecs);
        std.mem.writeInt(u32, out[8..12], h.max_width, .little);
        std.mem.writeInt(u32, out[12..16], h.max_height, .little);
    }

    pub fn decode(b: []const u8) ?Hello {
        if (b.len != len) return null;
        return .{
            .nonce = std.mem.readInt(u32, b[0..4], .little),
            .codecs = @bitCast(b[4]),
            .max_width = std.mem.readInt(u32, b[8..12], .little),
            .max_height = std.mem.readInt(u32, b[12..16], .little),
        };
    }
};

/// The stream's settings. The host sends one per session and a new one (next `epoch`)
/// whenever the size, frame rate, codec or display changes mid-stream; it takes effect at
/// `first_frame`, which the host encodes as an IDR.
pub const Config = struct {
    nonce: u32,
    codec: api.Codec,
    slices: u8,
    fps: u16,
    width: u32,
    height: u32,
    bitrate_bps: u64,
    /// Increments per mid-stream change (wraps). 0 for the session's first config.
    epoch: u32 = 0,
    /// The first frame (video `frame_id`) encoded with these settings.
    first_frame: u32 = 0,
    /// The display being streamed (`DisplayInfo.id`).
    display: u32 = 0,
    /// The newest `select_display.request` applied (0: none yet).
    request: u32 = 0,

    pub const len = 40;
    /// The Phase 2 form: no epoch, first frame, display or request (all read as 0).
    pub const len_v0 = 24;

    pub fn encode(c: Config, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], c.nonce, .little);
        out[4] = @intFromEnum(c.codec);
        out[5] = c.slices;
        std.mem.writeInt(u16, out[6..8], c.fps, .little);
        std.mem.writeInt(u32, out[8..12], c.width, .little);
        std.mem.writeInt(u32, out[12..16], c.height, .little);
        std.mem.writeInt(u64, out[16..24], c.bitrate_bps, .little);
        std.mem.writeInt(u32, out[24..28], c.epoch, .little);
        std.mem.writeInt(u32, out[28..32], c.first_frame, .little);
        std.mem.writeInt(u32, out[32..36], c.display, .little);
        std.mem.writeInt(u32, out[36..40], c.request, .little);
    }

    pub fn decode(b: []const u8) ?Config {
        if (b.len != len and b.len != len_v0) return null;
        var c: Config = .{
            .nonce = std.mem.readInt(u32, b[0..4], .little),
            .codec = @enumFromInt(b[4]),
            .slices = b[5],
            .fps = std.mem.readInt(u16, b[6..8], .little),
            .width = std.mem.readInt(u32, b[8..12], .little),
            .height = std.mem.readInt(u32, b[12..16], .little),
            .bitrate_bps = std.mem.readInt(u64, b[16..24], .little),
        };
        if (b.len == len) {
            c.epoch = std.mem.readInt(u32, b[24..28], .little);
            c.first_frame = std.mem.readInt(u32, b[28..32], .little);
            c.display = std.mem.readInt(u32, b[32..36], .little);
            c.request = std.mem.readInt(u32, b[36..40], .little);
        }
        if (c.fps == 0 or c.slices == 0 or c.width == 0 or c.height == 0) return null;
        return c;
    }

    /// Whether the decoder and presenter need configuring again between `a` and `b`.
    pub fn sameStream(a: Config, b: Config) bool {
        return a.codec == b.codec and a.width == b.width and a.height == b.height and a.fps == b.fps;
    }
};

pub const ByeReason = enum(u8) { done = 0, quit = 1, err = 2, _ };

pub const ClockReport = struct {
    offset_us: i64,
    error_bound_us: i64,

    pub const len = 16;

    pub fn encode(r: ClockReport, out: *[len]u8) void {
        std.mem.writeInt(i64, out[0..8], r.offset_us, .little);
        std.mem.writeInt(i64, out[8..16], r.error_bound_us, .little);
    }

    pub fn decode(b: []const u8) ?ClockReport {
        if (b.len != len) return null;
        return .{ .offset_us = std.mem.readInt(i64, b[0..8], .little), .error_bound_us = std.mem.readInt(i64, b[8..16], .little) };
    }
};

/// Envelope + payload into `buf`.
pub fn message(buf: []u8, stream: proto.StreamId, kind: u8, seq: u32, payload: []const u8) []u8 {
    var e = proto.wire.Encoder.init(buf);
    (proto.Envelope{ .stream = stream, .kind = kind, .seq = seq }).encode(&e) catch unreachable;
    e.bytes(payload) catch unreachable;
    return e.written();
}

test "session messages round trip" {
    var hb: [Hello.len]u8 = undefined;
    const h: Hello = .{ .nonce = 9, .codecs = .{ .hevc = true, .passthrough = true }, .max_width = 1920, .max_height = 1080 };
    h.encode(&hb);
    try std.testing.expectEqual(@as(?Hello, h), Hello.decode(&hb));
    try std.testing.expectEqual(@as(?Hello, null), Hello.decode(hb[1..]));

    var cb: [Config.len]u8 = undefined;
    const c: Config = .{ .nonce = 9, .codec = .passthrough, .slices = 4, .fps = 60, .width = 640, .height = 360, .bitrate_bps = 8_000_000, .epoch = 3, .first_frame = 1234, .display = 2, .request = 1 };
    c.encode(&cb);
    try std.testing.expectEqual(@as(?Config, c), Config.decode(&cb));
    // The 24-byte Phase 2 form still parses, as epoch 0.
    var v0 = c;
    v0.epoch = 0;
    v0.first_frame = 0;
    v0.display = 0;
    v0.request = 0;
    try std.testing.expectEqual(@as(?Config, v0), Config.decode(cb[0..Config.len_v0]));
    try std.testing.expectEqual(@as(?Config, null), Config.decode(cb[0..30]));
    cb[6] = 0;
    cb[7] = 0;
    try std.testing.expectEqual(@as(?Config, null), Config.decode(&cb));

    var rb: [ClockReport.len]u8 = undefined;
    (ClockReport{ .offset_us = -5, .error_bound_us = 300 }).encode(&rb);
    try std.testing.expectEqual(@as(i64, -5), ClockReport.decode(&rb).?.offset_us);
}
