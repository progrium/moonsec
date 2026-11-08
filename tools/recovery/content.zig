//! Desktop-like test content for the recovery gate on hardware encoders: a static,
//! detailed background (rows of "text" on light panels: costly to code intra, free to
//! predict), a window with its own text that slides a few pixels per frame (motion
//! vectors), and a small "video" box of fresh noise every frame (steady P-frame bits).
//! An IDR of this costs several times a P frame, as a real desktop does, so recovery
//! frames that are well under the IDR size mean something.
//!
//! Pure Zig, BGRA, deterministic in (width, height, frame).
const std = @import("std");

fn hash(x: u32) u32 {
    var h = x *% 0x9E3779B1;
    h ^= h >> 15;
    h *%= 0x85EBCA77;
    h ^= h >> 13;
    h *%= 0xC2B2AE3D;
    h ^= h >> 16;
    return h;
}

/// "Text": glyph cells of 6x10 px with 1-2 px strokes, in lines with gaps, seeded per
/// cell so it never repeats exactly. Returns ink or paper.
fn textPixel(x: u32, y: u32, seed: u32) bool {
    const line = y / 14;
    const in_line = y % 14;
    if (in_line >= 10) return false; // line gap
    const cell = x / 7;
    const cx = x % 7;
    if (cx == 6) return false; // letter gap
    const word = hash(seed ^ (line *% 7919) ^ (cell / 6) *% 104729);
    if (word % 7 == 0) return false; // space between words
    const g = hash(seed ^ (line << 16) ^ cell);
    // A 3x5 glyph bitmap scaled by 2 vertically, from the hash bits.
    const gx = @min(cx / 2, 2);
    const gy = in_line / 2;
    const bit: u5 = @intCast(gy * 3 + gx);
    return (g >> bit) & 1 == 1;
}

fn put(px: []u8, stride: u32, x: u32, y: u32, bgr: [3]u8) void {
    const o = @as(usize, y) * stride + @as(usize, x) * 4;
    px[o] = bgr[0];
    px[o + 1] = bgr[1];
    px[o + 2] = bgr[2];
    px[o + 3] = 255;
}

pub fn render(px: []u8, w: u32, h: u32, stride: u32, frame: u32) void {
    // Background: four panels with different paper colours, all covered in text.
    const papers = [_][3]u8{ .{ 250, 250, 250 }, .{ 235, 242, 248 }, .{ 245, 238, 230 }, .{ 228, 240, 228 } };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const panel = (x * 2 / w) + 2 * (y * 2 / h);
            const ink = textPixel(x, y, 0xA5A5 + panel);
            put(px, stride, x, y, if (ink) .{ 30, 30, 30 } else papers[panel]);
        }
    }
    // Title bar stripe, for some large flat area.
    const bar = @max(h / 30, 8);
    y = 0;
    while (y < bar) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) put(px, stride, x, y, .{ 90, 60, 40 });
    }

    // A sliding window: 1/3 x 1/3 of the screen, 4 px per frame, bouncing.
    const ww = w / 3;
    const wh = h / 3;
    const span_x = w - ww;
    const span_y = h - wh - bar;
    const t = frame * 4;
    const ox = if ((t / span_x) % 2 == 0) t % span_x else span_x - t % span_x;
    const oy = bar + (if (((t / 2) / span_y) % 2 == 0) (t / 2) % span_y else span_y - (t / 2) % span_y);
    y = 0;
    while (y < wh) : (y += 1) {
        var x: u32 = 0;
        while (x < ww) : (x += 1) {
            const edge = x < 2 or y < 2 or x + 2 >= ww or y + 2 >= wh;
            const ink = textPixel(x, y, 0x5EED);
            const c: [3]u8 = if (edge) .{ 120, 80, 20 } else if (y < 16) .{ 200, 140, 60 } else if (ink) .{ 20, 20, 20 } else .{ 255, 255, 255 };
            put(px, stride, ox + x, oy + y, c);
        }
    }

    // A "video" box: fresh noise every frame, 1/10 x 1/10 of the screen, fixed place.
    const vw = @max(w / 10, 16);
    const vh = @max(h / 10, 16);
    const vx = w - vw - 8;
    const vy = h - vh - 8;
    var rng = std.Random.DefaultPrng.init(0xC0FFEE ^ @as(u64, frame));
    const r = rng.random();
    y = 0;
    while (y < vh) : (y += 1) {
        var x: u32 = 0;
        while (x < vw) : (x += 1) {
            const v = r.int(u32);
            put(px, stride, vx + x, vy + y, .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16) });
        }
    }
}

test "render is deterministic and moves" {
    const w = 320;
    const h = 180;
    const a = try std.testing.allocator.alloc(u8, w * h * 4);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(u8, w * h * 4);
    defer std.testing.allocator.free(b);
    render(a, w, h, w * 4, 7);
    render(b, w, h, w * 4, 7);
    try std.testing.expectEqualSlices(u8, a, b);
    render(b, w, h, w * 4, 8);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    // Mostly static: well over half the pixels are the same one frame later.
    var same: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 4) {
        if (std.mem.eql(u8, a[i..][0..4], b[i..][0..4])) same += 1;
    }
    try std.testing.expect(same * 10 > (w * h) * 7);
}
