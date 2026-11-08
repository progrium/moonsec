//! Linux network-namespace tests for the shim: rate handoff on a path change (to the relay
//! and back), the no-ack-progress signal, and drop accounting behind a real bottleneck.
//!
//! Needs root, iproute2 (ip, tc with tbf) and iptables. Build and run from the repo root:
//!   zig build netns-test && sudo zig-out/bin/iroh-netns-test
//! Each test skips when not root. The peer is `zig-out/bin/shim-echo sink` (override with
//! SHIM_ECHO=path) running in namespace msn-srv, reached from the root namespace over two veth
//! links, so the client sees two direct paths:
//!
//!   root ns                          msn-srv
//!   ms-a0 10.91.1.1/24  <------>  ms-a1 10.91.1.2/24
//!   ms-b0 10.91.2.1/24  <------>  ms-b1 10.91.2.2/24
const std = @import("std");
const builtin = @import("builtin");
const iroh = @import("iroh");

const alpn = "moonsec/s1-echo/0"; // shim-echo's ALPN
const ns = "msn-srv";
const dgram_len = 1100;
const ticket_path = "/tmp/moonsec-netns-ticket";

const io = std.testing.io;
const gpa = std.testing.allocator;

var init_done = false;

fn skipUnlessRoot() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.geteuid() != 0) {
        std.debug.print("netns tests need root; skipping\n", .{});
        return error.SkipZigTest;
    }
    if (!init_done) {
        try iroh.init(null, null);
        init_done = true;
    }
}

fn sleepMs(ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn sh(cmd: []const u8) !void {
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "sh", "-c", cmd } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("command failed: {s}\n{s}{s}\n", .{ cmd, r.stdout, r.stderr });
        return error.CommandFailed;
    }
}

fn shOut(cmd: []const u8) ![]u8 {
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "sh", "-c", cmd } });
    gpa.free(r.stderr);
    return r.stdout;
}

fn teardown() void {
    sh("ip netns del " ++ ns ++ " 2>/dev/null; for l in a c; do ip link del ms-${l}0 2>/dev/null; done; true") catch {};
}

/// Creates msn-srv with the given links ("a" = 10.91.1.0/24, "c" = 10.91.3.0/24).
fn topology(comptime links: []const u8) !void {
    teardown();
    try sh(
        \\set -e
        \\ip netns add msn-srv
        \\ip -n msn-srv link set lo up
        \\for n in 
    ++ links ++
        \\; do
        \\  case $n in a) i=1;; c) i=3;; esac
        \\  ip link add ms-${n}0 type veth peer name ms-${n}1
        \\  ip link set ms-${n}1 netns msn-srv
        \\  ip addr add 10.91.$i.1/24 dev ms-${n}0
        \\  ip -n msn-srv addr add 10.91.$i.2/24 dev ms-${n}1
        \\  ip link set ms-${n}0 up
        \\  ip -n msn-srv link set ms-${n}1 up
        \\done
    );
}

/// Drops everything on one server-side link (both directions), like S5's blackhole.
fn blackhole(link: u8, on: bool) !void {
    var buf: [256]u8 = undefined;
    const op: u8 = if (on) 'I' else 'D';
    try sh(try std.fmt.bufPrint(&buf, "ip netns exec " ++ ns ++ " iptables -{c} INPUT -i ms-{c}1 -j DROP && ip netns exec " ++ ns ++ " iptables -{c} OUTPUT -o ms-{c}1 -j DROP", .{ op, link, op, link }));
}

