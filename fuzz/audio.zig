//! core/audio (frame and parity messages, the jitter buffer with RS recovery) and the
//! Opus packet path the client runs on what the host sends (codec/opus/stage.zig).
const std = @import("std");
const core = @import("core");
const stage = @import("audio_stage");
const c = @import("common.zig");

const proto = core.proto;
const audio = core.audio;
const awire = audio.wire;

/// One audio message body through `Frame.parse` or `Parity.parse`, then back through the
/// encoders and `proto.decode`.
pub fn messages(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [proto.max_datagram]u8 = undefined;
    const body = c.bytes(s, &in);
    var out: [proto.max_datagram + 64]u8 = undefined;
    if (awire.Frame.parse(body)) |f| {
        const dg = try awire.encodeFrame(&out, 1, f.header, f.packet);
        const m = try proto.decode(dg);
        const f2 = try awire.Frame.parse(m.other.payload);
        try c.expectEqual(f.header, f2.header);
        try c.expectEqualBytes(f.packet, f2.packet);
        try c.expectEqualBytes(body, m.other.payload);
    } else |_| {}
    if (awire.Parity.parse(body)) |p| {
        const dg = try awire.encodeParity(&out, 2, p.header, p.shard);
        const m = try proto.decode(dg);
        const p2 = try awire.Parity.parse(m.other.payload);
        try c.expectEqual(p.header, p2.header);
        try c.expectEqualBytes(body, m.other.payload);
    } else |_| {}
}

/// Datagrams from a real sender: four 10 ms frames with k=2, m=1 parity.
fn senderDatagrams(ss: *c.Seeds, out: *std.ArrayList([]const u8)) void {
    var tx = audio.Sender.init(.{ .k = 2, .m = 1 }) catch unreachable;
    var seq: u32 = 0;
    for (0..4) |i| {
        var pkt: [40]u8 = undefined;
        for (&pkt, 0..) |*b, j| b.* = @truncate(i * 31 + j);
        var buf: [proto.max_datagram]u8 = undefined;
        const dg = tx.frame(&buf, seq, 1000 + 10_000 * i, 480, i > 0, pkt[0 .. 20 + i]) catch unreachable;
        seq += 1;
        out.append(ss.arena, ss.arena.dupe(u8, dg) catch @panic("OOM")) catch @panic("OOM");
        while (tx.parity(&buf, seq) catch unreachable) |p| {
            seq += 1;
            out.append(ss.arena, ss.arena.dupe(u8, p) catch @panic("OOM")) catch @panic("OOM");
        }
    }
}

fn messageSeeds(ss: *c.Seeds) void {
    var dgs: std.ArrayList([]const u8) = .empty;
    senderDatagrams(ss, &dgs);
    for (dgs.items) |dg| ss.bytes(dg[proto.Envelope.size..]);
}

const Op = enum(u8) { message, pull, _ };

/// The client jitter buffer fed any sequence of audio datagrams and pulls. Every action
/// it returns must be playable: a frame it hands out parses and has a sane length.
pub fn receiver(gpa: std.mem.Allocator, s: *c.Smith) !void {
    const rx = try gpa.create(audio.Receiver);
    defer gpa.destroy(rx);
    rx.init(.{});
    var now: i64 = s.value(i32);
    while (!s.eosWeightedSimple(64, 1)) {
        now +%= s.valueRangeAtMost(u16, 0, 20_000);
        switch (s.value(Op)) {
            .message => {
                var in: [proto.max_datagram]u8 = undefined;
                const dg = c.bytes(s, &in);
                const m = proto.decode(dg) catch continue;
                const env = m.envelope();
                if (env.stream != .audio) continue;
                rx.onMessage(env, m.other.payload, now);
            },
            .pull, _ => switch (rx.pull(now)) {
                .silence, .conceal => |n| try c.expect(n > 0),
                .decode, .fec, .drop => |f| {
                    try c.expect(f.packet.len > 0 and f.packet.len <= awire.max_packet and f.header.samples > 0);
                },
            },
        }
    }
}

