//! `zig build sim -- [options]`: run the scenario catalog and print a table.
//!
//!   --scenario NAME   run one scenario (default: all)
//!   --seeds N         seeds 1..N per scenario (default 3)
//!   --check FILE      compare run digests against FILE; exit 1 on any mismatch
//!   --update FILE     write run digests to FILE
//!   --list            list scenarios and exit
//!
//! A digest covers every media delivery and drop in a run, so `--check` against
//! the committed `sim/golden.txt` proves the runs are deterministic by seed and
//! identical on every platform CI builds.
const std = @import("std");
const run = @import("run.zig");
const scenarios = @import("scenarios.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var only: ?[]const u8 = null;
    var seeds: u64 = 3;
    var check: ?[]const u8 = null;
    var update: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list")) {
            for (scenarios.all) |s| std.debug.print("{s:<20} {s}\n", .{ s.name, s.about });
            return;
        }
        if (i + 1 >= args.len) return usage(a);
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--scenario")) {
            if (scenarios.find(v) == null) {
                std.debug.print("unknown scenario '{s}' (try --list)\n", .{v});
                std.process.exit(2);
            }
            only = v;
        } else if (std.mem.eql(u8, a, "--seeds")) {
            seeds = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--check")) {
            check = v;
        } else if (std.mem.eql(u8, a, "--update")) {
            update = v;
        } else return usage(a);
    }

    var golden: std.StringHashMapUnmanaged(u64) = .empty;
    if (check) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.tokenizeAny(u8, line, " \t\r");
            const name = f.next() orelse continue;
            const seed = f.next() orelse continue;
            const dig = f.next() orelse continue;
            const key = try std.fmt.allocPrint(arena, "{s} {s}", .{ name, seed });
            try golden.put(arena, key, try std.fmt.parseInt(u64, dig, 16));
        }
    }

    var out: std.ArrayList(u8) = .empty;
    var gold_out: std.ArrayList(u8) = .empty;
    try gold_out.appendSlice(arena, "# scenario seed digest -- regenerate with: zig build sim -- --update sim/golden.txt\n");
    try out.print(arena, "{s:<20} {s:>4} {s:>16} {s:>8} {s:>7} {s:>7} {s:>7} {s:>8} {s:>7} {s:>7} {s:>7} {s:>9} {s:>7} {s:>7}\n", .{
        "scenario", "seed", "digest", "sent", "loss%", "qdrop", "reord", "frames%", "freeze", "owd50", "owd99", "maxq_KB", "media", "cross",
    });

    var mismatches: usize = 0;
    var checked: usize = 0;
    for (scenarios.all) |sc| {
        if (only) |o| if (!std.mem.eql(u8, o, sc.name)) continue;
        for (1..seeds + 1) |seed| {
            const r = try run.run(gpa, sc, seed, .{});
            try out.print(arena, "{s:<20} {d:>4} {x:0>16} {d:>8} {d:>7.2} {d:>7} {d:>7} {d:>8.2} {d:>7.1} {d:>7.2} {d:>7.2} {d:>9.0} {d:>7.2} {d:>7.2}\n", .{
                sc.name,
                seed,
                r.digest,
                r.media_sent,
                r.lossPct(),
                r.queue_drops,
                r.reordered,
                100 * @as(f64, @floatFromInt(r.frames_complete)) / @as(f64, @floatFromInt(@max(r.frames, 1))),
                r.max_freeze_ms,
                r.owd_p50_ms,
                r.owd_p99_ms,
                @as(f64, @floatFromInt(r.max_queue_bytes)) / 1000,
                r.media_mbps,
                r.cross_mbps,
            });
            try gold_out.print(arena, "{s} {d} {x:0>16}\n", .{ sc.name, seed, r.digest });
            if (check != null) {
                const key = try std.fmt.allocPrint(arena, "{s} {d}", .{ sc.name, seed });
                if (golden.get(key)) |want| {
                    checked += 1;
                    if (want != r.digest) {
                        mismatches += 1;
                        try out.print(arena, "  MISMATCH: want {x:0>16}\n", .{want});
                    }
                }
            }
        }
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
    if (update) |path| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = gold_out.items });
    if (check) |path| {
        if (checked == 0) {
            std.debug.print("no digests in {s} matched the runs\n", .{path});
            std.process.exit(1);
        }
        if (mismatches > 0) {
            std.debug.print("{d} of {d} runs differ from {s}\n", .{ mismatches, checked, path });
            std.process.exit(1);
        }
        std.debug.print("all {d} runs match {s}\n", .{ checked, path });
    }
}

fn usage(arg: []const u8) void {
    std.debug.print("bad argument '{s}'; usage: sim [--scenario NAME] [--seeds N] [--check FILE] [--update FILE] [--list]\n", .{arg});
    std.process.exit(2);
}
