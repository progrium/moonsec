//! Client side of loss recovery: freeze decode at a gap, ask the host for a recovery frame,
//! retry if it does not come, and ack the long-term references the decoder produced.
//!
//! Apple's HEVC decoder breaks permanently if fed frames after a gap (S8), and dropping is
//! harmless on other decoders, so every client drops all frames from the gap until a recovery
//! point (an LTR refresh or IDR newer than the gap) arrives.
//!
//! The caller feeds complete frames in frame order (`onFrame`), tells it about frames reassembly
//! gave up on (`onFrameLost`) and about decoder results (`onDecoded`), and polls for frame acks
//! to send (`poll`). Times are microseconds on any monotonic clock.

const std = @import("std");
const types = @import("types.zig");

const FrameId = types.FrameId;
const FrameMeta = types.FrameMeta;
const after = types.after;
const atOrAfter = types.atOrAfter;

pub const Verdict = enum { decode, drop };

pub const State = enum {
    /// No keyframe yet: everything but an IDR is dropped.
    awaiting_keyframe,
    decoding,
    /// Dropping frames until a recovery point newer than `gap_start`.
    frozen,
};

pub const Config = struct {
    frame_interval_us: u64 = 16_667,
    /// Added to RTT plus two frame intervals before a request is retried.
    retry_margin_us: u64 = 10_000,
    retry_min_us: u64 = 20_000,
    /// How many recent acks each ack message repeats (at most `Ack.max_entries`).
    ack_redundancy: u8 = 8,
};

pub const Stats = struct {
    freezes: u64 = 0,
    requests: u64 = 0,
    retries: u64 = 0,
    dropped_frames: u64 = 0,
    late_frames: u64 = 0,
    decode_errors: u64 = 0,
    frozen_us_total: u64 = 0,
    frozen_us_max: u64 = 0,
};

