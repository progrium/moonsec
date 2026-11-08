//! `zig build audio-sim [-- <scenario>...] [--seed N]`: runs the audio scenarios in
//! sim/audio.zig at full length with real libopus and prints one row per scenario.
const std = @import("std");
const audio = @import("audio.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    var seed: u64 = 1;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--seed")) {
            seed = try std.fmt.parseInt(u64, args.next() orelse return error.MissingSeed, 10);
        } else try names.append(gpa, a);
    }

    std.debug.print("{s:<18} {s:>5} {s:>5} {s:>6} {s:>5} {s:>5} {s:>5} {s:>5} {s:>5} {s:>5} {s:>5} {s:>5} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>14} {s:>5}\n", .{
        "scenario", "lost", "fec%", "kbps", "rs", "fec", "plc", "late", "drop", "ins", "cov%", "dly", "p50 ms", "p99 ms", "snr dB", "rep dB", "codec", "modes s/h/c", "secs",
    });
    for (audio.all) |sc| {
        if (names.items.len > 0) {
            var want = false;
            for (names.items) |n| want = want or std.mem.eql(u8, n, sc.name);
            if (!want) continue;
        }
        const t0 = std.Io.Clock.awake.now(init.io);
        const r = try audio.run(gpa, sc, seed);
        const secs = @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds)) / 1e9;
        const fec_pct = 100 * @as(f64, @floatFromInt(r.frames_with_fec)) / @as(f64, @floatFromInt(r.frames));
        std.debug.print("{s:<18} {d:>5} {d:>5.1} {d:>6.1} {d:>5} {d:>5} {d:>5} {d:>5} {d:>5} {d:>5} {d:>5.1} {d:>5.1} {d:>7.1} {d:>7.1} {d:>7.1} {d:>7.1} {d:>7.1} {d:>4}/{d:>4}/{d:>4} {d:>5.2}\n", .{
            sc.name,           r.lost,                                         fec_pct,          r.kbps,           r.buf.rs_recovered,
            r.buf.fec,         r.buf.concealed,                                r.buf.late,       r.buf.dropped,    r.buf.inserted,
            r.covered_pct,     @as(f64, @floatFromInt(r.buf.delay_us)) / 1000, r.latency_p50_ms, r.latency_p99_ms, r.snr_db,
            r.repaired_snr_db, r.codec_snr_db,                                 r.silk,           r.hybrid,         r.celt,
            secs,
        });
    }
}
