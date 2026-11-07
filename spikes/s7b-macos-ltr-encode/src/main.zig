//! S7 probe driver: parses flags, runs the ObjC capture/encode core, prints per-stage percentiles.
const std = @import("std");
const c = @cImport(@cInclude("probe.h"));

const usage =
    \\usage: s7probe [--source synthetic|display|window] [--codec h264|hevc] [--no-lowlat]
    \\               [--pixfmt nv12|bgra] [--scene motion|noise] [--seconds N] [--fps N]
    \\               [--bitrate-kbps N] [--size WxH] [--no-window] [--csv path]
    \\
;

fn pct(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx: usize = @intFromFloat(@min(@as(f64, @floatFromInt(sorted.len - 1)), @ceil(p / 100.0 * @as(f64, @floatFromInt(sorted.len))) - 1));
    return sorted[idx];
}

fn stats(name: []const u8, vals: []f64, bar: ?f64) void {
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (vals) |v| sum += v;
    const mean = if (vals.len > 0) sum / @as(f64, @floatFromInt(vals.len)) else 0;
    std.debug.print("  {s:<8} n={d:<5} mean={d:6.2} p50={d:6.2} p95={d:6.2} p99={d:6.2} max={d:6.2} ms", .{
        name, vals.len, mean, pct(vals, 50), pct(vals, 95), pct(vals, 99), if (vals.len > 0) vals[vals.len - 1] else 0,
    });
    if (bar) |b| {
        var over: usize = 0;
        for (vals) |v| {
            if (v >= b) over += 1;
        }
        std.debug.print("   [{s} vs {d} ms bar at p99; {d} frames >= bar]", .{ if (pct(vals, 99) < b) "PASS" else "FAIL", b, over });
    }
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var cfg = c.probe_config{
        .source = 1, .codec = 0, .low_latency = 1, .pixfmt = 0, .scene = 0,
        .width = 1920, .height = 1080, .fps = 60, .seconds = 30, .bitrate_kbps = 20000, .show_window = 1,
    };
    var csv_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const eq = std.mem.eql;
        if (eq(u8, a, "--no-lowlat")) { cfg.low_latency = 0; continue; }
        if (eq(u8, a, "--no-window")) { cfg.show_window = 0; continue; }
        if (eq(u8, a, "-h") or eq(u8, a, "--help")) { std.debug.print("{s}", .{usage}); return; }
        i += 1;
        if (i >= args.len) { std.debug.print("{s}", .{usage}); return error.BadArgs; }
        const v = args[i];
        if (eq(u8, a, "--source")) {
            cfg.source = if (eq(u8, v, "synthetic")) 0 else if (eq(u8, v, "window")) 2 else 1;
        } else if (eq(u8, a, "--codec")) {
            cfg.codec = if (eq(u8, v, "hevc")) 1 else 0;
        } else if (eq(u8, a, "--pixfmt")) {
            cfg.pixfmt = if (eq(u8, v, "bgra")) 1 else 0;
        } else if (eq(u8, a, "--scene")) {
            cfg.scene = if (eq(u8, v, "noise")) 1 else 0;
        } else if (eq(u8, a, "--seconds")) {
            cfg.seconds = try std.fmt.parseInt(c_int, v, 10);
        } else if (eq(u8, a, "--size")) {
            var it = std.mem.splitScalar(u8, v, 'x');
            cfg.width = try std.fmt.parseInt(c_int, it.next() orelse "", 10);
            cfg.height = try std.fmt.parseInt(c_int, it.next() orelse "", 10);
        } else if (eq(u8, a, "--fps")) {
            cfg.fps = try std.fmt.parseInt(c_int, v, 10);
        } else if (eq(u8, a, "--bitrate-kbps")) {
            cfg.bitrate_kbps = try std.fmt.parseInt(c_int, v, 10);
        } else if (eq(u8, a, "--csv")) {
            csv_path = v;
        } else {
            std.debug.print("{s}", .{usage});
            return error.BadArgs;
        }
    }

    const max: usize = @intCast(cfg.fps * (cfg.seconds + 5));
    const samples = try arena.alloc(c.probe_sample, max);
    var count: c_int = 0;
    var info: [16384]u8 = undefined;
    const rc = c.probe_run(&cfg, samples.ptr, @intCast(max), &count, &info, info.len);
    std.debug.print("{s}", .{std.mem.sliceTo(&info, 0)});
    if (rc != 0) {
        std.debug.print("probe_run failed: {d}\n", .{rc});
        std.process.exit(1);
    }

    const n: usize = @intCast(count);
    const warmup: usize = @min(n, @as(usize, @intCast(cfg.fps))); // drop the first second
    var cap: std.ArrayList(f64) = .empty;
    var enc: std.ArrayList(f64) = .empty;
    var tot: std.ArrayList(f64) = .empty;
    var bytes: u64 = 0;
    var keys: usize = 0;
    var dropped: usize = 0;
    for (samples[warmup..n]) |s| {
        if (s.done == 0) { dropped += 1; continue; }
        if (cfg.source != 0) try cap.append(arena, s.capture_ms);
        try enc.append(arena, s.encode_ms);
        try tot.append(arena, s.total_ms);
        bytes += s.bytes;
        if (s.keyframe != 0) keys += 1;
    }
    const secs: f64 = @floatFromInt(cfg.seconds);
    std.debug.print("frames: {d} submitted, {d} measured after 1 s warmup, {d} not encoded, {d} keyframes; {d:.1} fps delivered; avg {d:.1} KB/frame\n", .{
        n, enc.items.len, dropped, keys, @as(f64, @floatFromInt(n)) / secs,
        if (enc.items.len > 0) @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(enc.items.len)) / 1024.0 else 0,
    });

    if (csv_path) |p| {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, "idx,capture_ms,encode_ms,total_ms,bytes,keyframe,ltr_token,refresh,lost\n");
        for (samples[0..n], 0..) |s, k| {
            if (s.done == 0) continue;
            try buf.print(arena, "{d},{d:.3},{d:.3},{d:.3},{d},{d},{d},{d},{d}\n", .{ k, s.capture_ms, s.encode_ms, s.total_ms, s.bytes, s.keyframe, s.ltr_token, s.refresh, s.lost });
        }
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = p, .data = buf.items });
    }

    if (cfg.source != 0) stats("capture", cap.items, null); // signed: callback minus display (glass) time
    stats("encode", enc.items, 8.0);
    stats(if (cfg.source != 0) "glass2enc" else "total", tot.items, null);
}
