//! The Phase 5 recovery gate (docs/design.md, "Phase 5: Quality and recovery"): drives a
//! host backend's encoder through core/recovery over a link that loses frames, and checks
//! that loss is recovered with long-term-reference refreshes, without IDR spikes.
//!
//!   recovery-gate [--backend NAME] [--codec h264|hevc] [--frames N] [--loss PCT]
//!                 [--burst N] [--rtt-ms N] [--seed N] [--size WxH] [--fps N]
//!                 [--bitrate BPS] [--expect ltr|idr] [--max-refresh-ratio R]
//!                 [--no-ltr] [--json PATH] [--trace]
//!
//! Backends: `synthetic` everywhere; win-nvenc, win-amf, win-vpl, win-auto and win-mf on
//! Windows; mac-vt on macOS. Exit status 0 on a pass, 1 on a fail, 2 when the backend
//! could not be opened (no such encoder on this machine). See tools/recovery/README.md.
const std = @import("std");
const api = @import("platform");
const run = @import("recovery_run");
const platform_backends = @import("recovery_platform");
const synthetic = @import("synthetic.zig");

const Args = struct {
    backend: []const u8 = "synthetic",
    cfg: run.Config = .{},
    size_set: bool = false,
    bitrate_set: bool = false,
    ratio_set: bool = false,
    json: ?[]const u8 = null,
};

fn usage() error{Usage} {
    std.debug.print(
        \\usage: recovery-gate [--backend NAME] [--codec h264|hevc] [--frames N] [--loss PCT]
        \\                     [--burst N] [--rtt-ms N] [--seed N] [--size WxH] [--fps N]
        \\                     [--bitrate BPS] [--expect ltr|idr] [--max-refresh-ratio R]
        \\                     [--no-ltr] [--json PATH] [--trace]
        \\backends: synthetic
    , .{});
    for (platform_backends.names) |n| std.debug.print(", {s}", .{n});
    std.debug.print("\n", .{});
    return error.Usage;
}

fn parseArgs(args: []const [:0]const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "--no-ltr")) {
            a.cfg.ltr = false;
            continue;
        }
        if (std.mem.eql(u8, s, "--trace")) {
            a.cfg.trace = true;
            continue;
        }
        if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) return usage();
        if (i + 1 >= args.len) return usage();
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, s, "--backend")) {
            a.backend = v;
        } else if (std.mem.eql(u8, s, "--codec")) {
            a.cfg.codec = std.meta.stringToEnum(api.Codec, v) orelse return usage();
        } else if (std.mem.eql(u8, s, "--frames")) {
            a.cfg.frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "--loss")) {
            a.cfg.loss = try std.fmt.parseFloat(f64, v) / 100;
        } else if (std.mem.eql(u8, s, "--burst")) {
            a.cfg.burst = @max(try std.fmt.parseInt(u32, v, 10), 1);
        } else if (std.mem.eql(u8, s, "--rtt-ms")) {
            a.cfg.rtt_us = try std.fmt.parseInt(u64, v, 10) * 1000;
        } else if (std.mem.eql(u8, s, "--seed")) {
            a.cfg.seed = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, s, "--size")) {
            const x = std.mem.indexOfScalar(u8, v, 'x') orelse return usage();
            a.cfg.width = try std.fmt.parseInt(u32, v[0..x], 10);
            a.cfg.height = try std.fmt.parseInt(u32, v[x + 1 ..], 10);
            a.size_set = true;
        } else if (std.mem.eql(u8, s, "--fps")) {
            a.cfg.fps = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "--bitrate")) {
            a.cfg.bitrate_bps = try std.fmt.parseInt(u64, v, 10);
            a.bitrate_set = true;
        } else if (std.mem.eql(u8, s, "--expect")) {
            a.cfg.expect = std.meta.stringToEnum(run.Expect, v) orelse return usage();
        } else if (std.mem.eql(u8, s, "--max-refresh-ratio")) {
            a.cfg.max_refresh_ratio = try std.fmt.parseFloat(f64, v);
            a.ratio_set = true;
        } else if (std.mem.eql(u8, s, "--json")) {
            a.json = v;
        } else return usage();
    }
    return a;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var a = parseArgs(args) catch return 2;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;

    var records: std.ArrayList(run.FrameRecord) = .empty;
    defer records.deinit(gpa);
    var result: run.Result = undefined;
    if (std.mem.eql(u8, a.backend, "synthetic")) {
        // The passthrough codec, at a size and rate the synthetic encoder handles quickly.
        a.cfg.codec = .passthrough;
        if (!a.size_set) {
            a.cfg.width = 640;
            a.cfg.height = 360;
        }
        if (!a.bitrate_set) a.cfg.bitrate_bps = 2_000_000;
        // Its model sizes a refresh at 0.75x an IDR: the run checks the protocol, not sizes.
        if (!a.ratio_set) a.cfg.max_refresh_ratio = 0.8;
        const be = try synthetic.Backend.open(gpa, a.cfg.width, a.cfg.height);
        defer be.close();
        result = try run.run(gpa, be.hb.encoder, be.source(), be.cb.decoder, a.cfg, &records, out);
    } else {
        const be = platform_backends.Backend.open(gpa, a.backend, a.cfg.width, a.cfg.height) catch |e| {
            std.debug.print("recovery-gate: cannot open backend {s}: {s}\n", .{ a.backend, @errorName(e) });
            if (e == error.UnknownBackend) _ = usage() catch {};
            return 2;
        };
        defer be.close();
        result = try run.run(gpa, be.encoder(), be.source(), null, a.cfg, &records, out);
    }
    try run.report(out, a.backend, &result, a.cfg);
    try out.flush();
    if (a.json) |path| {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try run.writeJson(&w.interface, a.backend, &result, a.cfg);
        try w.interface.flush();
    }
    return if (run.verdict(&result, a.cfg).pass) 0 else 1;
}
