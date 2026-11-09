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
    _,
};

pub const Hello = struct {
    /// Picked by the client per session; a hello with a new nonce is a new session.
    nonce: u32,
    codecs: api.CodecSet,
    max_width: u32 = 0,
    max_height: u32 = 0,
    /// Formats per codec the decoder and presenter handle; empty for a codec in `codecs`
    /// means 8-bit 4:2:0 SDR only (the 16-byte hello).
    formats: api.FormatCaps = .{},
    display: api.DisplayCaps = .{},

    /// The original hello, without formats or display.
    pub const base_len = 16;
    pub const len = 24;

    pub fn encode(h: Hello, out: *[len]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], h.nonce, .little);
        out[4] = @bitCast(h.codecs);
        std.mem.writeInt(u32, out[8..12], h.max_width, .little);
        std.mem.writeInt(u32, out[12..16], h.max_height, .little);
        h.formats.encode(out[16..20]);
        out[20] = @intFromBool(h.display.hdr10);
        std.mem.writeInt(u16, out[22..24], h.display.peak_nits, .little);
    }

    /// Takes the 16-byte hello of older clients too.
    pub fn decode(b: []const u8) ?Hello {
        if (b.len != base_len and b.len != len) return null;
        var h: Hello = .{
            .nonce = std.mem.readInt(u32, b[0..4], .little),
            .codecs = @bitCast(b[4]),
            .max_width = std.mem.readInt(u32, b[8..12], .little),
            .max_height = std.mem.readInt(u32, b[12..16], .little),
        };
        if (b.len == len) {
            h.formats = api.FormatCaps.decode(b[16..20]);
            h.display = .{ .hdr10 = b[20] & 1 != 0, .peak_nits = std.mem.readInt(u16, b[22..24], .little) };
        }
        return h;
    }

    /// What the client really decodes, per codec.
    pub fn decodable(h: Hello) api.FormatCaps {
        return api.effectiveFormats(h.codecs, h.formats);
    }
};

