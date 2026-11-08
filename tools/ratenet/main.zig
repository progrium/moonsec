//! `zig build ratenet`: the core's rate controller (`core.rate.Controller`) over plain
//! UDP, for real-qdisc runs. A copy of S11's `s11net` (same wire format, CLI, CSV
//! columns and RESULT line, so S11b's scripts drive it unchanged) with S11's
//! `est.zig` replaced by `core/rate`.
//!
//!   ratenet recv --port P                    far end; replies with feedback to whoever sends
//!   ratenet send --to IP:P [opts]            near end
//!
//! send options: --ctl core|core-s11b|fixed  --mbps N (fixed rate / start)
//!               --max-mbps N  --seconds N  --csv path  --tag name
//!   core       the controller with its defaults
//!   core-s11b  the S11b follow-ups off (no competing-flow mode, no loss rule
//!              below 10%, no train floor, no probe frames): S11b's gcc-hybrid
//!
//! Wire format (little endian):
//!   media    : u8 1, u64 seq, i64 send_us, u32 frame, u8 last, padding to size
//!   feedback : u8 2, u16 n, n x (u64 seq, i64 recv_us)
//!   hello    : u8 3
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const rate = core.rate;
const c = std.c;

extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
extern "c" fn clock_gettime(clk: c_int, tp: *c.timespec) c_int;

const CLOCK_MONO: c_int = if (builtin.os.tag == .macos) 6 else 1; // CLOCK_MONOTONIC
const SOL_SOCKET: i32 = if (builtin.os.tag == .macos) 0xffff else 1;
const SO_SNDBUF: u32 = if (builtin.os.tag == .macos) 0x1001 else 7;
const SO_RCVBUF: u32 = if (builtin.os.tag == .macos) 0x1002 else 8;
const MSG_DONTWAIT: u32 = if (builtin.os.tag == .macos) 0x80 else 0x40;

fn nowUs() i64 {
    var ts: c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONO, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

const Addr = c.sockaddr.in;

fn parseAddr(s: []const u8) !Addr {
    var it = std.mem.splitScalar(u8, s, ':');
    const host = it.next() orelse return error.BadAddr;
    const port = try std.fmt.parseInt(u16, it.next() orelse return error.BadAddr, 10);
    var parts = std.mem.splitScalar(u8, host, '.');
    var ip: [4]u8 = undefined;
    for (0..4) |k| ip[k] = try std.fmt.parseInt(u8, parts.next() orelse return error.BadAddr, 10);
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(ip) };
}

fn openSock(port: u16) !c.fd_t {
    const fd = socket(c.AF.INET, c.SOCK.DGRAM, 0);
    if (fd < 0) return error.Socket;
    const sz: c_int = 8 << 20;
    _ = c.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, @sizeOf(c_int));
    _ = c.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, @sizeOf(c_int));
    var a = Addr{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (c.bind(fd, @ptrCast(&a), @sizeOf(Addr)) != 0) return error.Bind;
    return fd;
}

fn sendTo(fd: c.fd_t, buf: []const u8, to: *const Addr) isize {
    return c.sendto(fd, buf.ptr, buf.len, 0, @ptrCast(to), @sizeOf(Addr));
}

fn recvFrom(fd: c.fd_t, buf: []u8, from: *Addr) isize {
    var len: c.socklen_t = @sizeOf(Addr);
    return c.recvfrom(fd, buf.ptr, buf.len, MSG_DONTWAIT, @ptrCast(from), &len);
}

fn waitReadable(fd: c.fd_t, timeout_ms: c_int) void {
    var p = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    _ = c.poll(&p, 1, timeout_ms);
}

// ---------------------------------------------------------------------------
// Receiver

const Pend = struct { seq: u64, recv: i64 };

fn pendLess(_: void, a: Pend, b: Pend) bool {
    return a.seq < b.seq;
}