fn receiverSeeds(ss: *c.Seeds) void {
    var dgs: std.ArrayList([]const u8) = .empty;
    senderDatagrams(ss, &dgs);
    // In order, then with the first frame lost so parity rebuilds it, then reordered.
    for ([_][]const usize{ &.{ 0, 1, 2, 3, 4, 5 }, &.{ 1, 2, 3, 4, 5 }, &.{ 2, 0, 1, 5, 4, 3 } }) |order| {
        const sd = ss.new();
        sd.int(@as(i32, 0));
        for (order) |i| {
            if (i >= dgs.items.len) continue;
            sd.eos(false);
            sd.int(@as(u16, 3000));
            sd.int(Op.message);
            sd.slice(dgs.items[i]);
        }
        for (0..8) |_| {
            sd.eos(false);
            sd.int(@as(u16, 10_000));
            sd.int(Op.pull);
        }
        sd.eos(true);
    }
}

/// The Opus path a client runs on what the host sends: the jitter buffer, then libopus on
/// whatever packet bytes and frame lengths arrive, into the app's own output buffer size.
pub fn opusClient(gpa: std.mem.Allocator, s: *c.Smith) !void {
    const channels: u8 = if (s.value(bool)) 2 else 1;
    var ca = try stage.ClientAudio.init(gpa, channels, .{});
    defer ca.deinit(gpa);
    // app/apps.zig renders into a buffer this size.
    var out: [stage.ClientAudio.max_frame_samples * 2]f32 = undefined;
    var now: i64 = 0;
    var env_seq: u32 = 0;
    var seq: u32 = 0;
    while (!s.eosWeightedSimple(32, 1)) {
        now += s.valueRangeAtMost(u16, 0, 20_000);
        if (s.value(bool)) {
            // A frame whose packet and header fields come from the input.
            var pkt: [awire.max_packet]u8 = undefined;
            const p = c.bytes(s, &pkt);
            if (p.len == 0) continue;
            seq +%= s.valueRangeAtMost(u8, 0, 3);
            const h: awire.FrameHeader = .{ .seq = seq, .capture_us = 0, .samples = s.value(u16), .flags = s.value(u8) };
            var buf: [proto.max_datagram + 64]u8 = undefined;
            const dg = awire.encodeFrame(&buf, env_seq, h, p) catch continue;
            env_seq +%= 1;
            const m = try proto.decode(dg);
            ca.onMessage(m.envelope(), m.other.payload, now);
        } else {
            const r = ca.render(now, &out) catch continue;
            try c.expect(r.samples * channels <= out.len);
        }
    }
}

fn opusSeeds(ss: *c.Seeds) void {
    // A real Opus packet: 10 ms of a 440 Hz tone from the encoder.
    const opus = @import("opus");
    var enc = opus.Encoder.init(std.heap.page_allocator, .{ .channels = 2 }) catch return;
    defer enc.deinit(std.heap.page_allocator);
    var pcm: [480 * 2]f32 = undefined;
    for (0..480) |i| {
        const v: f32 = @floatCast(0.3 * @sin(@as(f64, @floatFromInt(i)) * 2.0 * std.math.pi * 440.0 / 48000.0));
        pcm[2 * i] = v;
        pcm[2 * i + 1] = v;
    }
    var pkt: [awire.max_packet]u8 = undefined;
    const packet = enc.encode(&pcm, &pkt) catch return;
    for ([_]bool{ false, true }) |stereo| {
        const sd = ss.new();
        sd.int(stereo);
        for (0..3) |_| {
            sd.eos(false);
            sd.int(@as(u16, 10_000));
            sd.int(true);
            sd.slice(packet);
            sd.int(@as(u8, 1));
            sd.int(@as(u16, 480));
            sd.int(@as(u8, 0));
        }
        for (0..6) |_| {
            sd.eos(false);
            sd.int(@as(u16, 10_000));
            sd.int(false);
        }
        sd.eos(true);
    }
}

test "audio_messages" {
    try c.fuzz("audio_messages", messages, messageSeeds);
}

test "audio_receiver" {
    try c.fuzz("audio_receiver", receiver, receiverSeeds);
}

test "audio_opus_client" {
    try c.fuzz("audio_opus_client", opusClient, opusSeeds);
}
