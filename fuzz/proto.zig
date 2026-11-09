//! core/proto: the datagram envelope, video shard header, frame ack, transport feedback
//! and the LEB128 varints under them.
const std = @import("std");
const core = @import("core");
const c = @import("common.zig");

const proto = core.proto;
const wire = proto.wire;

/// Any datagram through `proto.decode`. What decodes must re-encode to bytes that decode to
/// the same message, and re-encoding that is a fixed point (one canonical form).
pub fn datagram(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [proto.max_datagram + 64]u8 = undefined;
    const dg = c.bytes(s, &in);
    const m = proto.decode(dg) catch return;
    var out: [proto.max_datagram + 64]u8 = undefined;
    var out2: [proto.max_datagram + 64]u8 = undefined;
    switch (m) {
        .video_shard => |v| {
            const re = try proto.encodeVideoShard(&out, v.envelope.seq, v.header, v.payload);
            const m2 = try proto.decode(re);
            try c.expectEqual(v.header, m2.video_shard.header);
            try c.expectEqualBytes(v.payload, m2.video_shard.payload);
            try c.expectEqualBytes(re, try proto.encodeVideoShard(&out2, v.envelope.seq, m2.video_shard.header, m2.video_shard.payload));
            // What the client hands recovery from a shard.
            _ = core.recovery.wire.frameMeta(v.header);
        },
        .frame_ack => |a| {
            var entries: [proto.FrameAck.max_entries]proto.FrameAck.Entry = undefined;
            var n: usize = 0;
            var it = a.ack.iterator();
            while (it.next()) |e| : (n += 1) entries[n] = e;
            try c.expect(n == a.ack.count);
            const ack: proto.FrameAck = .{ .flags = a.ack.flags, .gap_frame = a.ack.gap_frame, .entries = entries[0..n] };
            const re = try proto.encodeFrameAck(&out, a.envelope.seq, ack);
            const v2 = (try proto.decode(re)).frame_ack.ack;
            try c.expect(v2.flags == a.ack.flags and v2.gap_frame == a.ack.gap_frame and v2.count == a.ack.count);
            try c.expectEqualBytes(a.ack.raw_entries, v2.raw_entries);
            try c.expectEqualBytes(re, try proto.encodeFrameAck(&out2, a.envelope.seq, ack));
        },
        .feedback => |f| {
            var arrivals: [proto.Feedback.max_count]?u64 = undefined;
            var n: usize = 0;
            var received: usize = 0;
            var it = f.feedback.iterator();
            while (it.next()) |st| : (n += 1) {
                try c.expect(st.seq == f.feedback.base_seq +% @as(u32, @intCast(n)));
                arrivals[n] = st.arrival_us;
                if (st.arrival_us != null) received += 1;
            }
            try c.expect(n == f.feedback.count and received == f.feedback.received);
            const fb: proto.Feedback = .{ .feedback_seq = f.feedback.feedback_seq, .base_seq = f.feedback.base_seq, .ref_time_us = f.feedback.ref_time_us, .arrivals = arrivals[0..n] };
            var big: [proto.Feedback.fixed_size + 8 * 1024 + 10 * 65536]u8 = undefined;
            const re = try proto.encodeFeedback(&big, f.envelope.seq, fb);
            const v2 = (try proto.decode(re)).feedback.feedback;
            try c.expect(v2.count == f.feedback.count and v2.received == f.feedback.received and v2.ref_time_us == f.feedback.ref_time_us);
            try c.expectEqualBytes(f.feedback.bitmap, v2.bitmap);
            // Deltas are canonical (minimal LEB128), so the bytes match too.
            try c.expectEqualBytes(f.feedback.deltas, v2.deltas);
        },
        .other => |o| {
            // NACKs ride on control-fast as `other`; the host walks every seq they name.
            if (core.media.nack.parse(m)) |maybe| {
                if (maybe) |iter| {
                    var it = iter;
                    var count: usize = 0;
                    while (it.next()) |_| count += 1;
                    try c.expect(count <= o.payload.len / core.media.nack.entry_len * 17);
                }
            } else |_| try c.expect(o.payload.len % core.media.nack.entry_len != 0);
        },
    }
}

