//! Spike S10 harness: media datagrams over noq-proto, with the Zig side owning the UDP
//! socket, the event loop, timers, pacing and the media queue (and therefore every drop).
//!
//!   s10 recv   key=value...   QUIC server; logs per-datagram one-way delay (S2 format)
//!   s10 send   key=value...   QUIC client; S2 send schedule (smooth / 60 fps frames)
//!   s10 jitter key=value...   S4 handoff probe: t0 (media thread) -> sendto() entry
//!
//! libc is declared by hand below so the harness does not depend on Zig 0.16's
//! moving std.posix / std.Io surface.
const std = @import("std");
const build_options = @import("build_options");

// ---------------------------------------------------------------------------
// noq shim C ABI (shim/src/lib.rs)

const Nq = opaque {};
const NqAddr = extern struct { family: u16, port: u16, ip: [16]u8 };
const NqConfig = extern struct {
    is_server: c_int,
    cc_mode: c_int,
    target_bps: u64,
    datagram_send_buffer: usize,
    datagram_recv_buffer: usize,
    idle_timeout_ms: u32,
    keepalive_ms: u32,
};
const NqStats = extern struct {
    udp_tx: u64 = 0,
    udp_tx_bytes: u64 = 0,
    udp_rx: u64 = 0,
    udp_rx_bytes: u64 = 0,
    sent_packets: u64 = 0,
    lost_packets: u64 = 0,
    lost_bytes: u64 = 0,
    frame_tx_datagram: u64 = 0,
    frame_rx_datagram: u64 = 0,
    rtt_us: u64 = 0,
    cwnd: u64 = 0,
    congestion_events: u64 = 0,
    mtu: u64 = 0,
    send_blocked: u64 = 0,
};
extern fn nq_new(cfg: *const NqConfig, cert: ?[*]const u8, cert_len: usize) ?*Nq;
extern fn nq_cert_der(nq: *Nq, buf: [*]u8, cap: usize) isize;
extern fn nq_connect(nq: *Nq, now: u64, to: *const NqAddr) c_int;
extern fn nq_handle(nq: *Nq, now: u64, from: *const NqAddr, data: [*]const u8, len: usize) void;
extern fn nq_poll_transmit(nq: *Nq, now: u64, buf: [*]u8, cap: usize, to: *NqAddr) isize;
extern fn nq_timeout(nq: *Nq) u64;
extern fn nq_handle_timeout(nq: *Nq, now: u64) void;
extern fn nq_poll_event(nq: *Nq) c_int;
extern fn nq_send_datagram(nq: *Nq, data: [*]const u8, len: usize) c_int;
extern fn nq_recv_datagram(nq: *Nq, buf: [*]u8, cap: usize) isize;
extern fn nq_max_datagram(nq: *Nq) isize;
extern fn nq_stats(nq: *Nq, out: *NqStats) void;
extern fn nq_close(nq: *Nq, now: u64) void;
extern fn nq_is_closed(nq: *Nq) c_int;
const EV_CONNECTED = 1;
const EV_LOST = 2;

// ---------------------------------------------------------------------------
// libc

