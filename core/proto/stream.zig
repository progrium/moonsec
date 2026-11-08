//! Stream IDs and the datagram envelope that starts every media datagram.

const std = @import("std");
const wire = @import("wire.zig");

/// Wire protocol version carried in every envelope. Bumped only for incompatible changes;
/// new streams and message kinds are added without a bump.
pub const version: u8 = 0;

/// Which logical stream a datagram belongs to. Values not named here are valid on the
/// wire; receivers skip datagrams for streams they don't know.
pub const StreamId = enum(u8) {
    /// Never sent; a zero here means a zeroed or corrupt buffer.
    invalid = 0,
    video = 1,
    audio = 2,
    input = 3,
    /// Small, latency-critical control messages (frame acks, transport feedback).
    control_fast = 4,
    /// Reserved for microphone passthrough (not in v1).
    mic = 5,
    _,
};

/// Message kinds on the video stream.
pub const VideoKind = enum(u8) {
    shard = 1,
    _,
};

/// Message kinds on the control-fast stream.
pub const ControlFastKind = enum(u8) {
    frame_ack = 1,
    feedback = 2,
    _,
};

/// The 8-byte header on every datagram.
pub const Envelope = struct {
    stream: StreamId,
    /// Message kind within the stream (see VideoKind, ControlFastKind).
    kind: u8,
    /// Reserved; senders write 0, receivers ignore unknown bits.
    flags: u8 = 0,
    /// Transport-wide sequence number: one counter per direction across all streams,
    /// incremented for every datagram sent (retransmits included). Transport feedback
    /// reports arrivals by this number. Wraps; compare with `seqBefore`.
    seq: u32,

    pub const size = 8;

    pub fn encode(self: Envelope, e: *wire.Encoder) wire.EncodeError!void {
        std.debug.assert(self.stream != .invalid);
        try e.int(u8, version);
        try e.int(u8, @intFromEnum(self.stream));
        try e.int(u8, self.kind);
        try e.int(u8, self.flags);
        try e.int(u32, self.seq);
    }

    pub const DecodeError = wire.DecodeError || error{ UnsupportedVersion, InvalidStream };

    pub fn decode(d: *wire.Decoder) DecodeError!Envelope {
        if (try d.int(u8) != version) return error.UnsupportedVersion;
        const stream: StreamId = @enumFromInt(try d.int(u8));
        if (stream == .invalid) return error.InvalidStream;
        return .{
            .stream = stream,
            .kind = try d.int(u8),
            .flags = try d.int(u8),
            .seq = try d.int(u32),
        };
    }
};

/// Serial-number comparison (RFC 1982 style) for wrapping u32 counters:
/// true when `a` comes before `b`, assuming they are less than 2^31 apart.
pub fn seqBefore(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// Signed distance from `a` to `b` on a wrapping u32 counter.
pub fn seqDiff(b: u32, a: u32) i32 {
    return @bitCast(b -% a);
}

const testing = std.testing;

test "envelope round trip" {
    var buf: [Envelope.size]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    const env: Envelope = .{ .stream = .control_fast, .kind = 2, .seq = 0xdeadbeef };
    try env.encode(&e);
    try testing.expectEqual(@as(usize, Envelope.size), e.pos);
    try testing.expectEqualSlices(u8, &.{ 0, 4, 2, 0, 0xef, 0xbe, 0xad, 0xde }, &buf);
    var d = wire.Decoder.init(&buf);
    try testing.expectEqual(env, try Envelope.decode(&d));
}

test "envelope rejects bad version, zero stream, short buffer" {
    var d = wire.Decoder.init(&.{ 1, 1, 1, 0, 0, 0, 0, 0 });
    try testing.expectError(error.UnsupportedVersion, Envelope.decode(&d));
    d = wire.Decoder.init(&.{ 0, 0, 1, 0, 0, 0, 0, 0 });
    try testing.expectError(error.InvalidStream, Envelope.decode(&d));
    d = wire.Decoder.init(&.{ 0, 1, 1, 0, 0, 0, 0 });
    try testing.expectError(error.Truncated, Envelope.decode(&d));
}

test "unknown streams and kinds decode" {
    var d = wire.Decoder.init(&.{ 0, 200, 77, 0x80, 1, 0, 0, 0 });
    const env = try Envelope.decode(&d);
    try testing.expectEqual(@as(u8, 200), @intFromEnum(env.stream));
    try testing.expectEqual(@as(u8, 77), env.kind);
    try testing.expectEqual(@as(u8, 0x80), env.flags);
}

test "sequence comparison across wrap" {
    try testing.expect(seqBefore(1, 2));
    try testing.expect(!seqBefore(2, 1));
    try testing.expect(!seqBefore(5, 5));
    try testing.expect(seqBefore(0xffff_fff0, 3));
    try testing.expect(!seqBefore(3, 0xffff_fff0));
    try testing.expectEqual(@as(i32, 19), seqDiff(3, 0xffff_fff0));
    try testing.expectEqual(@as(i32, -19), seqDiff(0xffff_fff0, 3));
}
