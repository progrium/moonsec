//! Video formats beyond 8-bit 4:2:0 SDR: chroma subsampling, bit depth, colour space and
//! HDR static metadata, what encoders and decoders can do with each codec, and how the
//! host picks one (docs/design.md, "Media pipeline"; wire form in spec/wire-v0.md,
//! "Session"). Pure data and logic: no OS, no allocation.
//!
//! The client says what its decoder and display support (`FormatCaps`, `DisplayCaps` in
//! `hello`); the host intersects that with its encoder's caps and its own preferences
//! (`Preference`) and names one codec and one `VideoFormat` in `config` (`negotiate`).
const std = @import("std");

pub const Chroma = enum(u8) {
    yuv420 = 0,
    /// Full-resolution chroma, for sharp coloured text on a desktop. H.264 High 4:4:4
    /// Predictive, HEVC RExt (Main 4:4:4, Main 4:4:4 10), AV1 High profile.
    yuv444 = 1,
    _,
};

pub const ColorSpace = enum(u8) {
    /// BT.709 primaries, transfer and matrix.
    sdr_bt709 = 0,
    /// HDR10: BT.2020 primaries, SMPTE ST 2084 (PQ) transfer, BT.2020 non-constant-luminance
    /// matrix, 10-bit.
    hdr10 = 1,
    _,
};

/// SMPTE ST 2086 mastering display colour volume plus CTA-861.3 content light levels, in
/// the units HEVC's SEI and AV1's metadata OBUs use, so encoders copy them as they are.
pub const HdrMetadata = struct {
    /// Display primaries R, G, B as CIE 1931 (x, y), in units of 0.00002.
    primaries: [3][2]u16,
    /// White point (x, y), in units of 0.00002.
    white: [2]u16,
    /// Mastering display luminance, in units of 0.0001 cd/m².
    max_luminance: u32,
    min_luminance: u32,
    /// Maximum content light level and maximum frame-average light level, cd/m² (0 = unknown).
    max_cll: u16 = 0,
    max_fall: u16 = 0,

    /// Wire size: 6 + 2 u16 chromaticities, 2 u32 luminances, 2 u16 light levels.
    pub const len = 28;

    /// BT.2020 primaries, D65 white, 0.005–1000 cd/m²: the usual HDR10 values when the
    /// source cannot say (Windows reports its own through DXGI_OUTPUT_DESC1).
    pub const default_hdr10: HdrMetadata = .{
        .primaries = .{ .{ 35400, 14600 }, .{ 8500, 39850 }, .{ 6550, 2300 } },
        .white = .{ 15635, 16450 },
        .max_luminance = 1000 * 10_000,
        .min_luminance = 50,
        .max_cll = 1000,
        .max_fall = 400,
    };

    pub fn encode(m: HdrMetadata, out: *[len]u8) void {
        var i: usize = 0;
        for (m.primaries ++ [1][2]u16{m.white}) |p| for (p) |v| {
            std.mem.writeInt(u16, out[i..][0..2], v, .little);
            i += 2;
        };
        std.mem.writeInt(u32, out[16..20], m.max_luminance, .little);
        std.mem.writeInt(u32, out[20..24], m.min_luminance, .little);
        std.mem.writeInt(u16, out[24..26], m.max_cll, .little);
        std.mem.writeInt(u16, out[26..28], m.max_fall, .little);
    }

    pub fn decode(b: *const [len]u8) HdrMetadata {
        var xy: [8]u16 = undefined;
        for (&xy, 0..) |*v, i| v.* = std.mem.readInt(u16, b[i * 2 ..][0..2], .little);
        return .{
            .primaries = .{ .{ xy[0], xy[1] }, .{ xy[2], xy[3] }, .{ xy[4], xy[5] } },
            .white = .{ xy[6], xy[7] },
            .max_luminance = std.mem.readInt(u32, b[16..20], .little),
            .min_luminance = std.mem.readInt(u32, b[20..24], .little),
            .max_cll = std.mem.readInt(u16, b[24..26], .little),
            .max_fall = std.mem.readInt(u16, b[26..28], .little),
        };
    }

    /// Chromaticities within [0, 1] (50000 units), and max above min.
    pub fn valid(m: HdrMetadata) bool {
        for (m.primaries ++ [1][2]u16{m.white}) |p| for (p) |v| if (v > 50_000) return false;
        return m.max_luminance > m.min_luminance;
    }
};

