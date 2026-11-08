//! NACK: the client finds gaps in media_seq and asks again; the message format.
//!
//! The tracker is sans-I/O: `onPacket` for every video packet, `collect` whenever the
//! client wants to send (each packet or a timer), `abandonThrough` when reassembly
//! settles a frame. A missing seq is NACKed first after a reorder wait (so plain
//! reordering costs nothing), then again every RTT plus slack until it arrives, it is
//! too old, or `max_retries` is used up. The reorder wait adapts: when an original
//! (not a retransmit) fills a gap, the wait grows to 1.25x how late it was, up to
//! `max_reorder_wait_us`, and decays back toward `reorder_wait_us` otherwise.
//!
//! Wire format (payload of a NACK message on the control-fast stream; the envelope
//! and message kind come from core/proto): zero or more 6-byte entries, each
//! `base u32 LE, mask u16 LE`, naming `base` and `base + 1 + i` for each set bit i.
const std = @import("std");
const hdr = @import("header.zig");

pub const Config = struct {
    /// Wait this long after a gap appears before the first NACK.
    reorder_wait_us: u64 = 1_000,
    /// Ceiling for the adaptive reorder wait.
    max_reorder_wait_us: u64 = 5_000,
    /// Added to the RTT before a NACK is repeated.
    retry_slack_us: u64 = 2_000,
    /// Retries are mostly bounded by `max_age_us`; this caps them on short RTTs.
    max_retries: u8 = 10,
    /// Stop asking for a seq this long after it went missing.
    max_age_us: u64 = 150_000,
    /// Missing seqs tracked at once; the oldest is dropped when full.
    capacity: usize = 1024,
};

const Missing = struct {
    seq: u32,
    detected_us: u64,
    last_nack_us: u64 = 0,
    retries: u8 = 0,
};

pub const Stats = struct {
    gaps: u64 = 0,
    recovered: u64 = 0,
    nacks_sent: u64 = 0,
    gave_up: u64 = 0,
    overflow: u64 = 0,
};

