//! Client-to-host control-fast messages: frame acks and transport-wide feedback.

const std = @import("std");
const wire = @import("wire.zig");

/// Tells the host which long-term references the client holds, and whether it is stuck.
///
/// Layout: flags u8, gap_frame u32, count u8, then `count` x (frame_id u32, ltr_token u64).
pub const FrameAck = struct {
    pub const Flags = packed struct(u8) {
        /// The client hit a gap at `gap_frame` and is dropping frames until a keyframe or
        /// an `ltr_refresh` frame arrives.
        recovery_needed: bool = false,
        _reserved: u7 = 0,
    };

    pub const Entry = struct {
        frame_id: u32,
        ltr_token: u64,
    };

    pub const entry_size = 12;
    pub const fixed_size = 6;
    pub const max_entries = std.math.maxInt(u8);

    flags: Flags = .{},
    /// First frame the client could not decode; 0 unless `flags.recovery_needed`.
    gap_frame: u32 = 0,
    /// Long-term reference frames decoded since the last ack (or still unacked).
    entries: []const Entry,

    pub const EncodeError = wire.EncodeError || error{InvalidMessage};
    pub const DecodeError = wire.DecodeError || error{InvalidMessage};

    pub fn encode(self: FrameAck, e: *wire.Encoder) EncodeError!void {
        if (self.entries.len > max_entries) return error.InvalidMessage;
        if (!self.flags.recovery_needed and self.gap_frame != 0) return error.InvalidMessage;
        try e.int(u8, @bitCast(self.flags));
        try e.int(u32, self.gap_frame);
        try e.int(u8, @intCast(self.entries.len));
        for (self.entries) |en| {
            try e.int(u32, en.frame_id);
            try e.int(u64, en.ltr_token);
        }
    }

    /// Zero-copy view of a decoded ack; iterate entries with `iterator()`.
    pub const View = struct {
        flags: Flags,
        gap_frame: u32,
        count: u8,
        raw_entries: []const u8,

        pub fn iterator(self: View) Iterator {
            return .{ .d = wire.Decoder.init(self.raw_entries) };
        }

        pub const Iterator = struct {
            d: wire.Decoder,

            pub fn next(self: *Iterator) ?Entry {
                if (self.d.rest().len == 0) return null;
                // Lengths were checked at decode time.
                return .{
                    .frame_id = self.d.int(u32) catch unreachable,
                    .ltr_token = self.d.int(u64) catch unreachable,
                };
            }
        };
    };

    /// Consumes the rest of the decoder; trailing bytes are an error.
    pub fn decode(d: *wire.Decoder) DecodeError!View {
        const raw_flags = try d.int(u8);
        const flags: Flags = @bitCast(raw_flags & 0x01);
        const gap_frame = try d.int(u32);
        const count = try d.int(u8);
        const raw = try d.take(@as(usize, count) * entry_size);
        if (d.rest().len != 0) return error.InvalidMessage;
        if (!flags.recovery_needed and gap_frame != 0) return error.InvalidMessage;
        return .{ .flags = flags, .gap_frame = gap_frame, .count = count, .raw_entries = raw };
    }
};