/// One coded format: what `config` names and encoders and decoders are configured with.
pub const VideoFormat = struct {
    chroma: Chroma = .yuv420,
    /// 8 or 10.
    bit_depth: u8 = 8,
    color: ColorSpace = .sdr_bt709,
    /// With `.hdr10`: the source's mastering display and light levels, if it knows them.
    hdr: ?HdrMetadata = null,

    pub const sdr: VideoFormat = .{};

    /// The `Formats` bit this format needs.
    pub fn bit(f: VideoFormat) Formats {
        var s: Formats = .{};
        switch (f.chroma) {
            .yuv444 => if (f.bit_depth == 10) {
                s.yuv444_10 = true;
            } else {
                s.yuv444_8 = true;
            },
            else => if (f.bit_depth == 10) {
                s.yuv420_10 = true;
            } else {
                s.yuv420_8 = true;
            },
        }
        if (f.color == .hdr10) s.hdr10 = true;
        return s;
    }

    /// Consistent: a known chroma and colour space, 8 or 10 bits, HDR10 only at 10 bits,
    /// metadata only with HDR10.
    pub fn valid(f: VideoFormat) bool {
        if (f.chroma != .yuv420 and f.chroma != .yuv444) return false;
        if (f.bit_depth != 8 and f.bit_depth != 10) return false;
        return switch (f.color) {
            .sdr_bt709 => f.hdr == null,
            .hdr10 => f.bit_depth == 10 and (f.hdr == null or f.hdr.?.valid()),
            _ => false,
        };
    }

    pub fn eql(a: VideoFormat, b: VideoFormat) bool {
        return std.meta.eql(a, b);
    }

    /// "4:4:4 10-bit HDR10" and so on, for logs and the overlay.
    pub fn name(f: VideoFormat, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} {d}-bit {s}", .{
            if (f.chroma == .yuv444) "4:4:4" else "4:2:0",
            f.bit_depth,
            if (f.color == .hdr10) "HDR10" else "SDR",
        }) catch buf[0..0];
    }
};

/// The formats an encoder or decoder handles for one codec. 8-bit 4:2:0 is the baseline
/// every implementation of a codec has; `hdr10` says it can carry HDR10 (signal PQ and
/// BT.2020 in the bitstream, pass the metadata) at whichever 10-bit formats it has.
pub const Formats = packed struct(u8) {
    yuv420_8: bool = false,
    yuv420_10: bool = false,
    yuv444_8: bool = false,
    yuv444_10: bool = false,
    hdr10: bool = false,
    _reserved: u3 = 0,

    pub const baseline: Formats = .{ .yuv420_8 = true };
    pub const all: Formats = .{ .yuv420_8 = true, .yuv420_10 = true, .yuv444_8 = true, .yuv444_10 = true, .hdr10 = true };

    pub fn bits(s: Formats) u8 {
        return @bitCast(s);
    }
    pub fn intersect(a: Formats, b: Formats) Formats {
        return @bitCast(a.bits() & b.bits() & 0x1f);
    }
    /// Every bit of `want` is in `s`.
    pub fn covers(s: Formats, want: Formats) bool {
        return s.bits() & want.bits() == want.bits();
    }
    pub fn supports(s: Formats, f: VideoFormat) bool {
        return f.valid() and s.covers(f.bit());
    }
};

