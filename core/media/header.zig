//! Video shard header as core/media sees it.
//!
//! PROVISIONAL: item A owns the wire format (core/proto/video.zig `ShardHeader`). This
//! file mirrors A's fields so the rest of core/media codes against them now; once A
//! lands it becomes a re-export of A's type and these encode/decode helpers go away.
//! The envelope (stream ID, transport-wide seq) is added outside core/media.
//!
//! A slice is split into FEC groups; a group of `group_len` data bytes is split into
//! `data_shards` shards of `shardSize()` bytes, the last one shorter. Parity shards
//! (index >= data_shards) belong to FEC (item G) and are ignored here.
const std = @import("std");

pub const len = 36;

pub const Flags = packed struct(u8) {
    keyframe: bool = false,
    ltr_refresh: bool = false,
    ltr: bool = false,
    retransmit: bool = false,
    _: u4 = 0,
};

pub const Header = struct {
    /// Per-stream media sequence number, one per distinct shard. NACKs name it; a
    /// retransmit reuses it.
    media_seq: u32,
    frame_id: u32,
    slice: u8,
    slice_count: u8,
    group: u8,
    group_count: u8,
    shard: u8,
    data_shards: u8,
    parity_shards: u8 = 0,
    flags: Flags = .{},
    /// Data bytes in the group before padding.
    group_len: u32,
    capture_us: u64 = 0,
    encode_done_us: u32 = 0,
    ltr_token: u64 = 0,

    pub fn shardSize(h: Header) usize {
        return std.math.divCeil(usize, h.group_len, h.data_shards) catch unreachable;
    }

    /// Payload bytes this data shard carries.
    pub fn payloadLen(h: Header) usize {
        const size = h.shardSize();
        const start = @as(usize, h.shard) * size;
        return @min(size, h.group_len -| start);
    }

    pub fn encode(h: Header, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], h.media_seq, .little);
        std.mem.writeInt(u32, out[4..8], h.frame_id, .little);
        out[8] = h.slice;
        out[9] = h.slice_count;
        out[10] = h.group;
        out[11] = h.group_count;
        out[12] = h.shard;
        out[13] = h.data_shards;
        out[14] = h.parity_shards;
        out[15] = @bitCast(h.flags);
        std.mem.writeInt(u32, out[16..20], h.group_len, .little);
        std.mem.writeInt(u64, out[20..28], h.capture_us, .little);
        std.mem.writeInt(u32, out[28..32], h.encode_done_us, .little);
        std.mem.writeInt(u32, out[32..36], @truncate(h.ltr_token), .little);
    }

    pub fn decode(in: []const u8) error{Malformed}!Header {
        if (in.len < len) return error.Malformed;
        const h: Header = .{
            .media_seq = std.mem.readInt(u32, in[0..4], .little),
            .frame_id = std.mem.readInt(u32, in[4..8], .little),
            .slice = in[8],
            .slice_count = in[9],
            .group = in[10],
            .group_count = in[11],
            .shard = in[12],
            .data_shards = in[13],
            .parity_shards = in[14],
            .flags = @bitCast(in[15] & 0x0f),
            .group_len = std.mem.readInt(u32, in[16..20], .little),
            .capture_us = std.mem.readInt(u64, in[20..28], .little),
            .encode_done_us = std.mem.readInt(u32, in[28..32], .little),
            .ltr_token = std.mem.readInt(u32, in[32..36], .little),
        };
        if (h.slice_count == 0 or h.slice >= h.slice_count) return error.Malformed;
        if (h.group_count == 0 or h.group >= h.group_count) return error.Malformed;
        if (h.data_shards == 0 or h.shard >= @as(u16, h.data_shards) + h.parity_shards) return error.Malformed;
        if (h.group_len < h.data_shards and h.group_len != 0) return error.Malformed;
        return h;
    }
};

/// media_seq of an encoded packet without a full decode.
pub fn mediaSeq(pkt: []const u8) u32 {
    return std.mem.readInt(u32, pkt[0..4], .little);
}

/// Whether an encoded packet is a retransmission.
pub fn isRetransmit(pkt: []const u8) bool {
    return @as(Flags, @bitCast(pkt[15])).retransmit;
}

/// Mark an encoded packet as a retransmission in place.
pub fn setRetransmit(pkt: []u8) void {
    pkt[15] |= @as(u8, @bitCast(Flags{ .retransmit = true }));
}

/// Wrapping sequence comparison: true when `a` comes after `b` (RFC 1982 style).
pub fn seqAfter(a: u32, b: u32) bool {
    return a != b and (a -% b) < (1 << 31);
}

/// Signed wrapping distance a - b.
pub fn seqDiff(a: u32, b: u32) i32 {
    return @bitCast(a -% b);
}

test "header round trip" {
    const h: Header = .{
        .media_seq = 0xfffffffe,
        .frame_id = 77,
        .slice = 2,
        .slice_count = 3,
        .group = 1,
        .group_count = 2,
        .shard = 9,
        .data_shards = 10,
        .group_len = 10_000,
        .flags = .{ .keyframe = true, .retransmit = true },
        .capture_us = 123456,
        .encode_done_us = 6544,
        .ltr_token = 0xdeadbeef,
    };
    var buf: [len]u8 = undefined;
    h.encode(&buf);
    try std.testing.expectEqualDeep(h, try Header.decode(&buf));
    try std.testing.expectEqual(@as(usize, 1000), h.shardSize());
}

test "header rejects bad positions" {
    var buf: [len]u8 = undefined;
    (Header{ .media_seq = 1, .frame_id = 1, .slice = 0, .slice_count = 1, .group = 0, .group_count = 1, .shard = 0, .data_shards = 1, .group_len = 5 }).encode(&buf);
    _ = try Header.decode(&buf);
    buf[8] = 1; // slice == slice_count
    try std.testing.expectError(error.Malformed, Header.decode(&buf));
    try std.testing.expectError(error.Malformed, Header.decode(buf[0..10]));
}

test "last shard is shorter" {
    const h: Header = .{ .media_seq = 0, .frame_id = 0, .slice = 0, .slice_count = 1, .group = 0, .group_count = 1, .shard = 2, .data_shards = 3, .group_len = 7 };
    try std.testing.expectEqual(@as(usize, 3), h.shardSize());
    try std.testing.expectEqual(@as(usize, 1), h.payloadLen());
}

test "wrapping seq order" {
    try std.testing.expect(seqAfter(0, 0xffffffff));
    try std.testing.expect(!seqAfter(0xffffffff, 0));
    try std.testing.expectEqual(@as(i32, 2), seqDiff(1, 0xffffffff));
}
