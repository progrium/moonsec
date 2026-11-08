//! FEC benchmark: `zig build fec-bench` (ReleaseFast by default).
//! Times encode and worst-case reconstruct (m data shards lost) for
//! block shapes the media path uses, with 1150-byte shards.

const std = @import("std");
const fec = @import("fec.zig");

const shard_len = 1150;

const Case = struct { k: usize, m: usize, what: []const u8 };
const cases = [_]Case{
    .{ .k = 1, .m = 1, .what = "tiny frame, 1 parity" },
    .{ .k = 10, .m = 2, .what = "11 KB frame, 20%" },
    .{ .k = 36, .m = 4, .what = "41 KB frame (20 Mbit/s @60), 10%" },
    .{ .k = 36, .m = 11, .what = "41 KB frame, 30%" },
    .{ .k = 128, .m = 38, .what = "147 KB frame, 30%" },
    .{ .k = 200, .m = 56, .what = "230 KB frame (IDR), max block" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    try out.print("fec bench: {d}-byte shards, {s} on {s}\n\n", .{ shard_len, @tagName(@import("builtin").mode), @import("builtin").cpu.model.name });
    try out.print("{s:>4} {s:>4}  {s:>11} {s:>10}  {s:>11} {s:>10}  {s}\n", .{ "k", "m", "encode us", "MB/s", "decode us", "MB/s", "" });

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    for (cases) |cs| {
        const codec = try fec.Codec.init(cs.k, cs.m);
        const nn = codec.n();
        const store = try alloc.alloc(u8, nn * shard_len);
        rng.bytes(store);
        const shards = try alloc.alloc([]u8, nn);
        for (shards, 0..) |*s, i| s.* = store[i * shard_len ..][0..shard_len];
        const data: []const []const u8 = @ptrCast(shards[0..cs.k]);
        const parity = shards[cs.k..];

        // Lose the first min(k, m) data shards: the most work for the decoder.
        const present = try alloc.alloc(bool, nn);
        @memset(present, true);
        for (0..@min(cs.k, cs.m)) |i| present[i] = false;

        const enc_ns = try timeIt(io, struct {
            fn run(c: fec.Codec, d: []const []const u8, p: []const []u8) !void {
                try c.encode(d, p);
            }
        }.run, .{ codec, data, parity });
        const dec_ns = try timeIt(io, fec.Codec.reconstruct, .{ codec, @as([]const []u8, shards), @as([]const bool, present) });

        const bytes: f64 = @floatFromInt(cs.k * shard_len);
        try out.print("{d:>4} {d:>4}  {d:>11.2} {d:>10.0}  {d:>11.2} {d:>10.0}  {s}\n", .{
            cs.k, cs.m, enc_ns / 1e3, bytes / enc_ns * 1e3, dec_ns / 1e3, bytes / dec_ns * 1e3, cs.what,
        });
    }
    try out.flush();
}

/// Median ns per call over 15 batches of ~20 ms each.
fn timeIt(io: std.Io, comptime f: anytype, args: anytype) !f64 {
    const clock = std.Io.Clock.awake;
    // Calibrate the batch size.
    var iters: usize = 1;
    while (true) {
        const t0 = clock.now(io);
        for (0..iters) |_| try @call(.auto, f, args);
        const ns = t0.durationTo(clock.now(io)).toNanoseconds();
        if (ns > 20 * std.time.ns_per_ms) break;
        iters *= 2;
    }
    var samples: [15]f64 = undefined;
    for (&samples) |*s| {
        const t0 = clock.now(io);
        for (0..iters) |_| try @call(.auto, f, args);
        const ns: f64 = @floatFromInt(t0.durationTo(clock.now(io)).toNanoseconds());
        s.* = ns / @as(f64, @floatFromInt(iters));
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    return samples[samples.len / 2];
}
