//! Loopback tests for every shim call (two endpoints in one process, relays off).
//! Run with `zig build test`. Linux netns tests (path change, bottleneck): iroh_netns_test.zig.
const std = @import("std");
const builtin = @import("builtin");
const iroh = @import("iroh");

const alpn = "moonsec/test/0";
const dgram_len = 1100;

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

var hook_ran = std.atomic.Value(bool).init(false);
/// Linux: the hook pins the shim thread to CPU 0, like a host would (S4).
var hook_pinned = std.atomic.Value(bool).init(false);
var setup_done = false;

fn onShimThread(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    if (builtin.os.tag == .linux) {
        var set: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);
        set[0] = 1;
        if (std.os.linux.sched_setaffinity(0, &set)) |_| {
            hook_pinned.store(true, .release);
        } else |_| {}
    }
    hook_ran.store(true, .release);
}



/// iroh.init must run before any other shim call; every test calls this first.
fn setup() void {
    // Tests run one at a time on the main thread.
    if (setup_done) return;
    iroh.init(onShimThread, null) catch @panic("iroh.init");
    setup_done = true;
}

fn sleepMs(ms: i64) void {
    std.testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn die(what: []const u8, e: anyerror) anyerror {
    std.debug.print("{s}: {t}: {s}\n", .{ what, e, iroh.lastError() });
    return e;
}

const Pair = struct {
    server_ep: iroh.Endpoint,
    client_ep: iroh.Endpoint,
    server: iroh.Conn,
    client: iroh.Conn,

    const AcceptCtx = struct { ep: iroh.Endpoint, conn: ?iroh.Conn = null, err: ?anyerror = null };

    fn acceptThread(ctx: *AcceptCtx) void {
        ctx.conn = ctx.ep.accept(20_000) catch |e| {
            ctx.err = e;
            return;
        };
    }

    /// Server and client on 127.0.0.1 with relays off. Options apply to both sides
    /// (alpn/relay/bind fields are overridden).
    fn open(server_opts: iroh.BindOptions, client_opts: iroh.BindOptions) !Pair {
        setup();
        var so = server_opts;
        so.alpn = alpn;
        so.relay_mode = .disabled;
        so.bind_addr = "127.0.0.1:0";
        var co = client_opts;
        co.relay_mode = .disabled;
        co.bind_addr = "127.0.0.1:0";
        const server_ep = iroh.Endpoint.bind(so) catch |e| return die("bind server", e);
        errdefer server_ep.deinit();
        const client_ep = iroh.Endpoint.bind(co) catch |e| return die("bind client", e);
        errdefer client_ep.deinit();
        var tbuf: [4096]u8 = undefined;
        const ticket = try server_ep.ticket(&tbuf);
        var ctx: AcceptCtx = .{ .ep = server_ep };
        const t = try std.Thread.spawn(.{}, acceptThread, .{&ctx});
        const client = client_ep.connect(ticket, alpn, 20_000) catch |e| {
            t.join();
            return die("connect", e);
        };
        t.join();
        if (ctx.err) |e| return die("accept", e);
        return .{ .server_ep = server_ep, .client_ep = client_ep, .server = ctx.conn.?, .client = client };
    }

    fn close(self: Pair) void {
        self.client.deinit(0);
        self.server.deinit(0);
        self.client_ep.deinit();
        self.server_ep.deinit();
    }
};

fn fill(buf: []u8, seq: u32) void {
    for (buf, 0..) |*b, k| b.* = @truncate(k *% 7 +% seq);
    std.mem.writeInt(u32, buf[0..4], seq, .little);
}

/// Drains every datagram that arrives within `quiet_ms` of the previous one.
fn drain(conn: iroh.Conn, quiet_ms: u32) !u64 {
    var buf: [65536]u8 = undefined;
    var n: u64 = 0;
    while (true) {
        _ = conn.recvDatagram(&buf, quiet_ms) catch |e| switch (e) {
            error.Timeout => return n,
            else => return e,
        };
        n += 1;
    }
}

fn waitReadable(handle: i64, timeout_ms: i32) !bool {
    if (builtin.os.tag == .windows) {
        return true; // WSAPoll is not wired up here; Windows checks the handle and the data path
    } else {
        var fds = [_]std.posix.pollfd{.{ .fd = @intCast(handle), .events = std.posix.POLL.IN, .revents = 0 }};
        return (try std.posix.poll(&fds, timeout_ms)) > 0;
    }
}

fn selectedPath(conn: iroh.Conn, buf: []iroh.PathStats) !?iroh.PathStats {
    for (try conn.pathStats(buf)) |p| if (p.is_selected != 0) return p;
    return null;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

test "runtime: init hook runs on the shim thread, second init fails, version and clock" {
    setup();
    try std.testing.expect(hook_ran.load(.acquire));
    if (builtin.os.tag == .linux) try std.testing.expect(hook_pinned.load(.acquire));
    try std.testing.expectError(error.Invalid, iroh.init(null, null));
    try std.testing.expectEqual(@as(u32, 0x000100), iroh.version());
    // The shim clock ticks in microseconds at the same rate as Zig's monotonic clock.
    const z0 = std.Io.Clock.awake.now(std.testing.io);
    const a = iroh.nowUs();
    sleepMs(20);
    const shim_us = iroh.nowUs() - a;
    const zig_us: u64 = @intCast(@divTrunc(z0.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), 1000));
    if (shim_us == 0 or @max(shim_us, zig_us) - @min(shim_us, zig_us) > 3000) {
        std.debug.print("shim clock advanced {d} us, Zig's {d} us\n", .{ shim_us, zig_us });
        return error.ClockMismatch;
    }
}

test "endpoint: bind options are validated, id and ticket" {
    setup();
    // Keep-alive must be below the path idle timeout.
    try std.testing.expectError(error.Invalid, iroh.Endpoint.bind(.{
        .relay_mode = .disabled,
        .bind_addr = "127.0.0.1:0",
        .path_idle_timeout_ms = 200,
        .path_keepalive_ms = 200,
    }));
    try std.testing.expectError(error.Invalid, iroh.Endpoint.bind(.{ .relay_mode = .disabled, .datagram_send_buffer = 100 }));
    const ep = try iroh.Endpoint.bind(.{
        .relay_mode = .disabled,
        .bind_addr = "127.0.0.1:0",
        .datagram_send_buffer = 4 << 20,
        .datagram_recv_buffer = 4 << 20,
        .recv_queue_len = 64,
        .path_idle_timeout_ms = 1000,
        .path_keepalive_ms = 250,
        .conn_idle_timeout_ms = 5000,
        .initial_target_bps = 10_000_000,
        .burst_us = 0,
        .no_ack_progress_ms = 0,
    });
    defer ep.deinit();
    var idbuf: [128]u8 = undefined;
    const id = try ep.id(&idbuf);
    try std.testing.expectEqual(@as(usize, 64), id.len);
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, ep.ticket(&small));
    var tbuf: [4096]u8 = undefined;
    const t = try ep.ticket(&tbuf);
    try std.testing.expect(std.mem.startsWith(u8, t, "endpoint"));
    // Dial-only endpoints cannot accept.
    try std.testing.expectError(error.Invalid, ep.accept(10));
}

