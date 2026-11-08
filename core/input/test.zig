const std = @import("std");
const input = @import("root.zig");
const testing = std.testing;

const Sender = input.Sender;
const Receiver = input.Receiver;
const Action = input.Action;

const Buf = [input.maxPacketLen(255)]u8;

/// Host-side state built by applying actions, to compare with the client.
const HostState = struct {
    keys: std.AutoHashMapUnmanaged(u16, void) = .empty,
    buttons: u8 = 0,
    mx: i64 = 0,
    my: i64 = 0,
    scroll_y: i64 = 0,
    abs: ?[2]u16 = null,
    pads: [input.max_pads]?input.Gamepad = .{null} ** input.max_pads,
    log: std.ArrayListUnmanaged(Action) = .empty,

    fn deinit(h: *HostState) void {
        h.keys.deinit(testing.allocator);
        h.log.deinit(testing.allocator);
    }

    fn apply(h: *HostState, actions: []const Action) !void {
        for (actions) |a| {
            try h.log.append(testing.allocator, a);
            switch (a) {
                .key => |k| {
                    if (k.down) try h.keys.put(testing.allocator, k.code, {}) else _ = h.keys.remove(k.code);
                },
                .button => |b| {
                    const bit = @as(u8, 1) << @intCast(b.code - 1);
                    if (b.down) h.buttons |= bit else h.buttons &= ~bit;
                },
                .scroll => |s| h.scroll_y += s.dy,
                .motion => |m| {
                    h.mx += m.dx;
                    h.my += m.dy;
                },
                .abs => |p| h.abs = .{ p.x, p.y },
                .pad => |p| h.pads[p.index] = if (p.connected) p.state else null,
            }
        }
    }
};

fn deliver(r: *Receiver, h: *HostState, pkt: []const u8) !usize {
    var out: [Receiver.max_actions]Action = undefined;
    const n = try r.process(pkt, &out);
    try h.apply(out[0..n]);
    return n;
}

test "events arrive in order with motion before the click" {
    var s = Sender.init(.{});
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var buf: Buf = undefined;

    s.moveRel(10, -5);
    s.button(1, true, 100);
    s.moveRel(3, 3);
    s.button(1, false, 200);
    s.key(0x04, true, 300);
    _ = try deliver(&r, &h, s.build(400, &buf));

    const log = h.log.items;
    try testing.expectEqual(@as(usize, 4), log.len);
    // The receiver joined at the first event, so motion before it is not ours.
    try testing.expect(log[0] == .button and log[0].button.down);
    try testing.expectEqual(@as(i32, 3), log[1].motion.dx);
    try testing.expect(log[2] == .button and !log[2].button.down);
    try testing.expect(log[3] == .key and log[3].key.code == 0x04);
    try testing.expectEqual(@as(i64, 300), log[3].key.time);
    try testing.expect(h.keys.contains(0x04));
}

test "lost packets are covered by redundancy" {
    var s = Sender.init(.{});
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var buf: Buf = undefined;

    _ = try deliver(&r, &h, s.build(0, &buf)); // empty first packet joins
    s.key(0x04, true, 10);
    _ = s.build(10, &buf); // lost
    s.key(0x04, false, 20);
    _ = s.build(20, &buf); // lost
    s.moveRel(7, 7);
    s.key(0x05, true, 30);
    _ = try deliver(&r, &h, s.build(30, &buf));

    try testing.expectEqual(@as(u64, 0), r.stats.lost_events);
    try testing.expectEqual(@as(u64, 3), r.stats.events);
    try testing.expectEqual(@as(i64, 7), h.mx);
    try testing.expect(!h.keys.contains(0x04));
    try testing.expect(h.keys.contains(0x05));
}

test "duplicate and reordered packets change nothing" {
    var s = Sender.init(.{});
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var b1: Buf = undefined;
    var b2: Buf = undefined;

    s.key(1, true, 0);
    const p1 = s.build(0, &b1);
    s.moveRel(5, 0);
    const p2 = s.build(5, &b2);
    _ = try deliver(&r, &h, p2);
    try testing.expectEqual(@as(usize, 0), try deliver(&r, &h, p1));
    try testing.expectEqual(@as(usize, 0), try deliver(&r, &h, p2));
    try testing.expectEqual(@as(u64, 2), r.stats.stale_packets);
    try testing.expectEqual(@as(i64, 5), h.mx);
}

