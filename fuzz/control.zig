//! Small control-fast and input-stream messages: core/input (events and acks), core/clock
//! (ping and pong) and the session messages in app/wire.zig.
const std = @import("std");
const core = @import("core");
const app_wire = @import("app_wire");
const c = @import("common.zig");

const proto = core.proto;
const input = core.input;
const clock = core.clock;

/// The host's input receiver fed any packets. A packet it rejects changes nothing, and it
/// never asks to inject more actions than `max_actions`.
pub fn inputReceiver(_: std.mem.Allocator, s: *c.Smith) !void {
    var rx = input.Receiver.init();
    var out: [input.Receiver.max_actions]input.Action = undefined;
    while (!s.eosWeightedSimple(16, 1)) {
        var in: [proto.max_datagram]u8 = undefined;
        const pkt = c.bytes(s, &in);
        const before = rx;
        const n = rx.process(pkt, &out) catch {
            try c.expect(std.meta.eql(before, rx));
            continue;
        };
        try c.expect(n <= out.len);
        for (out[0..n]) |a| switch (a) {
            .pad => |p| try c.expect(p.index < input.max_pads),
            else => {},
        };
        var ack: [input.ack_wire_len]u8 = undefined;
        input.encodeAck(rx.nextExpected(), &ack);
        try c.expect(try input.decodeAck(&ack) == rx.nextExpected());
    }
}

fn inputReceiverSeeds(ss: *c.Seeds) void {
    var tx = input.Sender.init(.{});
    var buf: [input.maxPacketLen(32)]u8 = undefined;
    const sd = ss.new();
    tx.key(4, true, 100);
    tx.moveRel(5, -3);
    tx.button(1, true, 120);
    sd.eos(false);
    sd.slice(tx.build(200, &buf));
    tx.key(4, false, 300);
    tx.scroll(0, 120, 310);
    tx.moveAbs(100, 200);
    tx.pad(0, .{ .buttons = 3, .lx = -100, .rt = 900 });
    sd.eos(false);
    sd.slice(tx.build(400, &buf));
    tx.pad(0, null);
    sd.eos(false);
    sd.slice(tx.build(500, &buf));
    sd.eos(true);
}

const SenderOp = enum(u8) { key, button, scroll, move_rel, move_abs, pad, ack, build, _ };

/// The client's input sender driven by any sequence of local events. Every packet it
/// builds must be accepted by the host's receiver.
pub fn inputRoundTrip(_: std.mem.Allocator, s: *c.Smith) !void {
    var tx = input.Sender.init(.{ .max_events = s.valueRangeAtMost(u8, 1, 32) });
    var rx = input.Receiver.init();
    var out: [input.Receiver.max_actions]input.Action = undefined;
    var buf: [input.maxPacketLen(32)]u8 = undefined;
    var now: input.Micros = 0;
    while (!s.eosWeightedSimple(64, 1)) {
        now += s.valueRangeAtMost(u16, 0, 20_000);
        switch (s.value(SenderOp)) {
            .key => tx.key(s.value(u16), s.value(bool), now),
            .button => tx.button(s.valueRangeAtMost(u16, 1, input.max_buttons), s.value(bool), now),
            .scroll => tx.scroll(s.value(i16), s.value(i16), now),
            .move_rel => tx.moveRel(s.value(i16), s.value(i16)),
            .move_abs => tx.moveAbs(s.value(u16), s.value(u16)),
            .pad => tx.pad(s.valueRangeLessThan(u8, 0, input.max_pads), if (s.value(bool)) null else .{
                .buttons = s.value(u32),
                .lx = s.value(i16),
                .ly = s.value(i16),
                .rx = s.value(i16),
                .ry = s.value(i16),
                .lt = s.value(u16),
                .rt = s.value(u16),
            }),
            .ack => tx.onAck(rx.nextExpected()),
            .build, _ => {
                const pkt = tx.build(now, &buf);
                if (s.value(bool)) continue; // lost on the way
                _ = try rx.process(pkt, &out);
            },
        }
    }
}

fn inputRoundTripSeeds(ss: *c.Seeds) void {
    const sd = ss.new();
    sd.int(@as(u8, 32));
    const ops = [_]SenderOp{ .key, .build, .move_rel, .button, .build, .ack, .build };
    for (ops) |op| {
        sd.eos(false);
        sd.int(@as(u16, 4000));
        sd.int(op);
        switch (op) {
            .key => {
                sd.int(@as(u16, 4));
                sd.int(true);
            },
            .button => {
                sd.int(@as(u16, 1));
                sd.int(true);
            },
            .move_rel => {
                sd.int(@as(i16, 7));
                sd.int(@as(i16, -2));
            },
            .build => sd.int(false),
            else => {},
        }
    }
    sd.eos(true);
}

