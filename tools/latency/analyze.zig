//! Glass-to-glass from what a photodiode or a camera saw. Both read the measurement
//! pattern (platform/pattern.zig) on the host's screen and the client's.
//!
//! Photodiode: a CSV of samples `t_us,host,client` (time in µs, then one level per
//! diode in any unit: ADC counts, volts). Each channel's rising and falling edges are
//! found at the midpoint of its range, with hysteresis, and interpolated between samples;
//! each client edge pairs with the latest host edge of the same direction. The flash
//! square changes twice a second, so one sample per edge and under 900 ms of latency.
//!
//! Frames (camera or screenshots): PNM pictures (P5 grey or P6 RGB; `ffmpeg -i v.mp4
//! -f image2pipe -c:v ppm out.ppm` gives a stream of them) that each show both screens.
//! Each frame's host and client crops are read with `pattern.read` (the barcode, µs),
//! falling back to `pattern.readDigits` (ms); the sample is host time minus client time.
//! Host and client screens refresh on their own frame grids, so single samples are
//! quantized to frames: use the mean, not a percentile, of many frames.
const std = @import("std");
const pattern = @import("platform").pattern;

const Io = std.Io;
const Micros = i64;

pub const Stats = struct {
    n: usize = 0,
    mean_us: f64 = 0,
    p50_us: Micros = 0,
    p95_us: Micros = 0,
    p99_us: Micros = 0,
    min_us: Micros = 0,
    max_us: Micros = 0,

    pub fn of(gpa: std.mem.Allocator, samples: []const Micros) !Stats {
        if (samples.len == 0) return .{};
        const s = try gpa.dupe(Micros, samples);
        defer gpa.free(s);
        std.mem.sort(Micros, s, {}, std.sort.asc(Micros));
        var sum: f64 = 0;
        for (s) |v| sum += @floatFromInt(v);
        return .{
            .n = s.len,
            .mean_us = sum / @as(f64, @floatFromInt(s.len)),
            .p50_us = pct(s, 50),
            .p95_us = pct(s, 95),
            .p99_us = pct(s, 99),
            .min_us = s[0],
            .max_us = s[s.len - 1],
        };
    }

    /// Nearest rank.
    fn pct(sorted: []const Micros, p: usize) Micros {
        const rank = (sorted.len * p + 99) / 100;
        return sorted[@max(rank, 1) - 1];
    }
};

pub fn ms(us: anytype) f64 {
    return switch (@typeInfo(@TypeOf(us))) {
        .float, .comptime_float => us / 1000,
        else => @as(f64, @floatFromInt(us)) / 1000,
    };
}

// ---------------------------------------------------------------------------
// Photodiode

pub const PhotodiodeOptions = struct {
    /// A client edge more than this after the latest host edge is not paired.
    max_latency_us: Micros = 500_000,
    /// Hysteresis band, as a share of the channel's range on each side of the midpoint.
    hysteresis: f64 = 0.15,
};

pub const PhotodiodeResult = struct {
    samples: []Micros,
    host_edges: usize,
    client_edges: usize,
    /// Client edges with no host edge within `max_latency_us` before them.
    unmatched: usize,

    pub fn deinit(r: *PhotodiodeResult, gpa: std.mem.Allocator) void {
        gpa.free(r.samples);
    }
};

const Edge = struct { t: f64, rising: bool };

