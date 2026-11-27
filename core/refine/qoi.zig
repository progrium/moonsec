//! QOI ("Quite OK Image", qoiformat.org, spec 1.0) for lossless tiles: encode a cell of
//! captured bgra8 pixels, decode it straight into a tile layer (bgra8 or rgba8, any
//! stride). Single pass, no allocation, no tables beyond QOI's own 64-entry index.
//!
//! Tiles are encoded with 3 channels: captured alpha means nothing, and every decoded
//! pixel gets alpha 255 (opaque over the video). The full QOI header and end marker are
//! kept, so a tile dumped to disk opens in any QOI viewer.
//!
//! The decoder takes untrusted bytes (fuzz/refine.zig): every read is bounds-checked, the
//! header must match the size the caller expects, and it never writes outside `out`.
const std = @import("std");

pub const header_len = 14;
pub const end_marker = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

const op_index: u8 = 0x00;
const op_diff: u8 = 0x40;
const op_luma: u8 = 0x80;
const op_run: u8 = 0xc0;
const op_rgb: u8 = 0xfe;
const op_rgba: u8 = 0xff;
const mask2: u8 = 0xc0;

pub const Order = enum { bgra, rgba };

const Px = packed struct(u32) { r: u8, g: u8, b: u8, a: u8 };

inline fn hash(p: Px) u6 {
    return @truncate((@as(u32, p.r) *% 3 +% @as(u32, p.g) *% 5 +% @as(u32, p.b) *% 7 +% @as(u32, p.a) *% 11) % 64);
}

/// Worst case encoded size of a `w` x `h` tile (every pixel an RGB op).
pub fn maxEncodedLen(w: u32, h: u32) usize {
    return header_len + @as(usize, w) * h * 4 + end_marker.len;
}

pub const EncodeError = error{BufferTooSmall};

/// Encodes the `w` x `h` bgra8 block at `src` (rows `stride` bytes apart) into `out`;
/// returns the bytes written. `out.len >= maxEncodedLen(w, h)` always fits.
pub fn encode(src: []const u8, stride: usize, w: u32, h: u32, out: []u8) EncodeError![]u8 {
    if (out.len < header_len + end_marker.len) return error.BufferTooSmall;
    @memcpy(out[0..4], "qoif");
    std.mem.writeInt(u32, out[4..8], w, .big);
    std.mem.writeInt(u32, out[8..12], h, .big);
    out[12] = 3;
    out[13] = 0; // sRGB with linear alpha
    var p: usize = header_len;
    var index: [64]Px = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    var prev: Px = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var run: u8 = 0;
    const limit = out.len - end_marker.len;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = src[@as(usize, y) * stride ..][0 .. @as(usize, w) * 4];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const px: Px = .{ .b = row[x * 4], .g = row[x * 4 + 1], .r = row[x * 4 + 2], .a = 255 };
            if (@as(u32, @bitCast(px)) == @as(u32, @bitCast(prev))) {
                run += 1;
                const last = y + 1 == h and x + 1 == w;
                if (run == 62 or last) {
                    if (p >= limit) return error.BufferTooSmall;
                    out[p] = op_run | (run - 1);
                    p += 1;
                    run = 0;
                }
                continue;
            }
            if (run > 0) {
                if (p >= limit) return error.BufferTooSmall;
                out[p] = op_run | (run - 1);
                p += 1;
                run = 0;
            }
            const hi = hash(px);
            if (@as(u32, @bitCast(index[hi])) == @as(u32, @bitCast(px))) {
                if (p >= limit) return error.BufferTooSmall;
                out[p] = op_index | hi;
                p += 1;
            } else {
                index[hi] = px;
                const vr: i8 = @bitCast(px.r -% prev.r);
                const vg: i8 = @bitCast(px.g -% prev.g);
                const vb: i8 = @bitCast(px.b -% prev.b);
                const vg_r = vr -% vg;
                const vg_b = vb -% vg;
                if (vr > -3 and vr < 2 and vg > -3 and vg < 2 and vb > -3 and vb < 2) {
                    if (p >= limit) return error.BufferTooSmall;
                    out[p] = op_diff | @as(u8, @intCast(vr + 2)) << 4 | @as(u8, @intCast(vg + 2)) << 2 | @as(u8, @intCast(vb + 2));
                    p += 1;
                } else if (vg_r > -9 and vg_r < 8 and vg > -33 and vg < 32 and vg_b > -9 and vg_b < 8) {
                    if (p + 2 > limit) return error.BufferTooSmall;
                    out[p] = op_luma | @as(u8, @intCast(vg + 32));
                    out[p + 1] = @as(u8, @intCast(vg_r + 8)) << 4 | @as(u8, @intCast(vg_b + 8));
                    p += 2;
                } else {
                    if (p + 4 > limit) return error.BufferTooSmall;
                    out[p] = op_rgb;
                    out[p + 1] = px.r;
                    out[p + 2] = px.g;
                    out[p + 3] = px.b;
                    p += 4;
                }
            }
            prev = px;
        }
    }
    @memcpy(out[p..][0..end_marker.len], &end_marker);
    return out[0 .. p + end_marker.len];
}