pub const Client = struct {
    cfg: Config,
    stats: Stats = .{},
    state: State = .awaiting_keyframe,
    rtt_us: u64 = 0,

    expected: ?FrameId = null,
    gap_start: FrameId = 0,
    frozen_since_us: u64 = 0,
    want_idr: bool = false,

    request_due: bool = false,
    last_request_us: u64 = 0,
    have_requested: bool = false,

    /// Frames in [noack_lo, noack_hi) were fed to the decoder after a gap; never ack them.
    noack_lo: FrameId = 0,
    noack_hi: FrameId = 0,

    acks: [types.Ack.max_entries]types.AckEntry = undefined,
    acks_len: u8 = 0,
    acks_dirty: bool = false,

    pub fn init(cfg: Config) Client {
        std.debug.assert(cfg.ack_redundancy >= 1 and cfg.ack_redundancy <= types.Ack.max_entries);
        return .{ .cfg = cfg };
    }

    pub fn setRtt(self: *Client, rtt_us: u64) void {
        self.rtt_us = rtt_us;
    }

    /// A complete frame from reassembly. Returns whether to hand it to the decoder.
    pub fn onFrame(self: *Client, m: FrameMeta, now_us: u64) Verdict {
        if (self.expected) |exp| {
            if (after(exp, m.frame_id)) {
                // Older than one we already passed: a frame we declared lost came in late.
                self.stats.late_frames += 1;
                return .drop;
            }
            if (m.frame_id != exp) self.freeze(exp, now_us, false);
        } else if (!m.keyframe) {
            self.freeze(m.frame_id, now_us, true);
        }
        self.expected = m.frame_id +% 1;

        switch (self.state) {
            .decoding => return .decode,
            .awaiting_keyframe, .frozen => {
                const ok = if (self.want_idr or self.state == .awaiting_keyframe)
                    m.keyframe
                else
                    m.isRecoveryPoint() and after(m.frame_id, self.gap_start);
                if (!ok) {
                    self.stats.dropped_frames += 1;
                    return .drop;
                }
                self.thaw(m.frame_id, now_us);
                return .decode;
            },
        }
    }

    /// Reassembly gave up on `frame_id` (FEC and retransmission could not complete it).
    pub fn onFrameLost(self: *Client, frame_id: FrameId, now_us: u64) void {
        if (self.expected) |exp| {
            if (after(exp, frame_id)) return;
            self.freeze(exp, now_us, false);
        } else {
            self.freeze(frame_id, now_us, true);
        }
        self.expected = frame_id +% 1;
    }

    /// The decoder finished a frame that `onFrame` passed. A failure freezes at that frame; a
    /// failed recovery frame asks for an IDR.
    pub fn onDecoded(self: *Client, m: FrameMeta, ok: bool, now_us: u64) void {
        if (!ok) {
            self.stats.decode_errors += 1;
            self.freeze(m.frame_id, now_us, m.isRecoveryPoint());
            if (self.expected == null or after(m.frame_id +% 1, self.expected.?)) self.expected = m.frame_id +% 1;
            return;
        }
        const token = m.ltr_token orelse return;
        if (self.state == .frozen and atOrAfter(m.frame_id, self.gap_start)) return;
        if (atOrAfter(m.frame_id, self.noack_lo) and after(self.noack_hi, m.frame_id)) return;
        if (self.acks_len == self.cfg.ack_redundancy) {
            std.mem.copyForwards(types.AckEntry, self.acks[0 .. self.acks_len - 1], self.acks[1..self.acks_len]);
            self.acks_len -= 1;
        }
        self.acks[self.acks_len] = .{ .frame_id = m.frame_id, .token = token };
        self.acks_len += 1;
        self.acks_dirty = true;
    }

    /// A frame ack to send now, if any: when something new was decoded, right after a freeze,
    /// and again each retry interval while still frozen. It repeats the most recent acks, and
    /// carries the recovery request when one is due.
    pub fn poll(self: *Client, now_us: u64) ?types.Ack {
        const req = self.requestDue(now_us);
        if (!self.acks_dirty and req == null) return null;
        self.acks_dirty = false;
        var a: types.Ack = .{ .len = self.acks_len, .recovery = req };
        @memcpy(a.entries[0..self.acks_len], self.acks[0..self.acks_len]);
        return a;
    }

    fn requestDue(self: *Client, now_us: u64) ?types.RecoveryRequest {
        if (self.state == .decoding) return null;
        if (!self.request_due) {
            if (!self.have_requested or now_us -| self.last_request_us < self.retryTimeout()) return null;
            self.stats.retries += 1;
        }
        self.request_due = false;
        self.have_requested = true;
        self.last_request_us = now_us;
        self.stats.requests += 1;
        return .{ .first_missing = self.gap_start, .want_idr = self.want_idr or self.state == .awaiting_keyframe };
    }

    pub fn retryTimeout(self: *const Client) u64 {
        return @max(self.cfg.retry_min_us, self.rtt_us + 2 * self.cfg.frame_interval_us + self.cfg.retry_margin_us);
    }

    fn freeze(self: *Client, first_missing: FrameId, now_us: u64, want_idr: bool) void {
        switch (self.state) {
            .awaiting_keyframe => {
                if (self.request_due or self.have_requested) return;
                self.gap_start = first_missing;
                self.frozen_since_us = now_us;
                self.want_idr = true;
                self.newRequest();
                return;
            },
            .frozen => {
                if (want_idr and !self.want_idr) {
                    self.want_idr = true;
                    self.newRequest();
                }
                return;
            },
            .decoding => {},
        }
        self.state = .frozen;
        self.gap_start = first_missing;
        self.frozen_since_us = now_us;
        self.want_idr = want_idr;
        self.stats.freezes += 1;
        self.newRequest();
    }

    fn newRequest(self: *Client) void {
        self.request_due = true;
    }

    fn thaw(self: *Client, frame_id: FrameId, now_us: u64) void {
        if (self.state == .frozen) {
            const d = now_us -| self.frozen_since_us;
            self.stats.frozen_us_total += d;
            self.stats.frozen_us_max = @max(self.stats.frozen_us_max, d);
            self.noack_lo = self.gap_start;
            self.noack_hi = frame_id;
        }
        self.state = .decoding;
        self.want_idr = false;
        self.request_due = false;
        self.have_requested = false;
    }
};

const testing = std.testing;

fn pollRequest(c: *Client, now_us: u64) ?types.RecoveryRequest {
    const a = c.poll(now_us) orelse return null;
    return a.recovery;
}

