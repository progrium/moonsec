//! QR code encoder (ISO/IEC 18004), for showing pairing tickets on the host's screen.
//!
//! Byte and alphanumeric modes, error correction levels L/M/Q/H, versions 1–40, automatic
//! or fixed mask. No allocation: a `Code` holds the module matrix in two bitsets (~8 KiB).
//! The structure follows the well-known reference encoders (format and version bits,
//! function patterns, Reed–Solomon blocks and interleaving, zigzag placement, masks and the
//! four penalty rules); the tests check matrices against an independent encoder.
const std = @import("std");

pub const Ecc = enum(u2) {
    low = 0,
    medium = 1,
    quartile = 2,
    high = 3,

    fn formatBits(e: Ecc) u32 {
        return switch (e) {
            .low => 1,
            .medium => 0,
            .quartile => 3,
            .high => 2,
        };
    }
};

pub const Mode = enum { alphanumeric, byte };

pub const max_version = 40;
pub const max_size = 17 + 4 * max_version;
const max_raw_codewords = 3706;

// Error-correction codewords per block, and the number of blocks, by level and version
// (ISO/IEC 18004 table 9). Index 0 is unused.
const ecc_per_block = [4][41]u8{
    .{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};
const num_blocks = [4][41]u8{
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

fn numRawDataModules(ver: u32) u32 {
    var r: u32 = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
        const na = ver / 7 + 2;
        r -= (25 * na - 10) * na - 55;
        if (ver >= 7) r -= 36;
    }
    return r;
}

fn numDataCodewords(ver: u32, ecc: Ecc) u32 {
    const e = @intFromEnum(ecc);
    return numRawDataModules(ver) / 8 - @as(u32, ecc_per_block[e][ver]) * num_blocks[e][ver];
}

const alnum_chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

fn alnumValue(c: u8) ?u32 {
    const i = std.mem.indexOfScalar(u8, alnum_chars, c) orelse return null;
    return @intCast(i);
}

pub fn isAlphanumeric(text: []const u8) bool {
    for (text) |c| if (alnumValue(c) == null) return false;
    return true;
}

fn countBits(mode: Mode, ver: u32) u5 {
    const i: usize = if (ver <= 9) 0 else if (ver <= 26) 1 else 2;
    return switch (mode) {
        .alphanumeric => ([3]u5{ 9, 11, 13 })[i],
        .byte => ([3]u5{ 8, 16, 16 })[i],
    };
}

fn segmentBits(mode: Mode, n: usize, ver: u32) usize {
    const data: usize = switch (mode) {
        .alphanumeric => n / 2 * 11 + (n % 2) * 6,
        .byte => n * 8,
    };
    return 4 + @as(usize, countBits(mode, ver)) + data;
}

const BitBuf = struct {
    bytes: [max_raw_codewords]u8 = @splat(0),
    n: usize = 0,

    fn append(b: *BitBuf, value: u32, bits: u5) void {
        var i: u5 = bits;
        while (i > 0) {
            i -= 1;
            if ((value >> i) & 1 != 0) b.bytes[b.n >> 3] |= @as(u8, 0x80) >> @intCast(b.n & 7);
            b.n += 1;
        }
    }
};

// --- Reed-Solomon over GF(256), polynomial 0x11D ---------------------------------

fn gfMul(x: u8, y: u8) u8 {
    var z: u32 = 0;
    var i: u3 = 7;
    while (true) : (i -= 1) {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((@as(u32, y) >> i) & 1) * x;
        if (i == 0) break;
    }
    return @intCast(z & 0xff);
}

fn rsDivisor(degree: usize, out: []u8) void {
    @memset(out[0..degree], 0);
    out[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            out[j] = gfMul(out[j], root);
            if (j + 1 < degree) out[j] ^= out[j + 1];
        }
        root = gfMul(root, 2);
    }
}

fn rsRemainder(data: []const u8, divisor: []const u8, out: []u8) void {
    @memset(out[0..divisor.len], 0);
    for (data) |b| {
        const factor = b ^ out[0];
        std.mem.copyForwards(u8, out[0 .. divisor.len - 1], out[1..divisor.len]);
        out[divisor.len - 1] = 0;
        for (divisor, 0..) |d, i| out[i] ^= gfMul(d, factor);
    }
}

pub const Options = struct {
    ecc: Ecc = .medium,
    /// Smallest version to use (1–40).
    min_version: u8 = 1,
    max_version: u8 = max_version,
    /// null: pick the mask with the lowest penalty.
    mask: ?u3 = null,
    /// Use a higher error correction level when it fits in the same version.
    boost_ecc: bool = true,
};