test "datagrams: echo, remote id, max size, wakeup handle" {
    const p = try Pair.open(.{}, .{});
    defer p.close();
    var idbuf: [128]u8 = undefined;
    var idbuf2: [128]u8 = undefined;
    try std.testing.expectEqualStrings(try p.server_ep.id(&idbuf2), try p.client.remoteId(&idbuf));
    try std.testing.expect(p.client.maxDatagramSize() >= dgram_len);

    const h = p.server.wakeupHandle();
    try std.testing.expect(h >= 0);
    p.server.clearWakeup();
    var out: [dgram_len]u8 = undefined;
    var in: [65536]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, p.server.recvDatagram(&in, 0));
    try std.testing.expectError(error.Invalid, p.client.sendDatagram(&.{}));
    for (0..50) |i| {
        fill(&out, @intCast(i));
        try p.client.sendDatagram(&out);
        try std.testing.expect(try waitReadable(h, 2000));
        p.server.clearWakeup();
        const got = try p.server.recvDatagram(&in, 1000);
        try std.testing.expectEqualSlices(u8, &out, got);
        try p.server.sendDatagram(got);
        try std.testing.expectEqualSlices(u8, &out, try p.client.recvDatagram(&in, 1000));
    }
    // Too-small receive buffer reports the size.
    try p.client.sendDatagram(&out);
    var tiny: [16]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, p.server.recvDatagram(&tiny, 1000));
    // Oversized send.
    var big: [4096]u8 = undefined;
    @memset(&big, 1);
    try std.testing.expectError(error.BufferTooSmall, p.client.sendDatagram(&big));

    const s = try p.server.stats();
    try std.testing.expectEqual(@as(u64, 51), s.dgram_read);
    try std.testing.expectEqual(@as(u64, 0), s.dgram_recv_drops_shim + s.dgram_recv_drops_quic);
    try std.testing.expect(s.selected_path != iroh.path_none);
    try std.testing.expect(s.path_count >= 1);
    try std.testing.expectEqual(@as(u32, 0), s.closed);
}

