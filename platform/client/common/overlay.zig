//! Latency overlay: telemetry snapshot to text lines to pixels.
//!
//! Platform-neutral. The client backend hands `render` a CPU-side BGRA canvas
//! (a mapped staging texture on Windows), then copies the touched rectangle
//! over the corner of the frame it is about to present. No shaders, no font
//! files: a built-in 5x7 bitmap font, drawn upper case, scaled by an integer.
//!
//! Layout (times in ms, per stage over the telemetry window):
//!
//!     MOONSEC  60 FPS  24.0 MBPS  DIRECT
//!     RTT 12.3  LOSS 0.4%  FREEZE 0
//!     STAGE   LAST   P50   P99
//!     CAP      1.2   1.1   3.4
//!     ...
//!     TOT     21.3  20.0  27.9
//!     DROP 0  FRAMES 12345
//!
//! Stages with no samples print "-" so a missing clock offset reads as
//! unknown, not zero; until the clock is synced the second line says so.

const std = @import("std");
const api = @import("platform");
const telemetry = @import("core").telemetry;

pub const glyph_w = 5;
pub const glyph_h = 7;
/// Cell size in font pixels: one column and one row of spacing.
pub const cell_w = glyph_w + 1;
pub const cell_h = glyph_h + 2;

const Glyph = [glyph_h]u5;

const glyph_table = [_]struct { u8, Glyph }{
    .{ '%', .{ 0b11000, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b00011 } },
    .{ '(', .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 } },
    .{ ')', .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 } },
    .{ '+', .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 } },
    .{ '-', .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 } },
    .{ '.', .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 } },
    .{ '/', .{ 0b00000, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000 } },
    .{ '0', .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 } },
    .{ '1', .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 } },
    .{ '2', .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 } },
    .{ '3', .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 } },
    .{ '4', .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 } },
    .{ '5', .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 } },
    .{ '6', .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 } },
    .{ '7', .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 } },
    .{ '8', .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 } },
    .{ '9', .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 } },
    .{ ':', .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 } },
    .{ '<', .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 } },
    .{ '=', .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 } },
    .{ '>', .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 } },
    .{ 'A', .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 } },
    .{ 'B', .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 } },
    .{ 'C', .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 } },
    .{ 'D', .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 } },
    .{ 'E', .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 } },
    .{ 'F', .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 } },
    .{ 'G', .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 } },
    .{ 'H', .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 } },
    .{ 'I', .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 } },
    .{ 'J', .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 } },
    .{ 'K', .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 } },
    .{ 'L', .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 } },
    .{ 'M', .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 } },
    .{ 'N', .{ 0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001 } },
    .{ 'O', .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 } },
    .{ 'P', .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 } },
    .{ 'Q', .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 } },
    .{ 'R', .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 } },
    .{ 'S', .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 } },
    .{ 'T', .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 } },
    .{ 'U', .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 } },
    .{ 'V', .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 } },
    .{ 'W', .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 } },
    .{ 'X', .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 } },
    .{ 'Y', .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 } },
    .{ 'Z', .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 } },
    .{ '_', .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 } },
    .{ '|', .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 } },
};

const glyphs: [128]?Glyph = blk: {
    var t: [128]?Glyph = .{null} ** 128;
    for (glyph_table) |e| t[e[0]] = e[1];
    break :blk t;
};

/// The 5x7 bitmap for `c` (lower case maps to upper), or null if the font
/// has no glyph for it (drawn as blank).
pub fn glyph(c: u8) ?Glyph {
    const u = std.ascii.toUpper(c);
    return if (u < 128) glyphs[u] else null;
}

