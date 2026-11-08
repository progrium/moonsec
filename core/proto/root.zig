//! Wire protocol v0: framing, stream IDs, and the messages the core sends and receives.
//! Spec: spec/wire-v0.md. Everything here is allocation-free and works on caller buffers.

const std = @import("std");

pub const wire = @import("wire.zig");
pub const stream = @import("stream.zig");
pub const video = @import("video.zig");
pub const feedback = @import("feedback.zig");

pub const version = stream.version;
pub const StreamId = stream.StreamId;
pub const VideoKind = stream.VideoKind;
pub const ControlFastKind = stream.ControlFastKind;
pub const Envelope = stream.Envelope;
pub const ShardHeader = video.ShardHeader;
pub const FrameAck = feedback.FrameAck;
pub const Feedback = feedback.Feedback;
pub const seqBefore = stream.seqBefore;
pub const seqDiff = stream.seqDiff;

/// Largest datagram the core emits; fits any QUIC datagram path (design: ~1150 bytes).
pub const max_datagram = 1200;
/// Default video datagram size, headers included.
pub const video_datagram = 1150;
/// Room for video payload in a default-size datagram.
pub const video_payload = video_datagram - Envelope.size - ShardHeader.size;

pub const EncodeError = wire.EncodeError || error{ InvalidHeader, InvalidMessage };
pub const DecodeError = wire.DecodeError || error{
    UnsupportedVersion,
    InvalidStream,
    InvalidHeader,
    InvalidMessage,
};

/// A decoded datagram. Payload slices and views point into the input buffer.
pub const Message = union(enum) {
    video_shard: struct { envelope: Envelope, header: ShardHeader, payload: []const u8 },
    frame_ack: struct { envelope: Envelope, ack: FrameAck.View },
    feedback: struct { envelope: Envelope, feedback: Feedback.View },
    /// A stream or kind this version does not parse (audio, input, or newer). Callers
    /// that own that stream parse `payload`; everyone else drops it.
    other: struct { envelope: Envelope, payload: []const u8 },

    pub fn envelope(self: Message) Envelope {
        return switch (self) {
            inline else => |m| m.envelope,
        };
    }
};

/// Parses one datagram.
pub fn decode(buf: []const u8) DecodeError!Message {
    var d = wire.Decoder.init(buf);
    const env = try Envelope.decode(&d);
    switch (env.stream) {
        .video => switch (@as(VideoKind, @enumFromInt(env.kind))) {
            .shard => {
                const h = try ShardHeader.decode(&d);
                const payload = d.rest();
                if (payload.len != h.payloadLen()) return error.InvalidMessage;
                return .{ .video_shard = .{ .envelope = env, .header = h, .payload = payload } };
            },
            _ => {},
        },
        .control_fast => switch (@as(ControlFastKind, @enumFromInt(env.kind))) {
            .frame_ack => return .{ .frame_ack = .{ .envelope = env, .ack = try FrameAck.decode(&d) } },
            .feedback => return .{ .feedback = .{ .envelope = env, .feedback = try Feedback.decode(&d) } },
            _ => {},
        },
        else => {},
    }
    return .{ .other = .{ .envelope = env, .payload = d.rest() } };
}

/// Writes envelope + shard header + payload; returns the datagram.
pub fn encodeVideoShard(buf: []u8, seq: u32, header: ShardHeader, payload: []const u8) EncodeError![]u8 {
    if (payload.len != header.payloadLen()) return error.InvalidMessage;
    var e = wire.Encoder.init(buf);
    try (Envelope{ .stream = .video, .kind = @intFromEnum(VideoKind.shard), .seq = seq }).encode(&e);
    try header.encode(&e);
    try e.bytes(payload);
    return e.written();
}

pub fn encodeFrameAck(buf: []u8, seq: u32, ack: FrameAck) EncodeError![]u8 {
    var e = wire.Encoder.init(buf);
    try (Envelope{ .stream = .control_fast, .kind = @intFromEnum(ControlFastKind.frame_ack), .seq = seq }).encode(&e);
    try ack.encode(&e);
    return e.written();
}

