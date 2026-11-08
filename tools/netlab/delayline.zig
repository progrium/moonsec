//! A transparent L2 delay line between two interfaces, for kernels without `sch_netem`
//! (the S5c lab VM, and this repo's cloud VMs). Port of `s5c delayline`
//! (spikes/s5c-idle-timeout/src/main.rs).
//!
//!   delayline <if_a> <if_b> <oneway_ms>
//!
//! Every frame read on one interface is written to the other `oneway_ms` later, in both
//! directions, in order. Raw AF_PACKET sockets, so NATs and hole punching see real traffic.
//! No loss of its own: big socket buffers and no queue limit. Linux only, root.
const std = @import("std");
const linux = std.os.linux;

const ETH_P_ALL: u16 = 0x0003;
const SOL_PACKET = 263;
const PACKET_IGNORE_OUTGOING = 23;
const SO_SNDBUFFORCE = 32;
const SO_RCVBUFFORCE = 33;

const Frame = struct { due_ns: u64, data: []u8 };

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("delayline: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn sysOk(rc: usize, what: []const u8) usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) fail("{s}: {t}", .{ what, e });
    return rc;
}

fn monoNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ifIndex(name: []const u8) i32 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/net/{s}/ifindex", .{name}) catch fail("interface name too long", .{});
    const fd: i32 = @intCast(sysOk(linux.open(path, .{}, 0), "open ifindex"));
    defer _ = linux.close(fd);
    var buf: [16]u8 = undefined;
    const n = sysOk(linux.read(fd, &buf, buf.len), "read ifindex");
    return std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \n"), 10) catch fail("bad ifindex for {s}", .{name});
}

fn open(name: []const u8) i32 {
    const proto = std.mem.nativeToBig(u16, ETH_P_ALL);
    const fd: i32 = @intCast(sysOk(linux.socket(linux.AF.PACKET, linux.SOCK.RAW | linux.SOCK.NONBLOCK, proto), "socket"));
    var sll: linux.sockaddr.ll = .{ .protocol = proto, .ifindex = ifIndex(name), .hatype = 0, .pkttype = 0, .halen = 0, .addr = @splat(0) };
    _ = sysOk(linux.bind(fd, @ptrCast(&sll), @sizeOf(linux.sockaddr.ll)), "bind");
    const one: i32 = 1;
    // Don't read back what we write.
    _ = linux.setsockopt(fd, SOL_PACKET, PACKET_IGNORE_OUTGOING, std.mem.asBytes(&one), 4);
    const big: i32 = 16 << 20;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, SO_RCVBUFFORCE, std.mem.asBytes(&big), 4);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, SO_SNDBUFFORCE, std.mem.asBytes(&big), 4);
    return fd;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 4) fail("usage: delayline <if_a> <if_b> <oneway_ms>", .{});
    const oneway_ms = std.fmt.parseFloat(f64, argv[3]) catch fail("bad delay {s}", .{argv[3]});
    const delay_ns: u64 = @intFromFloat(oneway_ms * std.time.ns_per_ms);
    const fds = [2]i32{ open(argv[1]), open(argv[2]) };
    // queues[i]: frames read on fds[i], to be written to fds[1 - i].
    var queues: [2]std.Deque(Frame) = .{ .empty, .empty };
    var buf: [65536]u8 = undefined;
    var fwd: u64 = 0;
    var errs: u64 = 0;
    // Frames longer than an Ethernet frame: GSO/GRO super-packets, which the other side
    // can't take. lab.sh turns the offloads off; this says if that didn't work.
    var oversize: u64 = 0;
    var max_len: usize = 0;
    var first_err: linux.E = .SUCCESS;
    var last_report = monoNs();
    std.debug.print("delayline {s} <-> {s}, one-way {d} ms\n", .{ argv[1], argv[2], oneway_ms });
    while (true) {
        const now = monoNs();
        for (&queues, 0..) |*q, i| {
            while (q.front()) |f| {
                if (f.due_ns > now) break;
                const rc = linux.write(fds[1 - i], f.data.ptr, f.data.len);
                const e = linux.errno(rc);
                if (e != .SUCCESS) {
                    if (errs == 0) first_err = e;
                    errs += 1;
                } else fwd += 1;
                gpa.free(f.data);
                _ = q.popFront();
            }
        }
        if (now - last_report > 10 * std.time.ns_per_s) {
            std.debug.print("delayline fwd={d} send_errs={d} (first {t}) oversize={d} max_len={d} queued={d}/{d}\n", .{ fwd, errs, first_err, oversize, max_len, queues[0].len, queues[1].len });
            last_report = now;
        }
        var next: ?u64 = null;
        for (&queues) |*q| if (q.front()) |f| {
            next = if (next) |n| @min(n, f.due_ns) else f.due_ns;
        };
        var pfds = [2]linux.pollfd{ .{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }, .{ .fd = fds[1], .events = linux.POLL.IN, .revents = 0 } };
        // poll's 1 ms resolution; a frame is at most ~1 ms late, as with S5c's ppoll.
        const timeout: i32 = if (next) |n| @intCast(if (n > now) (n - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms else 0) else 1000;
        _ = linux.poll(&pfds, 2, @min(timeout, 1000));
        for (fds, 0..) |fd, i| {
            while (true) {
                const rc = linux.read(fd, &buf, buf.len);
                if (linux.errno(rc) != .SUCCESS) break;
                if (rc > 1514) oversize += 1;
                max_len = @max(max_len, rc);
                const data = try gpa.dupe(u8, buf[0..rc]);
                try queues[i].pushBack(gpa, .{ .due_ns = monoNs() + delay_ns, .data = data });
            }
        }
    }
}
