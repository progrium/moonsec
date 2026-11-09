//! Video shard header: one per video datagram, after the envelope.

const std = @import("std");
const wire = @import("wire.zig");

pub const Flags = packed struct(u8) {
    /// Frame is an IDR; decodable with no prior state.
    keyframe: bool = false,
    /// Frame references only a long-term reference the client has acked, so it is
    /// decodable after a gap (the recovery frame clients wait for).
    ltr_refresh: bool = false,
    /// `ltr_token` is meaningful: this frame is a long-term reference and the client
    /// acks the token once it has decoded the frame.
    ltr: bool = false,
    /// This datagram re-sends a shard already sent (NACK response); `media_seq` is the
    /// original's, the envelope `seq` is new.
    retransmit: bool = false,
    _reserved: u4 = 0,
};

/// Fixed 40-byte header. A frame is split into slices; each slice into FEC groups; each
/// group into `data_shards` data shards followed by `parity_shards` parity shards.
pub const ShardHeader = struct {
    /// Per-stream packet number, one per distinct shard; NACKs refer to it and a
    /// retransmit reuses it. Wraps.
    media_seq: u32,
    /// Increments by one per encoded frame. Wraps.
    frame_id: u32,
    slice: u8,
    slice_count: u8,
    /// FEC group index within the slice.
    group: u8,
    group_count: u8,
    /// Index within the group: [0, data_shards) are data, the rest parity.
    shard: u8,
    data_shards: u8,
    parity_shards: u8,
    flags: Flags = .{},
    /// Bytes of payload in the group's data shards before padding. Each data shard
    /// carries `shardSize()` bytes except the last, which carries the remainder;
    /// parity shards are `shardSize()` bytes.
    group_len: u32,
    /// Host clock, microseconds, when the frame was captured.
    capture_us: u64,
    /// Host clock, microseconds, when the encoder returned the frame. Sent as a u32
    /// delta from `capture_us`.
    encode_done_us: u64,
    /// Encoder's long-term reference token (VideoToolbox sample attachment); 0 unless
    /// `flags.ltr`.
    ltr_token: u64 = 0,

    pub const size = 40;

    pub const EncodeError = wire.EncodeError || error{InvalidHeader};
    pub const DecodeError = wire.DecodeError || error{InvalidHeader};

    pub fn shardCount(self: ShardHeader) u16 {
        return @as(u16, self.data_shards) + self.parity_shards;
    }

    /// Size of every shard in the group except the last data shard.
    pub fn shardSize(self: ShardHeader) u32 {
        return std.math.divCeil(u32, self.group_len, self.data_shards) catch unreachable;
    }

    /// Payload bytes this shard carries on the wire.
    pub fn payloadLen(self: ShardHeader) u32 {
        const sz = self.shardSize();
        if (@as(u16, self.shard) + 1 == self.data_shards) return self.group_len - sz * (self.data_shards - 1);
        return sz;
    }

    fn lastShardNonEmpty(group_len: u32, data_shards: u8) bool {
        const sz = std.math.divCeil(u32, group_len, data_shards) catch return false;
        return @as(u64, sz) * (data_shards - 1) < group_len;
    }

    pub fn validate(self: ShardHeader) error{InvalidHeader}!void {
        const ok = self.slice_count > 0 and self.slice < self.slice_count and
            self.group_count > 0 and self.group < self.group_count and
            self.data_shards > 0 and self.shard < self.shardCount() and
            self.group_len > 0 and
            // The last data shard holds at least one byte.
            lastShardNonEmpty(self.group_len, self.data_shards) and
            self.flags._reserved == 0 and
            self.encode_done_us >= self.capture_us and
            self.encode_done_us - self.capture_us <= std.math.maxInt(u32) and
            (self.flags.ltr or self.ltr_token == 0);
        if (!ok) return error.InvalidHeader;
    }

    pub fn encode(self: ShardHeader, e: *wire.Encoder) EncodeError!void {
        try self.validate();
        try e.int(u32, self.media_seq);
        try e.int(u32, self.frame_id);
        try e.int(u8, self.slice);
        try e.int(u8, self.slice_count);
        try e.int(u8, self.group);
        try e.int(u8, self.group_count);
        try e.int(u8, self.shard);
        try e.int(u8, self.data_shards);
        try e.int(u8, self.parity_shards);
        try e.int(u8, @bitCast(self.flags));
        try e.int(u32, self.group_len);
        try e.int(u64, self.capture_us);
        try e.int(u32, @intCast(self.encode_done_us - self.capture_us));
        try e.int(u64, self.ltr_token);
    }

    pub fn decode(d: *wire.Decoder) DecodeError!ShardHeader {
        var h: ShardHeader = undefined;
        h.media_seq = try d.int(u32);
        h.frame_id = try d.int(u32);
        h.slice = try d.int(u8);
        h.slice_count = try d.int(u8);
        h.group = try d.int(u8);
        h.group_count = try d.int(u8);
        h.shard = try d.int(u8);
        h.data_shards = try d.int(u8);
        h.parity_shards = try d.int(u8);
        const raw_flags = try d.int(u8);
        h.flags = @bitCast(raw_flags & 0x0f); // reserved bits are ignored on receive
        h.group_len = try d.int(u32);
        h.capture_us = try d.int(u64);
        const encode_delta = try d.int(u32);
        h.encode_done_us = std.math.add(u64, h.capture_us, encode_delta) catch return error.InvalidHeader;
        h.ltr_token = try d.int(u64);
        try h.validate();
        return h;
    }
};