fn datagramSeeds(ss: *c.Seeds) void {
    var buf: [proto.max_datagram]u8 = undefined;
    // A real video shard from the packetizer (keyframe, LTR) and a parity shard.
    var payload: [proto.video_payload]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 7);
    const h: proto.ShardHeader = .{
        .media_seq = 77,
        .frame_id = 5,
        .slice = 0,
        .slice_count = 1,
        .group = 0,
        .group_count = 1,
        .shard = 0,
        .data_shards = 3,
        .parity_shards = 1,
        .flags = .{ .keyframe = true, .ltr = true },
        .group_len = 3 * proto.video_payload,
        .capture_us = 10_000,
        .encode_done_us = 16_500,
        .ltr_token = 42,
    };
    ss.bytes(proto.encodeVideoShard(&buf, 9, h, &payload) catch unreachable);
    var h2 = h;
    h2.shard = 2;
    h2.group_len = 2 * proto.video_payload + 10;
    ss.bytes(proto.encodeVideoShard(&buf, 10, h2, payload[0..h2.payloadLen()]) catch unreachable);
    const entries = [_]proto.FrameAck.Entry{ .{ .frame_id = 3, .ltr_token = 99 }, .{ .frame_id = 4, .ltr_token = 100 } };
    ss.bytes(proto.encodeFrameAck(&buf, 1, .{ .entries = &entries }) catch unreachable);
    ss.bytes(proto.encodeFrameAck(&buf, 2, .{ .flags = .{ .recovery_needed = true, .want_idr = true }, .gap_frame = 7, .entries = &.{} }) catch unreachable);
    ss.bytes(proto.encodeFeedback(&buf, 3, .{ .feedback_seq = 4, .base_seq = 100, .ref_time_us = 50, .arrivals = &.{ 60, null, 75, 74, null, null, null, null, 90 } }) catch unreachable);
    ss.bytes((core.media.nack.encodeMessage(&buf, 4, &.{ 10, 11, 13, 40, 0xffffffff }) catch unreachable).?);
    // Other streams pass through.
    ss.bytes(&.{ 0, @intFromEnum(proto.StreamId.audio), 1, 0, 5, 0, 0, 0, 0xaa });
}

/// LEB128 varints: every value that decodes was minimally encoded, so re-encoding it gives
/// back exactly the bytes consumed.
pub fn varint(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [256]u8 = undefined;
    const b = c.bytes(s, &in);
    const signed = s.value(bool);
    var d = wire.Decoder.init(b);
    while (true) {
        const start = d.pos;
        var out: [16]u8 = undefined;
        var e = wire.Encoder.init(&out);
        if (signed) {
            const v = d.svarint() catch return;
            try e.svarint(v);
            try c.expect(wire.unzigzag(wire.zigzag(v)) == v);
        } else {
            const v = d.uvarint() catch return;
            try e.uvarint(v);
        }
        try c.expectEqualBytes(b[start..d.pos], e.written());
    }
}

fn varintSeeds(ss: *c.Seeds) void {
    var buf: [64]u8 = undefined;
    for ([_]bool{ false, true }) |signed| {
        var e = wire.Encoder.init(&buf);
        e.uvarint(0) catch unreachable;
        e.uvarint(127) catch unreachable;
        e.uvarint(128) catch unreachable;
        e.uvarint(std.math.maxInt(u64)) catch unreachable;
        e.svarint(std.math.minInt(i64)) catch unreachable;
        const sd = ss.new();
        sd.slice(e.written());
        sd.int(signed);
    }
}

test "proto_datagram" {
    try c.fuzz("proto_datagram", datagram, datagramSeeds);
}

test "proto_varint" {
    try c.fuzz("proto_varint", varint, varintSeeds);
}
