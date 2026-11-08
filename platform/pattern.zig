//! The measurement test pattern: a BGRA picture that carries its own capture time and
//! frame number, readable by a program (a barcode) and by a person or camera (digits), with
//! a flash square for a photodiode.
//!
//! Layout, top to bottom:
//!   barcode   a start marker, then 112 black/white cells: capture time (u64 µs, host clock),
//!             frame number (u32) and a CRC-16 of both. Cells are at least 4 px wide and the
//!             band is h/8 tall, so the code survives scaling and lossy video codecs.
//!   digits    the capture time in milliseconds, mod 10^8, as seven-segment digits.
//!   flash     a square at the right that is white for the first `flash_ms` of every second
//!             of the capture clock and black otherwise. Tape a photodiode on the host
//!             screen and one on the client screen; the edge-to-edge delay is glass-to-glass.
//!   motion    a vertical bar that moves one step per frame, so a repeated frame is visible.
//!
//! `render` draws the pattern; `read` gets the stamp back from a picture (the synthetic
//! client checks every presented frame with it, and it reads screenshots or camera frames
//! after cropping); `readDigits` reads the digits when the barcode does not survive.
//! tools/latency turns these into glass-to-glass numbers. Pure Zig, no allocation.
const std = @import("std");

pub const Stamp = struct {
    /// Capture clock, microseconds.
    time_us: u64,
    frame: u32,
};

pub const flash_ms = 100;
pub const min_width = 128;
pub const min_height = 64;

const time_bits = 64;
const frame_bits = 32;
const crc_bits = 16;
const data_bits = time_bits + frame_bits + crc_bits;
/// Start marker: white, black, white, black (4 cells) before the data.
const marker_cells = 4;
const total_cells = marker_cells + data_bits;

const white = [4]u8{ 255, 255, 255, 255 };
const black = [4]u8{ 0, 0, 0, 255 };

pub fn crc16(time_us: u64, frame: u32) u16 {
    var b: [12]u8 = undefined;
    std.mem.writeInt(u64, b[0..8], time_us, .little);
    std.mem.writeInt(u32, b[8..12], frame, .little);
    return std.hash.crc.Crc16IbmSdlc.hash(&b);
}

const Layout = struct {
    w: u32,
    h: u32,
    bar_h: u32,
    cell_w: u32,
    code_x: u32,
    digits_y: u32,
    digits_h: u32,
    flash: u32,

    fn of(w: u32, h: u32) Layout {
        const bar_h = @max(h / 8, 4);
        const cell_w = @max(w / total_cells, 1);
        const flash = @min(h / 4, w / 4);
        return .{
            .w = w,
            .h = h,
            .bar_h = bar_h,
            .cell_w = cell_w,
            .code_x = (w - cell_w * total_cells) / 2,
            .digits_y = bar_h + h / 32,
            .digits_h = h / 5,
            .flash = flash,
        };
    }
};

fn bitOf(s: Stamp, crc: u16, i: usize) bool {
    if (i < time_bits) return (s.time_us >> @intCast(time_bits - 1 - i)) & 1 == 1;
    const j = i - time_bits;
    if (j < frame_bits) return (s.frame >> @intCast(frame_bits - 1 - j)) & 1 == 1;
    const k = j - frame_bits;
    return (crc >> @intCast(crc_bits - 1 - k)) & 1 == 1;
}

fn fill(px: []u8, stride: u32, x0: u32, y0: u32, x1: u32, y1: u32, c: [4]u8) void {
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = px[y * stride ..];
        var x = x0;
        while (x < x1) : (x += 1) @memcpy(row[x * 4 ..][0..4], &c);
    }
}

/// Draw the pattern for `s` into `px` (BGRA rows of `stride` bytes). `w` ≥ `min_width`,
/// `h` ≥ `min_height`.
pub fn render(px: []u8, w: u32, h: u32, stride: u32, s: Stamp) void {
    std.debug.assert(w >= min_width and h >= min_height and stride >= w * 4 and px.len >= stride * h);
    const l = Layout.of(w, h);
    // Background: dark grey, so black and white cells stand out from it.
    const bg = [4]u8{ 48, 48, 48, 255 };
    fill(px, stride, 0, 0, w, h, bg);
    // Motion bar: steps 1/64 of the width per frame.
    const bar_w = @max(w / 64, 2);
    const bx = (s.frame % 64) * (w / 64);
    fill(px, stride, bx, l.digits_y + l.digits_h, @min(bx + bar_w, w), h, .{ 0, 160, 255, 255 });
    // Barcode.
    const crc = crc16(s.time_us, s.frame);
    for (0..total_cells) |i| {
        const on = if (i < marker_cells) i % 2 == 0 else bitOf(s, crc, i - marker_cells);
        const x0 = l.code_x + @as(u32, @intCast(i)) * l.cell_w;
        fill(px, stride, x0, 0, x0 + l.cell_w, l.bar_h, if (on) white else black);
    }
    // Digits: milliseconds mod 10^8.
    const ms = (s.time_us / 1000) % 100_000_000;
    drawNumber(px, stride, l, ms);
    // Flash square, bottom right.
    const lit = (s.time_us / 1000) % 1000 < flash_ms;
    fill(px, stride, w - l.flash, h - l.flash, w, h, if (lit) white else black);
}

