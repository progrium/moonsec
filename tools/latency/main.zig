//! `latency`: glass-to-glass latency from photodiode logs, camera footage or screenshots
//! of the measurement pattern (platform/pattern.zig), and the Phase 4 gate across every
//! host/client pair. See tools/latency/README.md for the bench setup.
//!
//!   latency photodiode FILE.csv [--max-latency-ms N]
//!   latency camera|screenshot PATH [--host-crop X,Y,W,H] [--client-crop X,Y,W,H] [--max-latency-ms N]
//!       One measurement: print its statistics. PATH is a PNM file (one or more
//!       pictures) or a directory of them. Crops default to the left and right halves.
//!   latency matrix MANIFEST [--out REPORT.md]
//!       Measure every run in the manifest (tools/latency/matrix.zig), print the
//!       host×client matrix against the Phase 2 bar and write it to REPORT.md. Exits 1
//!       unless every target pair passes.
//!   latency synthetic --out-dir DIR [--seconds N] [--profile P] [--ref-profile P]
//!                     [--seed N] [--camera-seconds S] [--camera-fps N] [--size WxH]
//!       Record the synthetic pair (tools/latency/synth.zig) twice, as moonsec over
//!       --profile (default lan) and as the reference over --ref-profile (default clean),
//!       each by photodiode and camera, and write DIR/manifest.txt for `matrix`.
const std = @import("std");
const analyze = @import("analyze.zig");
const matrix = @import("matrix.zig");
const synth = @import("synth.zig");
const simrun = @import("simrun");

const Io = std.Io;

fn usage() error{Usage} {
    std.debug.print(
        \\usage: latency photodiode FILE.csv [--max-latency-ms N]
        \\       latency camera|screenshot PATH [--host-crop X,Y,W,H] [--client-crop X,Y,W,H] [--max-latency-ms N]
        \\       latency matrix MANIFEST [--out REPORT.md]
        \\       latency synthetic --out-dir DIR [--seconds N] [--profile lan|wan|longhaul|clean]
        \\                         [--ref-profile P] [--seed N] [--camera-seconds S] [--camera-fps N] [--size WxH]
        \\
    , .{});
    return error.Usage;
}

const Args = struct {
    cmd: []const u8 = "",
    path: []const u8 = "",
    out: []const u8 = "",
    out_dir: []const u8 = "",
    host_crop: ?analyze.Rect = null,
    client_crop: ?analyze.Rect = null,
    max_latency_ms: i64 = 500,
    synth: synth.Options = .{},
    ref_profile: simrun.Profile = .clean,
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var a: Args = .{};
    if (argv.len < 2) return usage();
    a.cmd = argv[1];
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (!std.mem.startsWith(u8, s, "--")) {
            if (a.path.len > 0) return usage();
            a.path = s;
            continue;
        }
        if (i + 1 >= argv.len) return usage();
        i += 1;
        const v = argv[i];
        const eq = std.mem.eql;
        if (eq(u8, s, "--out")) {
            a.out = v;
        } else if (eq(u8, s, "--out-dir")) {
            a.out_dir = v;
        } else if (eq(u8, s, "--host-crop")) {
            a.host_crop = try analyze.Rect.parse(v);
        } else if (eq(u8, s, "--client-crop")) {
            a.client_crop = try analyze.Rect.parse(v);
        } else if (eq(u8, s, "--max-latency-ms")) {
            a.max_latency_ms = try std.fmt.parseInt(i64, v, 10);
        } else if (eq(u8, s, "--seconds")) {
            a.synth.sim.seconds = try std.fmt.parseInt(u32, v, 10);
        } else if (eq(u8, s, "--seed")) {
            a.synth.sim.seed = try std.fmt.parseInt(u64, v, 10);
        } else if (eq(u8, s, "--profile")) {
            a.synth.sim.profile = std.meta.stringToEnum(simrun.Profile, v) orelse return usage();
        } else if (eq(u8, s, "--ref-profile")) {
            a.ref_profile = std.meta.stringToEnum(simrun.Profile, v) orelse return usage();
        } else if (eq(u8, s, "--camera-seconds")) {
            a.synth.camera_seconds = try std.fmt.parseFloat(f64, v);
        } else if (eq(u8, s, "--camera-fps")) {
            a.synth.camera_fps = try std.fmt.parseInt(u32, v, 10);
        } else if (eq(u8, s, "--size")) {
            const x = std.mem.indexOfScalar(u8, v, 'x') orelse return usage();
            a.synth.sim.width = try std.fmt.parseInt(u32, v[0..x], 10);
            a.synth.sim.height = try std.fmt.parseInt(u32, v[x + 1 ..], 10);
        } else return usage();
    }
    return a;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const a = parseArgs(argv) catch std.process.exit(2);
    var out_buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    const eq = std.mem.eql;
    const ok = if (eq(u8, a.cmd, "photodiode") or eq(u8, a.cmd, "camera") or eq(u8, a.cmd, "screenshot"))
        try cmdOne(gpa, io, a, w)
    else if (eq(u8, a.cmd, "matrix"))
        try cmdMatrix(gpa, io, a, w)
    else if (eq(u8, a.cmd, "synthetic"))
        try cmdSynthetic(gpa, io, a, w)
    else {
        _ = usage() catch {};
        std.process.exit(2);
    };
    try w.flush();
    std.process.exit(if (ok) 0 else 1);
}

