//! Host side: split encoded slices into video packets (shard header + payload).
//!
//! Sans-I/O. The caller hands over each slice as the encoder emits it, so packetizing
//! starts before the frame is done, and gets packets back in a caller-owned buffer.
//! A slice is cut into groups of up to `group_shards` data shards (the unit FEC protects);
//! the shards of a group are equal size except the last, so reassembly needs no offsets.
const std = @import("std");
const hdr = @import("header.zig");

/// About 1150 bytes fits any QUIC datagram path (design: wire format). This budget is
/// for the shard header plus payload; the envelope comes on top.
pub const default_max_packet = 1150;

pub const SliceInfo = struct {
    frame_id: u32,
    slice: u8,
    slice_count: u8,
    flags: hdr.Flags = .{},
    capture_us: u64 = 0,
    encode_done_us: u32 = 0,
    ltr_token: u64 = 0,
};

pub const Error = error{SliceTooLarge};

pub const Packetizer = struct {
    max_packet: usize = default_max_packet,
    /// Data shards per group, at most 255.
    group_shards: u8 = 32,
    next_seq: u32 = 0,

    /// Largest payload one packet carries.
    pub fn chunk(p: Packetizer) usize {
        return p.max_packet - hdr.len;
    }

    fn groupCap(p: Packetizer) usize {
        return @as(usize, p.group_shards) * p.chunk();
    }

    pub fn groupCount(p: Packetizer, slice_len: usize) Error!u8 {
        const n = @max(1, std.math.divCeil(usize, slice_len, p.groupCap()) catch unreachable);
        return std.math.cast(u8, n) orelse error.SliceTooLarge;
    }

    /// Iterate the packets of one slice. Media sequence numbers are taken as packets are produced.
    pub fn slice(p: *Packetizer, info: SliceInfo, data: []const u8) Error!SliceIterator {
        std.debug.assert(p.group_shards > 0 and p.max_packet > hdr.len);
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
            it.data_shards = @intCast(@max(1, std.math.divCeil(usize, it.group_len, it.p.chunk()) catch unreachable));
            it.shard = 0;
        }

        /// Writes the next packet into `out` (at least `max_packet` bytes) and returns it.
        pub fn next(it: *SliceIterator, out: []u8) ?[]u8 {
            if (it.shard == it.data_shards) {
                if (it.group + 1 >= it.group_count) return null;
                it.startGroup(it.group + 1);
            }
            const h: hdr.Header = .{
                .media_seq = it.p.next_seq,
                .frame_id = it.info.frame_id,
                .slice = it.info.slice,
                .slice_count = it.info.slice_count,
                .group = it.group,
                .group_count = it.group_count,
                .shard = it.shard,
                .data_shards = it.data_shards,
                .group_len = @intCast(it.group_len),
                .flags = it.info.flags,
                .capture_us = it.info.capture_us,
                .encode_done_us = it.info.encode_done_us,
                .ltr_token = it.info.ltr_token,
            };
            const start = it.group_start + @as(usize, it.shard) * h.shardSize();
            const payload = it.data[start..][0..h.payloadLen()];
            h.encode(out[0..hdr.len]);
            @memcpy(out[hdr.len..][0..payload.len], payload);
            it.p.next_seq +%= 1;
            it.shard += 1;
            return out[0 .. hdr.len + payload.len];
        }
    };
};

test "split sizes and positions" {
    var p: Packetizer = .{ .max_packet = hdr.len + 10, .group_shards = 4, .next_seq = 0xffffffff };
    var data: [95]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    var it = try p.slice(.{ .frame_id = 5, .slice = 1, .slice_count = 2 }, &data);
    var buf: [hdr.len + 10]u8 = undefined;
    var got: [95]u8 = undefined;
    var n: usize = 0;
    var count: u32 = 0;
    while (it.next(&buf)) |pkt| : (count += 1) {
        const h = try hdr.Header.decode(pkt);
        try std.testing.expectEqual(0xffffffff +% count, h.media_seq);
        try std.testing.expectEqual(@as(u8, 3), h.group_count); // 40 + 40 + 15
        try std.testing.expectEqual(h.payloadLen(), pkt.len - hdr.len);
        @memcpy(got[n..][0 .. pkt.len - hdr.len], pkt[hdr.len..]);
        n += pkt.len - hdr.len;
    }
    try std.testing.expectEqual(@as(u32, 4 + 4 + 2), count);
    try std.testing.expectEqualSlices(u8, &data, got[0..n]);
}

test "empty slice is one empty shard" {
    var p: Packetizer = .{};
    var it = try p.slice(.{ .frame_id = 0, .slice = 0, .slice_count = 1 }, &.{});
    var buf: [default_max_packet]u8 = undefined;
    try std.testing.expectEqual(@as(usize, hdr.len), it.next(&buf).?.len);
    try std.testing.expect(it.next(&buf) == null);
}

test "slice too large" {
    var p: Packetizer = .{ .max_packet = hdr.len + 1, .group_shards = 1 };
    const big = [_]u8{0} ** 256;
    try std.testing.expectError(error.SliceTooLarge, p.slice(.{ .frame_id = 0, .slice = 0, .slice_count = 1 }, &big));
}
