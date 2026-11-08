//! Audio stream messages (spec/audio-v0.md). Both follow the 8-byte envelope on stream 2.

const std = @import("std");
const proto = @import("../proto/root.zig");
const wire = proto.wire;

/// Message kinds on the audio stream (`proto.StreamId.audio`), host to client.
pub const Kind = enum(u8) {
    frame = 1,
    parity = 2,
    _,
};

/// Largest codec packet a frame may carry. Opus at 10 ms tops out near 640 bytes, so
/// this leaves room for parity headers in a `proto.max_datagram` datagram.
pub const max_packet = 1000;

/// Most data frames per parity group, and most parity packets per group.
pub const max_group = 8;
pub const max_parity = 2;

pub const FrameHeader = struct {
    /// Audio frame counter, +1 per frame; wraps.
    seq: u32,
    /// Host clock, microseconds, at the first sample of the frame.
    capture_us: u64,
    /// Samples per channel at 48 kHz (240 = 5 ms, 480 = 10 ms).
    samples: u16,
    /// Bit 0: the codec packet carries in-band FEC for frame `seq - 1`.
    flags: u8 = 0,

    pub const size = 15;
    pub const flag_fec: u8 = 1;

    pub fn hasFec(h: FrameHeader) bool {
        return h.flags & flag_fec != 0;
    }

    pub fn encode(h: FrameHeader, e: *wire.Encoder) wire.EncodeError!void {
        try e.int(u32, h.seq);
        try e.int(u64, h.capture_us);
        try e.int(u16, h.samples);
        try e.int(u8, h.flags);
    }

    pub fn decode(d: *wire.Decoder) wire.DecodeError!FrameHeader {
        return .{
            .seq = try d.int(u32),
            .capture_us = try d.int(u64),
            .samples = try d.int(u16),
            .flags = try d.int(u8),
        };
    }
};

/// A decoded frame message body: header plus codec packet (pointing into the input).
pub const Frame = struct {
    header: FrameHeader,
    packet: []const u8,

    pub fn parse(body: []const u8) proto.DecodeError!Frame {
        var d = wire.Decoder.init(body);
        const h = try FrameHeader.decode(&d);
        const packet = d.rest();
        if (packet.len == 0 or packet.len > max_packet or h.samples == 0) return error.InvalidMessage;
        return .{ .header = h, .packet = packet };
    }
};

/// Reed-Solomon parity over the bodies (header + packet) of `k` consecutive frames
/// starting at `first_seq`, each zero-padded to the longest. `lens` restores the
/// recovered bodies' lengths.
pub const ParityHeader = struct {
    first_seq: u32,
    k: u8,
    m: u8,
    /// This parity shard's index, 0..m-1.
    index: u8,
    lens: [max_group]u16 = @splat(0),

    pub fn size(h: ParityHeader) usize {
        return 7 + 2 * @as(usize, h.k);
    }

    pub fn encode(h: ParityHeader, e: *wire.Encoder) wire.EncodeError!void {
        try e.int(u32, h.first_seq);
        try e.int(u8, h.k);
        try e.int(u8, h.m);
        try e.int(u8, h.index);
        for (h.lens[0..h.k]) |l| try e.int(u16, l);
    }

    pub fn decode(d: *wire.Decoder) (wire.DecodeError || error{InvalidHeader})!ParityHeader {
        var h: ParityHeader = .{ .first_seq = try d.int(u32), .k = try d.int(u8), .m = try d.int(u8), .index = try d.int(u8) };
        if (h.k == 0 or h.k > max_group or h.m == 0 or h.m > max_parity or h.index >= h.m) return error.InvalidHeader;
        for (h.lens[0..h.k]) |*l| {
            l.* = try d.int(u16);
            if (l.* < FrameHeader.size + 1 or l.* > FrameHeader.size + max_packet) return error.InvalidHeader;
        }
        return h;
    }
};

