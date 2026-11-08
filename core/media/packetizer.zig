//! Host side: split encoded slices into video shards (proto.ShardHeader + payload).
//!
//! Sans-I/O and copy-free: the caller hands over each slice as the encoder emits it, so
//! packetizing starts before the frame is done, and gets back shards whose payload
//! points into the slice. The network stage wraps each one in an envelope
//! (`proto.encodeVideoShard`) and records it in the retransmit `History`.
//! A slice is cut into groups of up to `group_shards` data shards (the unit FEC
//! protects); a group's shards are equal size except the last (spec/wire-v0.md).
//!
//! FEC: `parity[k]` is the number of Reed-Solomon parity shards sent after a group of
//! `k` data shards (all zero, the default, means FEC off; `policy.zig` fills it from
//! measured loss). Parity is computed once the group's last data shard is handed out,
//! over the data shards zero-padded to the group's shard size, and written to the
//! caller's `ParityBuffer`, so parity payloads are valid until the next group's parity.
const std = @import("std");
const proto = @import("../proto/root.zig");
const fec = @import("fec.zig");
const ShardHeader = proto.ShardHeader;

/// Most parity shards one group can carry (30% of a 32-shard group is 10; the rest is
/// headroom for larger groups).
pub const max_parity = 32;

/// Scratch for parity shards: one group's worth, plus the padded last data shard.
pub const ParityBuffer = struct {
    parity: [max_parity * proto.video_payload]u8 = undefined,
    last: [proto.video_payload]u8 = undefined,
};

/// Parity shards per data-shard count: `table[k]` for a group of k data shards.
pub const ParityTable = [256]u8;
pub const no_parity: ParityTable = @splat(0);

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

pub const Error = error{
    SliceTooLarge,
    EmptySlice,
    /// `parity` asks for FEC but there is no `parity_buf`, or the payload size is over
    /// what a `ParityBuffer` holds.
    NoParityBuffer,
};