/// Whether the flash square is lit at capture time `time_us`.
pub fn flashOn(time_us: u64) bool {
    return (time_us / 1000) % 1000 < flash_ms;
}

// Seven segments: a (top), b (top right), c (bottom right), d (bottom), e (bottom left),
// f (top left), g (middle).
const seg_masks = [10]u7{ 0b0111111, 0b0000110, 0b1011011, 0b1001111, 0b1100110, 0b1101101, 0b1111101, 0b0000111, 0b1111111, 0b1101111 };

const DigitGeom = struct {
    const n_digits = 8;
    dw: u32,
    dh: u32,
    t: u32,
    y: u32,

    fn of(l: Layout) ?DigitGeom {
        const dh = l.digits_h;
        const dw = @min(dh / 2, (l.w - l.flash) * 4 / (5 * n_digits + 6));
        if (dw < 3 or dh < 5) return null;
        return .{ .dw = dw, .dh = dh, .t = @max(dw / 5, 1), .y = l.digits_y };
    }

    /// Rectangles (x0, y0, x1, y1) of digit `i`'s segments a..g, most significant first.
    fn segments(g: DigitGeom, i: u32) [7][4]u32 {
        const x = g.dw / 2 + i * (g.dw + g.dw / 4);
        const y = g.y;
        const dw = g.dw;
        const dh = g.dh;
        const t = g.t;
        const half = dh / 2;
        return .{
            .{ x, y, x + dw, y + t }, // a
            .{ x + dw - t, y, x + dw, y + half }, // b
            .{ x + dw - t, y + half, x + dw, y + dh }, // c
            .{ x, y + dh - t, x + dw, y + dh }, // d
            .{ x, y + half, x + t, y + dh }, // e
            .{ x, y, x + t, y + half }, // f
            .{ x, y + half - t / 2, x + dw, y + half - t / 2 + t }, // g
        };
    }
};

fn drawNumber(px: []u8, stride: u32, l: Layout, value: u64) void {
    const g = DigitGeom.of(l) orelse return;
    var v = value;
    var i: u32 = DigitGeom.n_digits;
    while (i > 0) {
        i -= 1;
        const d: usize = @intCast(v % 10);
        v /= 10;
        const m = seg_masks[d];
        for (g.segments(i), 0..) |r, si| {
            if ((m >> @intCast(si)) & 1 == 1) fill(px, stride, r[0], r[1], r[2], r[3], white);
        }
    }
}

fn luma(px: []const u8, stride: u32, x: u32, y: u32) u32 {
    const p = px[y * stride + x * 4 ..][0..4];
    return (@as(u32, p[0]) * 29 + @as(u32, p[1]) * 150 + @as(u32, p[2]) * 77) >> 8;
}

/// Read the stamp back from a BGRA picture of the pattern (same size it was rendered at,
/// or scaled; lossy codecs are fine). Null when the marker or the CRC does not match.
pub fn read(px: []const u8, w: u32, h: u32, stride: u32) ?Stamp {
    if (w < min_width or h < min_height) return null;
    const l = Layout.of(w, h);
    const y = l.bar_h / 2;
    var bits: [total_cells]bool = undefined;
    for (&bits, 0..) |*b, i| {
        const x = l.code_x + @as(u32, @intCast(i)) * l.cell_w + l.cell_w / 2;
        b.* = luma(px, stride, x, y) >= 128;
    }
    for (0..marker_cells) |i| if (bits[i] != (i % 2 == 0)) return null;
    var time_us: u64 = 0;
    var frame: u32 = 0;
    var crc: u16 = 0;
    const d = bits[marker_cells..];
    for (0..time_bits) |i| time_us = (time_us << 1) | @intFromBool(d[i]);
    for (0..frame_bits) |i| frame = (frame << 1) | @intFromBool(d[time_bits + i]);
    for (0..crc_bits) |i| crc = (crc << 1) | @intFromBool(d[time_bits + frame_bits + i]);
    if (crc != crc16(time_us, frame)) return null;
    return .{ .time_us = time_us, .frame = frame };
}

