//! Client side: put shards back into frames, in frame order.
//!
//! Sans-I/O: `push` takes a packet and the current time, `poll` hands out the next
//! frame or a loss, in frame-ID order. A frame is delivered once every data shard of
//! every group of every slice is in; it is declared lost when it is still incomplete
//! `frame_timeout_us` after we first learned of it (its own first packet, or the first
//! packet of a later frame when it has none), or when newer frames push it out of the
//! window. Frames are never delivered out of order, and nothing after a lost frame is
//! held back for it: freezing on a gap is the recovery module's job (item H).
//!
//! Parity shards (FEC, item G) are counted and ignored for now.
const std = @import("std");
const hdr = @import("header.zig");
const Header = hdr.Header;

pub const Config = struct {
    /// Frames tracked at once, counting from the next one to deliver.
    window: u32 = 32,
    /// Largest frame accepted; bounds what one sender can make us allocate per frame.
    max_frame_bytes: usize = 8 << 20,
    /// How long an incomplete frame is waited for (covers NACK round trips).
    frame_timeout_us: u64 = 100_000,
};

pub const Meta = struct {
    flags: hdr.Flags,
    capture_us: u64,
    encode_done_us: u32,
    ltr_token: u64,
};

pub const PushResult = enum {
    /// A new shard was stored.
    stored,
    /// Already had it (e.g. a retransmit raced the original).
    duplicate,
    /// Its frame was already delivered or declared lost.
    late,
    /// Too far ahead, inconsistent with earlier shards, or over a size limit.
    rejected,
    /// FEC parity, not used without FEC.
    parity,
    /// Allocation failed.
    out_of_memory,
};

pub const Stats = struct {
    stored: u64 = 0,
    duplicate: u64 = 0,
    late: u64 = 0,
    rejected: u64 = 0,
    parity: u64 = 0,
    out_of_memory: u64 = 0,
    frames_delivered: u64 = 0,
    frames_lost: u64 = 0,
};

const Group = struct {
    len: u32 = 0,
    data_shards: u8 = 0,
    have: u16 = 0,
    bits: std.StaticBitSet(256) = .initEmpty(),
    data: []u8 = &.{},

    fn started(g: Group) bool {
        return g.data_shards != 0;
    }
    fn complete(g: Group) bool {
        return g.started() and g.have == g.data_shards;
    }
};

const Slice = struct {
    groups: []Group = &.{},
    complete_groups: u16 = 0,
};

const Frame = struct {
    used: bool = false,
    id: u32 = 0,
    slices: []Slice = &.{},
    complete_slices: u16 = 0,
    first_seen_us: u64 = 0,
    bytes: usize = 0,
    /// Highest media_seq seen for this frame (seqs are sent in frame order).
    max_seq: u32 = 0,
    meta: Meta = undefined,

    fn complete(f: *const Frame) bool {
        return f.used and f.slices.len > 0 and f.complete_slices == f.slices.len;
    }
};

/// A delivered frame. Valid until the next `poll`.
pub const FrameView = struct {
    id: u32,
    meta: Meta,
    len: usize,
    frame: *const Frame,

    pub fn sliceCount(v: FrameView) usize {
        return v.frame.slices.len;
    }

    pub fn sliceLen(v: FrameView, i: usize) usize {
        var n: usize = 0;
        for (v.frame.slices[i].groups) |g| n += g.len;
        return n;
    }

    /// Copy slice `i` into `out` and return the copied bytes.
    pub fn copySlice(v: FrameView, i: usize, out: []u8) []u8 {
        var n: usize = 0;
        for (v.frame.slices[i].groups) |g| {
            @memcpy(out[n..][0..g.len], g.data);
            n += g.len;
        }
        return out[0..n];
    }

    /// Copy the whole frame (slices in order) into `out`, at least `len` bytes.
    pub fn copyTo(v: FrameView, out: []u8) []u8 {
        var n: usize = 0;
        for (0..v.sliceCount()) |i| n += v.copySlice(i, out[n..]).len;
        return out[0..n];
    }
};

pub const Event = union(enum) {
    frame: FrameView,
    /// Frame ID given up on; `max_seq` is the highest media_seq seen for it, if any.
    lost: struct { id: u32, max_seq: ?u32 },
};