/// Per-codec formats, indexed like `api.Codec` (h264, hevc, av1, passthrough). A codec
/// with no bits is not supported at all.
pub const FormatCaps = struct {
    h264: Formats = .{},
    hevc: Formats = .{},
    av1: Formats = .{},
    passthrough: Formats = .{},

    pub const len = 4;

    /// `codec` is `api.Codec`'s value (1 h264, 2 hevc, 3 av1, 250 passthrough).
    pub fn get(c: FormatCaps, codec: u8) Formats {
        return switch (codec) {
            1 => c.h264,
            2 => c.hevc,
            3 => c.av1,
            250 => c.passthrough,
            else => .{},
        };
    }

    pub fn set(c: *FormatCaps, codec: u8, f: Formats) void {
        switch (codec) {
            1 => c.h264 = f,
            2 => c.hevc = f,
            3 => c.av1 = f,
            250 => c.passthrough = f,
            else => {},
        }
    }

    pub fn encode(c: FormatCaps, out: *[len]u8) void {
        out.* = .{ c.h264.bits(), c.hevc.bits(), c.av1.bits(), c.passthrough.bits() };
    }

    pub fn decode(b: *const [len]u8) FormatCaps {
        // Reserved bits are ignored, as the spec says.
        return .{ .h264 = @bitCast(b[0] & 0x1f), .hevc = @bitCast(b[1] & 0x1f), .av1 = @bitCast(b[2] & 0x1f), .passthrough = @bitCast(b[3] & 0x1f) };
    }
};

/// The client's display: whether it can show HDR10 now (an HDR mode is on), and its peak.
pub const DisplayCaps = struct {
    hdr10: bool = false,
    /// Peak luminance in cd/m², 0 when unknown. For the host's tone mapping, if it does any.
    peak_nits: u16 = 0,
};

/// The host's side of the choice.
pub const Preference = struct {
    /// Codecs in the order the host prefers them (api.Codec values).
    codecs: Order,
    /// Prefer 4:4:4 when both ends have it (desktop text). Costs bitrate and, on most
    /// hardware, decoder support.
    yuv444: bool = false,
    /// Prefer 10-bit for SDR too (less banding).
    ten_bit: bool = false,
    /// Send HDR10 when the source is HDR (`source_hdr`) and the client's display shows it.
    hdr: bool = true,
    /// Set when the captured display is in an HDR mode, with its metadata when known.
    source_hdr: ?HdrMetadata = null,
    source_is_hdr: bool = false,
};

/// Up to four codecs, by value, so a `Preference` can be copied freely.
pub const Order = struct {
    buf: [4]u8 = @splat(0),
    len: u8 = 0,

    pub fn of(list: []const u8) Order {
        var o: Order = .{};
        for (list) |c| o.add(c);
        return o;
    }
    /// Appends `c` unless it is there already or the list is full.
    pub fn add(o: *Order, c: u8) void {
        if (o.len == o.buf.len or std.mem.indexOfScalar(u8, o.slice(), c) != null) return;
        o.buf[o.len] = c;
        o.len += 1;
    }
    pub fn slice(o: *const Order) []const u8 {
        return o.buf[0..o.len];
    }
};

pub const Choice = struct {
    /// api.Codec value.
    codec: u8,
    format: VideoFormat,
};

/// What the host sends: the best (codec, format) both ends can do. Features rank HDR10
/// (when wanted and possible) over 4:4:4 over 10-bit; ties go to the host's codec order.
/// Null when no codec is common to both.
pub fn negotiate(p: Preference, enc: FormatCaps, dec: FormatCaps, display: DisplayCaps) ?Choice {
    const want_hdr = p.hdr and p.source_is_hdr and display.hdr10;
    var best: ?Choice = null;
    var best_score: i32 = -1;
    for (p.codecs.slice()) |codec| {
        const both = enc.get(codec).intersect(dec.get(codec));
        if (!both.yuv420_8) continue;
        // Candidates in descending preference; the first one both ends support wins
        // for this codec.
        const hdr_opts: []const bool = if (want_hdr) &.{ true, false } else &.{false};
        const c444: []const bool = if (p.yuv444) &.{ true, false } else &.{false};
        outer: for (hdr_opts) |hdr| for (c444) |y444| for ([_]bool{ true, false }) |ten| {
            if (hdr and !ten) continue;
            if (ten and !hdr and !p.ten_bit) continue;
            const f: VideoFormat = .{
                .chroma = if (y444) .yuv444 else .yuv420,
                .bit_depth = if (ten) 10 else 8,
                .color = if (hdr) .hdr10 else .sdr_bt709,
                .hdr = if (hdr) (p.source_hdr orelse HdrMetadata.default_hdr10) else null,
            };
            if (!both.supports(f)) continue;
            const score: i32 = @as(i32, @intFromBool(hdr)) * 4 + @as(i32, @intFromBool(y444)) * 2 + @intFromBool(ten);
            if (score > best_score) {
                best_score = score;
                best = .{ .codec = codec, .format = f };
            }
            break :outer;
        };
    }
    return best;
}

