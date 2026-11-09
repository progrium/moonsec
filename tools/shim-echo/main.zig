//! S1 echo harness for the iroh shim.
//!
//!   shim-echo selftest [--relay] [-n COUNT]   two endpoints in one process, datagram echo
//!   shim-echo selftest --relay-url URL [--relay-ca PEM_FILE] [-n COUNT]
//!                                             same, both endpoints on one relay only (a smoke
//!                                             test for a self-hosted relay, see relay/README.md)
//!   shim-echo listen                          print a ticket, echo datagrams until killed
//!   shim-echo dial TICKET [-n COUNT]          send COUNT datagrams to a listener, check echoes
//!   shim-echo sink BIND_ADDR TICKET_FILE [--relay-url URL] [--relay-ca PEM_FILE]
//!                                             relays off (or only URL); write the ticket to TICKET_FILE, then
//!                                             count datagrams and report counts every 20 ms
//!                                             (peer for transport/iroh_netns_test.zig)
//!   shim-echo serve TICKET_FILE [--relay-url URL] [--relay-ca PEM_FILE]
//!                                             relay only (n0's without URL); write the ticket, then
//!                                             serve every connection: echo datagrams and
//!                                             bidirectional streams, plus the blast/sink
//!                                             commands below (peer for shim-web/test)
//!
//! Exit status 0 means every datagram came back intact.
const std = @import("std");
const iroh = @import("iroh");

const alpn = "moonsec/s1-echo/0";
const payload_len = 1150; // design doc: video packets ~1150 bytes

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();

    var count: u32 = 100;
    var relay = false;
    var ticket: ?[:0]const u8 = null;
    var extra: ?[:0]const u8 = null;
    var relay_url: ?[:0]const u8 = null;
    var relay_ca: ?[:0]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-n") and i + 1 < args.len) {
            i += 1;
            count = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--relay-url") and i + 1 < args.len) {
            i += 1;
            relay_url = args[i];
        } else if (std.mem.eql(u8, a, "--relay-ca") and i + 1 < args.len) {
            i += 1;
            relay_ca = std.Io.Dir.cwd().readFileAllocOptions(init.io, args[i], arena, .limited(1 << 20), .of(u8), 0) catch |e| {
                std.debug.print("cannot read --relay-ca {s}: {t}\n", .{ args[i], e });
                return e;
            };
        } else if (std.mem.eql(u8, a, "--relay")) {
            relay = true;
        } else if (ticket == null) {
            ticket = a;
        } else {
            extra = a;
        }
    }

    iroh.init(onShimThread, null) catch |e| return die("init", e);
    std.debug.print("iroh shim ABI v{x}\n", .{iroh.version()});
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "selftest")) {
        if (relay_url) |u| try selftestOwnRelay(init.io, u, relay_ca, count) else try selftest(init.io, relay, count);
    } else if (std.mem.eql(u8, cmd, "listen")) {
        try listen();
    } else if (std.mem.eql(u8, cmd, "dial")) {
        const t = ticket orelse return usage();
        const ep = try bindOrDie(.{ .relay_mode = .default });
        defer ep.deinit();
        const conn = ep.connect(t, alpn, 30_000) catch |e| return die("connect", e);
        defer conn.deinit(0);
        try pingLoop(init.io, conn, count);
    } else if (std.mem.eql(u8, cmd, "serve")) {
        try serve(init.io, ticket orelse return usage(), relay_url, relay_ca);
    } else if (std.mem.eql(u8, cmd, "sink")) {
        try sink(init.io, ticket orelse return usage(), extra orelse return usage(), relay_url, relay_ca);
    } else return usage();
}

/// Report datagram the sink sends back: magic, then little-endian u64 counters.
pub const sink_magic = "RPT1";