pub const Config = struct {
    nonce: u32,
    codec: api.Codec,
    slices: u8,
    fps: u16,
    width: u32,
    height: u32,
    bitrate_bps: u64,
    format: api.VideoFormat = .{},

    /// The original config: 8-bit 4:2:0 SDR.
    pub const base_len = 24;
    /// Plus chroma, bit depth, colour space, flags and the HDR metadata block.
    pub const len = base_len + 4 + api.HdrMetadata.len;

    const flag_hdr_metadata: u8 = 1;

    pub fn encode(c: Config, out: *[len]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], c.nonce, .little);
        out[4] = @intFromEnum(c.codec);
        out[5] = c.slices;
        std.mem.writeInt(u16, out[6..8], c.fps, .little);
        std.mem.writeInt(u32, out[8..12], c.width, .little);
        std.mem.writeInt(u32, out[12..16], c.height, .little);
        std.mem.writeInt(u64, out[16..24], c.bitrate_bps, .little);
        out[24] = @intFromEnum(c.format.chroma);
        out[25] = c.format.bit_depth;
        out[26] = @intFromEnum(c.format.color);
        if (c.format.hdr) |m| {
            out[27] = flag_hdr_metadata;
            m.encode(out[28..][0..api.HdrMetadata.len]);
        }
    }

    /// Takes the 24-byte config of older hosts too. Rejects a format that is not
    /// `VideoFormat.valid` (unknown chroma or colour space, 8-bit HDR10, ...).
    pub fn decode(b: []const u8) ?Config {
        if (b.len != base_len and b.len != len) return null;
        var c: Config = .{
            .nonce = std.mem.readInt(u32, b[0..4], .little),
            .codec = @enumFromInt(b[4]),
            .slices = b[5],
            .fps = std.mem.readInt(u16, b[6..8], .little),
            .width = std.mem.readInt(u32, b[8..12], .little),
            .height = std.mem.readInt(u32, b[12..16], .little),
            .bitrate_bps = std.mem.readInt(u64, b[16..24], .little),
        };
        if (c.fps == 0 or c.slices == 0 or c.width == 0 or c.height == 0) return null;
        if (b.len == len) {
            c.format = .{ .chroma = @enumFromInt(b[24]), .bit_depth = b[25], .color = @enumFromInt(b[26]) };
            if (b[27] & flag_hdr_metadata != 0) c.format.hdr = api.HdrMetadata.decode(b[28..][0..api.HdrMetadata.len]);
            if (!c.format.valid()) return null;
        }
        return c;
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

test "hello and config carry formats, display and HDR metadata" {
    var hb: [Hello.len]u8 = undefined;
    const h: Hello = .{
        .nonce = 3,
        .codecs = .{ .hevc = true, .av1 = true },
        .formats = .{ .hevc = api.Formats.all, .av1 = .{ .yuv420_8 = true, .yuv420_10 = true, .hdr10 = true } },
        .display = .{ .hdr10 = true, .peak_nits = 1000 },
    };
    h.encode(&hb);
    try std.testing.expectEqual(@as(?Hello, h), Hello.decode(&hb));
    try std.testing.expectEqual(@as(?Hello, null), Hello.decode(hb[0..20]));

    var cb: [Config.len]u8 = undefined;
    var m = api.HdrMetadata.default_hdr10;
    m.max_cll = 812;
    const c: Config = .{ .nonce = 3, .codec = .av1, .slices = 2, .fps = 120, .width = 3840, .height = 2160, .bitrate_bps = 50_000_000, .format = .{ .bit_depth = 10, .color = .hdr10, .hdr = m } };
    c.encode(&cb);
    try std.testing.expectEqual(@as(?Config, c), Config.decode(&cb));
    // Without metadata.
    const c2: Config = .{ .nonce = 3, .codec = .hevc, .slices = 2, .fps = 60, .width = 64, .height = 64, .bitrate_bps = 1, .format = .{ .chroma = .yuv444 } };
    c2.encode(&cb);
    try std.testing.expectEqual(@as(?Config, c2), Config.decode(&cb));
    // Invalid formats are rejected: 8-bit HDR10, unknown chroma, 12-bit.
    cb[26] = 1;
    try std.testing.expectEqual(@as(?Config, null), Config.decode(&cb));
    cb[26] = 0;
    cb[24] = 7;
    try std.testing.expectEqual(@as(?Config, null), Config.decode(&cb));
    cb[24] = 0;
    cb[25] = 12;
    try std.testing.expectEqual(@as(?Config, null), Config.decode(&cb));
}

test "session messages round trip" {
    var hb: [Hello.len]u8 = undefined;
    const h: Hello = .{ .nonce = 9, .codecs = .{ .hevc = true, .passthrough = true }, .max_width = 1920, .max_height = 1080 };
    h.encode(&hb);
    try std.testing.expectEqual(@as(?Hello, h), Hello.decode(&hb));
    try std.testing.expectEqual(@as(?Hello, null), Hello.decode(hb[1..]));

    var cb: [Config.len]u8 = undefined;
    const c: Config = .{ .nonce = 9, .codec = .passthrough, .slices = 4, .fps = 60, .width = 640, .height = 360, .bitrate_bps = 8_000_000 };
    c.encode(&cb);
    try std.testing.expectEqual(@as(?Config, c), Config.decode(&cb));
    cb[6] = 0;
    cb[7] = 0;
    try std.testing.expectEqual(@as(?Config, null), Config.decode(&cb));

    // Older peers: the 16-byte hello and 24-byte config still decode, as 8-bit 4:2:0 SDR.
    const old_h = Hello.decode(hb[0..Hello.base_len]).?;
    try std.testing.expectEqual(api.FormatCaps{}, old_h.formats);
    try std.testing.expectEqual(api.Formats.baseline, old_h.decodable().hevc);
    try std.testing.expectEqual(api.Formats{}, old_h.decodable().h264);
    cb[6] = 60;
    try std.testing.expect(Config.decode(cb[0..Config.base_len]).?.format.eql(.{}));

    var rb: [ClockReport.len]u8 = undefined;
    (ClockReport{ .offset_us = -5, .error_bound_us = 300 }).encode(&rb);
    try std.testing.expectEqual(@as(i64, -5), ClockReport.decode(&rb).?.offset_us);
}