/// Transport-wide congestion feedback (TWCC-style): per-packet arrival times for a run of
/// transport sequence numbers, sent every 5-10 ms.
///
/// Layout: feedback_seq u16, base_seq u32, count u16, ref_time_us u64, then a received
/// bitmap of ceil(count/8) bytes (bit i, LSB first, = packet base_seq+i arrived), then one
/// zigzag-LEB128 signed delta (microseconds) per received packet in sequence order: the
/// first relative to ref_time_us, each next relative to the previous received packet.
pub const Feedback = struct {
    pub const fixed_size = 16;
    pub const max_count = std.math.maxInt(u16);

    /// Increments per feedback message so the host can see lost feedback. Wraps.
    feedback_seq: u16,
    /// Transport sequence number of arrivals[0].
    base_seq: u32,
    /// Client clock, microseconds; the base for the first delta.
    ref_time_us: u64,
    /// Arrival time (client clock, µs) of packet base_seq+i, or null if not received.
    arrivals: []const ?u64,

    pub const EncodeError = wire.EncodeError || error{InvalidMessage};
    pub const DecodeError = wire.DecodeError || error{InvalidMessage};

    pub fn encode(self: Feedback, e: *wire.Encoder) EncodeError!void {
        const n = self.arrivals.len;
        if (n == 0 or n > max_count) return error.InvalidMessage;
        try e.int(u16, self.feedback_seq);
        try e.int(u32, self.base_seq);
        try e.int(u16, @intCast(n));
        try e.int(u64, self.ref_time_us);
        const bitmap = try e.reserve(bitmapLen(n));
        @memset(bitmap, 0);
        for (self.arrivals, 0..) |a, i| {
            if (a != null) bitmap[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        }
        var prev: u64 = self.ref_time_us;
        for (self.arrivals) |a| {
            const t = a orelse continue;
            const delta = std.math.cast(i64, @as(i128, t) - prev) orelse return error.InvalidMessage;
            try e.svarint(delta);
            prev = t;
        }
    }

    pub fn bitmapLen(count: usize) usize {
        return (count + 7) / 8;
    }

    /// One packet's status from a decoded feedback message.
    pub const Status = struct {
        seq: u32,
        /// Client clock, µs; null if the packet had not arrived.
        arrival_us: ?u64,
    };

    /// Zero-copy view of a decoded feedback message; iterate with `iterator()`.
    pub const View = struct {
        feedback_seq: u16,
        base_seq: u32,
        count: u16,
        ref_time_us: u64,
        received: u16,
        bitmap: []const u8,
        deltas: []const u8,

        pub fn iterator(self: View) Iterator {
            return .{ .view = self, .d = wire.Decoder.init(self.deltas), .prev = self.ref_time_us };
        }

        pub const Iterator = struct {
            view: View,
            d: wire.Decoder,
            prev: u64,
            i: u16 = 0,

            pub fn next(self: *Iterator) ?Status {
                if (self.i == self.view.count) return null;
                const i = self.i;
                self.i += 1;
                const seq = self.view.base_seq +% i;
                if (!bitSet(self.view.bitmap, i)) return .{ .seq = seq, .arrival_us = null };
                // Deltas and their sums were validated at decode time.
                const delta = self.d.svarint() catch unreachable;
                self.prev = applyDelta(self.prev, delta) catch unreachable;
                return .{ .seq = seq, .arrival_us = self.prev };
            }
        };
    };

    fn bitSet(bitmap: []const u8, i: usize) bool {
        return bitmap[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
    }

    fn applyDelta(prev: u64, delta: i64) error{InvalidMessage}!u64 {
        const t = @as(i128, prev) + delta;
        return std.math.cast(u64, t) orelse error.InvalidMessage;
    }

    /// Consumes the rest of the decoder and validates every delta, so the iterator
    /// cannot fail. Trailing bytes and set padding bits are errors.
    pub fn decode(d: *wire.Decoder) DecodeError!View {
        const feedback_seq = try d.int(u16);
        const base_seq = try d.int(u32);
        const count = try d.int(u16);
        if (count == 0) return error.InvalidMessage;
        const ref_time_us = try d.int(u64);
        const bitmap = try d.take(bitmapLen(count));
        if (count % 8 != 0 and bitmap[bitmap.len - 1] >> @intCast(count % 8) != 0)
            return error.InvalidMessage;
        var received: u16 = 0;
        for (bitmap) |b| received += @popCount(b);

        const deltas = d.rest();
        var dd = wire.Decoder.init(deltas);
        var prev = ref_time_us;
        for (0..received) |_| prev = try applyDelta(prev, try dd.svarint());
        if (dd.rest().len != 0) return error.InvalidMessage;
        d.pos = d.buf.len;
        return .{
            .feedback_seq = feedback_seq,
            .base_seq = base_seq,
            .count = count,
            .ref_time_us = ref_time_us,
            .received = received,
            .bitmap = bitmap,
            .deltas = deltas,
        };
    }
};

const testing = std.testing;

test "frame ack round trip" {
    const entries = [_]FrameAck.Entry{
        .{ .frame_id = 10, .ltr_token = 1 },
        .{ .frame_id = 0xffffffff, .ltr_token = 0xffff_ffff_ffff_ffff },
    };
    const ack: FrameAck = .{ .flags = .{ .recovery_needed = true }, .gap_frame = 42, .entries = &entries };
    var buf: [64]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    try ack.encode(&e);
    try testing.expectEqual(@as(usize, FrameAck.fixed_size + 2 * FrameAck.entry_size), e.pos);

    var d = wire.Decoder.init(e.written());
    const v = try FrameAck.decode(&d);
    try testing.expect(v.flags.recovery_needed);
    try testing.expectEqual(@as(u32, 42), v.gap_frame);
    try testing.expectEqual(@as(u8, 2), v.count);
    var it = v.iterator();
    for (entries) |want| try testing.expectEqual(want, it.next().?);
    try testing.expectEqual(@as(?FrameAck.Entry, null), it.next());
}

test "frame ack with no entries, and malformed acks" {
    var buf: [16]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    try (FrameAck{ .entries = &.{} }).encode(&e);
    var d = wire.Decoder.init(e.written());
    const v = try FrameAck.decode(&d);
    try testing.expectEqual(@as(u8, 0), v.count);

    // gap_frame without recovery_needed
    d = wire.Decoder.init(&.{ 0, 1, 0, 0, 0, 0 });
    try testing.expectError(error.InvalidMessage, FrameAck.decode(&d));
    // count says 1 entry, none present
    d = wire.Decoder.init(&.{ 0, 0, 0, 0, 0, 1 });
    try testing.expectError(error.Truncated, FrameAck.decode(&d));
    // trailing byte
    d = wire.Decoder.init(&.{ 0, 0, 0, 0, 0, 0, 9 });
    try testing.expectError(error.InvalidMessage, FrameAck.decode(&d));
}

fn roundTripFeedback(fb: Feedback) !void {
    var buf: [1 << 16]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    try fb.encode(&e);
    var d = wire.Decoder.init(e.written());
    const v = try Feedback.decode(&d);
    try testing.expectEqual(fb.feedback_seq, v.feedback_seq);
    try testing.expectEqual(fb.base_seq, v.base_seq);
    try testing.expectEqual(fb.ref_time_us, v.ref_time_us);
    try testing.expectEqual(fb.arrivals.len, v.count);
    var it = v.iterator();
    for (fb.arrivals, 0..) |want, i| {
        const got = it.next().?;
        try testing.expectEqual(fb.base_seq +% @as(u32, @intCast(i)), got.seq);
        try testing.expectEqual(want, got.arrival_us);
    }
    try testing.expectEqual(@as(?Feedback.Status, null), it.next());
}

test "feedback round trip with loss, reordering and seq wrap" {
    const arrivals = [_]?u64{ 1_000_000, 1_000_120, null, 1_000_090, null, null, 1_004_000, 1_004_001, 1_020_000 };
    try roundTripFeedback(.{
        .feedback_seq = 0xffff,
        .base_seq = 0xffff_fffc,
        .ref_time_us = 999_500,
        .arrivals = &arrivals,
    });
}

test "feedback all lost, single packet, and large random run" {
    try roundTripFeedback(.{ .feedback_seq = 1, .base_seq = 0, .ref_time_us = 0, .arrivals = &.{ null, null, null } });
    try roundTripFeedback(.{ .feedback_seq = 1, .base_seq = 7, .ref_time_us = 5, .arrivals = &.{5} });

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var arrivals: [3000]?u64 = undefined;
    var t: u64 = 50_000_000;
    for (&arrivals) |*a| {
        if (r.uintLessThan(u8, 100) < 5) {
            a.* = null;
        } else {
            // mostly forward, sometimes reordered backwards
            t = if (r.boolean() and t > 2000) t - r.uintLessThan(u64, 2000) else t + r.uintLessThan(u64, 20_000);
            a.* = t;
        }
    }
    try roundTripFeedback(.{ .feedback_seq = 9, .base_seq = 123, .ref_time_us = 50_000_000, .arrivals = &arrivals });
}

test "feedback is compact for typical spacing" {
    // 100 packets ~90 µs apart: 16 fixed + 13 bitmap + 100 two-byte deltas.
    var arrivals: [100]?u64 = undefined;
    for (&arrivals, 0..) |*a, i| a.* = 1_000_000 + i * 90;
    var buf: [512]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    try (Feedback{ .feedback_seq = 0, .base_seq = 0, .ref_time_us = 1_000_000, .arrivals = &arrivals }).encode(&e);
    try testing.expectEqual(@as(usize, 16 + 13 + 1 + 99 * 2), e.pos);
}

test "feedback rejects malformed input" {
    var buf: [64]u8 = undefined;
    var e = wire.Encoder.init(&buf);
    try (Feedback{ .feedback_seq = 0, .base_seq = 0, .ref_time_us = 100, .arrivals = &.{ 110, null, 120 } }).encode(&e);
    const good = e.written();

    var d = wire.Decoder.init(good[0 .. good.len - 1]);
    try testing.expectError(error.Truncated, Feedback.decode(&d));

    var extra: [64]u8 = undefined;
    @memcpy(extra[0..good.len], good);
    extra[good.len] = 0;
    d = wire.Decoder.init(extra[0 .. good.len + 1]);
    try testing.expectError(error.InvalidMessage, Feedback.decode(&d));

    var pad: [64]u8 = undefined;
    @memcpy(pad[0..good.len], good);
    pad[16] |= 0x80; // padding bit past count
    d = wire.Decoder.init(pad[0..good.len]);
    try testing.expectError(error.InvalidMessage, Feedback.decode(&d));

    // count 0
    d = wire.Decoder.init(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expectError(error.InvalidMessage, Feedback.decode(&d));

    // delta driving time below zero
    e = wire.Encoder.init(&buf);
    try e.int(u16, 0);
    try e.int(u32, 0);
    try e.int(u16, 1);
    try e.int(u64, 5);
    try e.int(u8, 1);
    try e.svarint(-6);
    d = wire.Decoder.init(e.written());
    try testing.expectError(error.InvalidMessage, Feedback.decode(&d));

    try testing.expectError(error.InvalidMessage, (Feedback{ .feedback_seq = 0, .base_seq = 0, .ref_time_us = 0, .arrivals = &.{} }).encode(&e));
}