const testing = std.testing;

fn sample() ShardHeader {
    return .{
        .media_seq = 0xfffffffe,
        .frame_id = 123456,
        .slice = 2,
        .slice_count = 4,
        .group = 1,
        .group_count = 3,
        .shard = 9,
        .data_shards = 8,
        .parity_shards = 2,
        .flags = .{ .ltr = true, .retransmit = true },
        .group_len = 8 * 1102 - 5,
        .capture_us = 1_700_000_000_123_456,
        .encode_done_us = 1_700_000_000_131_789,
        .ltr_token = 0x0123_4567_89ab_cdef,
    };
}

test "shard header round trip" {
    const h = sample();
    var buf: [ShardHeader.size]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    try h.encode(&e);
    try testing.expectEqual(@as(usize, ShardHeader.size), e.pos);
    var d = wire.Decoder.init(&buf);
    try testing.expectEqual(h, try ShardHeader.decode(&d));
}

test "shard sizes" {
    var h = sample();
    try testing.expectEqual(@as(u32, 1102), h.shardSize());
    try testing.expectEqual(@as(u32, 1102), h.payloadLen()); // parity
    h.shard = 7;
    try testing.expectEqual(@as(u32, 1102 - 5), h.payloadLen()); // last data shard
    h.shard = 0;
    try testing.expectEqual(@as(u32, 1102), h.payloadLen());
}

test "shard header validation" {
    const cases = [_]ShardHeader{
        blk: {
            var h = sample();
            h.slice = 4;
            break :blk h;
        },
        blk: {
            var h = sample();
            h.shard = 10;
            break :blk h;
        },
        blk: {
            var h = sample();
            h.data_shards = 0;
            break :blk h;
        },
        blk: {
            var h = sample();
            h.encode_done_us = h.capture_us - 1;
            break :blk h;
        },
        blk: {
            var h = sample();
            h.encode_done_us = h.capture_us + (1 << 32);
            break :blk h;
        },
        blk: {
            var h = sample();
            h.flags.ltr = false;
            break :blk h;
        },
        blk: {
            var h = sample();
            h.group_len = 7;
            break :blk h;
        },
        blk: {
            // ceil(9/4) = 3 per shard leaves nothing for the 4th.
            var h = sample();
            h.data_shards = 4;
            h.shard = 0;
            h.group_len = 9;
            break :blk h;
        },
    };
    for (cases) |h| {
        var buf: [ShardHeader.size]u8 = undefined;
        var e = wire.Encoder.init(&buf);
        try testing.expectError(error.InvalidHeader, h.encode(&e));
    }
}

test "decode rejects inconsistent indices" {
    var buf: [ShardHeader.size]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    try sample().encode(&e);
    buf[8] = 9; // slice >= slice_count
    var d = wire.Decoder.init(&buf);
    try testing.expectError(error.InvalidHeader, ShardHeader.decode(&d));
    d = wire.Decoder.init(buf[0..39]);
    try testing.expectError(error.Truncated, ShardHeader.decode(&d));
}