test "acks trim the redundancy" {
    var s = Sender.init(.{});
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var buf: Buf = undefined;
    var ack: [input.ack_wire_len]u8 = undefined;

    s.key(1, true, 0);
    s.key(2, true, 0);
    _ = try deliver(&r, &h, s.build(0, &buf));
    input.encodeAck(r.nextExpected(), &ack);
    s.onAck(try input.decodeAck(&ack));
    try testing.expectEqual(@as(u32, 0), s.unacked());
    s.key(3, true, 1);
    const pkt = s.build(1, &buf);
    try testing.expectEqual(@as(u8, 1), pkt[16]); // n_events
    // Bogus acks are ignored.
    s.onAck(1000);
    s.onAck(0);
    try testing.expectEqual(@as(u32, 1), s.unacked());
}

test "gamepad snapshots: lost updates, latest wins, disconnect" {
    var s = Sender.init(.{});
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var buf: Buf = undefined;

    s.pad(0, .{ .buttons = 1, .lx = 100 });
    _ = try deliver(&r, &h, s.build(0, &buf));
    s.pad(0, .{ .buttons = 3, .lx = 200 });
    _ = s.build(1, &buf); // lost
    s.pad(0, .{ .buttons = 2, .lx = -300, .rt = 65535 });
    s.pad(2, .{ .ry = 7 });
    _ = try deliver(&r, &h, s.build(2, &buf));
    try testing.expectEqual(input.Gamepad{ .buttons = 2, .lx = -300, .rt = 65535 }, h.pads[0].?);
    try testing.expectEqual(@as(i16, 7), h.pads[2].?.ry);

    // An unchanged snapshot produces no action.
    try testing.expectEqual(@as(usize, 0), try deliver(&r, &h, s.build(3, &buf)));

    s.pad(0, null);
    _ = try deliver(&r, &h, s.build(4, &buf));
    try testing.expect(h.pads[0] == null);
    try testing.expect(h.pads[2] != null);
}

test "held lists release a key whose release was lost beyond redundancy" {
    var s = Sender.init(.{ .max_events = 2 });
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var buf: Buf = undefined;

    s.key(0x10, true, 0);
    s.button(2, true, 0);
    _ = try deliver(&r, &h, s.build(0, &buf));
    try testing.expect(h.keys.contains(0x10));

    s.key(0x10, false, 1); // will fall out of the two-event window
    s.button(2, false, 2);
    s.scroll(0, 120, 3);
    s.scroll(0, 120, 4);
    _ = try deliver(&r, &h, s.build(5, &buf));
    try testing.expect(!h.keys.contains(0x10));
    try testing.expectEqual(@as(u8, 0), h.buttons);
    try testing.expectEqual(@as(u64, 2), r.stats.lost_events);
    try testing.expectEqual(@as(u64, 2), r.stats.reconciled);
    try testing.expectEqual(@as(i64, 240), h.scroll_y);
}

test "absolute move is sequenced before a click" {
    var s = Sender.init(.{});
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var buf: Buf = undefined;

    _ = try deliver(&r, &h, s.build(0, &buf));
    s.moveAbs(100, 200);
    s.moveAbs(1000, 2000);
    s.button(1, true, 10);
    s.moveAbs(5000, 6000);
    _ = try deliver(&r, &h, s.build(20, &buf));
    const log = h.log.items;
    try testing.expectEqual(@as(usize, 3), log.len);
    try testing.expectEqual(@as(u16, 1000), log[0].abs.x);
    try testing.expect(log[1] == .button);
    try testing.expectEqual(@as(u16, 5000), log[2].abs.x);
}

test "stale events are not replayed" {
    var s = Sender.init(.{ .max_event_age = 100_000 });
    var buf: Buf = undefined;
    s.key(1, true, 0);
    _ = s.build(0, &buf);
    const pkt = s.build(200_000, &buf);
    try testing.expectEqual(@as(u8, 0), pkt[16]);
}

test "send scheduling: dirty, tail repeats, unacked resend, keepalive" {
    var s = Sender.init(.{ .resend_interval = 8, .tail_repeats = 2, .keepalive = 100 });
    var buf: Buf = undefined;
    try testing.expect(!s.shouldSend(0));
    s.moveRel(1, 0);
    try testing.expect(s.shouldSend(0));
    _ = s.build(0, &buf);
    try testing.expect(!s.shouldSend(7));
    try testing.expectEqual(@as(?i64, 8), s.nextSendTime(7));
    try testing.expect(s.shouldSend(8));
    _ = s.build(8, &buf);
    _ = s.build(16, &buf);
    try testing.expect(!s.shouldSend(100)); // tail done, nothing unacked
    try testing.expectEqual(@as(?i64, null), s.nextSendTime(100));

    s.key(1, true, 200);
    _ = s.build(200, &buf);
    _ = s.build(208, &buf);
    _ = s.build(216, &buf);
    try testing.expect(s.shouldSend(224)); // still unacked
    s.onAck(1);
    try testing.expect(!s.shouldSend(224));

    s.pad(0, .{});
    _ = s.build(300, &buf);
    _ = s.build(308, &buf);
    _ = s.build(316, &buf);
    try testing.expect(!s.shouldSend(350));
    try testing.expect(s.shouldSend(416));
}