pub fn encodeFeedback(buf: []u8, seq: u32, fb: Feedback) EncodeError![]u8 {
    var e = wire.Encoder.init(buf);
    try (Envelope{ .stream = .control_fast, .kind = @intFromEnum(ControlFastKind.feedback), .seq = seq }).encode(&e);
    try fb.encode(&e);
    return e.written();
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "video shard datagram round trip" {
    var payload: [video_payload]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 31);
    const h: ShardHeader = .{
        .media_seq = 77,
        .frame_id = 5,
        .slice = 0,
        .slice_count = 1,
        .group = 0,
        .group_count = 1,
        .shard = 0,
        .data_shards = 3,
        .parity_shards = 1,
        .flags = .{ .keyframe = true },
        .group_len = 3 * video_payload,
        .capture_us = 10_000,
        .encode_done_us = 16_500,
    };
    var buf: [max_datagram]u8 = undefined;
    const dg = try encodeVideoShard(&buf, 9, h, &payload);
    try testing.expectEqual(@as(usize, video_datagram), dg.len);

    const m = try decode(dg);
    try testing.expectEqual(@as(u32, 9), m.envelope().seq);
    const v = m.video_shard;
    try testing.expectEqual(h, v.header);
    try testing.expectEqualSlices(u8, &payload, v.payload);

    // Payload length must match the header.
    try testing.expectError(error.InvalidMessage, decode(dg[0 .. dg.len - 1]));
    try testing.expectError(error.InvalidMessage, encodeVideoShard(&buf, 9, h, payload[1..]));
}

test "control-fast datagrams round trip" {
    var buf: [max_datagram]u8 = undefined;
    const entries = [_]FrameAck.Entry{.{ .frame_id = 3, .ltr_token = 99 }};
    var dg = try encodeFrameAck(&buf, 1, .{ .entries = &entries });
    var m = try decode(dg);
    try testing.expectEqual(StreamId.control_fast, m.envelope().stream);
    var it = m.frame_ack.ack.iterator();
    try testing.expectEqual(entries[0], it.next().?);

    dg = try encodeFeedback(&buf, 2, .{ .feedback_seq = 4, .base_seq = 100, .ref_time_us = 50, .arrivals = &.{ 60, null, 75 } });
    m = try decode(dg);
    try testing.expectEqual(@as(u32, 2), m.envelope().seq);
    try testing.expectEqual(@as(u16, 2), m.feedback.feedback.received);
}

test "unknown kinds and streams pass through as other" {
    const dg = [_]u8{ 0, @intFromEnum(StreamId.audio), 1, 0, 5, 0, 0, 0, 0xaa, 0xbb };
    const m = try decode(&dg);
    try testing.expectEqual(StreamId.audio, m.other.envelope.stream);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, m.other.payload);

    const dg2 = [_]u8{ 0, @intFromEnum(StreamId.video), 200, 0, 5, 0, 0, 0 };
    try testing.expectEqual(@as(usize, 0), (try decode(&dg2)).other.payload.len);
}

test "decode never panics on arbitrary bytes" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var buf: [256]u8 = undefined;
    for (0..20_000) |_| {
        const n = r.uintLessThan(usize, buf.len);
        r.bytes(buf[0..n]);
        // Bias toward valid envelopes so the message decoders get exercised.
        if (n >= 3) {
            buf[0] = 0;
            buf[1] = r.uintLessThan(u8, 6);
            buf[2] = r.uintLessThan(u8, 3);
        }
        if (decode(buf[0..n])) |m| switch (m) {
            .feedback => |f| {
                var it = f.feedback.iterator();
                while (it.next()) |_| {}
            },
            .frame_ack => |f| {
                var it = f.ack.iterator();
                while (it.next()) |_| {}
            },
            else => {},
        } else |_| {}
    }
}