pub const Reassembler = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    frames: []Frame,
    started: bool = false,
    /// Next frame ID to deliver.
    next: u32 = 0,
    /// Frames before this ID are given up immediately (window overflow).
    force_until: u32 = 0,
    /// Frame handed out by the last poll, freed on the next one.
    delivered: ?*Frame = null,
    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, cfg: Config) !Reassembler {
        std.debug.assert(cfg.window > 0);
        const frames = try gpa.alloc(Frame, cfg.window);
        @memset(frames, .{});
        return .{ .gpa = gpa, .cfg = cfg, .frames = frames };
    }

    pub fn deinit(r: *Reassembler) void {
        for (r.frames) |*f| r.release(f);
        r.gpa.free(r.frames);
    }

    fn slot(r: *Reassembler, id: u32) *Frame {
        return &r.frames[id % r.cfg.window];
    }

    fn find(r: *Reassembler, id: u32) ?*Frame {
        const f = r.slot(id);
        return if (f.used and f.id == id) f else null;
    }

    fn release(r: *Reassembler, f: *Frame) void {
        for (f.slices) |s| {
            for (s.groups) |g| r.gpa.free(g.data);
            r.gpa.free(s.groups);
        }
        r.gpa.free(f.slices);
        f.* = .{};
    }

    fn count(r: *Reassembler, res: PushResult) PushResult {
        switch (res) {
            inline else => |t| @field(r.stats, @tagName(t)) += 1,
        }
        return res;
    }

    /// Store one video packet (shard header + payload).
    pub fn push(r: *Reassembler, pkt: []const u8, now_us: u64) PushResult {
        const h = Header.decode(pkt) catch return r.count(.rejected);
        const payload = pkt[hdr.len..];
        if (h.shard >= h.data_shards) return r.count(.parity);
        if (payload.len != h.payloadLen()) return r.count(.rejected);

        if (!r.started) {
            r.started = true;
            r.next = h.frame_id;
            r.force_until = h.frame_id;
        }
        if (hdr.seqAfter(r.next, h.frame_id)) return r.count(.late);
        // Frames before force_until are being given up; their slots are already free.
        const base = if (hdr.seqAfter(r.force_until, r.next)) r.force_until else r.next;
        if (hdr.seqAfter(base, h.frame_id)) return r.count(.late);
        const ahead = h.frame_id -% base;
        if (ahead >= r.cfg.window) {
            // Far ahead after a burst of loss or a stall: give up the frames that no
            // longer fit, so this one can be stored. Refuse IDs absurdly far ahead
            // (garbage or a restarted sender).
            if (ahead >= 1 << 16) return r.count(.rejected);
            const need = h.frame_id -% r.cfg.window +% 1;
            var id = base;
            while (id != need) : (id +%= 1) {
                if (r.find(id)) |f| r.release(f);
            }
            r.force_until = need;
        }

        const f = r.slot(h.frame_id);
        if (!f.used) {
            const slices = r.gpa.alloc(Slice, h.slice_count) catch return r.count(.out_of_memory);
            @memset(slices, .{});
            f.* = .{
                .used = true,
                .id = h.frame_id,
                .slices = slices,
                .first_seen_us = now_us,
                .max_seq = h.media_seq,
                .meta = .{ .flags = h.flags, .capture_us = h.capture_us, .encode_done_us = h.encode_done_us, .ltr_token = h.ltr_token },
            };
            f.meta.flags.retransmit = false;
        } else std.debug.assert(f.id == h.frame_id); // window slots never alias inside the window
        if (f.slices.len != h.slice_count) return r.count(.rejected);

        const s = &f.slices[h.slice];
        if (s.groups.len == 0) {
            const groups = r.gpa.alloc(Group, h.group_count) catch return r.count(.out_of_memory);
            @memset(groups, .{});
            s.groups = groups;
        } else if (s.groups.len != h.group_count) return r.count(.rejected);

        const g = &s.groups[h.group];
        if (!g.started()) {
            if (f.bytes + h.group_len > r.cfg.max_frame_bytes) return r.count(.rejected);
            g.data = r.gpa.alloc(u8, h.group_len) catch return r.count(.out_of_memory);
            g.len = h.group_len;
            g.data_shards = h.data_shards;
            f.bytes += h.group_len;
        } else if (g.len != h.group_len or g.data_shards != h.data_shards) return r.count(.rejected);

        if (hdr.seqAfter(h.media_seq, f.max_seq)) f.max_seq = h.media_seq;
        if (g.bits.isSet(h.shard)) return r.count(.duplicate);
        g.bits.set(h.shard);
        g.have += 1;
        @memcpy(g.data[@as(usize, h.shard) * h.shardSize() ..][0..payload.len], payload);
        if (g.complete()) {
            s.complete_groups += 1;
            if (s.complete_groups == s.groups.len) f.complete_slices += 1;
        }
        return r.count(.stored);
    }

    /// Next frame or loss, in frame order, or null if the next frame is still worth waiting for.
    pub fn poll(r: *Reassembler, now_us: u64) ?Event {
        if (r.delivered) |f| {
            r.release(f);
            r.delivered = null;
        }
        if (!r.started) return null;

        const id = r.next;
        const cur = r.find(id);
        if (cur) |f| if (f.complete()) {
            r.next +%= 1;
            r.delivered = f;
            r.stats.frames_delivered += 1;
            return .{ .frame = .{ .id = f.id, .meta = f.meta, .len = f.bytes, .frame = f } };
        };

        const forced = hdr.seqAfter(r.force_until, id);
        if (!forced) {
            // When did we first know frame `id` should exist?
            const known_since: u64 = if (cur) |f| f.first_seen_us else blk: {
                var earliest: ?u64 = null;
                for (r.frames) |*f| {
                    if (f.used and hdr.seqAfter(f.id, id)) {
                        earliest = if (earliest) |e| @min(e, f.first_seen_us) else f.first_seen_us;
                    }
                }
                break :blk earliest orelse return null; // nothing newer yet: just wait
            };
            if (now_us -| known_since < r.cfg.frame_timeout_us) return null;
        }

        var max_seq: ?u32 = null;
        if (cur) |f| {
            max_seq = f.max_seq;
            r.release(f);
        }
        r.next +%= 1;
        r.stats.frames_lost += 1;
        return .{ .lost = .{ .id = id, .max_seq = max_seq } };
    }

    /// Earliest time `poll` could give up on the next frame, for scheduling a wakeup.
    /// Null when there is nothing to wait for.
    pub fn deadline(r: *Reassembler) ?u64 {
        if (!r.started) return null;
        var earliest: ?u64 = null;
        if (r.find(r.next)) |f| earliest = f.first_seen_us else for (r.frames) |*f| {
            if (f.used and hdr.seqAfter(f.id, r.next)) earliest = if (earliest) |e| @min(e, f.first_seen_us) else f.first_seen_us;
        }
        return if (earliest) |e| e + r.cfg.frame_timeout_us else null;
    }
};