fn runRecv(port: u16, hello_to: ?Addr) !void {
    const fd = try openSock(port);
    var peer: Addr = undefined;
    if (hello_to) |h| peer = h;
    var have_peer = hello_to != null;
    var pending: [8192]Pend = undefined;
    var np: usize = 0;
    var buf: [2048]u8 = undefined;
    var out: [1400]u8 = undefined;
    var last_fb = nowUs();
    var last_hello: i64 = 0;
    var got_media = false;
    var count: u64 = 0;
    var last_media = nowUs();
    std.debug.print("recv: listening on {d}\n", .{port});
    while (true) {
        waitReadable(fd, 1);
        const now = nowUs();
        while (true) {
            var from: Addr = undefined;
            const n = recvFrom(fd, &buf, &from);
            if (n <= 0) break;
            const t = nowUs();
            if (buf[0] != 1 or n < 22) continue;
            // a new sender (new source port) takes over at once, not after the 3 s idle timeout
            if (!have_peer or !got_media or (hello_to == null and (from.port != peer.port or from.addr != peer.addr))) {
                peer = from;
                have_peer = true;
                if (!got_media) std.debug.print("recv: stream started\n", .{});
            }
            got_media = true;
            last_media = t;
            count += 1;
            if (np < pending.len) {
                pending[np] = .{ .seq = std.mem.readInt(u64, buf[1..9], .little), .recv = t };
                np += 1;
            }
        }
        if (hello_to != null and !got_media and now - last_hello > 100_000) {
            out[0] = 3;
            _ = sendTo(fd, out[0..1], &peer);
            last_hello = now;
        }
        if (got_media and now - last_media > 3_000_000) {
            std.debug.print("recv: stream ended after {d} packets\n", .{count});
            got_media = false;
            count = 0;
            if (hello_to) |h| peer = h;
        }
        if (np > 0 and now - last_fb >= 5_000) {
            std.mem.sort(Pend, pending[0..np], {}, pendLess);
            var k: usize = 0;
            while (k < np) {
                const m: usize = @min(np - k, 80); // explicit usize: @min with 80 narrows to u7
                out[0] = 2;
                std.mem.writeInt(u16, out[1..3], @intCast(m), .little);
                for (0..m) |j| {
                    const o = 3 + j * 16;
                    std.mem.writeInt(u64, out[o..][0..8], pending[k + j].seq, .little);
                    std.mem.writeInt(i64, out[o + 8 ..][0..8], pending[k + j].recv, .little);
                }
                _ = sendTo(fd, out[0 .. 3 + m * 16], &peer);
                k += m;
            }
            np = 0;
            last_fb = now;
        }
    }
}

// ---------------------------------------------------------------------------
// Sender

const SentRec = struct { send_us: i64, size: u32, frame: u32, last: bool };
const FrameRec = struct { capture: i64, npkts: u32, arrived: u32 = 0, lost: bool = false, last_arr: i64 = 0 };
const Queued = struct { size: u32, frame: u32, last: bool };
const RING = 1 << 21;

const SendOpts = struct {
    ctl: []const u8 = "core",
    mbps: f64 = 5,
    max_mbps: f64 = 400,
    seconds: f64 = 30,
    csv: ?[]const u8 = null,
    tag: []const u8 = "",
};

fn pctf(xs: []const f32, p: usize) f32 {
    if (xs.len == 0) return 0;
    return xs[@min(xs.len - 1, xs.len * p / 100)];
}

