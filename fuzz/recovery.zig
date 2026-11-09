//! core/recovery: the host fed frame acks from the wire, and the client fed shard headers
//! from the wire, whose acks must survive the trip through `proto.FrameAck`.
const std = @import("std");
const core = @import("core");
const c = @import("common.zig");

const proto = core.proto;
const recovery = core.recovery;

const Op = enum(u8) { encode, ack, _ };

/// Host recovery between an encoder (driven as the contract requires) and frame-ack
/// datagrams that can say anything.
pub fn host(_: std.mem.Allocator, s: *c.Smith) !void {
    var h = recovery.host.Host(64).init(.{ .max_ltr_age = s.valueRangeAtMost(u32, 0, 100) });
    var id: u32 = s.value(u32);
    var token: u64 = 1;
    while (!s.eosWeightedSimple(64, 1)) switch (s.value(Op)) {
        .encode => {
            const d = h.nextEncode();
            if (s.valueRangeAtMost(u8, 0, 15) == 0) {
                h.onEncodeDropped();
                continue;
            }
            const keyframe = d.force == .idr or s.valueRangeAtMost(u8, 0, 30) == 0;
            const ltr = s.value(bool);
            const flags = h.onEncoded(id, if (ltr) token else null, keyframe);
            if (d.force == .ltr_refresh and !keyframe) try c.expect(flags.refresh);
            if (keyframe) try c.expect(flags.keyframe);
            id +%= 1;
            token +%= 1;
        },
        .ack, _ => {
            var in: [proto.max_datagram]u8 = undefined;
            const m = proto.decode(c.bytes(s, &in)) catch continue;
            if (m != .frame_ack) continue;
            recovery.wire.applyFrameAck(&h, m.frame_ack.ack);
        },
    };
}

fn hostSeeds(ss: *c.Seeds) void {
    const sd = ss.new();
    sd.int(@as(u32, 0));
    sd.int(@as(u32, 0));
    for (0..6) |i| {
        sd.eos(false);
        sd.int(Op.encode);
        sd.int(@as(u8, 1));
        sd.int(@as(u8, if (i == 0) 0 else 1));
        sd.int(true);
    }
    var buf: [proto.max_datagram]u8 = undefined;
    const entries = [_]proto.FrameAck.Entry{ .{ .frame_id = 1, .ltr_token = 2 }, .{ .frame_id = 2, .ltr_token = 3 } };
    sd.eos(false);
    sd.int(Op.ack);
    sd.slice(proto.encodeFrameAck(&buf, 1, .{ .entries = &entries }) catch unreachable);
    sd.eos(false);
    sd.int(Op.ack);
    sd.slice(proto.encodeFrameAck(&buf, 2, .{ .flags = .{ .recovery_needed = true }, .gap_frame = 4, .entries = &entries }) catch unreachable);
    for (0..3) |_| {
        sd.eos(false);
        sd.int(Op.encode);
        sd.int(@as(u8, 1));
        sd.int(@as(u8, 1));
        sd.int(false);
    }
    sd.eos(true);
}

const ClientOp = enum(u8) { frame, lost, decoded, poll, _ };

/// Client recovery fed frame metadata from decoded shard headers (whatever the host
/// sends), with decode results and losses; each ack it emits must encode to a valid
/// `FrameAck` that decodes back to the same ack.
pub fn client(_: std.mem.Allocator, s: *c.Smith) !void {
    var cl = recovery.Client.init(.{});
    cl.setRtt(s.valueRangeAtMost(u32, 0, 1_000_000));
    var now: u64 = 0;
    var last: ?recovery.FrameMeta = null;
    while (!s.eosWeightedSimple(64, 1)) {
        now += s.valueRangeAtMost(u16, 0, 40_000);
        switch (s.value(ClientOp)) {
            .frame => {
                var in: [proto.max_datagram]u8 = undefined;
                const m = proto.decode(c.bytes(s, &in)) catch continue;
                if (m != .video_shard) continue;
                const meta = recovery.wire.frameMeta(m.video_shard.header);
                if (cl.onFrame(meta, now) == .decode) last = meta;
            },
            .lost => cl.onFrameLost(s.value(u32), now),
            .decoded => if (last) |meta| {
                cl.onDecoded(meta, s.value(bool), now);
                last = null;
            },
            .poll, _ => if (cl.poll(now)) |ack| {
                var entries: [recovery.Ack.max_entries]proto.FrameAck.Entry = undefined;
                const fa = recovery.wire.toFrameAck(&ack, &entries);
                var buf: [proto.max_datagram]u8 = undefined;
                const dg = try proto.encodeFrameAck(&buf, 0, fa);
                const v = (try proto.decode(dg)).frame_ack.ack;
                try c.expect(v.count == fa.entries.len and v.gap_frame == fa.gap_frame and v.flags == fa.flags);
            },
        }
    }
}

fn clientSeeds(ss: *c.Seeds) void {
    var buf: [proto.max_datagram]u8 = undefined;
    const sd = ss.new();
    sd.int(@as(u32, 20_000));
    for (0..6) |i| {
        if (i == 3) continue; // frame 3 lost: freeze, request, refresh
        var h: proto.ShardHeader = .{
            .media_seq = @intCast(i),
            .frame_id = @intCast(i),
            .slice = 0,
            .slice_count = 1,
            .group = 0,
            .group_count = 1,
            .shard = 0,
            .data_shards = 1,
            .parity_shards = 0,
            .group_len = 4,
            .capture_us = 0,
            .encode_done_us = 0,
            .flags = .{ .keyframe = i == 0, .ltr = true, .ltr_refresh = i == 5 },
            .ltr_token = i + 1,
        };
        _ = &h;
        sd.eos(false);
        sd.int(@as(u16, 16_000));
        sd.int(ClientOp.frame);
        sd.slice(proto.encodeVideoShard(&buf, @intCast(i), h, "abcd") catch unreachable);
        sd.eos(false);
        sd.int(@as(u16, 1000));
        sd.int(ClientOp.decoded);
        sd.int(true);
        if (i == 4) {
            sd.eos(false);
            sd.int(@as(u16, 0));
            sd.int(ClientOp.lost);
            sd.int(@as(u32, 3));
        }
        sd.eos(false);
        sd.int(@as(u16, 1000));
        sd.int(ClientOp.poll);
    }
    sd.eos(true);
}

test "recovery_host" {
    try c.fuzz("recovery_host", host, hostSeeds);
}

test "recovery_client" {
    try c.fuzz("recovery_client", client, clientSeeds);
}