/// Edges of one channel. `t` and `v` are the sample times and levels.
fn edges(gpa: std.mem.Allocator, t: []const f64, v: []const f64, hysteresis: f64) ![]Edge {
    const sorted = try gpa.dupe(f64, v);
    defer gpa.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    // 2nd and 98th percentiles, so a spike does not set the range.
    const lo_v = sorted[sorted.len * 2 / 100];
    const hi_v = sorted[sorted.len * 98 / 100];
    const range = hi_v - lo_v;
    if (!(range > 0)) return error.NoSignal;
    const mid = (lo_v + hi_v) / 2;
    const lo = mid - range * hysteresis;
    const hi = mid + range * hysteresis;

    var out: std.ArrayList(Edge) = .empty;
    errdefer out.deinit(gpa);
    // Start in whichever state the first sample is clearly in.
    var high: ?bool = if (v[0] >= hi) true else if (v[0] <= lo) false else null;
    var cross: ?f64 = null; // where the level last crossed the midpoint
    for (1..v.len) |i| {
        const a = v[i - 1];
        const b = v[i];
        if ((a < mid) != (b < mid)) cross = t[i - 1] + (t[i] - t[i - 1]) * (mid - a) / (b - a);
        if (high != true and b >= hi) {
            if (high != null) try out.append(gpa, .{ .t = cross orelse t[i], .rising = true });
            high = true;
        } else if (high != false and b <= lo) {
            if (high != null) try out.append(gpa, .{ .t = cross orelse t[i], .rising = false });
            high = false;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Parse the CSV and pair the edges. Lines that are empty, start with `#`, or do not
/// start with a number (a header) are skipped; fields split on commas, tabs or spaces.
pub fn photodiode(gpa: std.mem.Allocator, text: []const u8, o: PhotodiodeOptions) !PhotodiodeResult {
    var ts: std.ArrayList(f64) = .empty;
    defer ts.deinit(gpa);
    var hs: std.ArrayList(f64) = .empty;
    defer hs.deinit(gpa);
    var cs: std.ArrayList(f64) = .empty;
    defer cs.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, ", \t");
        const first = f.next() orelse continue;
        if (first[0] == '#') continue;
        const t = std.fmt.parseFloat(f64, first) catch continue;
        const h = std.fmt.parseFloat(f64, f.next() orelse return error.BadCsv) catch return error.BadCsv;
        const c = std.fmt.parseFloat(f64, f.next() orelse return error.BadCsv) catch return error.BadCsv;
        if (ts.items.len > 0 and t <= ts.items[ts.items.len - 1]) return error.BadCsv; // time must increase
        try ts.append(gpa, t);
        try hs.append(gpa, h);
        try cs.append(gpa, c);
    }
    if (ts.items.len < 4) return error.NoSignal;
    const he = try edges(gpa, ts.items, hs.items, o.hysteresis);
    defer gpa.free(he);
    const ce = try edges(gpa, ts.items, cs.items, o.hysteresis);
    defer gpa.free(ce);

    var samples: std.ArrayList(Micros) = .empty;
    errdefer samples.deinit(gpa);
    var unmatched: usize = 0;
    // Each host edge pairs at most once: a glitch on the client does not count twice.
    var used = try gpa.alloc(bool, he.len);
    defer gpa.free(used);
    @memset(used, false);
    for (ce) |c| {
        var best: ?usize = null;
        for (he, 0..) |h, i| {
            if (h.t > c.t) break;
            if (h.rising == c.rising) best = i;
        }
        const i = best orelse {
            unmatched += 1;
            continue;
        };
        const lat: Micros = @intFromFloat(@round(c.t - he[i].t));
        if (used[i] or lat > o.max_latency_us) {
            unmatched += 1;
            continue;
        }
        used[i] = true;
        try samples.append(gpa, lat);
    }
    return .{ .samples = try samples.toOwnedSlice(gpa), .host_edges = he.len, .client_edges = ce.len, .unmatched = unmatched };
}

// ---------------------------------------------------------------------------
// Pictures

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    /// "X,Y,W,H".
    pub fn parse(s: []const u8) !Rect {
        var it = std.mem.splitScalar(u8, s, ',');
        var v: [4]u32 = undefined;
        for (&v) |*x| x.* = try std.fmt.parseInt(u32, it.next() orelse return error.BadRect, 10);
        if (it.next() != null) return error.BadRect;
        return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
    }
};

/// One PNM picture: 1 (grey) or 3 (RGB) bytes a pixel, rows packed.
pub const Picture = struct {
    width: u32,
    height: u32,
    channels: u8,
    data: []const u8,

    /// Copy `r` out as BGRA (what the pattern reader takes) into `out`.
    pub fn cropBgra(p: Picture, r: Rect, out: []u8) !void {
        if (r.w == 0 or r.h == 0 or r.x + r.w > p.width or r.y + r.h > p.height) return error.CropOutside;
        std.debug.assert(out.len >= r.w * r.h * 4);
        for (0..r.h) |y| {
            const row = p.data[(r.y + y) * p.width * p.channels ..];
            for (0..r.w) |x| {
                const s = row[(r.x + x) * p.channels ..];
                const o = out[(y * r.w + x) * 4 ..][0..4];
                if (p.channels == 1) {
                    o.* = .{ s[0], s[0], s[0], 255 };
                } else {
                    o.* = .{ s[2], s[1], s[0], 255 };
                }
            }
        }
    }
};

