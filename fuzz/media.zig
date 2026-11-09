//! core/media: reassembly with FEC rebuild and the NACK tracker on the client, and the
//! host's retransmit history answering NACKs.
const std = @import("std");
const core = @import("core");
const c = @import("common.zig");

const proto = core.proto;
const media = core.media;

const cfg: media.receiver.Config = .{
    .reassembly = .{ .window = 8, .max_frame_bytes = 64 << 10, .frame_timeout_us = 100_000 },
    .nack = .{ .capacity = 256 },
};
/// What the receiver may hold whatever it is sent: every frame slot full to the size limit,
/// plus parity and bookkeeping. A peer that can push it past this can exhaust the client.
const alloc_limit = 4 * cfg.reassembly.window * cfg.reassembly.max_frame_bytes + (1 << 20);

const Op = enum(u8) { shard, poll, nacks, _ };

/// Any sequence of datagrams into the client's video receiver, with polls and NACK
/// generation in between. Delivered frames are copied out; NACKs must parse.
pub fn receiver(gpa: std.mem.Allocator, s: *c.Smith) !void {
    var bounded: c.Bounded = .{ .child = gpa, .limit = alloc_limit };
    const a = bounded.allocator();
    var rx = try media.Receiver.init(a, cfg);
    defer rx.deinit();
    var now: u64 = s.value(u32);
    var frame_buf: [cfg.reassembly.max_frame_bytes]u8 = undefined;
    while (!s.eosWeightedSimple(64, 1)) {
        now += s.valueRangeAtMost(u16, 0, 50_000);
        switch (s.value(Op)) {
            .shard => {
                var in: [proto.max_datagram]u8 = undefined;
                const m = proto.decode(c.bytes(s, &in)) catch continue;
                if (m != .video_shard) continue;
                _ = rx.onShard(m.video_shard.header, m.video_shard.payload, now);
            },
            .poll => while (rx.poll(now)) |ev| switch (ev) {
                .frame => |f| {
                    try c.expect(f.len <= cfg.reassembly.max_frame_bytes);
                    try c.expect(f.copyTo(&frame_buf).len == f.len);
                },
                .lost => {},
            },
            .nacks, _ => {
                var out: [proto.max_datagram]u8 = undefined;
                const dg = (try rx.nacks(now, s.valueRangeAtMost(u32, 0, 500_000), 1, &out)) orelse continue;
                const m = try proto.decode(dg);
                var it = (try media.nack.parse(m)).?;
                while (it.next()) |_| {}
            },
        }
        try bounded.check();
    }
    try bounded.check();
}

/// Datagrams for two frames from the real packetizer: two slices, FEC on.
fn packetized(ss: *c.Seeds) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const pbuf = ss.arena.create(media.ParityBuffer) catch @panic("OOM");
    var table = media.packetizer.no_parity;
    for (&table) |*p| p.* = 1;
    var pk: media.Packetizer = .{ .group_shards = 4, .parity = table, .parity_buf = pbuf };
    var seq: u32 = 0;
    for (0..2) |frame| {
        for (0..2) |slice| {
            var data: [3000]u8 = undefined;
            for (&data, 0..) |*b, i| b.* = @truncate(i * 13 + frame);
            var it = pk.slice(.{
                .frame_id = @intCast(frame),
                .slice = @intCast(slice),
                .slice_count = 2,
                .flags = .{ .keyframe = frame == 0 },
                .capture_us = 1000 * frame,
                .encode_done_us = 1000 * frame + 500,
            }, data[0 .. 1000 + 1500 * slice]) catch unreachable;
            while (it.next()) |sh| {
                var buf: [proto.max_datagram]u8 = undefined;
                const dg = proto.encodeVideoShard(&buf, seq, sh.header, sh.payload) catch unreachable;
                seq += 1;
                list.append(ss.arena, ss.arena.dupe(u8, dg) catch @panic("OOM")) catch @panic("OOM");
            }
        }
    }
    return list.items;
}

fn receiverSeeds(ss: *c.Seeds) void {
    const dgs = packetized(ss);
    // Everything in order; every third shard lost (FEC and NACK); reversed.
    for (0..3) |mode| {
        const sd = ss.new();
        sd.int(@as(u32, 1_000_000));
        for (dgs, 0..) |_, k| {
            const i = if (mode == 2) dgs.len - 1 - k else k;
            if (mode == 1 and i % 3 == 1) continue;
            sd.eos(false);
            sd.int(@as(u16, 200));
            sd.int(Op.shard);
            sd.slice(dgs[i]);
            if (k % 4 == 3) {
                sd.eos(false);
                sd.int(@as(u16, 3000));
                sd.int(Op.nacks);
                sd.int(@as(u32, 20_000));
                sd.eos(false);
                sd.int(@as(u16, 0));
                sd.int(Op.poll);
            }
        }
        sd.eos(false);
        sd.int(@as(u16, 50_000));
        sd.int(Op.poll);
        sd.eos(true);
    }
}

/// The host side of NACK: shards recorded as the packetizer emits them, and NACK
/// datagrams (from the client, so untrusted) answered from the history.
pub fn retransmit(gpa: std.mem.Allocator, s: *c.Smith) !void {
    var h = try media.History.init(gpa, .{ .capacity = 64 });
    defer h.deinit(gpa);
    var now: u64 = 0;
    var next_seq: u32 = s.value(u32);
    var payload: [proto.video_payload]u8 = @splat(0x5a);
    while (!s.eosWeightedSimple(32, 1)) {
        now += s.valueRangeAtMost(u16, 0, 20_000);
        if (s.value(bool)) {
            const len = s.valueRangeAtMost(u16, 1, proto.video_payload);
            const hdr: proto.ShardHeader = .{
                .media_seq = next_seq,
                .frame_id = 0,
                .slice = 0,
                .slice_count = 1,
                .group = 0,
                .group_count = 1,
                .shard = 0,
                .data_shards = 1,
                .parity_shards = 0,
                .group_len = len,
                .capture_us = 0,
                .encode_done_us = 0,
            };
            h.record(.{ .header = hdr, .payload = payload[0..len] }, now);
            next_seq +%= 1;
        } else {
            var in: [proto.max_datagram]u8 = undefined;
            const m = proto.decode(c.bytes(s, &in)) catch continue;
            var it = (media.nack.parse(m) catch continue) orelse continue;
            while (it.next()) |seq| if (h.resend(seq, now)) |sh| {
                try c.expect(sh.header.media_seq == seq and sh.header.flags.retransmit);
                var buf: [proto.max_datagram]u8 = undefined;
                _ = try proto.encodeVideoShard(&buf, 0, sh.header, sh.payload);
            };
        }
    }
    _ = &payload;
}

fn retransmitSeeds(ss: *c.Seeds) void {
    const sd = ss.new();
    sd.int(@as(u32, 0xfffffff0));
    for (0..20) |_| {
        sd.eos(false);
        sd.int(@as(u16, 1000));
        sd.int(true);
        sd.int(@as(u16, 900));
    }
    var buf: [proto.max_datagram]u8 = undefined;
    sd.eos(false);
    sd.int(@as(u16, 1000));
    sd.int(false);
    sd.slice((media.nack.encodeMessage(&buf, 1, &.{ 0xfffffff1, 0xfffffff3, 0xffffffff, 1, 2 }) catch unreachable).?);
    sd.eos(true);
}

test "media_receiver" {
    try c.fuzz("media_receiver", receiver, receiverSeeds);
}

test "media_retransmit" {
    try c.fuzz("media_retransmit", retransmit, retransmitSeeds);
}