const Peer = struct {
    child: std.process.Child,
    ep: iroh.Endpoint,
    conn: iroh.Conn,

    fn start(client_opts: iroh.BindOptions, relay_url: ?[:0]const u8) !Peer {
        const echo_path: []const u8 = if (std.c.getenv("SHIM_ECHO")) |p| std.mem.span(p) else "zig-out/bin/shim-echo";
        std.Io.Dir.cwd().deleteFile(io, ticket_path) catch {};
        const base = [_][]const u8{ "ip", "netns", "exec", ns, echo_path, "sink", "0.0.0.0:47200", ticket_path };
        const with_relay = base ++ [_][]const u8{ "--relay-url", relay_url orelse "" };
        var child = try std.process.spawn(io, .{
            .argv = if (relay_url != null) &with_relay else &base,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        errdefer child.kill(io);
        var ticket: ?[]u8 = null;
        defer if (ticket) |t| gpa.free(t);
        for (0..600) |_| {
            ticket = std.Io.Dir.cwd().readFileAlloc(io, ticket_path, gpa, .limited(8192)) catch null;
            if (ticket != null and ticket.?.len > 0) break;
            sleepMs(25);
        }
        const t = ticket orelse return error.NoTicket;
        const tz = try gpa.dupeZ(u8, t);
        defer gpa.free(tz);
        var o = client_opts;
        o.relay_mode = if (relay_url != null) .custom_only else .disabled;
        o.relay_urls = if (relay_url) |u| u.ptr else null;
        o.bind_addr = "0.0.0.0:0";
        const ep = try iroh.Endpoint.bind(o);
        errdefer ep.deinit();
        if (relay_url != null) try ep.online(10_000);
        const conn = ep.connect(tz, alpn, 15_000) catch |e| {
            std.debug.print("connect: {s}\n", .{iroh.lastError()});
            return e;
        };
        return .{ .child = child, .ep = ep, .conn = conn };
    }

    fn stop(self: *Peer) void {
        self.conn.deinit(0);
        self.ep.deinit();
        self.child.kill(io);
    }
};

const Report = struct { read: u64 = 0, rx_wire: u64 = 0, bytes: u64 = 0, drops: u64 = 0, t_us: u64 = 0 };

/// Sends at `offered_bps` for `ms`, collecting the sink's reports and the client's events.
const Driver = struct {
    conn: iroh.Conn,
    last: Report = .{},
    events: std.ArrayList(iroh.Event) = .empty,

    fn deinit(self: *Driver) void {
        self.events.deinit(gpa);
    }

    fn pump(self: *Driver) !void {
        var buf: [256]u8 = undefined;
        while (true) {
            const d = self.conn.recvDatagram(&buf, 0) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return e,
            };
            if (d.len == 44 and std.mem.eql(u8, d[0..4], "RPT1")) {
                self.last = .{
                    .read = std.mem.readInt(u64, d[4..12], .little),
                    .rx_wire = std.mem.readInt(u64, d[12..20], .little),
                    .bytes = std.mem.readInt(u64, d[20..28], .little),
                    .drops = std.mem.readInt(u64, d[28..36], .little),
                    .t_us = std.mem.readInt(u64, d[36..44], .little),
                };
            }
        }
        while (try self.conn.pollEvent()) |ev| {
            std.debug.print("  event {t} path {d} {s}{s} value {d}\n", .{ ev.kind(), ev.pathId(), ev.remoteAddr(), if (ev.isRelay()) " (relay)" else "", ev.raw.value });
            try self.events.append(gpa, ev);
        }
    }

    /// Offers `offered_bps` (0 = just pump) for `ms`, stopping early once `until` returns true.
    fn run(self: *Driver, offered_bps: u64, ms: u64, until: ?*const fn (*Driver) bool) !void {
        var out: [dgram_len]u8 = undefined;
        @memset(&out, 0xab);
        const t0 = iroh.nowUs();
        var sent_bits: u64 = 0;
        while (iroh.nowUs() - t0 < ms * 1000) {
            const elapsed = iroh.nowUs() - t0;
            while (offered_bps > 0 and sent_bits < offered_bps * elapsed / 1_000_000) {
                self.conn.sendDatagram(&out) catch |e| switch (e) {
                    error.Closed => return e,
                    else => {},
                };
                sent_bits += dgram_len * 8;
            }
            try self.pump();
            if (until) |f| if (f(self)) return;
            sleepMs(1);
        }
    }

    /// Delivered payload rate at the sink over the next `ms`, while offering `offered_bps`.
    fn measure(self: *Driver, offered_bps: u64, ms: u64) !u64 {
        try self.run(offered_bps, 100, null);
        const a = self.last;
        try self.run(offered_bps, ms, null);
        const b = self.last;
        if (b.t_us <= a.t_us) return 0;
        return (b.bytes - a.bytes) * 8 * 1_000_000 / (b.t_us - a.t_us);
    }

    fn sawEvent(self: *Driver, kind: iroh.EventKind) ?iroh.Event {
        for (self.events.items) |ev| if (ev.kind() == kind) return ev;
        return null;
    }
};

fn selectedIs(d: *Driver, relay: bool) bool {
    var pbuf: [8]iroh.PathStats = undefined;
    const s = d.conn.stats() catch return false;
    const p = (pathById(d.conn, &pbuf, s.selected_path) catch return false) orelse return false;
    return (p.is_relay != 0) == relay;
}

fn onDirect(d: *Driver) bool {
    return selectedIs(d, false);
}

fn onRelay(d: *Driver) bool {
    return selectedIs(d, true);
}

fn within(actual: u64, expected: u64, pct: u64) bool {
    return actual * 100 >= expected * (100 - pct) and actual * 100 <= expected * (100 + pct);
}

fn pathById(conn: iroh.Conn, buf: []iroh.PathStats, id: u32) !?iroh.PathStats {
    for (try conn.pathStats(buf)) |p| if (p.path_id == id) return p;
    return null;
}

fn printPaths(conn: iroh.Conn) !void {
    var pbuf: [8]iroh.PathStats = undefined;
    for (try conn.pathStats(&pbuf)) |p| {
        std.debug.print("  path {d} {s} relay={d} selected={d} pacing={d} rtt={d}us stall={d}us\n", .{ p.path_id, iroh.pathRemoteAddr(&p), p.is_relay, p.is_selected, p.pacing_bps, p.rtt_us, p.ack_stall_us });
    }
}

fn udpSndbufErrors() !u64 {
    const out = try shOut("awk '/^Udp:/{n++} /^Udp:/ && n==2 {print $7}' /proc/net/snmp");
    defer gpa.free(out);
    return std.fmt.parseInt(u64, std.mem.trim(u8, out, " \n"), 10);
}

const local_relay = "http://10.91.3.1:3340";
const relay_config = "/tmp/moonsec-netns-relay.toml";

fn startRelay() !?std.process.Child {
    const bin: []const u8 = if (std.c.getenv("IROH_RELAY")) |p| std.mem.span(p) else "iroh-relay";
    // IPv4-only: the default metrics and QUIC listeners bind [::], which some CI hosts lack.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = relay_config,
        .data = "http_bind_addr = \"0.0.0.0:3340\"\nenable_metrics = false\nenable_quic_addr_discovery = false\n",
    });
    return std.process.spawn(io, .{
        .argv = &.{ bin, "--dev", "--config-path", relay_config },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        std.debug.print("cannot start {s} ({t}); install it with `cargo install iroh-relay --features server` or set IROH_RELAY; skipping\n", .{ bin, e });
        return null;
    };
}

