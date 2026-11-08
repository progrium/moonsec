//! Host side: split encoded slices into video shards (proto.ShardHeader + payload).
//!
//! Sans-I/O and copy-free: the caller hands over each slice as the encoder emits it, so
//! packetizing starts before the frame is done, and gets back shards whose payload
//! points into the slice. The network stage wraps each one in an envelope
//! (`proto.encodeVideoShard`) and records it in the retransmit `History`.
//! A slice is cut into groups of up to `group_shards` data shards (the unit FEC
//! protects); a group's shards are equal size except the last (spec/wire-v0.md).
const std = @import("std");
const proto = @import("../proto/root.zig");
const ShardHeader = proto.ShardHeader;

pub const Shard = struct {
    header: ShardHeader,
    payload: []const u8,
};

pub const SliceInfo = struct {
    frame_id: u32,
    slice: u8,
    slice_count: u8,
    flags: proto.video.Flags = .{},
    capture_us: u64 = 0,
    /// At or after `capture_us`, by less than 2^32 us.
    encode_done_us: u64 = 0,
    /// Only with `flags.ltr`.
    ltr_token: u64 = 0,
};

pub const Error = error{ SliceTooLarge, EmptySlice };

pub const Packetizer = struct {
    /// Largest shard payload; the default fills a 1150-byte datagram.
    max_payload: usize = proto.video_payload,
    /// Data shards per group, at most 255.
    group_shards: u8 = 32,
    next_seq: u32 = 0,

    fn groupCap(p: Packetizer) usize {
        return @as(usize, p.group_shards) * p.max_payload;
    }

    pub fn groupCount(p: Packetizer, slice_len: usize) Error!u8 {
        if (slice_len == 0) return error.EmptySlice;
        const n = std.math.divCeil(usize, slice_len, p.groupCap()) catch unreachable;
        if (p.groupCap() > std.math.maxInt(u32)) return error.SliceTooLarge;
        return std.math.cast(u8, n) orelse error.SliceTooLarge;
    }

    /// Iterate the shards of one slice. Media sequence numbers are taken as shards are produced.
    pub fn slice(p: *Packetizer, info: SliceInfo, data: []const u8) Error!SliceIterator {
        std.debug.assert(p.group_shards > 0 and p.max_payload > 0);
        std.debug.assert(info.encode_done_us >= info.capture_us);
        std.debug.assert(info.flags.ltr or info.ltr_token == 0);
        var it: SliceIterator = .{ .p = p, .info = info, .data = data, .group_count = try p.groupCount(data.len) };
        it.startGroup(0);
        return it;
    }

    pub const SliceIterator = struct {
        p: *Packetizer,
        info: SliceInfo,
        data: []const u8,
        group_count: u8,
        group: u8 = 0,
        group_start: usize = 0,
        group_len: usize = 0,
        data_shards: u8 = 0,
        shard: u8 = 0,

        fn startGroup(it: *SliceIterator, g: u8) void {
            it.group = g;
            it.group_start = @as(usize, g) * it.p.groupCap();
            it.group_len = @min(it.p.groupCap(), it.data.len - it.group_start);
            // n = ceil(len / max) shards of ceil(len / n) bytes: never more than max, and the
            // last one is never empty because len > (n - 1) * max.
            it.data_shards = @intCast(std.math.divCeil(usize, it.group_len, it.p.max_payload) catch unreachable);
            it.shard = 0;
        }

        pub fn next(it: *SliceIterator) ?Shard {
            if (it.shard == it.data_shards) {
                if (it.group + 1 >= it.group_count) return null;
                it.startGroup(it.group + 1);
            }
            const h: ShardHeader = .{
                .media_seq = it.p.next_seq,
                .frame_id = it.info.frame_id,
                .slice = it.info.slice,
                .slice_count = it.info.slice_count,
                .group = it.group,
                .group_count = it.group_count,
                .shard = it.shard,
                .data_shards = it.data_shards,
                .parity_shards = 0,
                .group_len = @intCast(it.group_len),
                .flags = it.info.flags,
                .capture_us = it.info.capture_us,
                .encode_done_us = it.info.encode_done_us,
                .ltr_token = it.info.ltr_token,
            };
            const start = it.group_start + @as(usize, it.shard) * h.shardSize();
            it.p.next_seq +%= 1;
            it.shard += 1;
            return .{ .header = h, .payload = it.data[start..][0..h.payloadLen()] };
        }
    };
};

test "split sizes and positions" {
    var p: Packetizer = .{ .max_payload = 10, .group_shards = 4, .next_seq = 0xffffffff };
    var data: [95]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    var it = try p.slice(.{ .frame_id = 5, .slice = 1, .slice_count = 2 }, &data);
    var got: [95]u8 = undefined;
    var n: usize = 0;
    var count: u32 = 0;
    while (it.next()) |s| : (count += 1) {
        try s.header.validate();
        try std.testing.expectEqual(0xffffffff +% count, s.header.media_seq);
        try std.testing.expectEqual(@as(u8, 3), s.header.group_count); // 40 + 40 + 15
        @memcpy(got[n..][0..s.payload.len], s.payload);
        n += s.payload.len;
    }
    try std.testing.expectEqual(@as(u32, 4 + 4 + 2), count);
    try std.testing.expectEqualSlices(u8, &data, got[0..n]);
}

test "every shard of odd sizes is valid and fits" {
    var p: Packetizer = .{ .max_payload = 7, .group_shards = 5 };
    var data: [200]u8 = undefined;
    for (1..data.len) |len| {
        var it = try p.slice(.{ .frame_id = 0, .slice = 0, .slice_count = 1 }, data[0..len]);
        var n: usize = 0;
        while (it.next()) |s| {
            try s.header.validate();
            try std.testing.expect(s.payload.len > 0 and s.payload.len <= 7);
            n += s.payload.len;
        }
        try std.testing.expectEqual(len, n);
    }
}

test "empty and oversized slices" {
    var p: Packetizer = .{ .max_payload = 1, .group_shards = 1 };
    try std.testing.expectError(error.EmptySlice, p.slice(.{ .frame_id = 0, .slice = 0, .slice_count = 1 }, &.{}));
    const big = [_]u8{0} ** 256;
    try std.testing.expectError(error.SliceTooLarge, p.slice(.{ .frame_id = 0, .slice = 0, .slice_count = 1 }, &big));
}