fn sink(io: std.Io, bind_addr: [:0]const u8, ticket_file: []const u8, relay_url: ?[:0]const u8, relay_ca: ?[:0]const u8) !void {
    const ep = try bindOrDie(.{
        .alpn = alpn,
        .relay_mode = if (relay_url != null) .custom_only else .disabled,
        .relay_urls = if (relay_url) |u| u.ptr else null,
        .relay_ca_pem = if (relay_ca) |p| p.ptr else null,
        .bind_addr = bind_addr,
    });
    if (relay_url != null) ep.online(10_000) catch |e| return die("online", e);
    defer ep.deinit();
    var tbuf: [4096]u8 = undefined;
    const t = try ep.ticket(&tbuf);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ticket_file, .data = t });
    std.debug.print("sink ticket: {s}\n", .{t});
    while (true) {
        const conn = ep.accept(600_000) catch |e| return die("accept", e);
        defer conn.deinit(0);
        var buf: [65536]u8 = undefined;
        var bytes: u64 = 0;
        var last = iroh.nowUs();
        while (true) {
            if (conn.recvDatagram(&buf, 5)) |d| {
                bytes += d.len;
            } else |e| switch (e) {
                error.Timeout => {},
                error.Closed => break,
                else => return die("sink recv", e),
            }
            const now = iroh.nowUs();
            if (now - last >= 20_000) {
                last = now;
                const s = conn.stats() catch break;
                var rpt: [4 + 5 * 8]u8 = undefined;
                @memcpy(rpt[0..4], sink_magic);
                std.mem.writeInt(u64, rpt[4..12], s.dgram_read, .little);
                std.mem.writeInt(u64, rpt[12..20], s.dgram_rx_wire, .little);
                std.mem.writeInt(u64, rpt[20..28], bytes, .little);
                std.mem.writeInt(u64, rpt[28..36], s.dgram_recv_drops_quic + s.dgram_recv_drops_shim, .little);
                std.mem.writeInt(u64, rpt[36..44], now, .little);
                conn.sendDatagram(&rpt) catch break;
            }
        }
    }
}

fn onShimThread(_: ?*anyopaque) callconv(.c) void {
    // A real host pins this thread and raises its priority here (see spike S4).
    std.debug.print("shim runtime thread started\n", .{});
}

fn usage() error{Usage} {
    std.debug.print("usage: shim-echo selftest [--relay | --relay-url URL [--relay-ca PEM_FILE]] [-n COUNT] | listen | dial TICKET [-n COUNT] | sink BIND_ADDR TICKET_FILE [--relay-url URL] [--relay-ca PEM_FILE] | serve TICKET_FILE [--relay-url URL] [--relay-ca PEM_FILE]\n", .{});
    return error.Usage;
}

fn die(what: []const u8, e: anyerror) anyerror {
    std.debug.print("{s} failed: {t}: {s}\n", .{ what, e, iroh.lastError() });
    return e;
}

fn bindOrDie(opts: iroh.BindOptions) !iroh.Endpoint {
    return iroh.Endpoint.bind(opts) catch |e| return die("bind", e);
}

fn echoServer(ep: iroh.Endpoint) void {
    const conn = ep.accept(60_000) catch |e| {
        _ = die("accept", e) catch {};
        return;
    };
    defer conn.deinit(0);
    var buf: [65536]u8 = undefined;
    while (true) {
        const d = conn.recvDatagram(&buf, 10_000) catch |e| switch (e) {
            error.Timeout, error.Closed => return,
            else => {
                _ = die("server recv", e) catch {};
                return;
            },
        };
        conn.sendDatagram(d) catch |e| {
            _ = die("server send", e) catch {};
            return;
        };
    }
}

fn listen() !void {
    const ep = try bindOrDie(.{ .alpn = alpn, .relay_mode = .default });
    defer ep.deinit();
    ep.online(15_000) catch |e| return die("online", e);
    var tbuf: [4096]u8 = undefined;
    std.debug.print("ticket: {s}\n", .{try ep.ticket(&tbuf)});
    while (true) echoServer(ep);
}

fn selftest(io: std.Io, relay: bool, count: u32) !void {
    // Direct mode binds to loopback with relays and discovery off, so it needs no network.
    const server_opts: iroh.BindOptions = if (relay)
        .{ .alpn = alpn, .relay_mode = .default }
    else
        .{ .alpn = alpn, .relay_mode = .disabled, .bind_addr = "127.0.0.1:0" };
    const server = try bindOrDie(server_opts);
    defer server.deinit();
    if (relay) server.online(20_000) catch |e| return die("online", e);

    var tbuf: [4096]u8 = undefined;
    const t = try server.ticket(&tbuf);
    std.debug.print("server ticket: {s}\n", .{t});

    const thread = try std.Thread.spawn(.{}, echoServer, .{server});

    const client = try bindOrDie(if (relay)
        .{ .relay_mode = .default }
    else
        .{ .relay_mode = .disabled, .bind_addr = "127.0.0.1:0" });
    defer client.deinit();
    const conn = client.connect(t, alpn, 30_000) catch |e| return die("connect", e);
    var idbuf: [128]u8 = undefined;
    std.debug.print("connected to {s}\n", .{try conn.remoteId(&idbuf)});

    const result = pingLoop(io, conn, count);
    conn.deinit(0);
    thread.join();
    return result;
}