fn runSend(init: std.process.Init, to_opt: ?Addr, listen: u16, o: SendOpts) !void {
    const gpa = init.gpa;
    const fd = try openSock(listen);
    var buf: [2048]u8 = undefined;
    var peer: Addr = undefined;
    if (to_opt) |t| peer = t else {
        std.debug.print("send: waiting for hello on {d}\n", .{listen});
        while (true) {
            waitReadable(fd, 100);
            var from: Addr = undefined;
            const n = recvFrom(fd, &buf, &from);
            if (n >= 1 and buf[0] == 3) {
                peer = from;
                break;
            }
        }
    }

    const fixed = std.mem.eql(u8, o.ctl, "fixed");
    var cfg: rate.Config = .{ .gcc = .{ .start_bps = o.mbps * 1e6, .max_bps = o.max_mbps * 1e6, .rtt_us = 30_000 } };
    if (std.mem.eql(u8, o.ctl, "core-s11b")) {
        cfg.gcc.competing = false;
        cfg.gcc.loss_high = 0;
        cfg.floor_pkts = 0;
        cfg.probe_interval_us = 0;
    } else if (!fixed and !std.mem.eql(u8, o.ctl, "core")) return error.Usage;
    const ctl = try gpa.create(rate.Controller);
    defer gpa.destroy(ctl);
    ctl.reset(cfg);

    const sent = try gpa.alloc(SentRec, RING);
    defer gpa.free(sent);
    var frames: std.ArrayList(FrameRec) = .empty;
    defer frames.deinit(gpa);
    var fifo: std.ArrayList(Queued) = .empty;
    defer fifo.deinit(gpa);
    var fhead: usize = 0;
    var owds: std.ArrayList([2]i64) = .empty; // (recv_us, owd) per received packet
    defer owds.deinit(gpa);
    var results: std.ArrayList(rate.PacketResult) = .empty;
    defer results.deinit(gpa);
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);
    try csv.print(gpa, "t,target,pace,train,acked,sent_mbps,recv_mbps,lost,enobufs,standing_ms,q50_ms,q95_ms,competing,floor,state,usage\n", .{});
    var win_owd: std.ArrayList(i64) = .empty; // OWDs received in this 100 ms window
    defer win_owd.deinit(gpa);
    var min_owd: i64 = std.math.maxInt(i64);

    var prng = std.Random.DefaultPrng.init(@intCast(nowUs()));
    const rnd = prng.random();
    var target: f64 = o.mbps * 1e6;
    var pace: f64 = if (fixed) target else 2.5 * target;

    const t0 = nowUs();
    const end = t0 + @as(i64, @intFromFloat(o.seconds * 1e6));
    var next_frame = t0;
    var pacer_next = t0;
    var next_sample = t0 + 100_000;
    var seq: u64 = 0;
    var expected: u64 = 0;
    var lost: u64 = 0;
    var late: u64 = 0;
    var enobufs: u64 = 0;
    var bad: u64 = 0;
    var win_sent: u64 = 0;
    var win_recv: u64 = 0;
    var win_lost: u64 = 0;
    var tot_recv_bytes: u64 = 0;
    var pkt: [1500]u8 = undefined;
    @memset(&pkt, 0xa5);

    std.debug.print("send: {s} to port {d}, {d:.0} s\n", .{ o.ctl, std.mem.bigToNative(u16, peer.port), o.seconds });
    while (true) {
        var now = nowUs();
        if (now >= end) break;
        if (now >= next_frame) {
            const fid: u32 = @intCast(frames.items.len);
            var bytes = target / 8.0 / 60.0;
            if (!fixed) {
                bytes *= @exp(0.25 * rnd.floatNorm(f64) - 0.03);
                if (fid % 180 == 0 and fid > 0) bytes *= 4;
            }
            const n: u32 = @max(1, @as(u32, @intFromFloat(@ceil(bytes / 1200))));
            var left: u32 = @intFromFloat(@max(bytes, 100));
            for (0..n) |k| {
                const sz: u32 = if (k + 1 == n) std.math.clamp(left, 100, 1200) else 1200;
                left -|= sz;
                try fifo.append(gpa, .{ .size = sz, .frame = fid, .last = k + 1 == n });
            }
            try frames.append(gpa, .{ .capture = now, .npkts = n });
            if (!fixed) {
                ctl.onFrame(now, fid, @intFromFloat(@max(bytes, 100)));
                pace = ctl.pacingAt(now);
            }
            next_frame += 16_667;
        }
        if (!fixed) pace = ctl.pacingAt(now);
        while (fhead < fifo.items.len and now >= pacer_next) {
            const p = fifo.items[fhead];
            pkt[0] = 1;
            std.mem.writeInt(u64, pkt[1..9], seq, .little);
            std.mem.writeInt(i64, pkt[9..17], now, .little);
            std.mem.writeInt(u32, pkt[17..21], p.frame, .little);
            pkt[21] = @intFromBool(p.last);
            const rc = sendTo(fd, pkt[0..p.size], &peer);
            if (rc < 0) {
                // ENOBUFS / EAGAIN: the local interface queue is full; retry shortly
                enobufs += 1;
                pacer_next = now + 200;
                break;
            }
            sent[seq % RING] = .{ .send_us = now, .size = p.size, .frame = p.frame, .last = p.last };
            seq += 1;
            win_sent += p.size;
            fhead += 1;
            pacer_next = @max(pacer_next, now - 2_000) + @as(i64, @intFromFloat(@as(f64, @floatFromInt(p.size)) * 8e6 / pace));
        }
        if (fhead > 65536) {
            const rest = fifo.items[fhead..];
            std.mem.copyForwards(Queued, fifo.items[0..rest.len], rest);
            fifo.shrinkRetainingCapacity(rest.len);
            fhead = 0;
        }
        while (true) {
            var from: Addr = undefined;
            const n = recvFrom(fd, &buf, &from);
            if (n <= 0) break;
            if (buf[0] != 2) continue;
            if (n < 3) continue;
            const m = std.mem.readInt(u16, buf[1..3], .little);
            if (n != 3 + @as(isize, m) * 16) {
                if (bad < 5) std.debug.print("bad feedback len {d} m={d}\n", .{ n, m });
                bad += 1;
                continue;
            }
            results.clearRetainingCapacity();
            for (0..m) |j| {
                const off = 3 + j * 16;
                const s = std.mem.readInt(u64, buf[off..][0..8], .little);
                const rt = std.mem.readInt(i64, buf[off + 8 ..][0..8], .little);
                if (s < expected) {
                    late += 1;
                    continue;
                }
                while (expected < s) : (expected += 1) {
                    const r = sent[expected % RING];
                    lost += 1;
                    win_lost += 1;
                    frames.items[r.frame].lost = true;
                    try results.append(gpa, .{ .seq = expected, .send_us = r.send_us, .recv_us = -1, .size = r.size, .frame = r.frame, .frame_last = r.last });
                }
                const r = sent[s % RING];
                const res = rate.PacketResult{ .seq = s, .send_us = r.send_us, .recv_us = rt, .size = r.size, .frame = r.frame, .frame_last = r.last };
                try results.append(gpa, res);
                try owds.append(gpa, .{ rt, rt - r.send_us });
                try win_owd.append(gpa, rt - r.send_us);
                min_owd = @min(min_owd, rt - r.send_us);
                const f = &frames.items[r.frame];
                f.arrived += 1;
                f.last_arr = @max(f.last_arr, rt);
                win_recv += r.size;
                tot_recv_bytes += r.size;
                expected = s + 1;
            }
            now = nowUs();
            if (!fixed) {
                ctl.onFeedback(now, results.items);
                target = ctl.targetBps();
                pace = ctl.pacingAt(now);
            }
        }
        if (now >= next_sample) {
            const tc = ctl.capacityBps() orelse 0;
            const acked: f64 = ctl.gcc.acked.rate(ctl.gcc.last_recv) orelse 0;
            std.mem.sort(i64, win_owd.items, {}, std.sort.asc(i64));
            const wq = win_owd.items;
            const q50: f64 = if (wq.len > 0) @as(f64, @floatFromInt(wq[wq.len / 2] - min_owd)) / 1000 else -1;
            const q95: f64 = if (wq.len > 0) @as(f64, @floatFromInt(wq[@min(wq.len - 1, wq.len * 95 / 100)] - min_owd)) / 1000 else -1;
            win_owd.clearRetainingCapacity();
            try csv.print(gpa, "{d:.1},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d},{d},{d:.2},{d:.2},{d:.2},{d},{d:.2},{s},{s}\n", .{
                @as(f64, @floatFromInt(now - t0)) / 1e6,     target / 1e6,                                pace / 1e6,                      tc / 1e6,             acked / 1e6,
                @as(f64, @floatFromInt(win_sent)) * 8 / 1e5, @as(f64, @floatFromInt(win_recv)) * 8 / 1e5, win_lost,                        enobufs,              (ctl.gcc.standing_us orelse 0) / 1000,
                q50,                                         q95,                                         @intFromBool(ctl.gcc.competing), ctl.floorBps() / 1e6, @tagName(ctl.gcc.state),
                @tagName(ctl.gcc.usage),
            });
            win_sent = 0;
            win_recv = 0;
            win_lost = 0;
            next_sample += 100_000;
        }
        // sleep in poll when the next action is > 1.5 ms away, else spin
        const next_act = @min(next_frame, @min(next_sample, if (fhead < fifo.items.len) pacer_next else next_frame));
        const wait = next_act - nowUs();
        if (wait > 1_500) waitReadable(fd, @intCast(@divTrunc(wait - 1_000, 1000)));
    }

    // queue delay: OWD minus the min OWD within +-5 s (absorbs clock drift)
    var qd: std.ArrayList(f32) = .empty;
    defer qd.deinit(gpa);
    const ow = owds.items;
    const nb: usize = @as(usize, @intFromFloat(o.seconds)) + 4;
    const bmin = try gpa.alloc(i64, nb);
    defer gpa.free(bmin);
    @memset(bmin, std.math.maxInt(i64));
    const r0 = if (ow.len > 0) ow[0][0] else 0;
    for (ow) |x| {
        const b: usize = @intCast(std.math.clamp(@divTrunc(x[0] - r0, 1_000_000), 0, @as(i64, @intCast(nb - 1))));
        bmin[b] = @min(bmin[b], x[1]);
    }
    for (ow) |x| {
        const b: usize = @intCast(std.math.clamp(@divTrunc(x[0] - r0, 1_000_000), 0, @as(i64, @intCast(nb - 1))));
        var m: i64 = std.math.maxInt(i64);
        for (b -| 5..@min(nb, b + 6)) |k| m = @min(m, bmin[k]);
        if (x[0] - r0 > 3_000_000) try qd.append(gpa, @as(f32, @floatFromInt(x[1] - m)) / 1000);
    }
    std.mem.sort(f32, qd.items, {}, std.sort.asc(f32));
    // frame delay beyond the base OWD (capture to last packet)
    var fdl: std.ArrayList(f32) = .empty;
    defer fdl.deinit(gpa);
    var flost: u32 = 0;
    var base: i64 = std.math.maxInt(i64);
    for (ow) |x| base = @min(base, x[1]);
    for (frames.items) |f| {
        if (f.capture - t0 < 3_000_000 or f.capture > end - 500_000) continue;
        if (f.lost or f.arrived < f.npkts) {
            flost += 1;
            continue;
        }
        try fdl.append(gpa, @as(f32, @floatFromInt(f.last_arr - f.capture - base)) / 1000);
    }
    std.mem.sort(f32, fdl.items, {}, std.sort.asc(f32));
    const secs = @as(f64, @floatFromInt(nowUs() - t0)) / 1e6;
    const tl = ctl.telemetry(nowUs());
    std.debug.print("RESULT {s} qdelay_ms p50/95/99={d:.2}/{d:.2}/{d:.2} frames_lost={d}/{d} ctl={s} recv_mbps={d:.2} sent_pkts={d} lost={d} late={d} enobufs={d} frame_ms p50/95/99={d:.2}/{d:.2}/{d:.2} overuses={d} drains={d} giveups={d} jumps={d} competing_entries={d} competing_cuts={d} loss_cuts={d} probes={d}\n", .{
        o.tag,        pct(qd, 50),                                              pct(qd, 95),       pct(qd, 99),  flost,     frames.items.len,
        o.ctl,        @as(f64, @floatFromInt(tot_recv_bytes)) * 8 / secs / 1e6, seq,               lost,         late,      enobufs,
        pct(fdl, 50), pct(fdl, 95),                                             pct(fdl, 99),      tl.overuses,  tl.drains, tl.drain_giveups,
        tl.jumps,     tl.competing_entries,                                     tl.competing_cuts, tl.loss_cuts, tl.probes,
    });
    if (o.csv) |path| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = csv.items });
}

fn pct(xs: std.ArrayList(f32), p: usize) f32 {
    return pctf(xs.items, p);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.Usage;
    var to: ?Addr = null;
    var port: u16 = 0;
    var o = SendOpts{};
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--to")) to = try parseAddr(v);
        if (std.mem.eql(u8, k, "--port") or std.mem.eql(u8, k, "--listen")) port = try std.fmt.parseInt(u16, v, 10);
        if (std.mem.eql(u8, k, "--ctl")) o.ctl = v;
        if (std.mem.eql(u8, k, "--mbps")) o.mbps = try std.fmt.parseFloat(f64, v);
        if (std.mem.eql(u8, k, "--max-mbps")) o.max_mbps = try std.fmt.parseFloat(f64, v);
        if (std.mem.eql(u8, k, "--seconds")) o.seconds = try std.fmt.parseFloat(f64, v);
        if (std.mem.eql(u8, k, "--csv")) o.csv = v;
        if (std.mem.eql(u8, k, "--tag")) o.tag = v;
    }
    if (std.mem.eql(u8, args[1], "recv")) return runRecv(port, to);
    if (std.mem.eql(u8, args[1], "send")) return runSend(init, to, port, o);
    return error.Usage;
}