pub const Parity = struct {
    header: ParityHeader,
    shard: []const u8,

    pub fn parse(body: []const u8) (proto.DecodeError || error{InvalidHeader})!Parity {
        var d = wire.Decoder.init(body);
        const h = try ParityHeader.decode(&d);
        const shard = d.rest();
        var longest: usize = 0;
        for (h.lens[0..h.k]) |l| longest = @max(longest, l);
        if (shard.len != longest) return error.InvalidMessage;
        return .{ .header = h, .shard = shard };
    }
};

/// Writes envelope + frame header + packet.
pub fn encodeFrame(buf: []u8, env_seq: u32, h: FrameHeader, packet: []const u8) proto.EncodeError![]u8 {
    if (packet.len == 0 or packet.len > max_packet) return error.InvalidMessage;
    var e = wire.Encoder.init(buf);
    try (proto.Envelope{ .stream = .audio, .kind = @intFromEnum(Kind.frame), .seq = env_seq }).encode(&e);
    try h.encode(&e);
    try e.bytes(packet);
    return e.written();
}

/// Writes envelope + parity header + parity shard.
pub fn encodeParity(buf: []u8, env_seq: u32, h: ParityHeader, shard: []const u8) proto.EncodeError![]u8 {
    var e = wire.Encoder.init(buf);
    try (proto.Envelope{ .stream = .audio, .kind = @intFromEnum(Kind.parity), .seq = env_seq }).encode(&e);
    try h.encode(&e);
    try e.bytes(shard);
    return e.written();
}

const testing = std.testing;

test "frame round trip through proto.decode" {
    var buf: [proto.max_datagram]u8 = undefined;
    const h: FrameHeader = .{ .seq = 0xffff_fffe, .capture_us = 123_456_789, .samples = 480, .flags = FrameHeader.flag_fec };
    const dg = try encodeFrame(&buf, 77, h, "opus!");
    try testing.expectEqual(@as(usize, proto.Envelope.size + FrameHeader.size + 5), dg.len);
    const m = try proto.decode(dg);
    try testing.expectEqual(proto.StreamId.audio, m.envelope().stream);
    try testing.expectEqual(@as(u32, 77), m.envelope().seq);
    const f = try Frame.parse(m.other.payload);
    try testing.expectEqual(h, f.header);
    try testing.expect(f.header.hasFec());
    try testing.expectEqualStrings("opus!", f.packet);
}

test "frame rejects empty and oversized packets" {
    var buf: [2000]u8 = undefined;
    try testing.expectError(error.InvalidMessage, encodeFrame(&buf, 1, .{ .seq = 0, .capture_us = 0, .samples = 480 }, ""));
    try testing.expectError(error.InvalidMessage, encodeFrame(&buf, 1, .{ .seq = 0, .capture_us = 0, .samples = 480 }, &([_]u8{0} ** (max_packet + 1))));
    try testing.expectError(error.Truncated, Frame.parse(&([_]u8{0} ** 10)));
}

test "parity round trip and validation" {
    var buf: [proto.max_datagram]u8 = undefined;
    var h: ParityHeader = .{ .first_seq = 10, .k = 2, .m = 1, .index = 0 };
    h.lens[0] = 20;
    h.lens[1] = 30;
    const shard = [_]u8{0xab} ** 30;
    const dg = try encodeParity(&buf, 5, h, &shard);
    const m = try proto.decode(dg);
    try testing.expectEqual(@as(u8, @intFromEnum(Kind.parity)), m.envelope().kind);
    const p = try Parity.parse(m.other.payload);
    try testing.expectEqual(h, p.header);
    try testing.expectEqual(@as(usize, 30), p.shard.len);
    // Shard length must equal the longest body.
    try testing.expectError(error.InvalidMessage, Parity.parse(m.other.payload[0 .. m.other.payload.len - 1]));
    // k = 0 and index >= m are invalid.
    var bad: [11]u8 = m.other.payload[0..11].*;
    bad[4] = 0;
    try testing.expectError(error.InvalidHeader, Parity.parse(&bad));
}
