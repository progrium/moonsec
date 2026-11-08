//! Host side: keep recently sent video shards so NACKed ones can be sent again.
//!
//! A fixed ring indexed by media_seq, allocated once. A shard is resent only while it
//! is younger than `max_age_us` (an older one would arrive after the client gave up its
//! frame) and at most once per `min_interval_us` (duplicate NACKs in flight).
//! A retransmit keeps its media_seq and carries the retransmit flag; the network stage
//! gives it a new envelope seq.
const std = @import("std");
const proto = @import("../proto/root.zig");
const Shard = @import("packetizer.zig").Shard;

pub const Config = struct {
    /// Shards kept; at ~1100 bytes, 4096 is about 4.5 MB and 30 Mbit/s for 1.2 s.
    capacity: usize = 4096,
    max_payload: usize = proto.video_payload,
    max_age_us: u64 = 150_000,
    min_interval_us: u64 = 5_000,
};

const Slot = struct {
    valid: bool = false,
    header: proto.ShardHeader = undefined,
    len: usize = 0,
    sent_us: u64 = 0,
    resent_us: ?u64 = null,
};

pub const Stats = struct {
    resent: u64 = 0,
    /// Not in the ring any more (overwritten or never sent).
    unknown: u64 = 0,
    too_old: u64 = 0,
    rate_limited: u64 = 0,
};

pub const History = struct {
    cfg: Config,
    slots: []Slot,
    buf: []u8,
    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, cfg: Config) !History {
        const slots = try gpa.alloc(Slot, cfg.capacity);
        @memset(slots, .{});
        errdefer gpa.free(slots);
        return .{ .cfg = cfg, .slots = slots, .buf = try gpa.alloc(u8, cfg.capacity * cfg.max_payload) };
    }

    pub fn deinit(h: *History, gpa: std.mem.Allocator) void {
        gpa.free(h.slots);
        gpa.free(h.buf);
    }

    fn data(h: *History, i: usize) []u8 {
        return h.buf[i * h.cfg.max_payload ..][0..h.cfg.max_payload];
    }

    /// Remember a shard just handed to the transport.
    pub fn record(h: *History, s: Shard, now_us: u64) void {
        std.debug.assert(s.payload.len <= h.cfg.max_payload);
        const i = s.header.media_seq % h.slots.len;
        @memcpy(h.data(i)[0..s.payload.len], s.payload);
        h.slots[i] = .{ .valid = true, .header = s.header, .len = s.payload.len, .sent_us = now_us };
    }

    /// The shard to send again for a NACKed media_seq, or null. Valid until the next `record`.
    pub fn resend(h: *History, seq: u32, now_us: u64) ?Shard {
        const i = seq % h.slots.len;
        const s = &h.slots[i];
        if (!s.valid or s.header.media_seq != seq) {
            h.stats.unknown += 1;
            return null;
        }
        if (now_us -| s.sent_us > h.cfg.max_age_us) {
            h.stats.too_old += 1;
            return null;
        }
        if (s.resent_us) |r| if (now_us -| r < h.cfg.min_interval_us) {
            h.stats.rate_limited += 1;
            return null;
        };
        s.resent_us = now_us;
        h.stats.resent += 1;
        var hdr = s.header;
        hdr.flags.retransmit = true;
        return .{ .header = hdr, .payload = h.data(i)[0..s.len] };
    }
};

test "resend, age and rate limits" {
    const gpa = std.testing.allocator;
    var h = try History.init(gpa, .{ .capacity = 8, .max_payload = 30, .max_age_us = 1000, .min_interval_us = 100 });
    defer h.deinit(gpa);
    var p: @import("packetizer.zig").Packetizer = .{ .max_payload = 30 };
    const data = "abcdefghij" ** 15;
    var it = try p.slice(.{ .frame_id = 1, .slice = 0, .slice_count = 1 }, data);
    while (it.next()) |s| h.record(s, 0);
    const again = h.resend(1, 10).?;
    try std.testing.expectEqual(@as(u32, 1), again.header.media_seq);
    try std.testing.expect(again.header.flags.retransmit);
    try std.testing.expectEqualStrings(data[30..60], again.payload);
    try std.testing.expect(h.resend(1, 50) == null); // rate limited
    try std.testing.expect(h.resend(1, 110) != null);
    try std.testing.expect(h.resend(2, 1001) == null); // too old
    try std.testing.expect(h.resend(9, 10) == null); // never sent
    try std.testing.expectEqual(Stats{ .resent = 2, .unknown = 1, .too_old = 1, .rate_limited = 1 }, h.stats);
}