/// Both endpoints use only `url` (no n0 relays or discovery) and must register with it, so this
/// checks a relay's TLS, hostname and ports. On one machine the connection may then go direct.
fn selftestOwnRelay(io: std.Io, url: [:0]const u8, ca: ?[:0]const u8, count: u32) !void {
    const base: iroh.BindOptions = .{ .relay_mode = .custom_only, .relay_urls = url.ptr, .relay_ca_pem = if (ca) |p| p.ptr else null };
    var server_opts = base;
    server_opts.alpn = alpn;
    const server = try bindOrDie(server_opts);
    defer server.deinit();
    server.online(15_000) catch |e| return die("server online", e);
    var tbuf: [4096]u8 = undefined;
    const t = try server.ticket(&tbuf);
    std.debug.print("server online at {s}\n", .{url});

    const thread = try std.Thread.spawn(.{}, echoServer, .{server});
    const client = try bindOrDie(base);
    defer client.deinit();
    client.online(15_000) catch |e| return die("client online", e);
    const conn = client.connect(t, alpn, 30_000) catch |e| return die("connect", e);
    const result = pingLoop(io, conn, count);
    var pbuf: [8]iroh.PathStats = undefined;
    const paths = conn.pathStats(&pbuf) catch &.{};
    for (paths) |p| std.debug.print("path {d} {s} relay={d} selected={d}\n", .{ p.path_id, iroh.pathRemoteAddr(&p), p.is_relay, p.is_selected });
    conn.deinit(0);
    thread.join();
    return result;
}

fn pingLoop(io: std.Io, conn: iroh.Conn, count: u32) !void {
    std.debug.print("max datagram size: {d}\n", .{conn.maxDatagramSize()});
    var out: [payload_len]u8 = undefined;
    var in: [65536]u8 = undefined;
    var ok: u32 = 0;
    var total_ns: u64 = 0;
    var max_ns: u64 = 0;
    var seq: u32 = 0;
    while (seq < count) : (seq += 1) {
        for (&out, 0..) |*b, k| b.* = @truncate(k *% 31 +% seq);
        std.mem.writeInt(u32, out[0..4], seq, .little);
        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            const t0 = std.Io.Clock.awake.now(io);
            conn.sendDatagram(&out) catch |e| return die("send", e);
            const got = recvSeq(conn, &in, seq) catch |e| switch (e) {
                error.Timeout => continue,
                else => return die("recv", e),
            };
            const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
            if (!std.mem.eql(u8, got, &out)) {
                std.debug.print("seq {d}: payload mismatch\n", .{seq});
                return error.Mismatch;
            }
            ok += 1;
            total_ns += ns;
            max_ns = @max(max_ns, ns);
            break;
        }
    }
    const avg_us = if (ok > 0) total_ns / ok / 1000 else 0;
    std.debug.print(
        "echo: {d}/{d} ok, {d} B payload, rtt avg {d} us, max {d} us, shim drops {d}\n",
        .{ ok, count, payload_len, avg_us, max_ns / 1000, conn.localDrops() },
    );
    if (ok != count) return error.EchoFailed;
    std.debug.print("PASS\n", .{});
}

/// Wait up to 1 s for the echo of `seq`, skipping late echoes of earlier retries.
fn recvSeq(conn: iroh.Conn, buf: []u8, seq: u32) ![]u8 {
    while (true) {
        const d = try conn.recvDatagram(buf, 1_000);
        if (d.len >= 4 and std.mem.readInt(u32, d[0..4], .little) == seq) return d;
    }
}

// --- serve: the native peer for the browser transport tests (shim-web/test) ---------------
//
// Datagrams are echoed, except those starting with a 4-byte command:
//   "SINK" ...                        counted (count, bytes), not echoed: browser -> native rate
//   "STAT"                            answered with "STAT" count:u64 bytes:u64 (LE), then reset
//   "BLST" kbps:u32 ms:u32 size:u32   send `size`-byte datagrams at `kbps` for `ms`, each
//                                     "BDAT" seq:u32 t_us:u64 ..., then "BEND" sent:u32
//                                     (native -> browser rate)
// Every bidirectional stream is echoed until the peer finishes it, then finished.