fn pnmToken(r: *Io.Reader, buf: []u8) ![]const u8 {
    var n: usize = 0;
    while (true) {
        const c = try r.takeByte();
        if (c == '#') {
            while (try r.takeByte() != '\n') {}
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            if (n > 0) return buf[0..n];
            continue;
        }
        if (n == buf.len) return error.BadPnm;
        buf[n] = c;
        n += 1;
    }
}

/// Reads PNM pictures one after another from a stream (a file may hold many).
pub const PnmReader = struct {
    r: *Io.Reader,
    pixels: std.ArrayList(u8) = .empty,

    pub fn deinit(p: *PnmReader, gpa: std.mem.Allocator) void {
        p.pixels.deinit(gpa);
    }

    /// The next picture, valid until the next call; null at the end of the stream.
    pub fn next(p: *PnmReader, gpa: std.mem.Allocator) !?Picture {
        // Skip whitespace between pictures; end of stream here is the clean end.
        while (true) {
            const c = p.r.peekByte() catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return e,
            };
            if (!std.ascii.isWhitespace(c)) break;
            p.r.toss(1);
        }
        var tb: [16]u8 = undefined;
        const magic = pnmToken(p.r, &tb) catch return error.BadPnm;
        const channels: u8 = if (std.mem.eql(u8, magic, "P5")) 1 else if (std.mem.eql(u8, magic, "P6")) 3 else return error.BadPnm;
        const w = std.fmt.parseInt(u32, pnmToken(p.r, &tb) catch return error.BadPnm, 10) catch return error.BadPnm;
        const h = std.fmt.parseInt(u32, pnmToken(p.r, &tb) catch return error.BadPnm, 10) catch return error.BadPnm;
        const maxval = std.fmt.parseInt(u32, pnmToken(p.r, &tb) catch return error.BadPnm, 10) catch return error.BadPnm;
        if (maxval != 255) return error.UnsupportedPnm; // 8-bit only
        if (w == 0 or h == 0 or w > 16384 or h > 16384) return error.BadPnm;
        // pnmToken consumed the single whitespace byte after maxval.
        try p.pixels.resize(gpa, @as(usize, w) * h * channels);
        p.r.readSliceAll(p.pixels.items) catch return error.BadPnm;
        return .{ .width = w, .height = h, .channels = channels, .data = p.pixels.items };
    }
};

pub const FramesOptions = struct {
    /// Where each screen is in the picture. Default: host on the left half, client on
    /// the right.
    host: ?Rect = null,
    client: ?Rect = null,
    max_latency_us: Micros = 500_000,
};

pub const How = enum { barcode, digits };