test "sequence numbers wrap" {
    var s = Sender.init(.{});
    s.first_seq = std.math.maxInt(u32) - 2;
    s.next_seq = s.first_seq;
    var r = Receiver.init();
    var h: HostState = .{};
    defer h.deinit();
    var buf: Buf = undefined;
    var i: u16 = 0;
    while (i < 8) : (i += 1) {
        s.key(i, true, i);
        if (i % 3 != 1) _ = try deliver(&r, &h, s.build(i, &buf)) else _ = s.build(i, &buf);
        s.onAck(r.nextExpected());
    }
    _ = try deliver(&r, &h, s.build(9, &buf));
    try testing.expectEqual(@as(u64, 0), r.stats.lost_events);
    try testing.expectEqual(@as(u32, 8), h.keys.count());
}

test "malformed packets are rejected without side effects" {
    var s = Sender.init(.{});
    var buf: Buf = undefined;
    s.key(1, true, 0);
    s.pad(1, .{ .lx = 5 });
    s.moveAbs(1, 1);
    s.button(1, true, 0);
    const pkt = s.build(0, &buf);
    var r = Receiver.init();
    var out: [Receiver.max_actions]Action = undefined;
    for (0..pkt.len) |len| {
        try testing.expectError(error.Truncated, r.process(pkt[0..len], &out));
    }
    try testing.expectEqual(@as(u64, 0), r.stats.packets);
    var bad = buf;
    bad[31] = 200; // more held keys than allowed
    try testing.expectError(error.InvalidMessage, r.process(bad[0..pkt.len], &out));
    try testing.expectError(error.InvalidMessage, r.process(buf[0 .. pkt.len + 1], &out));
    try testing.expect((try r.process(pkt, &out)) > 0);
}

test "sim: random input over a lossy link converges to the client state" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    for (0..20) |round| {
        var s = Sender.init(.{});
        var r = Receiver.init();
        var h: HostState = .{};
        defer h.deinit();
        var buf: Buf = undefined;
        var ack: ?u32 = null;
        var client_keys = std.AutoHashMapUnmanaged(u16, void).empty;
        defer client_keys.deinit(testing.allocator);
        var mx: i64 = 0;
        var scroll_sent: i64 = 0;
        const loss = 0.1 + 0.05 * @as(f64, @floatFromInt(round % 6)); // 10–35%

        // The first packet joins the stream.
        _ = try deliver(&r, &h, s.build(0, &buf));
        var now: i64 = 0;
        for (0..3000) |_| {
            now += 1000 + rnd.intRangeAtMost(i64, 0, 3000);
            switch (rnd.intRangeLessThan(u8, 0, 10)) {
                0...3 => {
                    const dx = rnd.intRangeAtMost(i32, -50, 50);
                    s.moveRel(dx, 0);
                    mx += dx;
                },
                4, 5 => {
                    const k = rnd.intRangeAtMost(u16, 4, 12);
                    const down = !client_keys.contains(k);
                    if (down) {
                        try client_keys.put(testing.allocator, k, {});
                    } else _ = client_keys.remove(k);
                    s.key(k, down, now);
                },
                6 => {
                    s.scroll(0, 120, now);
                    scroll_sent += 120;
                },
                7 => s.button(rnd.intRangeAtMost(u16, 1, 3), rnd.boolean(), now),
                else => s.pad(rnd.intRangeLessThan(u8, 0, 2), .{ .lx = rnd.int(i16), .buttons = rnd.int(u32) }),
            }
            if (s.shouldSend(now)) {
                const pkt = s.build(now, &buf);
                if (rnd.float(f64) >= loss) {
                    _ = try deliver(&r, &h, pkt);
                    if (rnd.float(f64) >= loss) ack = r.nextExpected();
                }
            }
            if (ack) |a| s.onAck(a);
        }
        // A clean final packet settles everything.
        _ = try deliver(&r, &h, s.build(now + 1, &buf));

        try testing.expectEqual(mx, h.mx);
        try testing.expectEqual(client_keys.count(), h.keys.count());
        var it = client_keys.keyIterator();
        while (it.next()) |k| try testing.expect(h.keys.contains(k.*));
        try testing.expectEqual(s.buttons_held, h.buttons);
        try testing.expectEqual(s.pads, h.pads);
        // Packets are sent on every input, so with acks flowing nothing
        // falls out of the 32-event window and every scroll arrives once.
        try testing.expectEqual(@as(u64, 0), r.stats.lost_events);
        try testing.expectEqual(scroll_sent, h.scroll_y);
    }
}