/// Ping and pong decode and re-encode, and the client's pinger fed pongs that echo its
/// own pings (as a real host does) with host timestamps that can be anything.
pub fn clockSync(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [64]u8 = undefined;
    const raw = c.bytes(s, &in);
    if (clock.Ping.decode(raw)) |p| {
        var b: [clock.Ping.wire_len]u8 = undefined;
        p.encode(&b);
        try c.expectEqualBytes(raw, &b);
    } else |_| {}
    if (clock.Pong.decode(raw)) |p| {
        var b: [clock.Pong.wire_len]u8 = undefined;
        p.encode(&b);
        try c.expectEqualBytes(raw, &b);
        // app/client_session.zig samples every pong it receives, matched or not.
        var est = clock.Estimator(64).init(.{});
        for (0..4) |_| if (clock.sampleOf(p, s.value(i64))) |smp| est.add(smp);
        if (est.estimate()) |e| _ = e.offsetAt(0);
    } else |_| {}

    var now: clock.Micros = s.value(u32);
    var pinger = clock.Pinger.init(.{}, now);
    var pings: [16]clock.Ping = undefined;
    var n: usize = 0;
    while (!s.eosWeightedSimple(64, 1)) {
        now += s.valueRangeAtMost(u32, 0, 2_000_000);
        if (s.value(bool) or n == 0) {
            pings[n % pings.len] = pinger.makePing(now);
            n += 1;
        } else {
            const ping = pings[s.valueRangeLessThan(u8, 0, @intCast(@min(n, pings.len)))];
            var b: [clock.Pong.wire_len]u8 = undefined;
            (clock.Pong{ .seq = ping.seq, .t1 = ping.t1, .t2 = s.value(i64), .t3 = s.value(i64) }).encode(&b);
            const pong = try clock.Pong.decode(&b);
            _ = pinger.onPong(pong, now);
            if (pinger.estimate()) |e| {
                _ = e.offsetAt(now);
                _ = e.localToHost(now);
            }
        }
    }
}

fn clockSeeds(ss: *c.Seeds) void {
    var b: [clock.Pong.wire_len]u8 = undefined;
    (clock.Pong{ .seq = 1, .t1 = 1000, .t2 = 5_000_000, .t3 = 5_000_100 }).encode(&b);
    // A host 5 s ahead with 10 ms each way.
    const sd = ss.new();
    sd.slice(&b);
    sd.int(@as(u32, 1000));
    var host: i64 = 5_000_000;
    for (0..40) |i| {
        sd.eos(false);
        sd.int(@as(u32, 100_000));
        sd.int(true);
        sd.eos(false);
        sd.int(@as(u32, 20_000));
        sd.int(false);
        sd.int(@as(u8, @intCast(@min(i, 15))));
        host += 120_000;
        sd.int(host);
        sd.int(host + 100);
    }
    sd.eos(true);
}

/// app/wire.zig's hello, config and clock report: what decodes re-encodes to the same
/// value.
pub fn session(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [64]u8 = undefined;
    const b = c.bytes(s, &in);
    if (app_wire.Hello.decode(b)) |h| {
        var out: [app_wire.Hello.len]u8 = undefined;
        h.encode(&out);
        try c.expectEqual(@as(?app_wire.Hello, h), app_wire.Hello.decode(&out));
    }
    if (app_wire.Config.decode(b)) |cfg| {
        var out: [app_wire.Config.len]u8 = undefined;
        cfg.encode(&out);
        try c.expectEqualBytes(b, &out);
    }
    if (app_wire.ClockReport.decode(b)) |r| {
        var out: [app_wire.ClockReport.len]u8 = undefined;
        r.encode(&out);
        try c.expectEqualBytes(b, &out);
    }
}

fn sessionSeeds(ss: *c.Seeds) void {
    var hb: [app_wire.Hello.len]u8 = undefined;
    (app_wire.Hello{ .nonce = 9, .codecs = .{ .hevc = true, .passthrough = true }, .max_width = 1920, .max_height = 1080 }).encode(&hb);
    ss.bytes(&hb);
    var cb: [app_wire.Config.len]u8 = undefined;
    (app_wire.Config{ .nonce = 9, .codec = .passthrough, .slices = 4, .fps = 60, .width = 640, .height = 360, .bitrate_bps = 8_000_000 }).encode(&cb);
    ss.bytes(&cb);
    var rb: [app_wire.ClockReport.len]u8 = undefined;
    (app_wire.ClockReport{ .offset_us = -5, .error_bound_us = 300 }).encode(&rb);
    ss.bytes(&rb);
}

test "input_receiver" {
    try c.fuzz("input_receiver", inputReceiver, inputReceiverSeeds);
}

test "input_round_trip" {
    try c.fuzz("input_round_trip", inputRoundTrip, inputRoundTripSeeds);
}

test "clock_sync" {
    try c.fuzz("clock_sync", clockSync, clockSeeds);
}

test "app_session" {
    try c.fuzz("app_session", session, sessionSeeds);
}
