//! Host side: keep recently sent video packets so NACKed ones can be sent again.
//!
//! A fixed ring indexed by media_seq, allocated once. A packet is resent only while it
//! is younger than `max_age_us` (an older one would arrive after the client gave up its
//! frame) and at most once per `min_interval_us` (duplicate NACKs in flight).
//! Retransmits keep their media_seq and carry the retransmit flag.
const std = @import("std");
const hdr = @import("header.zig");

pub const Config = struct {
    /// Packets kept; at 1150 bytes, 4096 is about 4.7 MB and 30 Mbit/s for 1.2 s.
    capacity: usize = 4096,
    max_packet: usize = @import("packetizer.zig").default_max_packet,
    max_age_us: u64 = 150_000,
    min_interval_us: u64 = 5_000,
};

const Slot = struct {
    valid: bool = false,
    seq: u32 = 0,
    len: u16 = 0,
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
        return .{ .cfg = cfg, .slots = slots, .buf = try gpa.alloc(u8, cfg.capacity * cfg.max_packet) };
    }

    pub fn deinit(h: *History, gpa: std.mem.Allocator) void {
        gpa.free(h.slots);
        gpa.free(h.buf);
    }

    fn data(h: *History, i: usize) []u8 {
        return h.buf[i * h.cfg.max_packet ..][0..h.cfg.max_packet];
    }

    /// Remember a packet just handed to the transport.
    pub fn record(h: *History, pkt: []const u8, now_us: u64) void {
        std.debug.assert(pkt.len >= hdr.len and pkt.len <= h.cfg.max_packet);
        const seq = hdr.mediaSeq(pkt);
        const i = seq % h.slots.len;
        @memcpy(h.data(i)[0..pkt.len], pkt);
        h.slots[i] = .{ .valid = true, .seq = seq, .len = @intCast(pkt.len), .sent_us = now_us };
    }

    /// The packet to send again for a NACKed seq, or null. Valid until the next `record`.
    pub fn resend(h: *History, seq: u32, now_us: u64) ?[]const u8 {
        const i = seq % h.slots.len;
        const s = &h.slots[i];
        if (!s.valid or s.seq != seq) {
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
        const pkt = h.data(i)[0..s.len];
        hdr.setRetransmit(pkt);
        return pkt;
    }
};

test "resend, age and rate limits" {
    const gpa = std.testing.allocator;
    var h = try History.init(gpa, .{ .capacity = 8, .max_packet = 64, .max_age_us = 1000, .min_interval_us = 100 });
    defer h.deinit(gpa);
    var p: @import("packetizer.zig").Packetizer = .{ .max_packet = 64 };
    var it = try p.slice(.{ .frame_id = 1, .slice = 0, .slice_count = 1 }, "x" ** 150);
    var buf: [64]u8 = undefined;
    while (it.next(&buf)) |pkt| h.record(pkt, 0);
    const again = h.resend(1, 10).?;
    const parsed = try hdr.Header.decode(again);
    try std.testing.expectEqual(@as(u32, 1), parsed.media_seq);
    try std.testing.expect(parsed.flags.retransmit);
    try std.testing.expect(h.resend(1, 50) == null); // rate limited
    try std.testing.expect(h.resend(1, 110) != null);
    try std.testing.expect(h.resend(2, 1001) == null); // too old
    try std.testing.expect(h.resend(9, 10) == null); // never sent
    try std.testing.expectEqual(Stats{ .resent = 2, .unknown = 1, .too_old = 1, .rate_limited = 1 }, h.stats);
}