pub const Error = error{ DataTooLong, BadOptions };

pub const Code = struct {
    version: u8,
    size: u8,
    ecc: Ecc,
    mask: u3,
    dark: std.StaticBitSet(max_size * max_size) = .initEmpty(),
    func: std.StaticBitSet(max_size * max_size) = .initEmpty(),

    pub fn get(c: *const Code, x: usize, y: usize) bool {
        return c.dark.isSet(y * max_size + x);
    }

    fn set(c: *Code, x: usize, y: usize, v: bool) void {
        c.dark.setValue(y * max_size + x, v);
    }

    fn setFunc(c: *Code, x: usize, y: usize, v: bool) void {
        c.set(x, y, v);
        c.func.set(y * max_size + x);
    }

    fn isFunc(c: *const Code, x: usize, y: usize) bool {
        return c.func.isSet(y * max_size + x);
    }

    /// Encodes `text` in alphanumeric mode if every character allows it, else byte mode.
    pub fn encode(out: *Code, text: []const u8, opts: Options) Error!void {
        if (opts.min_version < 1 or opts.max_version > max_version or opts.min_version > opts.max_version) return error.BadOptions;
        const mode: Mode = if (isAlphanumeric(text)) .alphanumeric else .byte;
        var ver: u32 = opts.min_version;
        var ecc = opts.ecc;
        while (true) : (ver += 1) {
            if (ver > opts.max_version) return error.DataTooLong;
            if (text.len < (@as(usize, 1) << countBits(mode, ver)) and segmentBits(mode, text.len, ver) <= numDataCodewords(ver, ecc) * 8) break;
        }
        const used = segmentBits(mode, text.len, ver);
        if (opts.boost_ecc) {
            for ([_]Ecc{ .medium, .quartile, .high }) |e| {
                if (@intFromEnum(e) > @intFromEnum(ecc) and used <= numDataCodewords(ver, e) * 8) ecc = e;
            }
        }

        // Data bits: mode, count, payload, terminator, byte padding, pad codewords.
        var bb: BitBuf = .{};
        bb.append(if (mode == .alphanumeric) 0b0010 else 0b0100, 4);
        bb.append(@intCast(text.len), countBits(mode, ver));
        switch (mode) {
            .byte => for (text) |ch| bb.append(ch, 8),
            .alphanumeric => {
                var i: usize = 0;
                while (i + 1 < text.len) : (i += 2) bb.append(alnumValue(text[i]).? * 45 + alnumValue(text[i + 1]).?, 11);
                if (i < text.len) bb.append(alnumValue(text[i]).?, 6);
            },
        }
        const cap_bits = numDataCodewords(ver, ecc) * 8;
        bb.append(0, @intCast(@min(4, cap_bits - bb.n)));
        bb.append(0, @intCast((8 - bb.n % 8) % 8));
        var pad: u32 = 0xEC;
        while (bb.n < cap_bits) : (pad ^= 0xEC ^ 0x11) bb.append(pad, 8);

        out.* = .{ .version = @intCast(ver), .size = @intCast(17 + 4 * ver), .ecc = ecc, .mask = 0 };
        out.drawFunctionPatterns();
        var all: [max_raw_codewords]u8 = undefined;
        const all_len = addEccAndInterleave(bb.bytes[0 .. cap_bits / 8], @intCast(ver), ecc, &all);
        out.drawCodewords(all[0..all_len]);

        const mask = opts.mask orelse blk: {
            var best: u3 = 0;
            var best_score: u32 = std.math.maxInt(u32);
            for (0..8) |m| {
                const mm: u3 = @intCast(m);
                out.applyMask(mm);
                out.drawFormatBits(mm);
                const s = out.penalty();
                if (s < best_score) {
                    best = mm;
                    best_score = s;
                }
                out.applyMask(mm); // XOR undoes it
            }
            break :blk best;
        };
        out.mask = mask;
        out.applyMask(mask);
        out.drawFormatBits(mask);
    }

    fn drawFunctionPatterns(c: *Code) void {
        const size: usize = c.size;
        for (0..size) |i| {
            c.setFunc(6, i, i % 2 == 0);
            c.setFunc(i, 6, i % 2 == 0);
        }
        c.drawFinder(3, 3);
        c.drawFinder(size - 4, 3);
        c.drawFinder(3, size - 4);
        var pos_buf: [7]u8 = undefined;
        const pos = alignmentPositions(c.version, &pos_buf);
        for (pos, 0..) |px, i| for (pos, 0..) |py, j| {
            const last = pos.len - 1;
            if ((i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0)) continue;
            c.drawAlignment(px, py);
        };
        c.drawFormatBits(0);
        c.drawVersion();
    }

    fn drawFinder(c: *Code, cx: usize, cy: usize) void {
        const size: isize = c.size;
        var dy: isize = -4;
        while (dy <= 4) : (dy += 1) {
            var dx: isize = -4;
            while (dx <= 4) : (dx += 1) {
                const d = @max(@abs(dx), @abs(dy));
                const x = @as(isize, @intCast(cx)) + dx;
                const y = @as(isize, @intCast(cy)) + dy;
                if (x >= 0 and x < size and y >= 0 and y < size) c.setFunc(@intCast(x), @intCast(y), d != 2 and d != 4);
            }
        }
    }

    fn drawAlignment(c: *Code, cx: usize, cy: usize) void {
        var dy: isize = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: isize = -2;
            while (dx <= 2) : (dx += 1) {
                const x: usize = @intCast(@as(isize, @intCast(cx)) + dx);
                const y: usize = @intCast(@as(isize, @intCast(cy)) + dy);
                c.setFunc(x, y, @max(@abs(dx), @abs(dy)) != 1);
            }
        }
    }

    fn drawFormatBits(c: *Code, mask: u3) void {
        const data: u32 = c.ecc.formatBits() << 3 | mask;
        var rem = data;
        for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        const bits = (data << 10 | rem) ^ 0x5412;
        const size: usize = c.size;
        const bit = struct {
            fn f(b: u32, i: usize) bool {
                return (b >> @intCast(i)) & 1 != 0;
            }
        }.f;
        for (0..6) |i| c.setFunc(8, i, bit(bits, i));
        c.setFunc(8, 7, bit(bits, 6));
        c.setFunc(8, 8, bit(bits, 7));
        c.setFunc(7, 8, bit(bits, 8));
        for (9..15) |i| c.setFunc(14 - i, 8, bit(bits, i));
        for (0..8) |i| c.setFunc(size - 1 - i, 8, bit(bits, i));
        for (8..15) |i| c.setFunc(8, size - 15 + i, bit(bits, i));
        c.setFunc(8, size - 8, true);
    }

    fn drawVersion(c: *Code) void {
        if (c.version < 7) return;
        var rem: u32 = c.version;
        for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        const bits: u32 = @as(u32, c.version) << 12 | rem;
        for (0..18) |i| {
            const v = (bits >> @intCast(i)) & 1 != 0;
            const a: usize = c.size - 11 + i % 3;
            const b: usize = i / 3;
            c.setFunc(a, b, v);
            c.setFunc(b, a, v);
        }
    }

    fn drawCodewords(c: *Code, data: []const u8) void {
        const size: usize = c.size;
        var i: usize = 0;
        var right: isize = @intCast(size - 1);
        while (right >= 1) : (right -= 2) {
            if (right == 6) right = 5;
            const r: usize = @intCast(right);
            for (0..size) |vert| for (0..2) |j| {
                const x = r - j;
                const upward = ((r + 1) & 2) == 0;
                const y = if (upward) size - 1 - vert else vert;
                if (!c.isFunc(x, y) and i < data.len * 8) {
                    c.set(x, y, (data[i >> 3] >> @intCast(7 - (i & 7))) & 1 != 0);
                    i += 1;
                }
            };
        }
    }

    fn applyMask(c: *Code, mask: u3) void {
        const size: usize = c.size;
        for (0..size) |y| for (0..size) |x| {
            if (c.isFunc(x, y)) continue;
            const inv = switch (mask) {
                0 => (x + y) % 2 == 0,
                1 => y % 2 == 0,
                2 => x % 3 == 0,
                3 => (x + y) % 3 == 0,
                4 => (x / 3 + y / 2) % 2 == 0,
                5 => x * y % 2 + x * y % 3 == 0,
                6 => (x * y % 2 + x * y % 3) % 2 == 0,
                7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
            };
            if (inv) c.dark.toggle(y * max_size + x);
        };
    }

    /// ISO/IEC 18004 penalty rules N1 (runs), N2 (2x2 blocks), N3 (finder-like), N4 (balance).
    fn penalty(c: *const Code) u32 {
        const size: usize = c.size;
        var score: u32 = 0;
        for (0..2) |dir| {
            for (0..size) |a| {
                var run: u32 = 0;
                var prev = false;
                var bits: u32 = 0; // last 11 modules along the line
                for (0..size) |b| {
                    const v = if (dir == 0) c.get(b, a) else c.get(a, b);
                    if (b > 0 and v == prev) {
                        run += 1;
                        if (run == 5) score += 3 else if (run > 5) score += 1;
                    } else {
                        run = 1;
                        prev = v;
                    }
                    bits = ((bits << 1) | @intFromBool(v)) & 0x7ff;
                    if (b >= 10 and (bits == 0b10111010000 or bits == 0b00001011101)) score += 40;
                }
            }
        }
        for (0..size - 1) |y| for (0..size - 1) |x| {
            const v = c.get(x, y);
            if (v == c.get(x + 1, y) and v == c.get(x, y + 1) and v == c.get(x + 1, y + 1)) score += 3;
        };
        var dark: u32 = 0;
        for (0..size) |y| for (0..size) |x| {
            dark += @intFromBool(c.get(x, y));
        };
        const total: u32 = @intCast(size * size);
        const k = (@as(u32, @intCast(@abs(@as(i64, dark) * 20 - @as(i64, total) * 10))) + total - 1) / total - 1;
        score += k * 10;
        return score;
    }

    /// Text rendering with Unicode half blocks: two module rows per line, dark modules as
    /// ink, with a quiet zone. Readable by phone cameras from most terminals.
    pub fn writeText(c: *const Code, w: *std.Io.Writer, quiet: u8) std.Io.Writer.Error!void {
        const size: isize = c.size;
        const q: isize = quiet;
        var y: isize = -q;
        while (y < size + q) : (y += 2) {
            var x: isize = -q;
            while (x < size + q) : (x += 1) {
                const top = c.getSafe(x, y);
                const bot = c.getSafe(x, y + 1);
                // Light-on-dark terminals: print light modules as ink so the code is not inverted.
                const s = switch (@as(u2, @intFromBool(!top)) << 1 | @intFromBool(!bot)) {
                    0 => " ",
                    1 => "\u{2584}",
                    2 => "\u{2580}",
                    3 => "\u{2588}",
                };
                try w.writeAll(s);
            }
            try w.writeByte('\n');
        }
    }

    fn getSafe(c: *const Code, x: isize, y: isize) bool {
        if (x < 0 or y < 0 or x >= c.size or y >= c.size) return false;
        return c.get(@intCast(x), @intCast(y));
    }

    /// SVG with one path, `scale` pixels per module and a 4-module quiet zone.
    pub fn writeSvg(c: *const Code, w: *std.Io.Writer, scale: u32) std.Io.Writer.Error!void {
        const dim = (@as(u32, c.size) + 8) * scale;
        try w.print("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" shape-rendering=\"crispEdges\">", .{ c.size + 8, c.size + 8, dim, dim });
        try w.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"#fff\"/><path fill=\"#000\" d=\"");
        for (0..c.size) |y| for (0..c.size) |x| {
            if (c.get(x, y)) try w.print("M{d} {d}h1v1h-1z", .{ x + 4, y + 4 });
        };
        try w.writeAll("\"/></svg>\n");
    }

    /// Binary PPM (P6) with `scale` pixels per module and a 4-module quiet zone.
    pub fn writePpm(c: *const Code, w: *std.Io.Writer, scale: u32) std.Io.Writer.Error!void {
        const dim = (@as(usize, c.size) + 8) * scale;
        try w.print("P6\n{d} {d}\n255\n", .{ dim, dim });
        for (0..dim) |py| for (0..dim) |px| {
            const x = @as(isize, @intCast(px / scale)) - 4;
            const y = @as(isize, @intCast(py / scale)) - 4;
            const v: u8 = if (c.getSafe(x, y)) 0 else 255;
            try w.writeAll(&.{ v, v, v });
        };
    }
};