// Like S5: a direct path (link a) plus a relay path (relay in the root namespace, reached by the
// sink over link c, whose UDP is blocked so it is no second direct path).
test "netns: target rate moves from a dead direct path to the relay" {
    try skipUnlessRoot();
    try topology("a c");
    defer teardown();
    try sh("ip netns exec " ++ ns ++ " iptables -A INPUT -i ms-c1 -p udp -j DROP && ip netns exec " ++ ns ++ " iptables -A OUTPUT -o ms-c1 -p udp -j DROP");
    var relay = (try startRelay()) orelse return error.SkipZigTest;
    defer relay.kill(io);
    sleepMs(500);

    const target: u64 = 10_000_000;
    var peer = try Peer.start(.{ .initial_target_bps = target }, local_relay);
    defer peer.stop();
    var d: Driver = .{ .conn = peer.conn };
    defer d.deinit();
    var pbuf: [8]iroh.PathStats = undefined;

    // The connection settles on the direct path (it may start on the relay).
    try d.run(target, 10_000, onDirect);
    try d.run(target, 500, null);
    try printPaths(peer.conn);
    const s0 = try peer.conn.stats();
    const direct = (try pathById(peer.conn, &pbuf, s0.selected_path)).?;
    try std.testing.expectEqual(@as(u8, 0), direct.is_relay);
    try std.testing.expect(s0.path_count >= 2); // the relay path stays open as a backup
    try std.testing.expectEqual(target, direct.pacing_bps);
    for (try peer.conn.pathStats(&pbuf)) |p| {
        if (p.path_id != direct.path_id) try std.testing.expect(p.pacing_bps <= 1_000_000);
    }
    const before = try d.measure(2 * target, 1000);
    std.debug.print("direct: delivered {d} kbit/s at target {d}\n", .{ before / 1000, target / 1000 });
    try std.testing.expect(within(before, target, 15));

    // Blackhole the direct link: no-ack-progress first, then the path closes (300 ms idle
    // timeout) and iroh selects the relay; the target moves with it.
    d.events.clearRetainingCapacity();
    const t_block = iroh.nowUs();
    try blackhole('a', true);
    try d.run(2 * target, 10_000, onRelay);
    try printPaths(peer.conn);
    const stall = d.sawEvent(.no_ack_progress) orelse return error.NoStallSignal;
    const closed = d.sawEvent(.path_closed) orelse return error.NoPathClosed;
    const sel = d.sawEvent(.path_selected) orelse return error.NoReselection;
    std.debug.print("no-ack-progress after {d} ms, direct closed after {d} ms, relay selected after {d} ms\n", .{ (stall.raw.t_us - t_block) / 1000, (closed.raw.t_us - t_block) / 1000, (sel.raw.t_us - t_block) / 1000 });
    try std.testing.expectEqual(direct.path_id, stall.pathId());
    try std.testing.expectEqual(direct.path_id, closed.pathId());
    try std.testing.expect(stall.raw.t_us <= closed.raw.t_us);
    try std.testing.expect(sel.isRelay());
    try std.testing.expect(sel.pathId() != direct.path_id);

    const s1 = try peer.conn.stats();
    try std.testing.expectEqual(sel.pathId(), s1.selected_path);
    try d.run(target, 200, null);
    try std.testing.expectEqual(target, (try pathById(peer.conn, &pbuf, sel.pathId())).?.pacing_bps);
    const after = try d.measure(2 * target, 1500);
    std.debug.print("relay: delivered {d} kbit/s at target {d}\n", .{ after / 1000, target / 1000 });
    try std.testing.expect(within(after, target, 20));

    // A new target applies to the relay path's controller.
    try peer.conn.setTargetBitrate(target / 2);
    const halved = try d.measure(2 * target, 1500);
    std.debug.print("relay: delivered {d} kbit/s at target {d}\n", .{ halved / 1000, target / 2000 });
    try std.testing.expect(within(halved, target / 2, 20));
    try std.testing.expectEqual(target / 2, (try pathById(peer.conn, &pbuf, sel.pathId())).?.pacing_bps);

    // Unblock: when iroh punches a direct path again, the target moves back to it. Stock
    // iroh may take up to its 60 s upgrade check for that (S5c), so this half is reported,
    // not required.
    try blackhole('a', false);
    const t_open = iroh.nowUs();
    try d.run(target / 2, 20_000, onDirect);
    if (!onDirect(&d)) {
        std.debug.print("direct path not back within 20 s of unblocking; skipping the move back\n", .{});
        return;
    }
    try d.run(target / 2, 300, null);
    try printPaths(peer.conn);
    const s2 = try peer.conn.stats();
    const back = (try pathById(peer.conn, &pbuf, s2.selected_path)).?;
    std.debug.print("direct again after {d} ms; path selections {d}\n", .{ (iroh.nowUs() - t_open) / 1000, s2.path_selections });
    try std.testing.expectEqual(@as(u8, 0), back.is_relay);
    try std.testing.expectEqual(target / 2, back.pacing_bps);
    try std.testing.expect(s2.path_selections > s1.path_selections);
    for (try peer.conn.pathStats(&pbuf)) |p| {
        if (p.path_id != back.path_id) try std.testing.expect(p.pacing_bps <= 1_000_000);
    }
    const again = try d.measure(target, 1500);
    std.debug.print("direct again: delivered {d} kbit/s at target {d}\n", .{ again / 1000, target / 2000 });
    try std.testing.expect(within(again, target / 2, 20));
}