/// A 32-bit BGRA pixel buffer (DXGI_FORMAT_B8G8R8A8_UNORM byte order as a
/// little-endian u32: 0xAARRGGBB). `stride` is in pixels.
pub const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn fill(c: Canvas, x: u32, y: u32, w: u32, h: u32, color: u32) void {
        const x1 = @min(c.width, x +| w);
        const y1 = @min(c.height, y +| h);
        var yy = y;
        while (yy < y1) : (yy += 1) {
            if (x >= x1) break;
            @memset(c.pixels[yy * c.stride + x .. yy * c.stride + x1], color);
        }
    }

    /// Draws `text` with its top-left at (x, y), each font pixel `scale`
    /// canvas pixels. Clips at the canvas edge.
    pub fn text(c: Canvas, x: u32, y: u32, s: []const u8, scale: u32, color: u32) void {
        for (s, 0..) |ch, i| {
            const g = glyph(ch) orelse continue;
            const gx = x + @as(u32, @intCast(i)) * cell_w * scale;
            for (g, 0..) |row, ry| {
                var col: u32 = 0;
                while (col < glyph_w) : (col += 1) {
                    if (row & (@as(u5, 1) << @intCast(glyph_w - 1 - col)) == 0) continue;
                    c.fill(gx + col * scale, y + @as(u32, @intCast(ry)) * scale, scale, scale, color);
                }
            }
        }
    }
};

/// What the overlay shows: the session's `api.Overlay` plus the frame rate
/// the presenter measured.
pub const Status = struct {
    fps: ?f32 = null,
    bitrate_bps: u64 = 0,
    rtt_us: telemetry.Micros = 0,
    loss: f32 = 0,
    relayed: bool = false,
    freezes: u32 = 0,
    clock_synced: bool = false,
    /// Multi-user presence line (`core.multi.View.presence`), empty for one client.
    presence: []const u8 = "",

    pub fn from(o: *const api.Overlay, fps: ?f32) Status {
        return .{
            .fps = fps,
            .bitrate_bps = o.bitrate_bps,
            .rtt_us = o.rtt_us,
            .loss = o.loss,
            .relayed = o.relayed,
            .freezes = o.freezes,
            .clock_synced = o.clock_synced,
            .presence = o.presence,
        };
    }
};

pub const max_cols = 40;
pub const max_lines = 12;

pub const Lines = struct {
    buf: [max_lines][max_cols]u8 = undefined,
    lens: [max_lines]u8 = .{0} ** max_lines,
    n: usize = 0,

    pub fn get(l: *const Lines, i: usize) []const u8 {
        return l.buf[i][0..l.lens[i]];
    }

    fn add(l: *Lines, comptime fmt: []const u8, args: anytype) void {
        if (l.n == max_lines) return;
        const s = std.fmt.bufPrint(&l.buf[l.n], fmt, args) catch blk: {
            // Truncate rather than drop a line that ran long.
            break :blk l.buf[l.n][0..max_cols];
        };
        l.lens[l.n] = @intCast(s.len);
        l.n += 1;
    }

    /// Widest line in characters.
    pub fn cols(l: *const Lines) usize {
        var m: usize = 0;
        for (l.lens[0..l.n]) |n| m = @max(m, n);
        return m;
    }
};

const rows = [_]struct { telemetry.Stage, []const u8 }{
    .{ .capture, "CAP" },
    .{ .encode, "ENC" },
    .{ .network, "NET" },
    .{ .decode, "DEC" },
    .{ .present, "PRS" },
    .{ .total, "TOT" },
    .{ .input, "INP" },
};

/// Milliseconds with one decimal, right-aligned in 6 columns, or "-".
const Ms = struct {
    us: ?telemetry.Micros,
    pub fn format(m: Ms, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const us = m.us orelse return w.writeAll("     -");
        const tenths = @divTrunc(us + if (us < 0) @as(i64, -50) else 50, 100);
        const neg = tenths < 0;
        const a: u64 = @abs(tenths);
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{s}{d}.{d}", .{ if (neg) "-" else "", a / 10, a % 10 }) catch unreachable;
        if (s.len < 6) try w.splatByteAll(' ', 6 - s.len);
        try w.writeAll(s);
    }
};