/// Accumulates samples from frames.
pub const Frames = struct {
    o: FramesOptions,
    samples: std.ArrayList(Micros) = .empty,
    crop: std.ArrayList(u8) = .empty,
    frames: usize = 0,
    barcode: usize = 0,
    digits: usize = 0,
    /// Neither the barcode nor the digits read on one of the screens.
    unreadable: usize = 0,
    /// Read, but the client looked ahead of the host or behind by over the limit.
    rejected: usize = 0,

    pub fn deinit(f: *Frames, gpa: std.mem.Allocator) void {
        f.samples.deinit(gpa);
        f.crop.deinit(gpa);
    }

    const Read = union(How) { barcode: u64, digits: u64 };

    fn readCrop(f: *Frames, gpa: std.mem.Allocator, p: Picture, r: Rect) !?Read {
        try f.crop.resize(gpa, @as(usize, r.w) * r.h * 4);
        try p.cropBgra(r, f.crop.items);
        if (pattern.read(f.crop.items, r.w, r.h, r.w * 4)) |s| return .{ .barcode = s.time_us };
        if (pattern.readDigits(f.crop.items, r.w, r.h, r.w * 4)) |d| return .{ .digits = d };
        return null;
    }

    pub fn add(f: *Frames, gpa: std.mem.Allocator, p: Picture) !void {
        f.frames += 1;
        const half = p.width / 2;
        const hr = f.o.host orelse Rect{ .x = 0, .y = 0, .w = half, .h = p.height };
        const cr = f.o.client orelse Rect{ .x = half, .y = 0, .w = p.width - half, .h = p.height };
        const h = try f.readCrop(gpa, p, hr) orelse {
            f.unreadable += 1;
            return;
        };
        const c = try f.readCrop(gpa, p, cr) orelse {
            f.unreadable += 1;
            return;
        };
        const mod: i64 = 100_000_000;
        const lat: Micros = if (h == .barcode and c == .barcode)
            @as(i64, @bitCast(h.barcode -% c.barcode))
        else blk: {
            const hm: i64 = switch (h) {
                .barcode => |v| @intCast((v / 1000) % @as(u64, mod)),
                .digits => |v| @intCast(v),
            };
            const cm: i64 = switch (c) {
                .barcode => |v| @intCast((v / 1000) % @as(u64, mod)),
                .digits => |v| @intCast(v),
            };
            break :blk 1000 * @mod(hm - cm, mod);
        };
        if (lat < 0 or lat > f.o.max_latency_us) {
            f.rejected += 1;
            return;
        }
        if (h == .barcode and c == .barcode) f.barcode += 1 else f.digits += 1;
        try f.samples.append(gpa, lat);
    }

    /// Every picture in `path` under `dir`: a file of one or more PNM pictures, or a
    /// directory of them (*.ppm, *.pgm, *.pnm, by name).
    pub fn addPath(f: *Frames, gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) !void {
        if (dir.openDir(io, path, .{ .iterate = true })) |d| {
            var sub = d;
            defer sub.close(io);
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |n| gpa.free(n);
                names.deinit(gpa);
            }
            var it = sub.iterate();
            while (try it.next(io)) |e| {
                if (e.kind != .file) continue;
                const ext = std.fs.path.extension(e.name);
                if (!(std.ascii.eqlIgnoreCase(ext, ".ppm") or std.ascii.eqlIgnoreCase(ext, ".pgm") or std.ascii.eqlIgnoreCase(ext, ".pnm"))) continue;
                try names.append(gpa, try gpa.dupe(u8, e.name));
            }
            std.mem.sort([]u8, names.items, {}, struct {
                fn lt(_: void, a: []u8, b: []u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lt);
            for (names.items) |n| try f.addFile(gpa, io, sub, n);
        } else |e| switch (e) {
            error.NotDir => try f.addFile(gpa, io, dir, path),
            else => return e,
        }
    }

    fn addFile(f: *Frames, gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) !void {
        var file = try dir.openFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(io, &buf);
        var pr: PnmReader = .{ .r = &fr.interface };
        defer pr.deinit(gpa);
        while (try pr.next(gpa)) |p| try f.add(gpa, p);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "stats" {
    const s = try Stats.of(testing.allocator, &.{ 5, 1, 4, 2, 3, 100, 6, 7, 8, 9 });
    try testing.expectEqual(@as(usize, 10), s.n);
    try testing.expectEqual(@as(Micros, 5), s.p50_us);
    try testing.expectEqual(@as(Micros, 100), s.p95_us);
    try testing.expectEqual(@as(Micros, 1), s.min_us);
    try testing.expectApproxEqAbs(@as(f64, 14.5), s.mean_us, 1e-9);
}

test "photodiode: edges pair across the flash and its fall, with a header and noise" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("# scope export\nt_us,host,client\n");
    var prng = std.Random.DefaultPrng.init(9);
    // 3 s at 1 kHz; host lit 100 ms a second, client the same 23.4 ms later.
    var t: i64 = 0;
    while (t < 3_000_000) : (t += 1000) {
        const host_on = @mod(t, 1_000_000) < 100_000;
        const ct = t - 23_400;
        const client_on = ct >= 0 and @mod(ct, 1_000_000) < 100_000;
        const n1 = prng.random().float(f64) * 20;
        const n2 = prng.random().float(f64) * 20;
        try w.print("{d},{d:.1},{d:.1}\n", .{ t, (if (host_on) @as(f64, 900) else 100) + n1, (if (client_on) @as(f64, 700) else 50) + n2 });
    }
    var r = try photodiode(testing.allocator, aw.written(), .{});
    defer r.deinit(testing.allocator);
    // Edges: the host starts lit, so it rises at 1 s and 2 s and falls at 0.1, 1.1 and
    // 2.1 s. The client starts dark and rises at 23.4 ms too, with no host rise before it.
    try testing.expectEqual(@as(usize, 5), r.host_edges);
    try testing.expectEqual(@as(usize, 6), r.client_edges);
    try testing.expectEqual(@as(usize, 1), r.unmatched);
    try testing.expectEqual(@as(usize, 5), r.samples.len);
    for (r.samples) |s| try testing.expect(@abs(s - 23_400) <= 1000);
}

test "photodiode: bad input" {
    try testing.expectError(error.NoSignal, photodiode(testing.allocator, "0,1,1\n1,1,1\n2,1,1\n3,1,1\n4,1,1\n", .{}));
    try testing.expectError(error.BadCsv, photodiode(testing.allocator, "0,1,1\n0,1,1\n", .{}));
    try testing.expectError(error.BadCsv, photodiode(testing.allocator, "0,1\n", .{}));
}

fn renderPair(gpa: std.mem.Allocator, w: *Io.Writer, sw: u32, sh: u32, host: pattern.Stamp, client: pattern.Stamp, wipe_client_barcode: bool) !void {
    const a = try gpa.alloc(u8, sw * sh * 4);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, sw * sh * 4);
    defer gpa.free(b);
    pattern.render(a, sw, sh, sw * 4, host);
    pattern.render(b, sw, sh, sw * 4, client);
    if (wipe_client_barcode) @memset(b[0 .. sw * 4 * (sh / 8)], 0);
    try w.print("P6\n# two screens\n{d} {d}\n255\n", .{ sw * 2, sh });
    for (0..sh) |y| {
        for ([2][]u8{ a, b }) |px| {
            for (0..sw) |x| {
                const p = px[(y * sw + x) * 4 ..];
                try w.writeAll(&.{ p[2], p[1], p[0] });
            }
        }
    }
}

test "frames: a PPM stream of both screens, barcode and digits" {
    const gpa = testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try renderPair(gpa, &aw.writer, 256, 144, .{ .time_us = 10_050_000, .frame = 9 }, .{ .time_us = 10_016_667, .frame = 7 }, false);
    try renderPair(gpa, &aw.writer, 256, 144, .{ .time_us = 10_066_667, .frame = 10 }, .{ .time_us = 10_033_333, .frame = 8 }, true);
    // Client ahead of host: rejected.
    try renderPair(gpa, &aw.writer, 256, 144, .{ .time_us = 10_000_000, .frame = 1 }, .{ .time_us = 10_016_667, .frame = 2 }, false);
    // A grey frame: unreadable.
    try aw.writer.writeAll("P5 512 144 255\n");
    try aw.writer.splatByteAll(90, 512 * 144);

    var r: Io.Reader = .fixed(aw.written());
    var pr: PnmReader = .{ .r = &r };
    defer pr.deinit(gpa);
    var f: Frames = .{ .o = .{} };
    defer f.deinit(gpa);
    while (try pr.next(gpa)) |p| try f.add(gpa, p);
    try testing.expectEqual(@as(usize, 4), f.frames);
    try testing.expectEqual(@as(usize, 1), f.barcode);
    try testing.expectEqual(@as(usize, 1), f.digits);
    try testing.expectEqual(@as(usize, 1), f.rejected);
    try testing.expectEqual(@as(usize, 1), f.unreadable);
    try testing.expectEqualSlices(Micros, &.{ 33_333, 33_000 }, f.samples.items);
}

test "rect" {
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 3, .h = 4 }, try Rect.parse("1,2,3,4"));
    try testing.expectError(error.BadRect, Rect.parse("1,2,3"));
}