pub const Tracker = struct {
    cfg: Config,
    missing: []Missing,
    len: usize = 0,
    started: bool = false,
    highest: u32 = 0,
    /// Current reorder wait.
    reorder_us: u64,
    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, cfg: Config) !Tracker {
        return .{ .cfg = cfg, .missing = try gpa.alloc(Missing, cfg.capacity), .reorder_us = cfg.reorder_wait_us };
    }

    fn learnReorder(t: *Tracker, late_us: u64) void {
        const want = @max(t.cfg.reorder_wait_us, @min(late_us * 5 / 4, t.cfg.max_reorder_wait_us));
        if (want > t.reorder_us) t.reorder_us = want else t.reorder_us -= (t.reorder_us - want) / 16;
    }

    pub fn deinit(t: *Tracker, gpa: std.mem.Allocator) void {
        gpa.free(t.missing);
    }

    fn removeAt(t: *Tracker, i: usize) void {
        std.mem.copyForwards(Missing, t.missing[i .. t.len - 1], t.missing[i + 1 .. t.len]);
        t.len -= 1;
    }

    fn add(t: *Tracker, seq: u32, now_us: u64) void {
        if (t.len == t.missing.len) {
            t.removeAt(0);
            t.stats.overflow += 1;
        }
        t.missing[t.len] = .{ .seq = seq, .detected_us = now_us };
        t.len += 1;
        t.stats.gaps += 1;
    }

    /// Record a received media_seq; `retransmit` is the header's retransmit flag.
    pub fn onPacket(t: *Tracker, seq: u32, retransmit: bool, now_us: u64) void {
        if (!t.started) {
            t.started = true;
            t.highest = seq;
            return;
        }
        if (hdr.seqAfter(seq, t.highest)) {
            const gap = seq -% t.highest -% 1;
            // A gap wider than we can track: only the newest seqs are worth asking for.
            var s = if (gap > t.missing.len) seq -% @as(u32, @intCast(t.missing.len)) else t.highest +% 1;
            if (gap > t.missing.len) t.stats.overflow += gap - t.missing.len;
            while (s != seq) : (s +%= 1) t.add(s, now_us);
            t.highest = seq;
            return;
        }
        // Old or reordered: if we were waiting for it, it is recovered.
        for (t.missing[0..t.len], 0..) |m, i| if (m.seq == seq) {
            if (!retransmit) t.learnReorder(now_us -| m.detected_us);
            t.removeAt(i);
            t.stats.recovered += 1;
            return;
        };
    }

    /// Forget missing seqs up to and including `seq` (their frame was settled).
    pub fn abandonThrough(t: *Tracker, seq: u32) void {
        var i: usize = 0;
        while (i < t.len) {
            if (!hdr.seqAfter(t.missing[i].seq, seq)) t.removeAt(i) else i += 1;
        }
    }

    /// Seqs to NACK now, oldest first, written to `out`.
    pub fn collect(t: *Tracker, now_us: u64, rtt_us: u64, out: []u32) []u32 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < t.len) {
            const m = &t.missing[i];
            if (now_us -| m.detected_us > t.cfg.max_age_us or m.retries >= t.cfg.max_retries and
                now_us -| m.last_nack_us >= rtt_us + t.cfg.retry_slack_us)
            {
                t.removeAt(i);
                t.stats.gave_up += 1;
                continue;
            }
            const due = if (m.retries == 0)
                m.detected_us + t.reorder_us
            else
                m.last_nack_us + rtt_us + t.cfg.retry_slack_us;
            if (m.retries < t.cfg.max_retries and now_us >= due and n < out.len) {
                out[n] = m.seq;
                n += 1;
                m.retries += 1;
                m.last_nack_us = now_us;
                t.stats.nacks_sent += 1;
            }
            i += 1;
        }
        return out[0..n];
    }

    /// Earliest time `collect` might return something, for scheduling a wakeup.
    pub fn deadline(t: *const Tracker, rtt_us: u64) ?u64 {
        var best: ?u64 = null;
        for (t.missing[0..t.len]) |m| {
            if (m.retries >= t.cfg.max_retries) continue;
            const due = if (m.retries == 0) m.detected_us + t.reorder_us else m.last_nack_us + rtt_us + t.cfg.retry_slack_us;
            best = if (best) |b| @min(b, due) else due;
        }
        return best;
    }

    pub fn pending(t: *const Tracker) usize {
        return t.len;
    }
};

pub const entry_len = 6;

/// Encode seqs (ascending in wrapping order, as `collect` returns them) into `out`.
/// Returns the bytes written; stops early if `out` fills up.
pub fn encode(seqs: []const u32, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < seqs.len and n + entry_len <= out.len) {
        const base = seqs[i];
        var mask: u16 = 0;
        i += 1;
        while (i < seqs.len) : (i += 1) {
            const d = seqs[i] -% base;
            if (d == 0 or d > 16) break;
            mask |= @as(u16, 1) << @intCast(d - 1);
        }
        std.mem.writeInt(u32, out[n..][0..4], base, .little);
        std.mem.writeInt(u16, out[n + 4 ..][0..2], mask, .little);
        n += entry_len;
    }
    return n;
}

/// Iterate the seqs named by a NACK message.
pub const Iterator = struct {
    buf: []const u8,
    base: u32 = 0,
    mask: u16 = 0,
    in_entry: bool = false,

    pub fn init(buf: []const u8) error{Malformed}!Iterator {
        if (buf.len % entry_len != 0) return error.Malformed;
        return .{ .buf = buf };
    }

    pub fn next(it: *Iterator) ?u32 {
        if (it.in_entry and it.mask != 0) {
            const bit: u5 = @intCast(@ctz(it.mask));
            it.mask &= it.mask - 1;
            return it.base +% bit +% 1;
        }
        if (it.buf.len == 0) return null;
        it.base = std.mem.readInt(u32, it.buf[0..4], .little);
        it.mask = std.mem.readInt(u16, it.buf[4..6], .little);
        it.buf = it.buf[entry_len..];
        it.in_entry = true;
        return it.base;
    }
};