test "rate: target paces the selected path and shows in path stats" {
    const target: u64 = 8_000_000;
    const p = try Pair.open(.{}, .{ .initial_target_bps = target });
    defer p.close();
    var pbuf: [8]iroh.PathStats = undefined;
    // Pacing at the target: offer 4x the target for 1 s, count what arrives.
    var out: [dgram_len]u8 = undefined;
    const t0 = iroh.nowUs();
    var seq: u32 = 0;
    // Offer 4x the target by elapsed time (sleep granularity is ~15 ms on Windows).
    while (iroh.nowUs() - t0 < 1_000_000) {
        const due = 4 * target * (iroh.nowUs() - t0) / 1_000_000 / (dgram_len * 8);
        while (seq < due) : (seq += 1) {
            fill(&out, seq);
            try p.client.sendDatagram(&out);
        }
        sleepMs(1);
    }
    sleepMs(300);
    const sel = (try selectedPath(p.client, &pbuf)).?;
    try std.testing.expectEqual(target, sel.pacing_bps);
    try std.testing.expect(sel.rtt_us > 0);
    try std.testing.expect(sel.sent_packets > 0);
    try std.testing.expect(sel.last_ack_us > 0);
    try std.testing.expectEqual(@as(u8, 0), sel.is_relay);
    const cs = try p.client.stats();
    try std.testing.expectEqual(target, cs.target_bps);
    const wire_bits = cs.dgram_tx_wire * dgram_len * 8;
    // 1 s at 8 Mbit/s, plus 300 ms of drain and one burst: well under what was offered.
    std.debug.print("rate: offered {d} dgrams, on wire {d} ({d} kbit), drops {d}\n", .{ cs.dgram_sent, cs.dgram_tx_wire, wire_bits / 1000, cs.dgram_send_drops });
    try std.testing.expect(wire_bits < target * 3 / 2);
    try std.testing.expect(wire_bits > target * 9 / 10);
    try std.testing.expect(cs.dgram_send_drops > 0);

    // Changing the target applies immediately; 0 removes pacing.
    try p.client.setTargetBitrate(2 * target);
    try p.client.sendDatagram(&out);
    sleepMs(50);
    try std.testing.expectEqual(2 * target, (try selectedPath(p.client, &pbuf)).?.pacing_bps);
    try p.client.setTargetBitrate(0);
    try p.client.sendDatagram(&out);
    sleepMs(50);
    try std.testing.expectEqual(@as(u64, 0), (try selectedPath(p.client, &pbuf)).?.pacing_bps);
}