/// What one client of a shared stream (a multi-user session) can take: its decoder's
/// formats per codec and its display.
pub const Member = struct {
    dec: FormatCaps,
    display: DisplayCaps = .{},
};

/// What every member can take: the decoders' formats intersected codec by codec, and an
/// HDR display only when every display is one (the lowest peak). Null for no members.
pub fn common(members: []const Member) ?Member {
    if (members.len == 0) return null;
    var c = members[0];
    for (members[1..]) |m| {
        inline for (.{ "h264", "hevc", "av1", "passthrough" }) |f| {
            @field(c.dec, f) = @field(c.dec, f).intersect(@field(m.dec, f));
        }
        c.display.hdr10 = c.display.hdr10 and m.display.hdr10;
        c.display.peak_nits = @min(c.display.peak_nits, m.display.peak_nits);
    }
    return c;
}

/// One codec and format for a shared encoder: the best one every member decodes
/// (`negotiate` over `common`). Null when there are no members or no codec all of them
/// and the encoder have.
pub fn negotiateCommon(p: Preference, enc: FormatCaps, members: []const Member) ?Choice {
    const c = common(members) orelse return null;
    return negotiate(p, enc, c.dec, c.display);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "hdr metadata round trip" {
    var b: [HdrMetadata.len]u8 = undefined;
    const m = HdrMetadata.default_hdr10;
    m.encode(&b);
    try testing.expectEqual(m, HdrMetadata.decode(&b));
    try testing.expect(m.valid());
    var bad = m;
    bad.white[0] = 60_000;
    try testing.expect(!bad.valid());
}

test "format bits and validity" {
    try testing.expect(VideoFormat.sdr.valid());
    try testing.expect(!(VideoFormat{ .color = .hdr10 }).valid()); // 8-bit HDR10
    try testing.expect(!(VideoFormat{ .bit_depth = 12 }).valid());
    try testing.expect(!(VideoFormat{ .hdr = HdrMetadata.default_hdr10 }).valid()); // metadata on SDR
    const f: VideoFormat = .{ .chroma = .yuv444, .bit_depth = 10, .color = .hdr10 };
    try testing.expect(f.valid());
    try testing.expectEqual(Formats{ .yuv444_10 = true, .hdr10 = true }, f.bit());
    try testing.expect(Formats.all.supports(f));
    try testing.expect(!(Formats{ .yuv444_10 = true }).supports(f));
    var nb: [32]u8 = undefined;
    try testing.expectEqualStrings("4:4:4 10-bit HDR10", f.name(&nb));

    var caps: FormatCaps = .{ .hevc = Formats.all, .av1 = .{ .yuv420_8 = true, .yuv420_10 = true } };
    var w: [FormatCaps.len]u8 = undefined;
    caps.encode(&w);
    try testing.expectEqual(caps, FormatCaps.decode(&w));
    w[0] = 0xe1; // reserved bits set: ignored
    try testing.expectEqual(Formats.baseline, FormatCaps.decode(&w).h264);
    caps.set(1, Formats.baseline);
    try testing.expectEqual(Formats.baseline, caps.get(1));
    try testing.expectEqual(Formats{}, caps.get(99));
}

const H264 = 1;
const HEVC = 2;
const AV1 = 3;

test "negotiate: the host's codec order with plain SDR" {
    const enc: FormatCaps = .{ .h264 = Formats.all, .hevc = Formats.all, .av1 = Formats.all };
    const dec: FormatCaps = .{ .h264 = Formats.baseline, .hevc = Formats.baseline };
    const c = negotiate(.{ .codecs = .of(&.{ AV1, HEVC, H264 }) }, enc, dec, .{}).?;
    try testing.expectEqual(@as(u8, HEVC), c.codec);
    try testing.expect(c.format.eql(VideoFormat.sdr));
    // Nothing in common.
    try testing.expectEqual(@as(?Choice, null), negotiate(.{ .codecs = .of(&.{AV1}) }, enc, dec, .{}));
}

test "negotiate: HDR10 needs the source, the display and both codecs" {
    const enc: FormatCaps = .{ .hevc = Formats.all, .h264 = .{ .yuv420_8 = true, .yuv444_8 = true } };
    var dec: FormatCaps = .{ .hevc = .{ .yuv420_8 = true, .yuv420_10 = true, .hdr10 = true }, .h264 = Formats.baseline };
    const hdr_src: Preference = .{ .codecs = .of(&.{ H264, HEVC }), .source_is_hdr = true };
    // HDR beats the host's preference for H.264, which has no 10-bit here.
    var c = negotiate(hdr_src, enc, dec, .{ .hdr10 = true }).?;
    try testing.expectEqual(@as(u8, HEVC), c.codec);
    try testing.expectEqual(ColorSpace.hdr10, c.format.color);
    try testing.expectEqual(@as(u8, 10), c.format.bit_depth);
    try testing.expectEqual(HdrMetadata.default_hdr10, c.format.hdr.?);
    try testing.expect(c.format.valid());
    // The source's metadata is passed through.
    var src = hdr_src;
    var m = HdrMetadata.default_hdr10;
    m.max_cll = 600;
    src.source_hdr = m;
    try testing.expectEqual(@as(u16, 600), negotiate(src, enc, dec, .{ .hdr10 = true }).?.format.hdr.?.max_cll);
    // SDR display: SDR, back on H.264.
    c = negotiate(hdr_src, enc, dec, .{}).?;
    try testing.expectEqual(@as(u8, H264), c.codec);
    try testing.expect(c.format.eql(VideoFormat.sdr));
    // SDR source: SDR.
    c = negotiate(.{ .codecs = .of(&.{ HEVC, H264 }) }, enc, dec, .{ .hdr10 = true }).?;
    try testing.expect(c.format.eql(VideoFormat.sdr));
    // The user turned HDR off.
    var off = hdr_src;
    off.hdr = false;
    try testing.expect(negotiate(off, enc, dec, .{ .hdr10 = true }).?.format.color == .sdr_bt709);
    // Decoder has 10-bit but cannot signal HDR10: SDR.
    dec.hevc.hdr10 = false;
    try testing.expect(negotiate(hdr_src, enc, dec, .{ .hdr10 = true }).?.format.color == .sdr_bt709);
}

test "negotiate: 4:4:4 when asked for and common, else 4:2:0" {
    const enc: FormatCaps = .{ .h264 = .{ .yuv420_8 = true, .yuv444_8 = true }, .hevc = Formats.all, .av1 = Formats.all };
    var dec: FormatCaps = .{ .h264 = Formats.baseline, .hevc = .{ .yuv420_8 = true, .yuv444_8 = true }, .av1 = Formats.baseline };
    const p: Preference = .{ .codecs = .of(&.{ AV1, H264, HEVC }), .yuv444 = true };
    var c = negotiate(p, enc, dec, .{}).?;
    try testing.expectEqual(@as(u8, HEVC), c.codec);
    try testing.expectEqual(Chroma.yuv444, c.format.chroma);
    try testing.expectEqual(@as(u8, 8), c.format.bit_depth);
    // Not asked for: the host's first codec at 4:2:0.
    c = negotiate(.{ .codecs = p.codecs }, enc, dec, .{}).?;
    try testing.expectEqual(@as(u8, AV1), c.codec);
    try testing.expectEqual(Chroma.yuv420, c.format.chroma);
    // 4:4:4 and 10-bit both wanted: 4:4:4 10 when there, else 4:4:4 8 over 4:2:0 10.
    dec.av1 = .{ .yuv420_8 = true, .yuv420_10 = true };
    const both: Preference = .{ .codecs = p.codecs, .yuv444 = true, .ten_bit = true };
    c = negotiate(both, enc, dec, .{}).?;
    try testing.expectEqual(@as(u8, HEVC), c.codec);
    try testing.expectEqual(Chroma.yuv444, c.format.chroma);
    dec.hevc.yuv444_10 = true;
    c = negotiate(both, enc, dec, .{}).?;
    try testing.expectEqual(@as(u8, 10), c.format.bit_depth);
    try testing.expectEqual(Chroma.yuv444, c.format.chroma);
}

test "negotiate: every combination yields a format both ends support" {
    // Exhaustive over the low five bits of one codec on each side.
    var e: u8 = 0;
    while (e < 32) : (e += 1) {
        var d: u8 = 0;
        while (d < 32) : (d += 1) {
            for ([_]bool{ false, true }) |y444| for ([_]bool{ false, true }) |ten| for ([_]bool{ false, true }) |src_hdr| for ([_]bool{ false, true }) |disp_hdr| {
                const enc: FormatCaps = .{ .hevc = @bitCast(e) };
                const dec: FormatCaps = .{ .hevc = @bitCast(d) };
                const p: Preference = .{ .codecs = .of(&.{HEVC}), .yuv444 = y444, .ten_bit = ten, .source_is_hdr = src_hdr };
                const c = negotiate(p, enc, dec, .{ .hdr10 = disp_hdr }) orelse {
                    try testing.expect(e & d & 1 == 0);
                    continue;
                };
                try testing.expect(c.format.valid());
                try testing.expect(enc.hevc.supports(c.format) and dec.hevc.supports(c.format));
                if (c.format.color == .hdr10) try testing.expect(src_hdr and disp_hdr);
                if (c.format.chroma == .yuv444) try testing.expect(y444);
                // HDR is chosen whenever it is possible.
                const hdr_possible = src_hdr and disp_hdr and (e & d & 0x10 != 0) and (e & d & 0x02 != 0 or (y444 and e & d & 0x08 != 0));
                try testing.expectEqual(hdr_possible, c.format.color == .hdr10);
            };
        }
    }
}

test "negotiateCommon: the best format every member has, re-picked as members change" {
    const pref: Preference = .{ .codecs = .of(&.{ 2, 1, 3 }), .yuv444 = true, .ten_bit = true, .source_is_hdr = true };
    const enc: FormatCaps = .{ .h264 = Formats.all, .hevc = Formats.all, .av1 = Formats.all };
    const full: Member = .{ .dec = .{ .hevc = Formats.all, .h264 = Formats.all }, .display = .{ .hdr10 = true, .peak_nits = 1000 } };
    const no444: Member = .{ .dec = .{ .hevc = .{ .yuv420_8 = true, .yuv420_10 = true, .hdr10 = true } }, .display = .{ .hdr10 = true, .peak_nits = 600 } };
    const sdr_only: Member = .{ .dec = .{ .hevc = .{ .yuv420_8 = true, .yuv444_8 = true } } };
    const av1_only: Member = .{ .dec = .{ .av1 = Formats.all } };

    try testing.expectEqual(@as(?Choice, null), negotiateCommon(pref, enc, &.{}));
    // Alone, a member gets what `negotiate` gives it.
    const one = negotiateCommon(pref, enc, &.{full}).?;
    try testing.expectEqual(negotiate(pref, enc, full.dec, full.display).?, one);
    try testing.expectEqual(ColorSpace.hdr10, one.format.color);
    try testing.expectEqual(Chroma.yuv444, one.format.chroma);
    // A member without 4:4:4: HDR10 4:2:0 for both.
    const two = negotiateCommon(pref, enc, &.{ full, no444 }).?;
    try testing.expectEqual(@as(u8, 2), two.codec);
    try testing.expectEqual(Chroma.yuv420, two.format.chroma);
    try testing.expectEqual(ColorSpace.hdr10, two.format.color);
    try testing.expectEqual(@as(u16, 600), common(&.{ full, no444 }).?.display.peak_nits);
    // A member with an SDR display and 8-bit only: SDR; the only feature left in common
    // with the first is 4:4:4 8-bit.
    const three = negotiateCommon(pref, enc, &.{ full, sdr_only }).?;
    try testing.expect(three.format.eql(.{ .chroma = .yuv444 }));
    // All three: baseline HEVC.
    try testing.expect(negotiateCommon(pref, enc, &.{ full, no444, sdr_only }).?.format.eql(.{}));
    // Nothing in common.
    try testing.expectEqual(@as(?Choice, null), negotiateCommon(pref, enc, &.{ full, av1_only }));
    // Order does not matter.
    try testing.expectEqual(negotiateCommon(pref, enc, &.{ no444, full }).?, two);
}