const timespec = extern struct { sec: i64, nsec: i64 };
const sockaddr_in = extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 = @splat(0) };
const pollfd = extern struct { fd: c_int, events: i16, revents: i16 = 0 };
const sched_param = extern struct { prio: c_int };
const cpu_set_t = extern struct { bits: [16]u64 = @splat(0) };
extern "c" fn clock_gettime(clk: c_int, ts: *timespec) c_int;
extern "c" fn clock_nanosleep(clk: c_int, flags: c_int, req: *const timespec, rem: ?*timespec) c_int;
extern "c" fn socket(d: c_int, t: c_int, p: c_int) c_int;
extern "c" fn bind(fd: c_int, a: *const anyopaque, l: u32) c_int;
extern "c" fn setsockopt(fd: c_int, lvl: c_int, opt: c_int, v: *const anyopaque, l: u32) c_int;
extern "c" fn sendto(fd: c_int, b: [*]const u8, n: usize, fl: c_int, a: *const anyopaque, l: u32) isize;
extern "c" fn recvfrom(fd: c_int, b: [*]u8, n: usize, fl: c_int, a: *anyopaque, l: *u32) isize;
extern "c" fn ppoll(fds: [*]pollfd, n: u64, ts: ?*const timespec, sig: ?*const anyopaque) c_int;
extern "c" fn eventfd(v: c_uint, fl: c_int) c_int;
extern "c" fn read(fd: c_int, b: *anyopaque, n: usize) isize;
extern "c" fn write(fd: c_int, b: *const anyopaque, n: usize) isize;
extern "c" fn sched_setaffinity(pid: c_int, sz: usize, set: *const cpu_set_t) c_int;
extern "c" fn pthread_self() usize;
extern "c" fn pthread_setschedparam(t: usize, pol: c_int, p: *const sched_param) c_int;
extern "c" fn fopen(p: [*:0]const u8, m: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(p: [*]const u8, sz: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fread(p: [*]u8, sz: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn unlink(p: [*:0]const u8) c_int;
extern "c" fn rename(a: [*:0]const u8, b: [*:0]const u8) c_int;
const AF_INET = 2;
const SOCK_DGRAM = 2;
const SOL_SOCKET = 1;
const IPPROTO_IP = 0;
const IP_TTL = 2;
const SO_SNDBUFFORCE = 32;
const SO_RCVBUFFORCE = 33;
const MSG_DONTWAIT = 0x40;
const POLLIN = 1;
const EFD_NONBLOCK = 0o4000;
const SCHED_FIFO = 1;

inline fn nowNs() u64 {
    var ts: timespec = undefined;
    _ = clock_gettime(1, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepUntil(t: u64) void {
    // coarse sleep, then spin the last 150 us (same as s2bench's schedule)
    while (true) {
        const n = nowNs();
        if (n >= t) return;
        const left = t - n;
        if (left > 200_000) {
            const d = t - 150_000;
            const ts: timespec = .{ .sec = @intCast(d / 1_000_000_000), .nsec = @intCast(d % 1_000_000_000) };
            _ = clock_nanosleep(1, 1, &ts, null);
        } else std.atomic.spinLoopHint();
    }
}

fn sleepUntilExact(t: u64) void {
    const ts: timespec = .{ .sec = @intCast(t / 1_000_000_000), .nsec = @intCast(t % 1_000_000_000) };
    while (clock_nanosleep(1, 1, &ts, null) != 0) {}
}

fn pin(cpu: i64, prio: i64) void {
    if (cpu >= 0) {
        var set: cpu_set_t = .{};
        set.bits[@intCast(@divTrunc(cpu, 64))] |= @as(u64, 1) << @intCast(@mod(cpu, 64));
        if (sched_setaffinity(0, @sizeOf(cpu_set_t), &set) != 0) std.debug.print("warning: affinity cpu={d}\n", .{cpu});
    }
    // prio 0 explicitly resets to SCHED_OTHER: threads inherit the creator's RT policy, and a
    // spinning media thread at SCHED_FIFO gets RT-throttled for 50 ms every second.
    const p: sched_param = .{ .prio = @intCast(@max(prio, 0)) };
    if (pthread_setschedparam(pthread_self(), if (prio > 0) SCHED_FIFO else 0, &p) != 0) std.debug.print("warning: sched prio {d}\n", .{prio});
}

// ---------------------------------------------------------------------------
// Args: key=value pairs

const Opts = struct {
    bind: []const u8 = "0.0.0.0:0",
    to: []const u8 = "",
    out: []const u8 = "",
    csv: []const u8 = "",
    cert: []const u8 = "/tmp/s10.cert",
    // traffic (send/jitter)
    mbps: f64 = 50,
    size: usize = 1100,
    secs: f64 = 10,
    warmup: f64 = 2,
    pattern: []const u8 = "smooth",
    fps: f64 = 60,
    // pacing / queue
    pace_mbps: f64 = 0, // Zig pacer target in payload Mbit/s; 0 = 1.05x offered; <0 = off
    credit_us: f64 = 2000, // Zig pacer burst credit
    maxq_us: f64 = 5000, // drop media older than this in the Zig queue (counted)
    cc: i64 = 0, // 0 = Zig paces (QUIC unpaced); 1 = noq-proto pacer at the target (AppRate)
    sbuf: usize = 1 << 20,
    rbuf: usize = 1250000,
    // threads
    gen_cpu: i64 = 1,
    net_cpu: i64 = 2,
    net_prio: i64 = 0,
    gen_prio: i64 = 0,
    // jitter mode (S4)
    mode: []const u8 = "thread", // inline | thread
    n: usize = 20000,
    interval_us: u64 = 1000,
    burst: usize = 1,
    load: usize = 0,
    warm_n: usize = 500,
    // punch demo
    role: []const u8 = "host", // host | client
    iroh_bind: []const u8 = "0.0.0.0:0",
    peer: []const u8 = "", // client: host's iroh ip:port
    pings: usize = 1000,
};

fn parseAddr(s: []const u8) !sockaddr_in {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadAddr;
    var a: sockaddr_in = .{ .family = AF_INET, .port = 0, .addr = .{ 0, 0, 0, 0 } };
    a.port = std.mem.nativeToBig(u16, try std.fmt.parseInt(u16, s[colon + 1 ..], 10));
    var it = std.mem.splitScalar(u8, s[0..colon], '.');
    for (0..4) |i| a.addr[i] = try std.fmt.parseInt(u8, it.next() orelse return error.BadAddr, 10);
    return a;
}

fn toNq(a: sockaddr_in) NqAddr {
    var r: NqAddr = .{ .family = 4, .port = std.mem.bigToNative(u16, a.port), .ip = @splat(0) };
    @memcpy(r.ip[0..4], &a.addr);
    return r;
}

fn fromNq(a: NqAddr) sockaddr_in {
    return .{ .family = AF_INET, .port = std.mem.nativeToBig(u16, a.port), .addr = a.ip[0..4].* };
}

fn parse(args: std.process.Args) !struct { cmd: []const u8, o: Opts } {
    var o: Opts = .{};
    var it = args.iterate();
    _ = it.skip();
    const cmd = it.next() orelse return error.NoCommand;
    while (it.next()) |a| {
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse return error.BadArg;
        const k = a[0..eq];
        const v = a[eq + 1 ..];
        var found = false;
        inline for (std.meta.fields(Opts)) |f| {
            if (std.mem.eql(u8, k, f.name)) {
                found = true;
                switch (f.type) {
                    []const u8 => @field(o, f.name) = v,
                    f64 => @field(o, f.name) = try std.fmt.parseFloat(f64, v),
                    else => @field(o, f.name) = @intCast(try std.fmt.parseInt(i64, v, 10)),
                }
            }
        }
        if (!found) {
            std.debug.print("unknown arg {s}\n", .{k});
            return error.UnknownArg;
        }
    }
    return .{ .cmd = cmd, .o = o };
}

fn zpath(buf: []u8, s: []const u8) [*:0]const u8 {
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

const Out = struct {
    f: *anyopaque,
    buf: [1 << 16]u8 = undefined,
    n: usize = 0,
    fn open(path: []const u8) !Out {
        var pb: [512]u8 = undefined;
        return .{ .f = fopen(zpath(&pb, path), "w") orelse return error.Open };
    }
    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        if (self.n > self.buf.len - 512) self.flush();
        const s = std.fmt.bufPrint(self.buf[self.n..], fmt, args) catch unreachable;
        self.n += s.len;
    }
    fn flush(self: *Out) void {
        _ = fwrite(&self.buf, 1, self.n, self.f);
        self.n = 0;
    }
    fn close(self: *Out) void {
        self.flush();
        _ = fclose(self.f);
    }
};

// ---------------------------------------------------------------------------
// UDP socket owned by Zig

fn udpSocket(bind_addr: sockaddr_in) !c_int {
    const fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return error.Socket;
    const sz: c_int = 4 << 20;
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUFFORCE, &sz, 4);
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUFFORCE, &sz, 4);
    if (bind(fd, &bind_addr, @sizeOf(sockaddr_in)) != 0) return error.Bind;
    return fd;
}

/// One QUIC connection driven by Zig: the socket, the timer, the transmit loop.
const Pipe = struct {
    nq: *Nq,
    fd: c_int,
    txbuf: [65536]u8 = undefined,
    rxbuf: [65536]u8 = undefined,
    udp_send_errs: u64 = 0,
    connected: bool = false,
    lost: bool = false,
    // optional probe: called with (len, t_entry, t_return) for each sendto
    probe: ?*Probe = null,

    fn sendAll(self: *Pipe, now: u64) u64 {
        var bytes: u64 = 0;
        while (true) {
            var to: NqAddr = undefined;
            const n = nq_poll_transmit(self.nq, now, &self.txbuf, self.txbuf.len, &to);
            if (n <= 0) break;
            const sa = fromNq(to);
            const t3 = if (self.probe != null) nowNs() else 0;
            if (sendto(self.fd, &self.txbuf, @intCast(n), 0, &sa, @sizeOf(sockaddr_in)) < 0) self.udp_send_errs += 1;
            if (self.probe) |p| p.onSend(@intCast(n), t3, nowNs());
            bytes += @intCast(n);
        }
        return bytes;
    }

    fn recvAll(self: *Pipe) void {
        while (true) {
            var from: sockaddr_in = undefined;
            var fl: u32 = @sizeOf(sockaddr_in);
            const n = recvfrom(self.fd, &self.rxbuf, self.rxbuf.len, MSG_DONTWAIT, &from, &fl);
            if (n <= 0) break;
            const a = toNq(from);
            nq_handle(self.nq, nowNs(), &a, &self.rxbuf, @intCast(n));
        }
    }

    fn service(self: *Pipe, now: u64) void {
        if (nq_timeout(self.nq) <= now) nq_handle_timeout(self.nq, now);
        while (true) {
            const ev = nq_poll_event(self.nq);
            if (ev == 0) break;
            if (ev == EV_CONNECTED) self.connected = true;
            if (ev == EV_LOST) self.lost = true;
        }
    }

    /// Block until the socket/eventfd is readable or `deadline` (monotonic ns).
    fn wait(self: *Pipe, efd: c_int, deadline: u64) void {
        var fds = [2]pollfd{ .{ .fd = self.fd, .events = POLLIN }, .{ .fd = efd, .events = POLLIN } };
        const now = nowNs();
        const nfds: u64 = if (efd >= 0) 2 else 1;
        if (deadline == std.math.maxInt(u64)) {
            _ = ppoll(&fds, nfds, null, null);
        } else if (deadline > now) {
            const d = deadline - now;
            const ts: timespec = .{ .sec = @intCast(d / 1_000_000_000), .nsec = @intCast(d % 1_000_000_000) };
            _ = ppoll(&fds, nfds, &ts, null);
        }
        if (efd >= 0 and fds[1].revents != 0) {
            var v: u64 = 0;
            _ = read(efd, &v, 8);
        }
    }
};

// ---------------------------------------------------------------------------
// SPSC ring: media thread -> network thread

const SLOT = 1280;
const Slot = struct { len: u32, ts: u64, seq: u64, data: [SLOT]u8 };
const Ring = struct {
    slots: []Slot,
    head: std.atomic.Value(u64) = .init(0), // consumer
    tail: std.atomic.Value(u64) = .init(0), // producer
    sleeping: std.atomic.Value(bool) = .init(false),
    efd: c_int,
    full_drops: u64 = 0,

    fn push(self: *Ring, data: []const u8, ts: u64, seq: u64) void {
        const t = self.tail.load(.monotonic);
        if (t - self.head.load(.acquire) >= self.slots.len) {
            self.full_drops += 1;
            return;
        }
        const s = &self.slots[t % self.slots.len];
        @memcpy(s.data[0..data.len], data);
        s.len = @intCast(data.len);
        s.ts = ts;
        s.seq = seq;
        self.tail.store(t + 1, .seq_cst);
        if (self.sleeping.load(.seq_cst)) {
            const one: u64 = 1;
            _ = write(self.efd, &one, 8);
        }
    }
    fn peek(self: *Ring) ?*Slot {
        const h = self.head.load(.monotonic);
        if (h == self.tail.load(.acquire)) return null;
        return &self.slots[h % self.slots.len];
    }
    fn pop(self: *Ring) void {
        _ = self.head.fetchAdd(1, .release);
    }
    fn empty(self: *Ring) bool {
        return self.head.load(.monotonic) == self.tail.load(.acquire);
    }
};

// ---------------------------------------------------------------------------
// S4 probe: match QUIC packets to datagrams in FIFO order (one 1150 B datagram per packet)

const Probe = struct {
    t0: []u64,
    t1: []u64,
    t3: []u64,
    t4: []u64,
    min_len: usize,
    next: usize = 0, // next datagram index awaiting its packet
    queued: usize = 0, // datagrams handed to noq so far
    fn onSend(self: *Probe, len: usize, t3: u64, t4: u64) void {
        if (len < self.min_len) return;
        if (self.next < self.queued) {
            self.t3[self.next] = t3;
            self.t4[self.next] = t4;
            self.next += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// recv

fn readCert(path: []const u8, buf: []u8) !usize {
    var pb: [512]u8 = undefined;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (fopen(zpath(&pb, path), "r")) |f| {
            const n = fread(buf.ptr, 1, buf.len, f);
            _ = fclose(f);
            if (n > 0) return n;
        }
        sleepUntilExact(nowNs() + 50_000_000);
    }
    return error.NoCert;
}

const Rec = struct { seq: u64, send: u64, frame: u64, fts: u64, recv: u64, handoff: u64 };

fn cmdRecv(o: Opts, gpa: std.mem.Allocator) !void {
    pin(o.net_cpu, o.net_prio);
    const cfg: NqConfig = .{ .is_server = 1, .cc_mode = @intCast(o.cc), .target_bps = 0, .datagram_send_buffer = o.sbuf, .datagram_recv_buffer = o.rbuf, .idle_timeout_ms = 5000, .keepalive_ms = 0 };
    const nq = nq_new(&cfg, null, 0) orelse return error.Nq;
    // publish the cert (stands in for the iroh control stream)
    var der: [4096]u8 = undefined;
    const dn: usize = @intCast(nq_cert_der(nq, &der, der.len));
    {
        var tmp: [520]u8 = undefined;
        const tpath = try std.fmt.bufPrint(&tmp, "{s}.tmp", .{o.cert});
        var o2 = try Out.open(tpath);
        @memcpy(o2.buf[0..dn], der[0..dn]);
        o2.n = dn;
        o2.close();
        var a: [520]u8 = undefined;
        var b: [520]u8 = undefined;
        _ = rename(zpath(&a, tpath), zpath(&b, o.cert));
    }
    const fd = try udpSocket(try parseAddr(o.bind));
    var pipe: Pipe = .{ .nq = nq, .fd = fd };
    const recs = try gpa.alloc(Rec, 4_000_000);
    var nrec: usize = 0;
    var dbuf: [2048]u8 = undefined;
    var ever = false;
    var last_rx = nowNs();
    while (true) {
        pipe.recvAll();
        const now = nowNs();
        pipe.service(now);
        while (true) {
            const n = nq_recv_datagram(nq, &dbuf, dbuf.len);
            if (n <= 0) break;
            const r = nowNs();
            last_rx = r;
            if (nrec < recs.len and n >= 32) {
                recs[nrec] = .{
                    .seq = std.mem.readInt(u64, dbuf[0..8], .little),
                    .send = std.mem.readInt(u64, dbuf[8..16], .little),
                    .frame = std.mem.readInt(u64, dbuf[16..24], .little),
                    .fts = std.mem.readInt(u64, dbuf[24..32], .little),
                    .recv = r,
                    .handoff = if (n >= 40) std.mem.readInt(u64, dbuf[32..40], .little) else 0,
                };
                nrec += 1;
            }
        }
        _ = pipe.sendAll(now);
        if (pipe.connected) ever = true;
        if (pipe.lost or (ever and nq_is_closed(nq) != 0)) break;
        if (ever and nowNs() - last_rx > 8_000_000_000) break;
        pipe.wait(-1, nq_timeout(nq));
    }
    var st: NqStats = .{};
    nq_stats(nq, &st);
    if (o.csv.len > 0) {
        var w = try Out.open(o.csv);
        w.print("seq,send_ns,frame,frame_ns,recv_ns\n", .{});
        for (recs[0..nrec]) |r| w.print("{d},{d},{d},{d},{d}\n", .{ r.seq, r.send, r.frame, r.fts, r.recv });
        w.close();
        var pb: [520]u8 = undefined;
        var wq = try Out.open(try std.fmt.bufPrint(&pb, "{s}.handoff", .{o.csv}));
        wq.print("seq,handoff_ns\n", .{});
        for (recs[0..nrec]) |r| wq.print("{d},{d}\n", .{ r.seq, r.handoff });
        wq.close();
    }
    if (o.out.len > 0) {
        var w = try Out.open(o.out);
        w.print("{{\"app_received\": {d}, \"conn\": {{\"frame_rx_datagram\": {d}, \"frame_tx_datagram\": {d}, \"udp_rx\": {d}, \"udp_tx\": {d}, \"lost_packets\": {d}, \"rtt_us\": {d}}}}}\n", .{ nrec, st.frame_rx_datagram, st.frame_tx_datagram, st.udp_rx, st.udp_tx, st.lost_packets, st.rtt_us });
        w.close();
    }
    std.debug.print("recv done: {d} datagrams\n", .{nrec});
}

// ---------------------------------------------------------------------------
// send: generator thread -> ring -> network thread (socket, timers, pacer, drops)

const SendShared = struct {
    ring: Ring,
    connected: std.atomic.Value(bool) = .init(false),
    gen_done: std.atomic.Value(bool) = .init(false),
    sent: u64 = 0,
    warm: u64 = 0,
};

fn writeHeader(buf: []u8, seq: u64, frame: u64, fts: u64) u64 {
    std.mem.writeInt(u64, buf[0..8], seq, .little);
    std.mem.writeInt(u64, buf[16..24], frame, .little);
    std.mem.writeInt(u64, buf[24..32], fts, .little);
    const t = nowNs();
    std.mem.writeInt(u64, buf[8..16], t, .little);
    return t;
}

fn genThread(sh: *SendShared, o: Opts) void {
    pin(o.gen_cpu, o.gen_prio);
    while (!sh.connected.load(.acquire)) sleepUntilExact(nowNs() + 1_000_000);
    var buf: [SLOT]u8 = undefined;
    @memset(&buf, 0xAB);
    const bps = o.mbps * 1e6 / 8.0;
    const total = o.warmup + o.secs;
    const start = nowNs() + 1_000_000;
    var seq: u64 = 0;
    const smooth = std.mem.eql(u8, o.pattern, "smooth");
    if (smooth) {
        const interval = 1e9 * @as(f64, @floatFromInt(o.size)) / bps;
        const n: u64 = @intFromFloat(total * 1e9 / interval);
        const wn: u64 = @intFromFloat(o.warmup * 1e9 / interval);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const t = start + @as(u64, @intFromFloat(@as(f64, @floatFromInt(i)) * interval));
            sleepUntil(t);
            const ts = writeHeader(&buf, seq, i, t);
            sh.ring.push(buf[0..o.size], ts, seq);
            if (i < wn) sh.warm += 1;
            seq += 1;
        }
    } else {
        const per: u64 = @intFromFloat(@max(1.0, @round(bps / o.fps / @as(f64, @floatFromInt(o.size)))));
        const nf: u64 = @intFromFloat(total * o.fps);
        const wf: u64 = @intFromFloat(o.warmup * o.fps);
        var f: u64 = 0;
        while (f < nf) : (f += 1) {
            const t = start + @as(u64, @intFromFloat(@as(f64, @floatFromInt(f)) * 1e9 / o.fps));
            sleepUntil(t);
            for (0..per) |_| {
                const ts = writeHeader(&buf, seq, f, t);
                sh.ring.push(buf[0..o.size], ts, seq);
                if (f < wf) sh.warm += 1;
                seq += 1;
            }
        }
    }
    sh.sent = seq;
    sh.gen_done.store(true, .release);
    const one: u64 = 1;
    _ = write(sh.ring.efd, &one, 8);
}

fn cmdSend(o: Opts, gpa: std.mem.Allocator) !void {
    var der: [4096]u8 = undefined;
    const dn = try readCert(o.cert, &der);
    // Zig pacer target in QUIC-packet bytes/s (payload scaled by ~30 B/datagram overhead, as s2bench)
    const pace_payload_mbps: f64 = if (o.pace_mbps == 0) o.mbps * 1.05 else o.pace_mbps;
    const pace_on = o.pace_mbps >= 0 and o.cc == 0;
    const size_f: f64 = @floatFromInt(o.size);
    const rate_Bps: f64 = pace_payload_mbps * 1e6 / 8.0 * (size_f + 30.0) / size_f;
    const cfg: NqConfig = .{
        .is_server = 0,
        .cc_mode = @intCast(o.cc),
        .target_bps = if (o.cc == 1) @intFromFloat(rate_Bps * 8) else 0,
        .datagram_send_buffer = o.sbuf,
        .datagram_recv_buffer = o.rbuf,
        .idle_timeout_ms = 5000,
        .keepalive_ms = 0,
    };
    const nq = nq_new(&cfg, &der, dn) orelse return error.Nq;
    const fd = try udpSocket(try parseAddr(o.bind));
    var pipe: Pipe = .{ .nq = nq, .fd = fd };
    const efd = eventfd(0, EFD_NONBLOCK);
    const sh = try gpa.create(SendShared);
    sh.* = .{ .ring = .{ .slots = try gpa.alloc(Slot, 1 << 16), .efd = efd } };

    pin(o.net_cpu, o.net_prio);
    const to = toNq(try parseAddr(o.to));
    if (nq_connect(nq, nowNs(), &to) != 0) return error.Connect;
    const gen = try std.Thread.spawn(.{}, genThread, .{ sh, o });

    const credit: f64 = rate_Bps * o.credit_us / 1e6;
    var tokens: f64 = credit;
    var last = nowNs();
    const maxq: u64 = if (o.maxq_us > 0) @intFromFloat(o.maxq_us * 1000) else std.math.maxInt(u64);
    var qdrops: u64 = 0;
    var handed: u64 = 0;
    var blocked_waits: u64 = 0;
    var pacer_waits: u64 = 0;
    var drain_until: u64 = std.math.maxInt(u64);
    var max_qdelay: u64 = 0;
    var spin_guard: u64 = 0;
    var wakeups: u64 = 0;
    while (true) {
        wakeups += 1;
        pipe.recvAll();
        const now = nowNs();
        pipe.service(now);
        if (pipe.connected and !sh.connected.load(.monotonic)) sh.connected.store(true, .release);
        if (pipe.lost) break;
        // pacer refill
        if (pace_on) {
            tokens = @min(credit, tokens + rate_Bps * @as(f64, @floatFromInt(now - last)) / 1e9);
        }
        last = now;
        // drop stale media at the head of our queue (counted: this is the only place we drop)
        while (sh.ring.peek()) |s| {
            if (now -| s.ts <= maxq) break;
            qdrops += 1;
            sh.ring.pop();
        }
        // hand media to QUIC as the pacer allows; every packet leaves immediately
        var blocked = false;
        while (sh.ring.peek()) |s| {
            if (pace_on and tokens <= 0) break;
            // diagnostic: stamp the hand-off to QUIC at bytes 32..40, so the receiver can split
            // one-way delay into "Zig queue + pacer" and "QUIC + socket + network + receiver"
            if (s.len >= 40) std.mem.writeInt(u64, s.data[32..40], nowNs(), .little);
            const rc = nq_send_datagram(nq, &s.data, s.len);
            if (rc == 1) {
                blocked = true;
                blocked_waits += 1;
                break;
            }
            max_qdelay = @max(max_qdelay, now -| s.ts);
            sh.ring.pop();
            handed += 1;
            const b = pipe.sendAll(nowNs());
            if (pace_on) tokens -= @floatFromInt(b);
        }
        const b = pipe.sendAll(nowNs());
        if (pace_on) tokens -= @floatFromInt(b);

        if (sh.gen_done.load(.acquire) and sh.ring.empty() and drain_until == std.math.maxInt(u64))
            drain_until = nowNs() + 1_500_000_000;
        if (nowNs() >= drain_until) break;

        // next wake: QUIC timer, pacer credit, queue head expiry, drain end
        var dl = @min(nq_timeout(nq), drain_until);
        const had_items = !sh.ring.empty();
        if (sh.ring.peek()) |s| {
            if (blocked) {
                dl = @min(dl, nowNs() + 200_000);
            } else if (pace_on and tokens <= 0) {
                pacer_waits += 1;
                // tokens were last refilled at `now`; wait until the deficit is earned back
                dl = @min(dl, now + @as(u64, @intFromFloat((-tokens + 1) * 1e9 / rate_Bps)));
                spin_guard += @intFromBool(dl <= nowNs());
            } else dl = now;
            dl = @min(dl, s.ts +| maxq);
        }
        if (dl > nowNs()) {
            sh.ring.sleeping.store(true, .seq_cst);
            // don't sleep on a deadline computed for an empty queue if media arrived since
            if (had_items or sh.ring.empty()) pipe.wait(efd, dl);
            sh.ring.sleeping.store(false, .seq_cst);
        }
    }
    gen.join();
    var st: NqStats = .{};
    nq_stats(nq, &st);
    nq_close(nq, nowNs());
    _ = pipe.sendAll(nowNs());
    if (o.out.len > 0) {
        var w = try Out.open(o.out);
        w.print(
            \\{{"app_sent": {d}, "warmup_sent": {d}, "zig_queue_dropped": {d}, "ring_full_dropped": {d}, "handed_to_quic": {d},
            \\ "send_blocked": {d}, "pacer_waits": {d}, "max_zig_queue_delay_us": {d}, "udp_send_errors": {d}, "loop_iterations": {d}, "pacer_deadline_already_past": {d},
            \\ "send_buffer_would_drop": 0, "cc": "{s}", "pace_payload_mbps": {d:.1}, "credit_us": {d:.0}, "maxq_us": {d:.0},
            \\ "conn": {{"frame_tx_datagram": {d}, "frame_rx_datagram": {d}, "udp_tx": {d}, "udp_tx_bytes": {d}, "udp_rx": {d},
            \\ "sent_packets": {d}, "lost_packets": {d}, "lost_bytes": {d}, "paths": [{{"rtt_us": {d}, "cwnd": {d}, "congestion_events": {d}, "mtu": {d}}}]}}}}
            \\
        , .{
            sh.sent,               sh.warm,      qdrops,                         sh.ring.full_drops, handed,
            st.send_blocked,       pacer_waits,  max_qdelay / 1000,              pipe.udp_send_errs, wakeups, spin_guard, if (o.cc == 0) "zig" else "noq-rate",
            pace_payload_mbps,     o.credit_us,  o.maxq_us,                      st.frame_tx_datagram, st.frame_rx_datagram,
            st.udp_tx,             st.udp_tx_bytes, st.udp_rx,                   st.sent_packets,    st.lost_packets,
            st.lost_bytes,         st.rtt_us,    st.cwnd,                        st.congestion_events, st.mtu,
        });
        w.close();
    }
    std.debug.print("send done: sent={d} handed={d} qdrops={d} lost={d} blocked={d}\n", .{ sh.sent, handed, qdrops, st.lost_packets, blocked_waits });
}

// ---------------------------------------------------------------------------
// jitter (S4): Zig media thread stamps t0; measure to the sendto() that carries it

var stop_load = std.atomic.Value(bool).init(false);
fn loadThread(i: usize) void {
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

const JShared = struct {
    ring: Ring,
    probe: Probe,
    connected: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

fn jitterMedia(sh: *JShared, o: Opts) void {
    pin(o.gen_cpu, o.gen_prio);
    while (!sh.connected.load(.acquire)) sleepUntilExact(nowNs() + 1_000_000);
    var buf: [SLOT]u8 = undefined;
    @memset(&buf, 0xAB);
    const total = o.n + o.warm_n;
    var seq: u64 = 0;
    var next = nowNs() + 10_000_000;
    while (seq < total) {
        sleepUntilExact(next);
        next += o.interval_us * 1000;
        for (0..o.burst) |_| {
            if (seq >= total) break;
            std.mem.writeInt(u64, buf[0..8], seq, .little);
            const t0 = nowNs();
            sh.probe.t0[seq] = t0;
            sh.ring.push(buf[0..o.size], t0, seq);
            seq += 1;
        }
    }
    sleepUntilExact(nowNs() + 200_000_000);
    sh.done.store(true, .release);
    const one: u64 = 1;
    _ = write(sh.ring.efd, &one, 8);
}

fn cmdJitter(o: Opts, gpa: std.mem.Allocator) !void {
    var der: [4096]u8 = undefined;
    const dn = try readCert(o.cert, &der);
    const cfg: NqConfig = .{ .is_server = 0, .cc_mode = 0, .target_bps = 0, .datagram_send_buffer = o.sbuf, .datagram_recv_buffer = o.rbuf, .idle_timeout_ms = 5000, .keepalive_ms = 0 };
    const nq = nq_new(&cfg, &der, dn) orelse return error.Nq;
    const fd = try udpSocket(try parseAddr(o.bind));
    const total = o.n + o.warm_n;
    const sh = try gpa.create(JShared);
    sh.* = .{
        .ring = .{ .slots = try gpa.alloc(Slot, 1 << 12), .efd = eventfd(0, EFD_NONBLOCK) },
        .probe = .{ .t0 = try gpa.alloc(u64, total), .t1 = try gpa.alloc(u64, total), .t3 = try gpa.alloc(u64, total), .t4 = try gpa.alloc(u64, total), .min_len = o.size },
    };
    @memset(sh.probe.t3, 0);
    var pipe: Pipe = .{ .nq = nq, .fd = fd, .probe = &sh.probe };
    var loads: [64]std.Thread = undefined;
    for (0..o.load) |i| loads[i] = try std.Thread.spawn(.{}, loadThread, .{i});
    const inline_mode = std.mem.eql(u8, o.mode, "inline");

    // "thread": a dedicated network thread (this one) owns socket+QUIC; the media thread hands
    // datagrams over an SPSC ring + eventfd. "inline": the media thread is the network thread.
    if (inline_mode) pin(o.gen_cpu, o.gen_prio) else pin(o.net_cpu, o.net_prio);
    const to = toNq(try parseAddr(o.to));
    if (nq_connect(nq, nowNs(), &to) != 0) return error.Connect;
    var media: ?std.Thread = null;
    if (!inline_mode) media = try std.Thread.spawn(.{}, jitterMedia, .{ sh, o });

    var seq: u64 = 0;
    var next_send: u64 = std.math.maxInt(u64);
    var dbuf: [SLOT]u8 = undefined;
    @memset(&dbuf, 0xAB);
    while (true) {
        pipe.recvAll();
        var now = nowNs();
        pipe.service(now);
        if (pipe.connected and !sh.connected.load(.monotonic)) {
            sh.connected.store(true, .release);
            if (inline_mode) next_send = now + 10_000_000;
        }
        if (inline_mode) {
            if (now >= next_send and seq < total) {
                // the media thread sends a whole burst straight through QUIC to the socket
                next_send += o.interval_us * 1000;
                for (0..o.burst) |_| {
                    if (seq >= total) break;
                    std.mem.writeInt(u64, dbuf[0..8], seq, .little);
                    const t0 = nowNs();
                    sh.probe.t0[seq] = t0;
                    sh.probe.t1[seq] = t0;
                    _ = nq_send_datagram(nq, &dbuf, o.size);
                    sh.probe.queued += 1;
                    _ = pipe.sendAll(nowNs());
                    seq += 1;
                }
                if (seq >= total) next_send = nowNs() + 200_000_000;
            } else if (seq >= total and now >= next_send) break;
        } else {
            while (sh.ring.peek()) |s| {
                sh.probe.t1[s.seq] = nowNs();
                _ = nq_send_datagram(nq, &s.data, s.len);
                sh.probe.queued += 1;
                sh.ring.pop();
                _ = pipe.sendAll(nowNs());
            }
            if (sh.done.load(.acquire) and sh.ring.empty()) break;
        }
        _ = pipe.sendAll(nowNs());
        now = nowNs();
        var dl = nq_timeout(nq);
        if (inline_mode) {
            // sleep in clock_nanosleep (like the S4 sender) when the next send is closer than
            // any QUIC timer, so the send itself isn't gated on ppoll's wake latency
            if (next_send <= dl and next_send != std.math.maxInt(u64)) {
                if (seq < total) {
                    sleepUntilExact(next_send);
                    continue;
                }
                dl = next_send;
            }
            pipe.wait(-1, dl);
        } else {
            sh.ring.sleeping.store(true, .seq_cst);
            if (sh.ring.empty()) pipe.wait(sh.ring.efd, dl);
            sh.ring.sleeping.store(false, .seq_cst);
        }
    }
    if (media) |m| m.join();
    stop_load.store(true, .monotonic);
    for (0..o.load) |i| loads[i].join();
    nq_close(nq, nowNs());
    _ = pipe.sendAll(nowNs());

    // S4-compatible dump: <out>.seq.csv (seq,t0,t1,t2,t3,t4) and an empty <out>.ev.csv
    var pb: [520]u8 = undefined;
    var w = try Out.open(try std.fmt.bufPrint(&pb, "{s}.seq.csv", .{o.out}));
    w.print("seq,t0,t1,t2,t3,t4\n", .{});
    for (0..total) |i| w.print("{d},{d},{d},0,{d},{d}\n", .{ i, sh.probe.t0[i], sh.probe.t1[i], sh.probe.t3[i], sh.probe.t4[i] });
    w.close();
    var w2 = try Out.open(try std.fmt.bufPrint(&pb, "{s}.ev.csv", .{o.out}));
    w2.print("t3,t4,len,segs\n", .{});
    w2.close();
    std.debug.print("jitter done: mode={s} n={d} matched={d}\n", .{ o.mode, total, sh.probe.next });
}

pub fn main(init: std.process.Init.Minimal) !void {
    const p = try parse(init.args);
    const gpa = std.heap.c_allocator;
    if (std.mem.eql(u8, p.cmd, "recv")) return cmdRecv(p.o, gpa);
    if (std.mem.eql(u8, p.cmd, "send")) return cmdSend(p.o, gpa);
    if (std.mem.eql(u8, p.cmd, "jitter")) return cmdJitter(p.o, gpa);
    if (build_options.rv and std.mem.eql(u8, p.cmd, "punch")) return cmdPunch(p.o);
    return error.UnknownCommand;
}

// ---------------------------------------------------------------------------
// punch (needs -Drv=true): iroh dials and exchanges media candidates + cert over a control
// stream; then the Zig media socket punches and noq-proto connects; then a datagram ping-pong.

extern fn nq_rv(host: i32, iroh_bind: [*:0]const u8, peer: ?[*:0]const u8, media_port: u16, my: [*]const NqAddr, n_my: usize, cert: ?[*]const u8, cert_len: usize, out: [*]NqAddr, cap: usize, cert_out: ?[*]u8, cert_cap: usize, cert_out_len: *usize) i32;

const PUNCH = "S10PUNCH";
const PUNCH_ACK = "S10P-ACK";

fn sameAddr(a: NqAddr, b: NqAddr) bool {
    return a.port == b.port and std.mem.eql(u8, a.ip[0..4], b.ip[0..4]);
}

fn cmdPunch(o: Opts) !void {
    const host = std.mem.eql(u8, o.role, "host");
    const bind_sa = try parseAddr(o.bind);
    const fd = try udpSocket(bind_sa);
    const me = toNq(bind_sa);
    var cert: [4096]u8 = undefined;
    var cert_len: usize = 0;
    const cfg: NqConfig = .{ .is_server = @intFromBool(host), .cc_mode = 0, .target_bps = 0, .datagram_send_buffer = o.sbuf, .datagram_recv_buffer = o.rbuf, .idle_timeout_ms = 5000, .keepalive_ms = 1000 };
    var nq: ?*Nq = null;
    if (host) {
        nq = nq_new(&cfg, null, 0) orelse return error.Nq;
        cert_len = @intCast(nq_cert_der(nq.?, &cert, cert.len));
    }
    var pb1: [128]u8 = undefined;
    var pb2: [128]u8 = undefined;
    var cands: [16]NqAddr = undefined;
    var peer_cert: [4096]u8 = undefined;
    var peer_cert_len: usize = 0;
    const t_rv = nowNs();
    const nc = nq_rv(@intFromBool(host), zpath(&pb1, o.iroh_bind), if (host) null else zpath(&pb2, o.peer), me.port, @ptrCast(&me), 1, if (host) &cert else null, cert_len, &cands, cands.len, &peer_cert, peer_cert.len, &peer_cert_len);
    if (nc < 0) return error.Rendezvous;
    const t_rv_done = nowNs();
    std.debug.print("{s}: rendezvous over iroh took {d} ms; peer media candidates:", .{ o.role, (t_rv_done - t_rv) / 1_000_000 });
    for (cands[0..@intCast(nc)]) |c| std.debug.print(" {d}.{d}.{d}.{d}:{d}", .{ c.ip[0], c.ip[1], c.ip[2], c.ip[3], c.port });
    std.debug.print("\n", .{});
    if (!host) nq = nq_new(&cfg, &peer_cert, peer_cert_len) orelse return error.Nq;
    var pipe: Pipe = .{ .nq = nq.?, .fd = fd };

    // punch: both sides spray small probes at every peer candidate every 20 ms; a probe is
    // answered with an ack; the client connects to the first candidate that acks.
    var chosen: ?NqAddr = null;
    const deadline = nowNs() + 3_000_000_000;
    // The naive version had both sides probe at once. If the host's probe reaches the
    // client's NAT before the client has opened its mapping, Linux conntrack records it as an
    // inbound flow on the guessed port and MASQUERADE then maps the client to a different port
    // (seen in the first run of this demo), so the host's guess never matches.
    //
    // Fix used here (the classic TTL trick): both sides first send "opening" probes with TTL 2.
    // They create each side's own NAT mapping (on the port it asked for) and expire at the next
    // router, before reaching the other NAT. Normal probes start 100 ms later. On the internet the
    // opening TTL would be a few hops short of the peer, from the path's hop count.
    const opening_ttl: c_int = 2;
    const normal_ttl: c_int = 64;
    _ = setsockopt(fd, IPPROTO_IP, IP_TTL, &opening_ttl, 4);
    for (cands[0..@intCast(nc)]) |c| {
        const sa = fromNq(c);
        _ = sendto(fd, PUNCH, PUNCH.len, 0, &sa, @sizeOf(sockaddr_in));
    }
    sleepUntilExact(nowNs() + 100_000_000);
    _ = setsockopt(fd, IPPROTO_IP, IP_TTL, &normal_ttl, 4);
    var next_probe: u64 = 0;
    var probes: usize = 0;
    var buf: [2048]u8 = undefined;
    var t_punched: u64 = 0;
    var t_connected: u64 = 0;
    var pongs: usize = 0;
    var rtts = std.mem.zeroes([4096]u64);
    var sent_pings: usize = 0;
    var next_ping: u64 = 0;
    while (nowNs() < deadline or pipe.connected) {
        const now = nowNs();
        if (!pipe.connected and now >= next_probe and (chosen == null or host)) {
            for (cands[0..@intCast(nc)]) |c| {
                const sa = fromNq(c);
                _ = sendto(fd, PUNCH, PUNCH.len, 0, &sa, @sizeOf(sockaddr_in));
                probes += 1;
            }
            next_probe = now + 20_000_000;
        }
        // receive: probes are ours, everything else is QUIC
        while (true) {
            var from: sockaddr_in = undefined;
            var fl: u32 = @sizeOf(sockaddr_in);
            const n = recvfrom(fd, &buf, buf.len, MSG_DONTWAIT, &from, &fl);
            if (n <= 0) break;
            const len: usize = @intCast(n);
            const a = toNq(from);
            if (len == PUNCH.len and std.mem.eql(u8, buf[0..len], PUNCH)) {
                _ = sendto(fd, PUNCH_ACK, PUNCH_ACK.len, 0, &from, @sizeOf(sockaddr_in));
                continue;
            }
            if (len == PUNCH_ACK.len and std.mem.eql(u8, buf[0..len], PUNCH_ACK)) {
                if (chosen == null and !host) {
                    chosen = a;
                    t_punched = nowNs();
                    std.debug.print("client: punched to {d}.{d}.{d}.{d}:{d} after {d} probes, connecting\n", .{ a.ip[0], a.ip[1], a.ip[2], a.ip[3], a.port, probes });
                    _ = nq_connect(nq.?, nowNs(), &a);
                }
                continue;
            }
            nq_handle(nq.?, nowNs(), &a, &buf, len);
        }
        pipe.service(nowNs());
        if (pipe.connected and t_connected == 0) {
            t_connected = nowNs();
            std.debug.print("{s}: noq-proto media connection up\n", .{o.role});
            next_ping = t_connected;
        }
        if (pipe.lost) break;
        // ping-pong: client sends a timestamped datagram, host echoes it
        if (pipe.connected) {
            while (true) {
                const n = nq_recv_datagram(nq.?, &buf, buf.len);
                if (n <= 0) break;
                if (host) {
                    _ = nq_send_datagram(nq.?, &buf, @intCast(n));
                } else {
                    const t = std.mem.readInt(u64, buf[0..8], .little);
                    if (pongs < rtts.len) rtts[pongs] = nowNs() - t;
                    pongs += 1;
                }
            }
            if (!host and sent_pings < o.pings and nowNs() >= next_ping) {
                std.mem.writeInt(u64, buf[0..8], nowNs(), .little);
                _ = nq_send_datagram(nq.?, &buf, 1100);
                sent_pings += 1;
                next_ping += 2_000_000;
            }
            if (!host and pongs >= o.pings) break;
            if (!host and sent_pings >= o.pings and nowNs() > next_ping + 1_000_000_000) break;
        }
        _ = pipe.sendAll(nowNs());
        var dl = nq_timeout(nq.?);
        if (!pipe.connected) dl = @min(dl, next_probe);
        if (pipe.connected and !host) dl = @min(dl, next_ping);
        pipe.wait(-1, @min(dl, nowNs() + 50_000_000));
    }
    if (!host) {
        if (t_connected == 0) {
            std.debug.print("client: no media path after {d} probes; would fall back to iroh datagrams\n", .{probes});
            return;
        }
        const r = rtts[0..@min(pongs, rtts.len)];
        std.mem.sort(u64, r, {}, std.sort.asc(u64));
        std.debug.print("client: punch {d} ms, QUIC handshake {d} ms; {d}/{d} pongs, RTT p50 {d} us p99 {d} us\n", .{
            (t_punched - t_rv_done) / 1_000_000, (t_connected - t_punched) / 1_000_000, pongs, sent_pings,
            if (r.len > 0) r[r.len / 2] / 1000 else 0, if (r.len > 0) r[r.len * 99 / 100] / 1000 else 0,
        });
        nq_close(nq.?, nowNs());
        _ = pipe.sendAll(nowNs());
    }
}