/// The overlay text for a snapshot.
pub fn lines(snap: *const telemetry.Snapshot, status: Status) Lines {
    var l: Lines = .{};
    var fps_buf: [12]u8 = undefined;
    var rate_buf: [16]u8 = undefined;
    const fps: []const u8 = if (status.fps) |f| std.fmt.bufPrint(&fps_buf, "{d:.0} FPS", .{f}) catch "" else "- FPS";
    const kbps = status.bitrate_bps / 1000;
    const rate: []const u8 = if (status.bitrate_bps > 0) std.fmt.bufPrint(&rate_buf, "{d}.{d} MBPS", .{ kbps / 1000, (kbps % 1000) / 100 }) catch "" else "- MBPS";
    l.add("MOONSEC  {s}  {s}  {s}", .{ fps, rate, if (status.relayed) "RELAY" else "DIRECT" });
    const loss_tenths: u32 = @intFromFloat(@round(std.math.clamp(status.loss, 0, 1) * 1000));
    if (status.clock_synced) {
        l.add("RTT{f}  LOSS {d}.{d}%  FREEZE {d}", .{ Ms{ .us = status.rtt_us }, loss_tenths / 10, loss_tenths % 10, status.freezes });
    } else {
        l.add("NO CLOCK SYNC  LOSS {d}.{d}%  FREEZE {d}", .{ loss_tenths / 10, loss_tenths % 10, status.freezes });
    }
    l.add("STAGE   LAST   P50   P99", .{});
    for (rows) |r| {
        const st = snap.stage(r[0]);
        const has = st.count > 0;
        l.add("{s}   {f}{f}{f}", .{
            r[1],
            Ms{ .us = snap.last.get(r[0]) },
            Ms{ .us = if (has) st.p50 else null },
            Ms{ .us = if (has) st.p99 else null },
        });
    }
    l.add("DROP {d}  FRAMES {d}", .{ snap.counters.frames_not_presented, snap.counters.frames });
    if (status.presence.len > 0) l.add("{s}", .{status.presence});
    return l;
}

pub const Style = struct {
    scale: u32 = 2,
    /// Padding around the text block, in font pixels.
    pad: u32 = 3,
    background: u32 = 0xE0101010,
    foreground: u32 = 0xFFE8E8E8,
    /// Colour of the header line; a relay path draws it in `relay`.
    header: u32 = 0xFF7FD7FF,
    relay: u32 = 0xFFFFB040,
};

/// Width and height in canvas pixels of the overlay for `l`.
pub fn size(l: *const Lines, style: Style) struct { w: u32, h: u32 } {
    const s = style.scale;
    return .{
        .w = (@as(u32, @intCast(l.cols())) * cell_w + 2 * style.pad) * s,
        .h = (@as(u32, @intCast(l.n)) * cell_h + 2 * style.pad) * s,
    };
}

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Draws the overlay at the canvas's top-left corner and returns the
/// rectangle it covered (clipped to the canvas), which is what the backend
/// copies over the frame.
pub fn render(c: Canvas, snap: *const telemetry.Snapshot, status: Status, style: Style) Rect {
    const l = lines(snap, status);
    return renderLines(c, &l, status.relayed, style);
}