test "codec round trip with wrap" {
    const seqs = [_]u32{ 0xfffffffe, 0xffffffff, 3, 14, 15, 40 };
    var buf: [64]u8 = undefined;
    const n = encode(&seqs, &buf);
    try std.testing.expectEqual(@as(usize, 3 * entry_len), n); // {fffffffe..14}, {15}, {40}
    var it = try Iterator.init(buf[0..n]);
    for (seqs) |s| try std.testing.expectEqual(s, it.next().?);
    try std.testing.expect(it.next() == null);
    try std.testing.expectError(error.Malformed, Iterator.init(buf[0..5]));
}

test "gap, reorder wait, retries, recovery" {
    const gpa = std.testing.allocator;
    var t = try Tracker.init(gpa, .{ .reorder_wait_us = 100, .retry_slack_us = 0, .max_retries = 2, .max_age_us = 10_000 });
    defer t.deinit(gpa);
    var out: [16]u32 = undefined;
    t.onPacket(10, false, 0);
    t.onPacket(13, false, 0); // 11, 12 missing
    t.onPacket(11, false, 50); // reordered, not NACKed
    try std.testing.expectEqual(@as(usize, 0), t.collect(99, 1000, &out).len);
    try std.testing.expectEqualSlices(u32, &.{12}, t.collect(100, 1000, &out));
    try std.testing.expectEqual(@as(usize, 0), t.collect(500, 1000, &out).len);
    try std.testing.expectEqualSlices(u32, &.{12}, t.collect(1100, 1000, &out));
    try std.testing.expectEqual(@as(?u64, null), t.deadline(1000));
    try std.testing.expectEqual(@as(usize, 0), t.collect(5000, 1000, &out).len);
    try std.testing.expectEqual(@as(usize, 0), t.pending()); // gave up
    try std.testing.expectEqual(@as(u64, 1), t.stats.gave_up);
    t.onPacket(16, false, 6000);
    t.abandonThrough(14);
    try std.testing.expectEqualSlices(u32, &.{15}, t.collect(6100, 1000, &out));
    t.onPacket(15, false, 6200);
    try std.testing.expectEqual(@as(u64, 2), t.stats.recovered);
}

test "reorder wait adapts to late originals" {
    const gpa = std.testing.allocator;
    var t = try Tracker.init(gpa, .{ .reorder_wait_us = 100, .max_reorder_wait_us = 1000 });
    defer t.deinit(gpa);
    t.onPacket(0, false, 0);
    t.onPacket(2, false, 0);
    t.onPacket(1, false, 400); // 400 us late: wait becomes 500
    try std.testing.expectEqual(@as(u64, 500), t.reorder_us);
    t.onPacket(4, false, 1000);
    t.onPacket(3, true, 1100); // a retransmit says nothing about reordering
    try std.testing.expectEqual(@as(u64, 500), t.reorder_us);
    t.onPacket(6, false, 2000);
    t.onPacket(5, false, 2000); // in time: decays toward the floor
    try std.testing.expectEqual(@as(u64, 500 - 400 / 16), t.reorder_us);
    t.onPacket(8, false, 3000);
    t.onPacket(7, false, 9000); // capped
    try std.testing.expectEqual(@as(u64, 1000), t.reorder_us);
}

test "huge gap keeps only the newest" {
    const gpa = std.testing.allocator;
    var t = try Tracker.init(gpa, .{ .capacity = 4, .reorder_wait_us = 0 });
    defer t.deinit(gpa);
    var out: [16]u32 = undefined;
    t.onPacket(0xfffffff0, false, 0);
    t.onPacket(5, false, 0);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, t.collect(0, 0, &out));
}