/// Read the seven-segment digits back: the capture time in milliseconds, mod 10^8. For
/// camera frames whose barcode does not survive (blur, glare, a frame caught mid-refresh);
/// null unless all eight digits are clean. Same geometry rules as `read`.
pub fn readDigits(px: []const u8, w: u32, h: u32, stride: u32) ?u64 {
    if (w < min_width or h < min_height) return null;
    const l = Layout.of(w, h);
    const g = DigitGeom.of(l) orelse return null;
    var v: u64 = 0;
    for (0..DigitGeom.n_digits) |i| {
        const segs = g.segments(@intCast(i));
        var m: u7 = 0;
        for (segs, 0..) |r, si| {
            const on = luma(px, stride, (r[0] + r[2]) / 2, (r[1] + r[3]) / 2) >= 128;
            if (on) m |= @as(u7, 1) << @intCast(si);
        }
        const d = std.mem.indexOfScalar(u7, &seg_masks, m) orelse return null;
        v = v * 10 + d;
    }
    return v;
}

/// Write the picture as a binary PPM (for looking at the pattern, or feeding a camera test).
pub fn writePpm(w: *std.Io.Writer, px: []const u8, width: u32, height: u32, stride: u32) !void {
    try w.print("P6\n{d} {d}\n255\n", .{ width, height });
    for (0..height) |y| {
        const row = px[y * stride ..];
        for (0..width) |x| {
            const p = row[x * 4 ..][0..4];
            try w.writeAll(&.{ p[2], p[1], p[0] });
        }
    }
}

const testing = std.testing;

test "render then read round trips" {
    const w = 320;
    const h = 180;
    var px: [w * h * 4]u8 = undefined;
    const cases = [_]Stamp{
        .{ .time_us = 0, .frame = 0 },
        .{ .time_us = 1_234_567_890, .frame = 77 },
        .{ .time_us = std.math.maxInt(u64), .frame = std.math.maxInt(u32) },
    };
    for (cases) |s| {
        render(&px, w, h, w * 4, s);
        try testing.expectEqual(@as(?Stamp, s), read(&px, w, h, w * 4));
    }
}

test "read survives noise and rejects a damaged code" {
    const w = 256;
    const h = 128;
    var px: [w * h * 4]u8 = undefined;
    const s: Stamp = .{ .time_us = 98_765_432_100, .frame = 4242 };
    render(&px, w, h, w * 4, s);
    // Codec-like noise: ±40 on every byte.
    var prng = std.Random.DefaultPrng.init(3);
    for (&px) |*b| {
        const n: i32 = prng.random().intRangeAtMost(i32, -40, 40);
        b.* = @intCast(std.math.clamp(@as(i32, b.*) + n, 0, 255));
    }
    try testing.expectEqual(@as(?Stamp, s), read(&px, w, h, w * 4));
    // Flip one data cell: the CRC catches it.
    const l = Layout.of(w, h);
    const x0 = l.code_x + (marker_cells + 10) * l.cell_w;
    const was = luma(&px, w * 4, x0 + l.cell_w / 2, l.bar_h / 2) >= 128;
    fill(&px, w * 4, x0, 0, x0 + l.cell_w, l.bar_h, if (was) black else white);
    try testing.expectEqual(@as(?Stamp, null), read(&px, w, h, w * 4));
}

test "flash square follows the clock" {
    const w = 128;
    const h = 64;
    var px: [w * h * 4]u8 = undefined;
    render(&px, w, h, w * 4, .{ .time_us = 5_050_000, .frame = 1 });
    try testing.expect(luma(&px, w * 4, w - 2, h - 2) > 200);
    render(&px, w, h, w * 4, .{ .time_us = 5_150_000, .frame = 2 });
    try testing.expect(luma(&px, w * 4, w - 2, h - 2) < 50);
    try testing.expect(flashOn(7_000_000) and !flashOn(7_100_000));
}

test "digits read back, and a smudged digit is rejected" {
    const w = 320;
    const h = 180;
    var px: [w * h * 4]u8 = undefined;
    for ([_]u64{ 0, 1_234_567_890, 99_999_999_999, 31_415_926_535 }) |t_ms| {
        render(&px, w, h, w * 4, .{ .time_us = t_ms * 1000 + 999, .frame = 3 });
        try testing.expectEqual(@as(?u64, t_ms % 100_000_000), readDigits(&px, w, h, w * 4));
    }
    // Wipe the barcode: the digits still read, the barcode does not.
    const l = Layout.of(w, h);
    fill(&px, w * 4, 0, 0, w, l.bar_h, black);
    try testing.expectEqual(@as(?Stamp, null), read(&px, w, h, w * 4));
    try testing.expect(readDigits(&px, w, h, w * 4) != null);
    // Light every segment of the first digit: 8 is valid, so light only b and e instead.
    const g = DigitGeom.of(l).?;
    const segs = g.segments(0);
    fill(&px, w * 4, segs[0][0], segs[0][1], segs[3][2], segs[3][3], [4]u8{ 48, 48, 48, 255 });
    for ([_]usize{ 1, 4 }) |si| fill(&px, w * 4, segs[si][0], segs[si][1], segs[si][2], segs[si][3], white);
    try testing.expectEqual(@as(?u64, null), readDigits(&px, w, h, w * 4));
}