test "drops: send-buffer evictions are counted exactly, nothing is lost silently" {
    const p = try Pair.open(.{}, .{
        .datagram_send_buffer = 64 * 1024,
        .initial_target_bps = 4_000_000,
        .burst_us = 0,
    });
    defer p.close();
    var out: [dgram_len]u8 = undefined;
    const n = 2000;
    for (0..n) |i| {
        fill(&out, @intCast(i));
        try p.client.sendDatagram(&out);
    }
    const mid = try p.client.stats();
    try std.testing.expectEqual(@as(u64, n), mid.dgram_sent);
    try std.testing.expectEqual(mid.dgram_sent, mid.dgram_tx_wire + mid.dgram_send_drops + mid.dgram_send_queued);
    try std.testing.expect(mid.dgram_send_drops > 0);
    // Let the buffer drain at 4 Mbit/s (64 KiB = ~130 ms), then count what the peer got.
    const got = try drain(p.server, 1000);
    const cs = try p.client.stats();
    const ss = try p.server.stats();
    std.debug.print("drops: sent {d} wire {d} evicted {d} queued {d} | peer got {d}\n", .{ cs.dgram_sent, cs.dgram_tx_wire, cs.dgram_send_drops, cs.dgram_send_queued, got });
    try std.testing.expectEqual(@as(u64, 0), cs.dgram_send_queued);
    try std.testing.expectEqual(cs.dgram_sent, cs.dgram_tx_wire + cs.dgram_send_drops);
    // Loopback loses nothing: every datagram that left was read.
    try std.testing.expectEqual(cs.dgram_tx_wire, got);
    try std.testing.expectEqual(cs.dgram_tx_wire, ss.dgram_rx_wire);
    try std.testing.expectEqual(got, ss.dgram_read);
    // The shim never drops datagrams it could still send: the newest ones survive.
    try std.testing.expect(cs.dgram_send_drops >= n - (64 * 1024 / dgram_len) - cs.dgram_tx_wire);
}

test "drops: a full receive queue is counted" {
    const p = try Pair.open(.{ .recv_queue_len = 16 }, .{});
    defer p.close();
    var out: [dgram_len]u8 = undefined;
    for (0..300) |i| {
        fill(&out, @intCast(i));
        try p.client.sendDatagram(&out);
        if (i % 50 == 0) sleepMs(2);
    }
    sleepMs(500);
    const before = try p.server.stats();
    std.debug.print("recv drops: wire {d} shim {d} quic {d} queued {d} lost {d}\n", .{ before.dgram_rx_wire, before.dgram_recv_drops_shim, before.dgram_recv_drops_quic, before.dgram_recv_queued, (try p.client.stats()).lost_packets });
    try std.testing.expectEqual(@as(u64, 16), before.dgram_recv_queued);
    try std.testing.expect(before.dgram_recv_drops_shim > 0);
    try std.testing.expectEqual(before.dgram_recv_drops_shim, p.server.localDrops());
    try std.testing.expectEqual(before.dgram_rx_wire, before.dgram_read + before.dgram_recv_drops_quic + before.dgram_recv_drops_shim + before.dgram_recv_queued);
    try std.testing.expectEqual(@as(u64, 16), try drain(p.server, 200));
    const after = try p.server.stats();
    try std.testing.expectEqual(@as(u64, 16), after.dgram_read);
    try std.testing.expectEqual(@as(u64, 0), after.dgram_recv_queued);
}

test "rate: with burst credit, frames above the target are still paced at the target" {
    // S10b: a bucket floored at zero forgives noq's 2-packet overdraft and drifts ~4% above
    // the target. With the debt carried, the sustained rate holds the target.
    const target: u64 = 20_000_000;
    const p = try Pair.open(.{}, .{ .initial_target_bps = target, .burst_us = 16_700 });
    defer p.close();
    var pbuf: [8]iroh.PathStats = undefined;
    var out: [dgram_len]u8 = undefined;
    // 60 fps frames at 1.25x the target, each handed over at once; measure from 0.5 s to 2.5 s.
    const per_frame = 5 * target / 4 / 60 / (dgram_len * 8);
    const t0 = iroh.nowUs();
    var frames: u64 = 0;
    var mark: ?struct { t: u64, bytes: u64 } = null;
    var seq: u32 = 0;
    while (true) {
        const now = iroh.nowUs() - t0;
        if (now >= 2_500_000) break;
        if (mark == null and now >= 500_000) {
            mark = .{ .t = iroh.nowUs(), .bytes = (try selectedPath(p.client, &pbuf)).?.sent_bytes };
        }
        while (frames * 1_000_000 / 60 <= now) : (frames += 1) {
            for (0..per_frame) |_| {
                fill(&out, seq);
                seq += 1;
                try p.client.sendDatagram(&out);
            }
        }
        sleepMs(1);
    }
    const m = mark.?;
    const bytes = (try selectedPath(p.client, &pbuf)).?.sent_bytes - m.bytes;
    const bps = bytes * 8 * 1_000_000 / (iroh.nowUs() - m.t);
    std.debug.print("rate: frames at 1.25x a {d} kbit/s target with 16.7 ms credit: sent {d} kbit/s\n", .{ target / 1000, bps / 1000 });
    try std.testing.expect(bps < target * 102 / 100);
    try std.testing.expect(bps > target * 95 / 100);
}