fn cmdOne(gpa: std.mem.Allocator, io: Io, a: Args, w: *Io.Writer) !bool {
    if (a.path.len == 0) return usage();
    const run: matrix.Run = .{
        .pair = .{ .host = "-", .client = "-" },
        .stack = .moonsec,
        .method = std.meta.stringToEnum(matrix.Method, a.cmd).?,
        .file = a.path,
        .host_crop = a.host_crop,
        .client_crop = a.client_crop,
        .max_latency_us = a.max_latency_ms * 1000,
    };
    const m = matrix.measure(gpa, io, Io.Dir.cwd(), run);
    if (m.err) |e| {
        std.debug.print("latency: {s}: {s}\n", .{ a.path, e });
        return false;
    }
    const s = m.stats;
    try w.print("{s}: {d} samples; {s} {d:.2} ms (median {d:.2}, mean {d:.2}, p95 {d:.2}, p99 {d:.2}, min {d:.2}, max {d:.2})\n", .{
        a.path,               s.n,                   run.method.statName(), analyze.ms(m.value_us()),
        analyze.ms(s.p50_us), analyze.ms(s.mean_us), analyze.ms(s.p95_us),  analyze.ms(s.p99_us),
        analyze.ms(s.min_us), analyze.ms(s.max_us),
    });
    if (run.method == .photodiode) {
        try w.print("  {d} host edges, {d} client edges, {d} unmatched\n", .{ m.counts[0], m.counts[1], m.counts[2] });
    } else {
        try w.print("  {d} frames: {d} by barcode, {d} by digits, {d} unreadable, {d} rejected\n", .{ m.counts[0], m.counts[1], m.counts[2], m.counts[3], m.counts[4] });
    }
    return s.n > 0;
}

/// Measure and evaluate a manifest; the caller owns the report.
pub fn runManifest(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, manifest_path: []const u8) !matrix.Report {
    const text = try dir.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    var line: usize = 0;
    var m = matrix.Manifest.parse(gpa, text, &line) catch |e| {
        std.debug.print("latency: {s} line {d}: {s}\n", .{ manifest_path, line, @errorName(e) });
        return e;
    };
    defer m.deinit();
    const base_path = std.fs.path.dirname(manifest_path) orelse ".";
    var base = try dir.openDir(io, base_path, .{});
    defer base.close(io);
    const measured = try gpa.alloc(matrix.Measured, m.runs.len);
    defer gpa.free(measured);
    for (m.runs, measured) |r, *x| x.* = matrix.measure(gpa, io, base, r);
    return matrix.evaluate(gpa, m, measured);
}

