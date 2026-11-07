//! S4 harness: a pinned, high-priority Zig "media" thread hands datagrams to the
//! Rust shim and stamps t0 right before each call. Everything after that is
//! measured inside the shim (see shim/src/lib.rs).
const std = @import("std");
const c = std.c;

const S4Config = extern struct {
    mode: c_int,
    rt_cpu: c_int,
    rt_prio: c_int,
    mt_workers: c_int,
    min_big_len: c_int,
};
const Shim = opaque {};
extern fn s4_init(cfg: *const S4Config) ?*Shim;
extern fn s4_send(shim: *Shim, buf: [*]const u8, len: usize) c_int;
extern fn s4_dump(shim: *Shim, prefix: [*:0]const u8) c_int;
extern fn s4_received(shim: *Shim) u64;
extern fn s4_max_datagram(shim: *Shim) c_int;
extern fn s4_pin_current_thread(cpu: c_int, prio: c_int) c_int;

const MAGIC: u64 = 0x5334_4a49_5454_4552;

inline fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepUntil(t: u64) void {
    const ts: c.timespec = .{ .sec = @intCast(t / 1_000_000_000), .nsec = @intCast(t % 1_000_000_000) };
    while (c.clock_nanosleep(c.CLOCK.MONOTONIC, .{ .ABSTIME = true }, &ts, null) != 0) {}
}

const Opts = struct {
    mode: c_int = 1,
    n: usize = 20_000,
    interval_us: u64 = 1000,
    burst: usize = 1,
    size: usize = 1150,
    cpu: c_int = -1, // sender thread pin
    prio: c_int = 0, // sender SCHED_FIFO prio
    rt_cpu: c_int = -1, // shim runtime thread pin (CT modes)
    rt_prio: c_int = 0,
    workers: c_int = 0,
    load: usize = 0, // background busy threads (normal prio, unpinned)
    warmup: usize = 500,
    out: [:0]const u8 = "out/run",
};

var stop_load = std.atomic.Value(bool).init(false);

fn loadThread(i: usize) void {
    // Cache- and CPU-hungry busy loop at normal priority.
    var buf: [1 << 20]u8 = undefined;
    var x: u64 = i *% 0x9E3779B97F4A7C15 +% 1;
    while (!stop_load.load(.monotonic)) {
        for (0..4096) |_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            buf[x & (buf.len - 1)] +%= @truncate(x);
        }
    }
    std.mem.doNotOptimizeAway(&buf);
}

fn parse(args: std.process.Args) !Opts {
    var o: Opts = .{};
    var it = args.iterate();
    _ = it.skip();
    while (it.next()) |a| {
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse return error.BadArg;
        const k = a[0..eq];
        const v = a[eq + 1 ..];
        if (std.mem.eql(u8, k, "out")) {
            o.out = a[eq + 1 .. :0];
            continue;
        }
        const n = try std.fmt.parseInt(i64, v, 10);
        inline for (std.meta.fields(Opts)) |f| {
            if (f.type != [:0]const u8 and std.mem.eql(u8, k, f.name)) {
                @field(o, f.name) = @intCast(n);
                break;
            }
        } else return error.UnknownArg;
    }
    return o;
}

fn sender(shim: *Shim, o: Opts) void {
    const rc = s4_pin_current_thread(o.cpu, o.prio);
    if (rc != 0) std.debug.print("warning: sender pin/prio rc={d}\n", .{rc});
    var buf: [2048]u8 = undefined;
    @memset(&buf, 0xAB);
    var seq: u64 = 0;
    var next = nowNs() + 1_000_000;
    const total = o.n + o.warmup;
    var errs: usize = 0;
    while (seq < total) {
        sleepUntil(next);
        next += o.interval_us * 1000;
        for (0..o.burst) |_| {
            if (seq >= total) break;
            std.mem.writeInt(u64, buf[0..8], seq, .little);
            std.mem.writeInt(u64, buf[16..24], MAGIC, .little);
            const t0 = nowNs();
            std.mem.writeInt(u64, buf[8..16], t0, .little);
            if (s4_send(shim, &buf, o.size) != 0) errs += 1;
            seq += 1;
        }
    }
    if (errs != 0) std.debug.print("send errors: {d}\n", .{errs});
}

pub fn main(init: std.process.Init.Minimal) !void {
    const o = try parse(init.args);
    const cfg: S4Config = .{
        .mode = o.mode,
        .rt_cpu = o.rt_cpu,
        .rt_prio = o.rt_prio,
        .mt_workers = o.workers,
        .min_big_len = @intCast(o.size),
    };
    const shim = s4_init(&cfg) orelse return error.InitFailed;
    std.debug.print("mode={d} max_datagram={d} n={d} interval_us={d} burst={d} load={d}\n", .{ o.mode, s4_max_datagram(shim), o.n, o.interval_us, o.burst, o.load });

    var loads: [64]std.Thread = undefined;
    for (0..o.load) |i| loads[i] = try std.Thread.spawn(.{}, loadThread, .{i});

    const t = try std.Thread.spawn(.{}, sender, .{ shim, o });
    t.join();
    sleepUntil(nowNs() + 200_000_000); // let the tail drain
    stop_load.store(true, .monotonic);
    for (0..o.load) |i| loads[i].join();
    std.debug.print("received={d}\n", .{s4_received(shim)});
    _ = s4_dump(shim, o.out.ptr);
}