fn alignmentPositions(ver: u8, buf: *[7]u8) []const u8 {
    if (ver == 1) return buf[0..0];
    const na: usize = ver / 7 + 2;
    const v: usize = ver;
    const step: usize = (v * 8 + na * 3 + 5) / (na * 4 - 4) * 2;
    buf[0] = 6;
    var pos: usize = 17 + 4 * v - 7;
    var i: usize = na - 1;
    while (i >= 1) : (i -= 1) {
        buf[i] = @intCast(pos);
        pos -%= step;
    }
    return buf[0..na];
}

fn addEccAndInterleave(data: []const u8, ver: u8, ecc: Ecc, out: *[max_raw_codewords]u8) usize {
    const e = @intFromEnum(ecc);
    const nb: usize = num_blocks[e][ver];
    const ecc_len: usize = ecc_per_block[e][ver];
    const raw: usize = numRawDataModules(ver) / 8;
    const num_short = nb - raw % nb;
    const short_len = raw / nb;
    var div: [30]u8 = undefined;
    rsDivisor(ecc_len, &div);
    // blocks[i] = data ++ (pad byte if short) ++ ecc, each short_len + 1 long.
    var blocks: [81][160]u8 = undefined;
    var k: usize = 0;
    for (0..nb) |i| {
        const dlen = short_len - ecc_len + @as(usize, if (i < num_short) 0 else 1);
        const dat = data[k .. k + dlen];
        k += dlen;
        @memcpy(blocks[i][0..dlen], dat);
        var off = dlen;
        if (i < num_short) {
            blocks[i][off] = 0;
            off += 1;
        }
        rsRemainder(dat, div[0..ecc_len], blocks[i][off..][0..ecc_len]);
    }
    var n: usize = 0;
    for (0..short_len + 1) |i| for (0..nb) |j| {
        if (i != short_len - ecc_len or j >= num_short) {
            out[n] = blocks[j][i];
            n += 1;
        }
    };
    std.debug.assert(n == raw);
    return n;
}

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const vectors = @import("qr_vectors.zig");

