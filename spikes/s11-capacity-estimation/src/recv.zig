//! S11 standalone far-end receiver (same wire format as net.zig's `recv`).
//! Build: zig build-exe -O ReleaseFast -lc recv.zig     Run: ./recv 9711
//! Timestamps each media packet on arrival (CLOCK_MONOTONIC) and every 5 ms
//! sends the sender a feedback packet: u8 2, u16 n, n x (u64 seq, i64 recv_us).
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
extern "c" fn clock_gettime(clk: c_int, tp: *c.timespec) c_int;
const CLOCK_MONO: c_int = if (builtin.os.tag == .macos) 6 else 1;
const SOL_SOCKET: i32 = if (builtin.os.tag == .macos) 0xffff else 1;
const SO_RCVBUF: u32 = if (builtin.os.tag == .macos) 0x1002 else 8;
const MSG_DONTWAIT: u32 = if (builtin.os.tag == .macos) 0x80 else 0x40;
const Addr = c.sockaddr.in;
const Pend = struct { seq: u64, recv: i64 };

fn nowUs() i64 {
    var ts: c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONO, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

fn pendLess(_: void, a: Pend, b: Pend) bool {
    return a.seq < b.seq;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = try std.fmt.parseInt(u16, if (args.len > 1) args[1] else "9711", 10);
    const fd = socket(c.AF.INET, c.SOCK.DGRAM, 0);
    if (fd < 0) return error.Socket;
    const sz: c_int = 8 << 20;
    _ = c.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, @sizeOf(c_int));
    var a = Addr{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (c.bind(fd, @ptrCast(&a), @sizeOf(Addr)) != 0) return error.Bind;
    var peer: Addr = undefined;
    var pending: [16384]Pend = undefined;
    var np: usize = 0;
    var buf: [2048]u8 = undefined;
    var out: [1400]u8 = undefined;
    var last_fb = nowUs();
    var active = false;
    var count: u64 = 0;
    var last_media: i64 = 0;
    std.debug.print("recv: listening on udp {d}\n", .{port});
    while (true) {
        var p = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        _ = c.poll(&p, 1, 1);
        while (true) {
            var from: Addr = undefined;
            var len: c.socklen_t = @sizeOf(Addr);
            const n = c.recvfrom(fd, &buf, buf.len, MSG_DONTWAIT, @ptrCast(&from), &len);
            if (n <= 0) break;
            const t = nowUs();
            if (buf[0] != 1 or n < 22) continue;
            if (!active) std.debug.print("recv: stream started\n", .{});
            active = true;
            peer = from;
            last_media = t;
            count += 1;
            if (np < pending.len) {
                pending[np] = .{ .seq = std.mem.readInt(u64, buf[1..9], .little), .recv = t };
                np += 1;
            }
        }
        const now = nowUs();
        if (active and now - last_media > 3_000_000) {
            std.debug.print("recv: stream ended after {d} packets\n", .{count});
            active = false;
            count = 0;
        }
        if (np > 0 and now - last_fb >= 5_000) {
            std.mem.sort(Pend, pending[0..np], {}, pendLess);
            var k: usize = 0;
            while (k < np) {
                const m: usize = @min(np - k, 80);
                out[0] = 2;
                std.mem.writeInt(u16, out[1..3], @intCast(m), .little);
                for (0..m) |j| {
                    const o = 3 + j * 16;
                    std.mem.writeInt(u64, out[o..][0..8], pending[k + j].seq, .little);
                    std.mem.writeInt(i64, out[o + 8 ..][0..8], pending[k + j].recv, .little);
                }
                _ = c.sendto(fd, &out, 3 + m * 16, 0, @ptrCast(&peer), @sizeOf(Addr));
                k += m;
            }
            np = 0;
            last_fb = now;
        }
    }
}