fn cmdMatrix(gpa: std.mem.Allocator, io: Io, a: Args, w: *Io.Writer) !bool {
    if (a.path.len == 0) return usage();
    var rep = try runManifest(gpa, io, Io.Dir.cwd(), a.path);
    defer rep.deinit();
    try rep.write(w);
    if (a.out.len > 0) {
        var f = try Io.Dir.cwd().createFile(io, a.out, .{});
        defer f.close(io);
        var buf: [16 * 1024]u8 = undefined;
        var fw = f.writer(io, &buf);
        try rep.write(&fw.interface);
        try fw.interface.flush();
    }
    return rep.passed();
}

/// Record the synthetic pair as moonsec and as the reference, and write the manifest.
pub fn writeSynthetic(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, o: synth.Options, ref_profile: simrun.Profile, log: ?*Io.Writer) !void {
    var mf: Io.Writer.Allocating = .init(gpa);
    defer mf.deinit();
    const mw = &mf.writer;
    try mw.print(
        \\# Written by `latency synthetic`: the synthetic host and client over the in-process sim,
        \\# filmed by a simulated photodiode and camera. Read it with `latency matrix`.
        \\# The reference is the same pair over the {s} profile, standing in for Moonlight.
        \\bar margin_ms=5 min_edges=10 min_frames=100
        \\target synthetic synthetic
        \\
    , .{@tagName(ref_profile)});
    const cr = synth.crops(o);
    for ([2]matrix.Stack{ .moonsec, .reference }) |stack| {
        var so = o;
        if (stack == .reference) so.sim.profile = ref_profile;
        var names: [2][64]u8 = undefined;
        const r, const files = try synth.record(gpa, io, dir, @tagName(stack), so, &names);
        if (r.failure(so.sim)) |why| {
            std.debug.print("latency: synthetic {s} run failed: {s}\n", .{ @tagName(stack), why });
            return error.RunFailed;
        }
        const name = if (stack == .reference) @tagName(ref_profile) else @tagName(so.sim.profile);
        try mw.print("# {s}: the session's own telemetry says glass-to-glass p50 {d:.2} ms, p99 {d:.2} ms\n", .{ @tagName(stack), analyze.ms(r.client.total_p50_us), analyze.ms(r.client.total_p99_us) });
        const mode_fps = so.sim.fps;
        try mw.print("run host=synthetic client=synthetic stack={s} name=\"{s} ({s} link)\" method=photodiode file={s} mode={d}x{d}p{d}\n", .{ @tagName(stack), @tagName(stack), name, files.photodiode, so.sim.width, so.sim.height, mode_fps });
        try mw.print("run host=synthetic client=synthetic stack={s} name=\"{s} ({s} link)\" method=camera file={s} mode={d}x{d}p{d} host_crop={d},{d},{d},{d} client_crop={d},{d},{d},{d}\n", .{
            @tagName(stack), @tagName(stack), name,     files.camera, so.sim.width, so.sim.height, mode_fps,
            cr[0][0],        cr[0][1],        cr[0][2], cr[0][3],     cr[1][0],     cr[1][1],      cr[1][2],
            cr[1][3],
        });
        if (log) |l| {
            try l.print("{s} ({s} link): ", .{ @tagName(stack), name });
            try r.print(l);
        }
    }
    try dir.writeFile(io, .{ .sub_path = "manifest.txt", .data = mf.written() });
}

fn cmdSynthetic(gpa: std.mem.Allocator, io: Io, a: Args, w: *Io.Writer) !bool {
    if (a.out_dir.len == 0) return usage();
    var dir = try Io.Dir.cwd().createDirPathOpen(io, a.out_dir, .{});
    defer dir.close(io);
    try writeSynthetic(gpa, io, dir, a.synth, a.ref_profile, w);
    try w.print("wrote {s}/manifest.txt\n", .{a.out_dir});
    return true;
}

test {
    _ = analyze;
    _ = matrix;
    _ = @import("test.zig");
}