test "netns: every datagram is accounted for behind a bottleneck" {
    try skipUnlessRoot();
    try topology("a");
    defer teardown();
    // 20 Mbit/s token bucket toward the sink; we pace at 30 and offer 45.
    try sh("tc qdisc add dev ms-a0 root tbf rate 20mbit burst 32kb latency 30ms");
    var peer = try Peer.start(.{ .initial_target_bps = 30_000_000, .datagram_send_buffer = 256 * 1024 }, null);
    defer peer.stop();
    var d: Driver = .{ .conn = peer.conn };
    defer d.deinit();

    try d.run(0, 500, null);
    const c0 = try peer.conn.stats();
    const r0 = d.last;
    const sndbuf0 = try udpSndbufErrors();
    try d.run(45_000_000, 3000, null);
    try d.run(0, 1500, null); // drain
    const c1 = try peer.conn.stats();
    const r1 = d.last;
    const sndbuf = try udpSndbufErrors() - sndbuf0;

    const out = try shOut("tc -s qdisc show dev ms-a0");
    defer gpa.free(out);
    var tc_drops: u64 = 0;
    var it = std.mem.tokenizeAny(u8, out, " \n,()");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "dropped")) tc_drops += try std.fmt.parseInt(u64, it.next().?, 10);
    }
    const tx = c1.dgram_tx_wire - c0.dgram_tx_wire;
    const rx = r1.rx_wire - r0.rx_wire;
    const lost = c1.lost_packets - c0.lost_packets;
    const missing = tx - rx;
    std.debug.print(
        "bottleneck: sent {d} evicted {d} queued {d} wire {d} | sink rx {d} read {d} drops {d} | missing {d}, QUIC lost {d}, tbf dropped {d} (socket ENOBUFS {d})\n",
        .{ c1.dgram_sent - c0.dgram_sent, c1.dgram_send_drops - c0.dgram_send_drops, c1.dgram_send_queued, tx, rx, r1.read - r0.read, r1.drops, missing, lost, tc_drops, sndbuf },
    );
    try std.testing.expect(tc_drops > 0);
    try std.testing.expect(c1.dgram_send_drops > c0.dgram_send_drops);
    // Shim side: every accepted datagram is on the wire, evicted, or still queued.
    try std.testing.expectEqual(c1.dgram_sent, c1.dgram_tx_wire + c1.dgram_send_drops + c1.dgram_send_queued);
    // Sink side: nothing dropped after the wire, and it read everything that arrived.
    try std.testing.expectEqual(@as(u64, 0), r1.drops);
    try std.testing.expectEqual(r1.rx_wire, r1.read);
    // Network side: what left but never arrived was dropped by the bottleneck, and QUIC counted
    // every one as lost (each lost packet here carried one datagram; a few keep-alives share the
    // link). tbf counts a GSO batch (send_quantum = 2 packets) as one drop.
    const slack = 10 + missing / 100;
    try std.testing.expect(lost + slack >= missing and lost <= missing + slack);
    try std.testing.expect(missing + slack >= tc_drops and missing <= 2 * tc_drops + slack);
}