test "starts on a keyframe, freezes on a gap, thaws on a newer refresh" {
    var c = Client.init(.{});
    try testing.expectEqual(Verdict.decode, c.onFrame(.{ .frame_id = 0, .keyframe = true, .ltr_token = 1 }, 0));
    c.onDecoded(.{ .frame_id = 0, .keyframe = true, .ltr_token = 1 }, true, 0);
    try testing.expectEqual(@as(u8, 1), c.poll(0).?.len);
    try testing.expectEqual(@as(?types.Ack, null), c.poll(0));

    try testing.expectEqual(Verdict.decode, c.onFrame(.{ .frame_id = 1 }, 1));
    try testing.expectEqual(Verdict.drop, c.onFrame(.{ .frame_id = 3, .ltr_token = 3 }, 3)); // 2 lost
    try testing.expectEqual(State.frozen, c.state);
    const r = pollRequest(&c, 3).?;
    try testing.expectEqual(@as(FrameId, 2), r.first_missing);
    try testing.expect(!r.want_idr);
    try testing.expectEqual(@as(?types.RecoveryRequest, null), pollRequest(&c, 4));
    try testing.expectEqual(Verdict.drop, c.onFrame(.{ .frame_id = 2, .refresh = true }, 5)); // late
    try testing.expectEqual(Verdict.decode, c.onFrame(.{ .frame_id = 4, .refresh = true, .ltr_token = 4 }, 50_000));
    try testing.expectEqual(State.decoding, c.state);
    try testing.expectEqual(@as(u64, 50_000 - 3), c.stats.frozen_us_total);
}

test "retries the request until the recovery frame arrives" {
    var c = Client.init(.{});
    c.setRtt(30_000);
    _ = c.onFrame(.{ .frame_id = 0, .keyframe = true }, 0);
    c.onFrameLost(1, 1000);
    const r1 = pollRequest(&c, 1000).?;
    const t = c.retryTimeout();
    try testing.expectEqual(@as(u64, 30_000 + 33_334 + 10_000), t);
    try testing.expectEqual(@as(?types.RecoveryRequest, null), pollRequest(&c, 1000 + t - 1));
    const r2 = pollRequest(&c, 1000 + t).?;
    try testing.expectEqual(r1.first_missing, r2.first_missing);
    try testing.expectEqual(@as(u64, 1), c.stats.retries);
}

test "no keyframe yet asks for an IDR and ignores refreshes" {
    var c = Client.init(.{});
    try testing.expectEqual(Verdict.drop, c.onFrame(.{ .frame_id = 5 }, 0));
    try testing.expect(pollRequest(&c, 0).?.want_idr);
    try testing.expectEqual(Verdict.drop, c.onFrame(.{ .frame_id = 6, .refresh = true }, 0));
    try testing.expectEqual(Verdict.decode, c.onFrame(.{ .frame_id = 7, .keyframe = true }, 0));
}

test "decode failure freezes; a failed refresh escalates to IDR; no acks from the gap" {
    var c = Client.init(.{});
    _ = c.onFrame(.{ .frame_id = 0, .keyframe = true }, 0);
    _ = c.onFrame(.{ .frame_id = 1, .ltr_token = 1 }, 0);
    _ = c.onFrame(.{ .frame_id = 2, .ltr_token = 2 }, 0);
    c.onDecoded(.{ .frame_id = 1, .ltr_token = 1 }, false, 0);
    c.onDecoded(.{ .frame_id = 2, .ltr_token = 2 }, true, 0); // decoded after the failure: not acked
    const a0 = c.poll(0).?;
    try testing.expectEqual(@as(u8, 0), a0.len);
    try testing.expectEqual(@as(FrameId, 1), a0.recovery.?.first_missing);
    const rf: FrameMeta = .{ .frame_id = 3, .refresh = true, .ltr_token = 3 };
    try testing.expectEqual(Verdict.decode, c.onFrame(rf, 0));
    c.onDecoded(rf, false, 0);
    const r = pollRequest(&c, 0).?;
    try testing.expect(r.want_idr);
    try testing.expectEqual(Verdict.drop, c.onFrame(.{ .frame_id = 4, .refresh = true }, 0));
    try testing.expectEqual(Verdict.decode, c.onFrame(.{ .frame_id = 5, .keyframe = true, .ltr_token = 5 }, 0));
    c.onDecoded(.{ .frame_id = 5, .keyframe = true, .ltr_token = 5 }, true, 0);
    try testing.expectEqual(@as(FrameId, 5), c.poll(0).?.slice()[0].frame_id);
}

test "acks repeat the most recent entries" {
    var c = Client.init(.{ .ack_redundancy = 3 });
    _ = c.onFrame(.{ .frame_id = 0, .keyframe = true }, 0);
    var i: FrameId = 0;
    while (i < 5) : (i += 1) c.onDecoded(.{ .frame_id = i, .ltr_token = i + 10 }, true, 0);
    const a = c.poll(0).?;
    try testing.expectEqual(@as(u8, 3), a.len);
    try testing.expectEqual(@as(FrameId, 2), a.slice()[0].frame_id);
    try testing.expectEqual(@as(FrameId, 4), a.slice()[2].frame_id);
}
