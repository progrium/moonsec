//! The synthetic pair under a simulated photodiode and camera: runs the synthetic host
//! and client over the in-process sim (app/simrun.zig) and records, on the simulation's
//! clock, what a photodiode taped to each screen's flash square reads (a CSV) and what a
//! camera filming both screens side by side sees (a stream of PGM frames). The files go
//! through the same analysis as real captures, so CI runs the gate end to end.
//!
//! The model: the host's screen shows the last captured pattern (the synthetic capture
//! draws the pattern when it captures), the client's the last presented picture. The
//! diodes respond with a 0.5 ms time constant and a little noise; every seventh camera
//! frame has glare over the client's barcode, so the digit reader is exercised too.
const std = @import("std");
const simrun = @import("simrun");
const synthetic = @import("synthetic");
const pattern = @import("platform").pattern;

const Io = std.Io;
const Micros = i64;

pub const Options = struct {
    sim: simrun.Options = .{ .width = 256, .height = 144, .seconds = 8 },
    camera_fps: u32 = 125,
    /// Film from `camera_start_s` for this long (the stream is about 74 KB a frame).
    camera_seconds: f64 = 4,
    camera_start_s: f64 = 1,
    /// Gap between the two screens in the camera picture.
    gap: u32 = 16,
};

pub const Files = struct {
    photodiode: []const u8,
    camera: []const u8,
};

/// What the camera crops are, for the manifest.
pub fn crops(o: Options) [2][4]u32 {
    return .{ .{ 0, 0, o.sim.width, o.sim.height }, .{ o.sim.width + o.gap, 0, o.sim.width, o.sim.height } };
}

const Probe = struct {
    gpa: std.mem.Allocator,
    o: Options,
    diode: *Io.Writer,
    camera: *Io.Writer,
    level: [2]f64 = .{ 0, 0 },
    prng: std.Random.DefaultPrng,
    next_shot_us: Micros,
    end_shot_us: Micros,
    interval_us: Micros,
    shots: u64 = 0,
    picture: []u8,

    fn flashLevel(s: ?synthetic.Screen) f64 {
        const sc = s orelse return 0;
        const f = @min(sc.height / 4, sc.width / 4);
        const p = sc.data[(sc.height - f / 2) * sc.stride + (sc.width - f / 2) * 4 ..][0..4];
        return @floatFromInt((@as(u32, p[0]) * 29 + @as(u32, p[1]) * 150 + @as(u32, p[2]) * 77) >> 8);
    }

    fn step(ctx: *anyopaque, t: Micros, host: ?synthetic.Screen, client: ?synthetic.Screen) anyerror!void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        const r = p.prng.random();
        // Photodiodes: first-order response, 0.5 ms time constant, ±1% noise.
        const alpha = 1 - @exp(-@as(f64, @floatFromInt(p.o.sim.step_us)) / 500.0);
        const target = [2]f64{ flashLevel(host), flashLevel(client) };
        for (&p.level, target) |*l, x| l.* += (x - l.*) * alpha;
        try p.diode.print("{d},{d:.1},{d:.1}\n", .{ t, p.level[0] + (r.float(f64) - 0.5) * 5, p.level[1] + (r.float(f64) - 0.5) * 5 });

        if (t < p.next_shot_us or t >= p.end_shot_us) return;
        p.next_shot_us += p.interval_us;
        const w = p.o.sim.width;
        const h = p.o.sim.height;
        const pw = 2 * w + p.o.gap;
        @memset(p.picture, 96);
        for ([2]?synthetic.Screen{ host, client }, 0..) |s, side| {
            const sc = s orelse continue;
            const x0 = side * (w + p.o.gap);
            for (0..@min(h, sc.height)) |y| for (0..@min(w, sc.width)) |x| {
                const px = sc.data[y * sc.stride + x * 4 ..][0..4];
                const l: i32 = @intCast((@as(u32, px[0]) * 29 + @as(u32, px[1]) * 150 + @as(u32, px[2]) * 77) >> 8);
                const n = r.intRangeAtMost(i32, -12, 12);
                p.picture[y * pw + x0 + x] = @intCast(std.math.clamp(l + n, 0, 255));
            };
        }
        // Glare over the client's barcode on every seventh frame.
        if (p.shots % 7 == 3) for (0..h / 8) |y| @memset(p.picture[y * pw + w + p.o.gap ..][0..w], 250);
        p.shots += 1;
        try p.camera.print("P5\n{d} {d}\n255\n", .{ pw, h });
        try p.camera.writeAll(p.picture);
    }
};

/// Run the pair and write `<prefix>-photodiode.csv` and `<prefix>-camera.pgm` in `dir`.
pub fn record(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, prefix: []const u8, o: Options, name_buf: *[2][64]u8) !struct { simrun.Result, Files } {
    const files: Files = .{
        .photodiode = try std.fmt.bufPrint(&name_buf[0], "{s}-photodiode.csv", .{prefix}),
        .camera = try std.fmt.bufPrint(&name_buf[1], "{s}-camera.pgm", .{prefix}),
    };
    var df = try dir.createFile(io, files.photodiode, .{});
    defer df.close(io);
    var dbuf: [64 * 1024]u8 = undefined;
    var dw = df.writer(io, &dbuf);
    var cf = try dir.createFile(io, files.camera, .{});
    defer cf.close(io);
    var cbuf: [64 * 1024]u8 = undefined;
    var cw = cf.writer(io, &cbuf);

    try dw.interface.print("# synthetic pair, {s} profile, seed {d}: photodiode levels on each flash square\nt_us,host,client\n", .{ @tagName(o.sim.profile), o.sim.seed });
    const picture = try gpa.alloc(u8, (2 * o.sim.width + o.gap) * o.sim.height);
    defer gpa.free(picture);
    const start: Micros = @intFromFloat(o.camera_start_s * 1e6);
    var probe: Probe = .{
        .gpa = gpa,
        .o = o,
        .diode = &dw.interface,
        .camera = &cw.interface,
        .prng = .init(o.sim.seed ^ 0x1a7e),
        .next_shot_us = start,
        .end_shot_us = start + @as(Micros, @intFromFloat(o.camera_seconds * 1e6)),
        .interval_us = @divTrunc(1_000_000, @as(Micros, o.camera_fps)),
        .picture = picture,
    };
    var so = o.sim;
    so.observer = .{ .ctx = &probe, .stepFn = Probe.step };
    const r = try simrun.run(gpa, so, null);
    try dw.interface.flush();
    try cw.interface.flush();
    return .{ r, files };
}