const Packetizer = @import("packetizer.zig").Packetizer;

fn packets(gpa: std.mem.Allocator, p: *Packetizer, frame_id: u32, slices: []const []const u8) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    for (slices, 0..) |s, i| {
        var it = try p.slice(.{ .frame_id = frame_id, .slice = @intCast(i), .slice_count = @intCast(slices.len) }, s);
        var buf: [2048]u8 = undefined;
        while (it.next(&buf)) |pkt| try list.append(gpa, try gpa.dupe(u8, pkt));
    }
    return list;
}

fn freePackets(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |p| gpa.free(p);
    list.deinit(gpa);
}

test "reverse order delivers bit-exact" {
    const gpa = std.testing.allocator;
    var p: Packetizer = .{ .max_packet = hdr.len + 7, .group_shards = 3 };
    const a = "the quick brown fox jumps over";
    const b = "the lazy dog";
    var pk = try packets(gpa, &p, 9, &.{ a, b });
    defer freePackets(gpa, &pk);
    var r = try Reassembler.init(gpa, .{});
    defer r.deinit();
    // First packet sets the starting frame; the rest arrive reversed and duplicated.
    try std.testing.expectEqual(PushResult.stored, r.push(pk.items[0], 0));
    var i = pk.items.len;
    while (i > 1) {
        i -= 1;
        try std.testing.expect(r.poll(0) == null);
        try std.testing.expectEqual(PushResult.stored, r.push(pk.items[i], 0));
        try std.testing.expectEqual(PushResult.duplicate, r.push(pk.items[i], 0));
    }
    const ev = r.poll(0).?;
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(a ++ b, ev.frame.copyTo(&out));
    try std.testing.expectEqualStrings(b, ev.frame.copySlice(1, &out));
    try std.testing.expectEqual(@as(u32, 9), ev.frame.id);
    try std.testing.expect(r.poll(0) == null);
    try std.testing.expectEqual(PushResult.late, r.push(pk.items[0], 0));
}