pub fn renderLines(c: Canvas, l: *const Lines, relay: bool, style: Style) Rect {
    const sz = size(l, style);
    const r: Rect = .{ .x = 0, .y = 0, .w = @min(sz.w, c.width), .h = @min(sz.h, c.height) };
    c.fill(0, 0, r.w, r.h, style.background);
    const s = style.scale;
    for (0..l.n) |i| {
        const color = if (i == 0) (if (relay) style.relay else style.header) else style.foreground;
        c.text(style.pad * s, (style.pad + @as(u32, @intCast(i)) * cell_h) * s, l.get(i), s, color);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "every printable overlay character has a glyph" {
    var snap: telemetry.Snapshot = .{};
    snap.stages[0] = .{ .count = 1, .p50 = 1234, .p99 = -5678 };
    for ([_]bool{ false, true }) |synced| {
        const l = lines(&snap, .{ .fps = 59.9, .bitrate_bps = 24_150_000, .relayed = true, .loss = 0.0042, .rtt_us = 12_345, .clock_synced = synced, .presence = "3 here  input: Host (you)" });
        for (0..l.n) |i| for (l.get(i)) |ch| {
            if (ch == ' ') continue;
            try testing.expect(glyph(ch) != null);
        };
    }
}

test "lines: header, stage rows and unknowns" {
    var t = telemetry.Telemetry(16).init();
    t.record(.{ .frame_id = 7, .capture_start = 0, .captured = 1200, .encoded = 4500, .received = 100, .decoded = 2100, .presented = 2600 }, null);
    const snap = t.snapshot();
    const ov: api.Overlay = .{ .telemetry = snap, .bitrate_bps = 24_150_000, .loss = 0.0042, .rtt_us = 12_345, .freezes = 2, .clock_synced = true };
    var l = lines(&snap, Status.from(&ov, 60));
    try testing.expectEqualStrings("MOONSEC  60 FPS  24.1 MBPS  DIRECT", l.get(0));
    try testing.expectEqualStrings("RTT  12.3  LOSS 0.4%  FREEZE 2", l.get(1));
    l = lines(&snap, .{});
    try testing.expectEqualStrings("MOONSEC  - FPS  - MBPS  DIRECT", l.get(0));
    try testing.expectEqualStrings("NO CLOCK SYNC  LOSS 0.0%  FREEZE 0", l.get(1));
    try testing.expectEqualStrings("STAGE   LAST   P50   P99", l.get(2));
    try testing.expectEqualStrings("CAP      1.2   1.2   1.2", l.get(3));
    try testing.expectEqualStrings("ENC      3.3   3.3   3.3", l.get(4));
    // No clock offset: network and total are unknown, not zero.
    try testing.expectEqualStrings("NET        -     -     -", l.get(5));
    try testing.expectEqualStrings("DEC      2.0   2.0   2.0", l.get(6));
    try testing.expectEqualStrings("PRS      0.5   0.5   0.5", l.get(7));
    try testing.expectEqualStrings("TOT        -     -     -", l.get(8));
    try testing.expectEqualStrings("DROP 0  FRAMES 1", l.get(10));
    try testing.expectEqual(@as(usize, 11), l.n);
    // A multi-user session adds the presence line.
    l = lines(&snap, .{ .presence = "2 here  input: Alice (you)" });
    try testing.expectEqualStrings("2 here  input: Alice (you)", l.get(11));
}

test "render draws inside its rectangle and clips to the canvas" {
    var px: [200 * 60]u32 = .{0} ** (200 * 60);
    const c: Canvas = .{ .pixels = &px, .width = 200, .height = 60, .stride = 200 };
    const snap: telemetry.Snapshot = .{};
    const r = render(c, &snap, .{}, .{});
    try testing.expectEqual(@as(u32, 200), r.w); // wider than the canvas: clipped
    try testing.expectEqual(@as(u32, 60), r.h);
    var fg: usize = 0;
    for (px) |p| {
        try testing.expect(p != 0); // all background or text
        if (p == (Style{}).header) fg += 1;
    }
    try testing.expect(fg > 0);
}

test "text: glyph pixels land where the bitmap says" {
    var px: [12 * 9]u32 = .{0} ** (12 * 9);
    const c: Canvas = .{ .pixels = &px, .width = 12, .height = 9, .stride = 12 };
    c.text(0, 0, "1", 1, 1);
    // "1": row 0 is ..#.., row 6 is .###.
    try testing.expectEqual(@as(u32, 1), px[2]);
    try testing.expectEqual(@as(u32, 0), px[0]);
    try testing.expectEqual(@as(u32, 1), px[6 * 12 + 1]);
    try testing.expectEqual(@as(u32, 1), px[6 * 12 + 3]);
    try testing.expectEqual(@as(u32, 0), px[6 * 12 + 4]);
}