test "capacity tables: data codewords for a few known versions" {
    // ISO/IEC 18004 table 7.
    try testing.expectEqual(@as(u32, 19), numDataCodewords(1, .low));
    try testing.expectEqual(@as(u32, 16), numDataCodewords(1, .medium));
    try testing.expectEqual(@as(u32, 9), numDataCodewords(1, .high));
    try testing.expectEqual(@as(u32, 2334), numDataCodewords(40, .medium));
    try testing.expectEqual(@as(u32, 1276), numDataCodewords(40, .high));
    try testing.expectEqual(@as(u32, 2956), numDataCodewords(40, .low));
    try testing.expectEqual(@as(u32, 3706), numRawDataModules(40) / 8);
}

test "Reed-Solomon: the 'HELLO WORLD' 1-M example's error correction bytes" {
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17 };
    var div: [10]u8 = undefined;
    rsDivisor(10, &div);
    var rem: [10]u8 = undefined;
    rsRemainder(&data, &div, &rem);
    try testing.expectEqualSlices(u8, &.{ 196, 35, 39, 119, 235, 215, 231, 226, 93, 23 }, &rem);
}

test "matrices match an independent encoder (python-qrcode), both modes, every level, versions 1-40" {
    for (vectors.cases) |v| {
        var code: Code = undefined;
        try code.encode(v.text, .{ .ecc = v.ecc, .min_version = v.version, .max_version = v.version, .mask = v.mask, .boost_ecc = false });
        try testing.expectEqual(v.version, code.version);
        const size: usize = code.size;
        var want: [(max_size * max_size + 7) / 8]u8 = undefined;
        const wb = try std.fmt.hexToBytes(&want, v.bits);
        try testing.expectEqual((size * size + 7) / 8, wb.len);
        var bad: usize = 0;
        for (0..size) |y| for (0..size) |x| {
            const i = y * size + x;
            const w = (wb[i / 8] >> @intCast(7 - i % 8)) & 1 != 0;
            if (w != code.get(x, y)) bad += 1;
        };
        if (bad != 0) {
            std.debug.print("version {d} {t} mask {d}: {d} modules differ\n", .{ v.version, v.ecc, v.mask, bad });
            return error.TestUnexpectedResult;
        }
    }
}