test "incomplete frame times out, later frame still delivered in order" {
    const gpa = std.testing.allocator;
    var p: Packetizer = .{ .max_packet = hdr.len + 4 };
    var f0 = try packets(gpa, &p, 0, &.{"aaaabbbb"});
    defer freePackets(gpa, &f0);
    var f1 = try packets(gpa, &p, 1, &.{"cccc"});
    defer freePackets(gpa, &f1);
    var f3 = try packets(gpa, &p, 3, &.{"dd"});
    defer freePackets(gpa, &f3);
    var r = try Reassembler.init(gpa, .{ .frame_timeout_us = 1000 });
    defer r.deinit();
    _ = r.push(f0.items[0], 0); // second shard of frame 0 never comes
    _ = r.push(f1.items[0], 100);
    _ = r.push(f3.items[0], 200); // frame 2 never comes
    try std.testing.expect(r.poll(999) == null);
    try std.testing.expectEqual(@as(?u64, 1000), r.deadline());
    const lost = r.poll(1000).?.lost;
    try std.testing.expectEqual(@as(u32, 0), lost.id);
    try std.testing.expectEqual(@as(?u32, 0), lost.max_seq);
    try std.testing.expectEqual(@as(u32, 1), r.poll(1000).?.frame.id);
    try std.testing.expect(r.poll(1000) == null); // frame 2 known since t=200
    try std.testing.expectEqual(@as(u32, 2), r.poll(1200).?.lost.id);
    try std.testing.expectEqual(@as(u32, 3), r.poll(1200).?.frame.id);
    try std.testing.expect(r.poll(99999) == null);
}

test "window overflow gives up old frames at once" {
    const gpa = std.testing.allocator;
    var p: Packetizer = .{};
    var r = try Reassembler.init(gpa, .{ .window = 4, .frame_timeout_us = 1_000_000 });
    defer r.deinit();
    for ([_]u32{ 0, 5 }) |id| {
        var pk = try packets(gpa, &p, id, &.{"x"});
        defer freePackets(gpa, &pk);
        for (pk.items) |x| _ = r.push(x, 0);
    }
    // Frame 5 forces 0 and 1 out (0 was complete but not yet polled: given up too).
    try std.testing.expectEqual(@as(u32, 0), r.poll(0).?.lost.id);
    try std.testing.expectEqual(@as(u32, 1), r.poll(0).?.lost.id);
    try std.testing.expect(r.poll(0) == null); // 2..4 wait for the timeout
    try std.testing.expectEqual(@as(u32, 2), r.poll(1_000_000).?.lost.id);
    _ = r.poll(1_000_000);
    _ = r.poll(1_000_000);
    try std.testing.expectEqual(@as(u32, 5), r.poll(1_000_000).?.frame.id);
}

test "inconsistent and oversized shards are rejected" {
    const gpa = std.testing.allocator;
    var p: Packetizer = .{};
    var r = try Reassembler.init(gpa, .{ .max_frame_bytes = 10 });
    defer r.deinit();
    var pk = try packets(gpa, &p, 0, &.{"0123456789abc"});
    defer freePackets(gpa, &pk);
    try std.testing.expectEqual(PushResult.rejected, r.push(pk.items[0], 0));
    try std.testing.expectEqual(PushResult.rejected, r.push(pk.items[0][0..hdr.len], 0));
}