pub const Packetizer = struct {
    /// Largest shard payload; the default fills a 1150-byte datagram.
    max_payload: usize = proto.video_payload,
    /// Data shards per group, at most 255.
    group_shards: u8 = 32,
    next_seq: u32 = 0,
    /// Parity shards per group size; `no_parity` turns FEC off.
    parity: ParityTable = no_parity,
    /// Where parity is written; needed once any `parity` entry is non-zero.
    parity_buf: ?*ParityBuffer = null,

    /// True when some group size gets parity.
    pub fn fecEnabled(p: *const Packetizer) bool {
        return !std.mem.allEqual(u8, &p.parity, 0);
    }

    /// Parity shards for a group of `k` data shards, clamped to what the wire and the
    /// buffer allow.
    pub fn parityFor(p: *const Packetizer, k: u8) u8 {
        return @min(p.parity[k], max_parity, 255 - @as(u16, k));
    }

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
        if (p.fecEnabled() and (p.parity_buf == null or p.max_payload > proto.video_payload)) return error.NoParityBuffer;
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
        parity_shards: u8 = 0,
        shard: u8 = 0,

        fn startGroup(it: *SliceIterator, g: u8) void {
            it.group = g;
            it.group_start = @as(usize, g) * it.p.groupCap();
            it.group_len = @min(it.p.groupCap(), it.data.len - it.group_start);
            // n = ceil(len / max) shards of ceil(len / n) bytes: never more than max, and the
            // last one is never empty because len > (n - 1) * max.
            it.data_shards = @intCast(std.math.divCeil(usize, it.group_len, it.p.max_payload) catch unreachable);
            it.parity_shards = it.p.parityFor(it.data_shards);
            it.shard = 0;
        }

        /// Encode the current group's parity into the packetizer's buffer.
        fn encodeParity(it: *SliceIterator, sz: usize) void {
            const buf = it.p.parity_buf.?;
            const k = it.data_shards;
            var data: [255][]const u8 = undefined;
            for (0..k) |i| {
                const start = it.group_start + i * sz;
                const len = @min(sz, it.group_len - i * sz);
                if (len == sz) {
                    data[i] = it.data[start..][0..sz];
                } else {
                    @memcpy(buf.last[0..len], it.data[start..][0..len]);
                    @memset(buf.last[len..sz], 0);
                    data[i] = buf.last[0..sz];
                }
            }
            var par: [max_parity][]u8 = undefined;
            for (0..it.parity_shards) |i| par[i] = buf.parity[i * sz ..][0..sz];
            const codec = fec.Codec.init(k, it.parity_shards) catch unreachable;
            codec.encode(data[0..k], par[0..it.parity_shards]) catch unreachable;
        }

        pub fn next(it: *SliceIterator) ?Shard {
            if (it.shard == it.data_shards + @as(u16, it.parity_shards)) {
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
                .parity_shards = it.parity_shards,
                .group_len = @intCast(it.group_len),
                .flags = it.info.flags,
                .capture_us = it.info.capture_us,
                .encode_done_us = it.info.encode_done_us,
                .ltr_token = it.info.ltr_token,
            };
            const sz = h.shardSize();
            it.p.next_seq +%= 1;
            it.shard += 1;
            if (h.shard >= it.data_shards) {
                if (h.shard == it.data_shards) it.encodeParity(sz);
                const i = h.shard - it.data_shards;
                return .{ .header = h, .payload = it.p.parity_buf.?.parity[i * sz ..][0..sz] };
            }
            const start = it.group_start + @as(usize, h.shard) * sz;
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

test "parity shards follow each group and rebuild lost data" {
    var buf: ParityBuffer = .{};
    var p: Packetizer = .{ .max_payload = 10, .group_shards = 4, .parity_buf = &buf };
    p.parity[4] = 2;
    p.parity[2] = 1;
    var data: [95]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    var it = try p.slice(.{ .frame_id = 1, .slice = 0, .slice_count = 1 }, &data);
    // Groups: 40 (4+2), 40 (4+2), 15 (2+1).
    var shards: [9][10]u8 = undefined;
    var lens: [9]usize = undefined;
    var hdrs: [9]ShardHeader = undefined;
    var n: usize = 0;
    while (it.next()) |s| : (n += 1) {
        try s.header.validate();
        try std.testing.expectEqual(@as(u32, @intCast(n)), s.header.media_seq);
        if (n < 9) {
            hdrs[n] = s.header;
            @memcpy(shards[n][0..s.payload.len], s.payload);
            lens[n] = s.payload.len;
        }
    }
    try std.testing.expectEqual(@as(usize, 6 + 6 + 3), n);
    // First group: lose data shards 1 and 3, rebuild from the two parity shards.
    try std.testing.expectEqual(@as(u8, 2), hdrs[4].parity_shards);
    try std.testing.expectEqual(@as(u8, 4), hdrs[4].shard);
    var bufs: [6][10]u8 = undefined;
    var slots: [6][]u8 = undefined;
    for (0..6) |i| {
        @memset(&bufs[i], 0);
        @memcpy(bufs[i][0..lens[i]], shards[i][0..lens[i]]);
        slots[i] = &bufs[i];
    }
    @memset(&bufs[1], 0xaa);
    @memset(&bufs[3], 0xaa);
    const present = [_]bool{ true, false, true, false, true, true };
    try (try fec.Codec.init(4, 2)).reconstruct(&slots, &present);
    for (0..4) |i| try std.testing.expectEqualSlices(u8, data[i * 10 ..][0..10], &bufs[i]);
}

test "fec needs a parity buffer" {
    var p: Packetizer = .{};
    p.parity[1] = 1;
    try std.testing.expectError(error.NoParityBuffer, p.slice(.{ .frame_id = 0, .slice = 0, .slice_count = 1 }, "x"));
}

test "parity over a short last shard uses zero padding" {
    var buf: ParityBuffer = .{};
    var p: Packetizer = .{ .max_payload = 8, .parity_buf = &buf };
    p.parity[3] = 1;
    const data = "0123456789abcdefghij"; // 3 shards of 7, last one 6
    var it = try p.slice(.{ .frame_id = 0, .slice = 0, .slice_count = 1 }, data);
    var xor: [7]u8 = @splat(0);
    var got_parity = false;
    while (it.next()) |s| {
        if (s.header.shard < 3) {
            for (s.payload, 0..) |b, i| xor[i] ^= b;
        } else {
            // Parity row 0 is the plain XOR of the padded data shards.
            try std.testing.expectEqualSlices(u8, &xor, s.payload);
            got_parity = true;
        }
    }
    try std.testing.expect(got_parity);
}