test "rate: burst credit lets a frame leave at once" {
    const target: u64 = 8_000_000;
    const p = try Pair.open(.{}, .{ .initial_target_bps = target });
    defer p.close();
    var out: [dgram_len]u8 = undefined;
    var in: [65536]u8 = undefined;
    // A ~19 KB frame is ~19 ms at 8 Mbit/s. With 20 ms of credit it should arrive at once.
    const frame = 17;
    var spreads: [2]u64 = undefined;
    for ([_]u32{ 20_000, 0 }, 0..) |burst, k| {
        try p.client.setBurst(burst);
        sleepMs(100); // earn credit
        for (0..frame) |i| {
            fill(&out, @intCast(i));
            try p.client.sendDatagram(&out);
        }
        _ = try p.server.recvDatagram(&in, 1000);
        const first = iroh.nowUs();
        for (1..frame) |_| _ = try p.server.recvDatagram(&in, 1000);
        spreads[k] = iroh.nowUs() - first;
    }
    std.debug.print("burst: frame spread {d} us with 20 ms credit, {d} us without\n", .{ spreads[0], spreads[1] });
    // Without credit only noq's own pacer bucket (~10 ms at this rate) lets part of it through early.
    try std.testing.expect(spreads[0] < 5_000);
    try std.testing.expect(spreads[1] > 7_000);
}

test "streams: open, write, finish, accept, read to end, reset" {
    const p = try Pair.open(.{}, .{});
    defer p.close();
    try std.testing.expectError(error.WouldBlock, p.server.acceptBi(0));
    const cs = try p.client.openBi(5000);
    const msg = "hello over a reliable stream " ** 200;
    try cs.writeAll(msg, 5000);
    try cs.finish();
    const ss = try p.server.acceptBi(5000);
    var buf: [1024]u8 = undefined;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    while (true) {
        const d = try ss.read(&buf, 5000);
        if (d.len == 0) break;
        try got.appendSlice(std.testing.allocator, d);
    }
    try std.testing.expectEqualStrings(msg, got.items);
    // Reply on the same stream.
    try ss.writeAll("ok", 5000);
    try ss.finish();
    try std.testing.expectEqualStrings("ok", try cs.read(&buf, 5000));
    try std.testing.expectEqual(@as(usize, 0), (try cs.read(&buf, 5000)).len);
    ss.deinit(0);
    cs.deinit(0);

    // A reset stream reads as closed on the peer.
    const cs2 = try p.client.openBi(5000);
    try cs2.writeAll("x", 5000);
    const ss2 = try p.server.acceptBi(5000);
    try std.testing.expectEqualStrings("x", try ss2.read(&buf, 5000));
    try std.testing.expectError(error.WouldBlock, ss2.read(&buf, 0));
    cs2.deinit(7);
    try std.testing.expectError(error.Closed, ss2.read(&buf, 5000));
    ss2.deinit(0);
}

test "events: peer close raises conn_closed, wakes the handle, recv reports closed" {
    const p = try Pair.open(.{}, .{});
    defer {
        p.server.deinit(0);
        p.client_ep.deinit();
        p.server_ep.deinit();
    }
    // Drain whatever path events the handshake produced.
    while (try p.server.pollEvent()) |_| {}
    p.server.clearWakeup();
    p.client.deinit(42);
    try std.testing.expect(try waitReadable(p.server.wakeupHandle(), 3000));
    var saw = false;
    const t0 = iroh.nowUs();
    while (!saw and iroh.nowUs() - t0 < 3_000_000) {
        while (try p.server.pollEvent()) |ev| {
            if (ev.kind() == .conn_closed) saw = true;
        }
        sleepMs(5);
    }
    try std.testing.expect(saw);
    var in: [64]u8 = undefined;
    try std.testing.expectError(error.Closed, p.server.recvDatagram(&in, 1000));
    try std.testing.expectEqual(@as(u32, 1), (try p.server.stats()).closed);
    try std.testing.expectError(error.Closed, p.server.sendDatagram("x"));
}