pub const DecodeError = error{ BadHeader, SizeMismatch, Truncated, TooLong, BufferTooSmall };

pub const Header = struct { width: u32, height: u32, channels: u8 };

pub fn readHeader(data: []const u8) DecodeError!Header {
    if (data.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, data[0..4], "qoif")) return error.BadHeader;
    const ch = data[12];
    if (ch != 3 and ch != 4) return error.BadHeader;
    if (data[13] > 1) return error.BadHeader;
    return .{ .width = std.mem.readInt(u32, data[4..8], .big), .height = std.mem.readInt(u32, data[8..12], .big), .channels = ch };
}

/// Decodes `data`, which must be a `w` x `h` QOI image, into `out` (rows `stride` bytes
/// apart) as `order` with alpha 255. Bytes after the end marker, or a missing marker, are
/// errors, so a truncated tile never shows.
pub fn decode(data: []const u8, w: u32, h: u32, out: []u8, stride: usize, order: Order) DecodeError!void {
    const hd = try readHeader(data);
    if (hd.width != w or hd.height != h) return error.SizeMismatch;
    if (h > 0 and (stride < @as(usize, w) * 4 or out.len < (@as(usize, h) - 1) * stride + @as(usize, w) * 4)) return error.BufferTooSmall;
    if (data.len < header_len + end_marker.len) return error.Truncated;
    const body = data[header_len .. data.len - end_marker.len];
    if (!std.mem.eql(u8, data[data.len - end_marker.len ..], &end_marker)) return error.Truncated;
    var index: [64]Px = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    var px: Px = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var p: usize = 0;
    var run: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = out[@as(usize, y) * stride ..][0 .. @as(usize, w) * 4];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (run > 0) {
                run -= 1;
            } else {
                if (p >= body.len) return error.Truncated;
                const b1 = body[p];
                p += 1;
                if (b1 == op_rgb) {
                    if (p + 3 > body.len) return error.Truncated;
                    px.r = body[p];
                    px.g = body[p + 1];
                    px.b = body[p + 2];
                    p += 3;
                } else if (b1 == op_rgba) {
                    if (p + 4 > body.len) return error.Truncated;
                    px.r = body[p];
                    px.g = body[p + 1];
                    px.b = body[p + 2];
                    px.a = body[p + 3];
                    p += 4;
                } else switch (b1 & mask2) {
                    op_index => px = index[b1 & 0x3f],
                    op_diff => {
                        px.r +%= ((b1 >> 4) & 3) -% 2;
                        px.g +%= ((b1 >> 2) & 3) -% 2;
                        px.b +%= (b1 & 3) -% 2;
                    },
                    op_luma => {
                        if (p >= body.len) return error.Truncated;
                        const b2 = body[p];
                        p += 1;
                        const vg = (b1 & 0x3f) -% 32;
                        px.r +%= vg -% 8 +% ((b2 >> 4) & 0x0f);
                        px.g +%= vg;
                        px.b +%= vg -% 8 +% (b2 & 0x0f);
                    },
                    else => run = b1 & 0x3f,
                }
                index[hash(px)] = px;
            }
            switch (order) {
                .bgra => {
                    row[x * 4] = px.b;
                    row[x * 4 + 1] = px.g;
                    row[x * 4 + 2] = px.r;
                },
                .rgba => {
                    row[x * 4] = px.r;
                    row[x * 4 + 1] = px.g;
                    row[x * 4 + 2] = px.b;
                },
            }
            row[x * 4 + 3] = 255;
        }
    }
    if (run > 0 or p != body.len) return error.TooLong;
}

/// Distinct colours in a bgra8 block, counting up to `limit` (cheap flatness test: the
/// tile picker skips cells of one or two colours, which video reproduces almost exactly).
pub fn countColors(src: []const u8, stride: usize, w: u32, h: u32, limit: u32) u32 {
    var seen: [8]u32 = undefined;
    var n: u32 = 0;
    const cap = @min(limit, seen.len);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = src[@as(usize, y) * stride ..][0 .. @as(usize, w) * 4];
        var x: usize = 0;
        outer: while (x < w) : (x += 1) {
            const v = std.mem.readInt(u32, row[x * 4 ..][0..4], .little) & 0x00ff_ffff;
            for (seen[0..n]) |s| if (s == v) continue :outer;
            if (n == cap) return n + 1;
            seen[n] = v;
            n += 1;
        }
    }
    return n;
}

/// Horizontal and vertical luma steps above a threshold: a rough "how much text" score
/// for ordering tiles (sharpest first).
pub fn edgeScore(src: []const u8, stride: usize, w: u32, h: u32) u32 {
    var score: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = src[@as(usize, y) * stride ..];
        var x: usize = 1;
        while (x < w) : (x += 1) {
            const a = luma(row[(x - 1) * 4 ..][0..3]);
            const b = luma(row[x * 4 ..][0..3]);
            if (@abs(@as(i32, a) - b) > 48) score += 1;
        }
    }
    return score;
}

