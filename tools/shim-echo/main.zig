//! S1 echo harness for the iroh shim.
//!
//!   shim-echo selftest [--relay] [-n COUNT]   two endpoints in one process, datagram echo
//!   shim-echo listen                          print a ticket, echo datagrams until killed
//!   shim-echo dial TICKET [-n COUNT]          send COUNT datagrams to a listener, check echoes
//!   shim-echo sink BIND_ADDR TICKET_FILE [--relay-url URL]
//!                                             relays off (or only URL); write the ticket to TICKET_FILE, then
//!                                             count datagrams and report counts every 20 ms
//!                                             (peer for transport/iroh_netns_test.zig)
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
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-n") and i + 1 < args.len) {
            i += 1;
            count = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--relay-url") and i + 1 < args.len) {
            i += 1;
            relay_url = args[i];
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
        try selftest(init.io, relay, count);
    } else if (std.mem.eql(u8, cmd, "listen")) {
        try listen();
    } else if (std.mem.eql(u8, cmd, "dial")) {
        const t = ticket orelse return usage();
        const ep = try bindOrDie(.{ .relay_mode = .default });
        defer ep.deinit();
        const conn = ep.connect(t, alpn, 30_000) catch |e| return die("connect", e);
        defer conn.deinit(0);
        try pingLoop(init.io, conn, count);
    } else if (std.mem.eql(u8, cmd, "sink")) {
        try sink(init.io, ticket orelse return usage(), extra orelse return usage(), relay_url);
    } else return usage();
}

/// Report datagram the sink sends back: magic, then little-endian u64 counters.
pub const sink_magic = "RPT1";

fn sink(io: std.Io, bind_addr: [:0]const u8, ticket_file: []const u8, relay_url: ?[:0]const u8) !void {
    const ep = try bindOrDie(.{
        .alpn = alpn,
        .relay_mode = if (relay_url != null) .custom_only else .disabled,
        .relay_urls = if (relay_url) |u| u.ptr else null,
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
    std.debug.print("usage: shim-echo selftest [--relay] [-n COUNT] | listen | dial TICKET [-n COUNT] | sink BIND_ADDR TICKET_FILE [--relay-url URL]\n", .{});
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