fn serve(io: std.Io, ticket_file: []const u8, relay_url: ?[:0]const u8, relay_ca: ?[:0]const u8) !void {
    const ep = try bindOrDie(.{
        .alpn = alpn,
        .relay_mode = if (relay_url != null) .custom_only else .default,
        .relay_urls = if (relay_url) |u| u.ptr else null,
        .relay_ca_pem = if (relay_ca) |p| p.ptr else null,
        .bind_addr = "127.0.0.1:0",
    });
    defer ep.deinit();
    ep.online(15_000) catch |e| return die("online", e);
    var tbuf: [4096]u8 = undefined;
    const t = try ep.ticket(&tbuf);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ticket_file, .data = t });
    std.debug.print("serve ticket: {s}\n", .{t});
    while (true) {
        const conn = ep.accept(3_600_000) catch |e| switch (e) {
            error.Timeout => continue,
            else => return die("accept", e),
        };
        var idbuf: [128]u8 = undefined;
        std.debug.print("serve: connection from {s}\n", .{conn.remoteId(&idbuf) catch "?"});
        const shared = try std.heap.page_allocator.create(Served);
        shared.* = .{ .conn = conn };
        const st = try std.Thread.spawn(.{}, serveStreams, .{shared});
        st.detach();
        const dt = try std.Thread.spawn(.{}, serveDatagrams, .{ io, shared });
        dt.detach();
    }
}

/// One served connection, shared by its stream and datagram threads; the last one out frees it.
const Served = struct {
    conn: iroh.Conn,
    refs: std.atomic.Value(u32) = .init(2),

    fn release(s: *Served) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) {
            s.conn.deinit(0);
            std.heap.page_allocator.destroy(s);
        }
    }
};

fn serveStreams(sv: *Served) void {
    defer sv.release();
    const conn = sv.conn;
    while (true) {
        const s = conn.acceptBi(3_600_000) catch return;
        defer s.deinit(0);
        var buf: [65536]u8 = undefined;
        while (true) {
            const d = s.read(&buf, 30_000) catch break;
            if (d.len == 0) {
                s.finish() catch {};
                break;
            }
            s.writeAll(d, 30_000) catch break;
        }
    }
}

fn serveDatagrams(io: std.Io, sv: *Served) void {
    defer sv.release();
    const conn = sv.conn;
    var buf: [65536]u8 = undefined;
    var count: u64 = 0;
    var bytes: u64 = 0;
    while (true) {
        const d = conn.recvDatagram(&buf, 3_600_000) catch |e| switch (e) {
            error.Timeout => continue,
            else => return,
        };
        const cmd = if (d.len >= 4) d[0..4] else "";
        if (std.mem.eql(u8, cmd, "SINK")) {
            count += 1;
            bytes += d.len;
        } else if (std.mem.eql(u8, cmd, "STAT")) {
            var r: [20]u8 = undefined;
            @memcpy(r[0..4], "STAT");
            std.mem.writeInt(u64, r[4..12], count, .little);
            std.mem.writeInt(u64, r[12..20], bytes, .little);
            conn.sendDatagram(&r) catch return;
            count = 0;
            bytes = 0;
        } else if (std.mem.eql(u8, cmd, "BLST") and d.len >= 16) {
            const kbps = std.mem.readInt(u32, d[4..8], .little);
            const ms = std.mem.readInt(u32, d[8..12], .little);
            const size = @min(@max(std.mem.readInt(u32, d[12..16], .little), 16), @as(u32, @intCast(@min(conn.maxDatagramSize(), 65536))));
            blast(io, conn, kbps, ms, size) catch return;
        } else {
            conn.sendDatagram(d) catch return;
        }
    }
}

fn blast(io: std.Io, conn: iroh.Conn, kbps: u32, ms: u32, size: u32) !void {
    var out: [65536]u8 = undefined;
    @memset(out[0..size], 0x5a);
    @memcpy(out[0..4], "BDAT");
    const start = iroh.nowUs();
    const end = start + @as(u64, ms) * 1000;
    const interval_us: u64 = @max(1, @as(u64, size) * 8 * 1000 / @max(kbps, 1));
    var seq: u32 = 0;
    var next = start;
    while (true) {
        const now = iroh.nowUs();
        if (now >= end) break;
        if (now < next) {
            if (next - now > 1500) io.sleep(.fromMicroseconds(@intCast(next - now - 1000)), .awake) catch {};
            continue;
        }
        std.mem.writeInt(u32, out[4..8], seq, .little);
        std.mem.writeInt(u64, out[8..16], now, .little);
        try conn.sendDatagram(out[0..size]);
        seq += 1;
        next += interval_us;
    }
    var r: [8]u8 = undefined;
    @memcpy(r[0..4], "BEND");
    std.mem.writeInt(u32, r[4..8], seq, .little);
    // The end marker may be lost like any datagram; send it a few times.
    for (0..3) |_| {
        try conn.sendDatagram(&r);
        io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
}