inline fn luma(p: *const [3]u8) i32 {
    return (@as(i32, p[0]) + 5 * @as(i32, p[1]) + 2 * @as(i32, p[2])) >> 3;
}

const testing = std.testing;

fn roundTrip(src: []const u8, stride: usize, w: u32, h: u32) !usize {
    var enc: [header_len + 64 * 64 * 4 + 8]u8 = undefined;
    const e = try encode(src, stride, w, h, &enc);
    var dec: [64 * 64 * 4]u8 = undefined;
    try decode(e, w, h, &dec, @as(usize, w) * 4, .bgra);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        for (0..w) |x| {
            const s = src[y * stride + x * 4 ..][0..3];
            const d = dec[y * w * 4 + x * 4 ..][0..4];
            try testing.expectEqualSlices(u8, s, d[0..3]);
            try testing.expectEqual(@as(u8, 255), d[3]);
        }
    }
    return e.len;
}

test "qoi round trip: flat, text-like, noise, odd sizes, strided source" {
    var buf: [64 * 4 * 80]u8 = undefined;
    // Flat white with alpha garbage: a few bytes.
    for (0..buf.len / 4) |i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], 0x12ff_ffff, .little);
    try testing.expect(try roundTrip(&buf, 64 * 4, 64, 64) < 100);
    // Black text strokes on white.
    var r = std.Random.DefaultPrng.init(1);
    for (0..64) |y| for (0..64) |x| {
        const ink = (x % 7 < 2 and y % 11 < 8) or r.random().uintLessThan(u8, 40) == 0;
        const v: u32 = if (ink) 0xff20_2020 else 0xffff_ffff;
        std.mem.writeInt(u32, buf[y * 256 + x * 4 ..][0..4], v, .little);
    };
    const text = try roundTrip(&buf, 256, 64, 64);
    try testing.expect(text < 64 * 64 * 3 / 2);
    // Noise: worst case, still exact.
    r.random().bytes(&buf);
    _ = try roundTrip(&buf, 256, 64, 64);
    // An edge cell (right and bottom of 1080p), read with a wider stride.
    _ = try roundTrip(&buf, 320, 37, 56);
    _ = try roundTrip(&buf, 256, 1, 1);
}

test "qoi encodes runs longer than 62 and the canonical header" {
    var px: [100 * 4]u8 = @splat(0);
    var enc: [maxEncodedLen(100, 1)]u8 = undefined;
    const e = try encode(&px, 400, 100, 1, &enc);
    try testing.expectEqualSlices(u8, "qoif", e[0..4]);
    try testing.expectEqual(@as(u8, 3), e[12]);
    // black from the start pixel (0,0,0,255) is one run of 62 + one of 38.
    try testing.expectEqualSlices(u8, &.{ op_run | 61, op_run | 37 }, e[header_len .. e.len - 8]);
}

test "qoi decoder rejects bad and truncated input" {
    var px: [16 * 16 * 4]u8 = undefined;
    var r = std.Random.DefaultPrng.init(7);
    r.random().bytes(&px);
    var enc: [maxEncodedLen(16, 16)]u8 = undefined;
    const e = try encode(&px, 64, 16, 16, &enc);
    var out: [16 * 16 * 4]u8 = undefined;
    try testing.expectError(error.SizeMismatch, decode(e, 16, 15, &out, 64, .rgba));
    try testing.expectError(error.BufferTooSmall, decode(e, 16, 16, out[0..100], 64, .rgba));
    try testing.expectError(error.Truncated, decode(e[0 .. e.len - 1], 16, 16, &out, 64, .rgba));
    try testing.expectError(error.Truncated, decode(e[0..20], 16, 16, &out, 64, .rgba));
    var bad = enc;
    bad[0] = 'x';
    try testing.expectError(error.BadHeader, decode(bad[0..e.len], 16, 16, &out, 64, .rgba));
    // Random bodies never write out of bounds.
    var junk: [300]u8 = undefined;
    for (0..2000) |_| {
        r.random().bytes(&junk);
        @memcpy(junk[0..header_len], e[0..header_len]);
        const n = r.random().intRangeAtMost(usize, header_len, junk.len);
        @memcpy(junk[n - 8 .. n], &end_marker);
        decode(junk[0..n], 16, 16, &out, 64, .bgra) catch {};
    }
}

test "rgba order and colour counting" {
    const px = [_]u8{ 1, 2, 3, 0, 1, 2, 3, 9, 9, 9, 9, 9, 1, 2, 3, 0 };
    var enc: [maxEncodedLen(4, 1)]u8 = undefined;
    const e = try encode(&px, 16, 4, 1, &enc);
    var out: [16]u8 = undefined;
    try decode(e, 4, 1, &out, 16, .rgba);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255 }, out[0..4]);
    try testing.expectEqual(@as(u32, 2), countColors(&px, 16, 4, 1, 8));
    try testing.expectEqual(@as(u32, 2), countColors(&px, 16, 4, 1, 1));
}