test "automatic version and mask; tickets fit; too long fails" {
    var code: Code = undefined;
    try code.encode("HELLO WORLD", .{ .ecc = .medium, .boost_ecc = false });
    try testing.expectEqual(@as(u8, 1), code.version);
    try testing.expectEqual(@as(u8, 21), code.size);
    // A ticket with a typical iroh address (~150 chars) lands well under version 20.
    const t = "MOONSEC1:" ++ "A" ** 330;
    try code.encode(t, .{});
    try testing.expect(code.version <= 12);
    const huge = "x" ** 3000;
    try testing.expectError(error.DataTooLong, code.encode(huge, .{}));
    try testing.expectError(error.BadOptions, code.encode("x", .{ .min_version = 0 }));
}

test "renderers produce the expected sizes" {
    var code: Code = undefined;
    try code.encode("HELLO", .{});
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try code.writeText(&w, 2);
    const lines = std.mem.count(u8, w.buffered(), "\n");
    try testing.expectEqual(@as(usize, (21 + 4 + 1) / 2), lines);
    w = .fixed(&buf);
    try code.writePpm(&w, 2);
    try testing.expectEqual(@as(usize, "P6\n58 58\n255\n".len + 58 * 58 * 3), w.buffered().len);
    w = .fixed(&buf);
    try code.writeSvg(&w, 4);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "<svg"));
}
