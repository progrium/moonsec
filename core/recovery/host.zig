//! Host side of loss recovery: long-term reference (LTR) bookkeeping, client acks, and the
//! choice between an LTR refresh and an IDR when the client reports a gap.
//!
//! Per encoded frame the caller does:
//!   1. `nextEncode()` -> the acked tokens to hand the encoder (VideoToolbox
//!      `AcknowledgedLTRTokens`) and whether to force an LTR refresh (`ForceLTRRefresh`) or a
//!      keyframe.
//!   2. `onEncoded(...)` when the encoder emits the frame -> header flags for the packetizer,
//!      or `onEncodeDropped()` when the encoder never emits it (S7b: the low-latency encoder
//!      drops frames under load). A forced recovery stays pending until a frame carries it.
//! Acks and recovery requests from the client go to `onAck` / `onRecoveryRequest` whenever they
//! arrive. No allocation, no clock, no I/O.

const std = @import("std");
const types = @import("types.zig");

const FrameId = types.FrameId;
const LtrToken = types.LtrToken;
const after = types.after;
const atOrAfter = types.atOrAfter;

pub const Force = enum { none, ltr_refresh, idr };

pub const Directive = struct {
    force: Force,
    /// Tokens the client acked since the previous encode. Valid until the next `nextEncode`.
    acked_tokens: []const LtrToken,
};

pub const Config = struct {
    /// The encoder supports long-term references. When false every recovery is an IDR.
    ltr: bool = true,
    /// LTR refreshes tried for one gap before falling back to an IDR. A repeated request for the
    /// same `first_missing` after the retry window means the previous refresh did not get through.
    max_ltr_attempts: u8 = 2,
    /// Frames after a recovery frame during which repeated requests for a gap it answers are
    /// treated as copies already in flight. Set it to about one RTT in frames plus one
    /// (`setRetryWindow`); the client retries after RTT + 2 frames + a margin.
    retry_window: u32 = 6,
    /// Use an IDR when the newest acked LTR is more than this many frames old (0: no limit).
    /// For encoders that keep long-term references for a bounded time.
    max_ltr_age: u32 = 0,
};

pub const Stats = struct {
    requests: u64 = 0,
    duplicate_requests: u64 = 0,
    ltr_refreshes: u64 = 0,
    /// Keyframes the host forced for recovery.
    recovery_idrs: u64 = 0,
    /// Keyframes the encoder produced on its own (counted, and they reset LTR state).
    other_keyframes: u64 = 0,
    /// Forced frames the encoder dropped; the force carried to the next frame.
    forced_dropped: u64 = 0,
    acks: u64 = 0,
    /// Acks for frames out of history, before the last keyframe, or with a wrong token.
    stale_acks: u64 = 0,
};

pub fn Host(comptime history_len: usize) type {
    std.debug.assert(std.math.isPowerOfTwo(history_len));
    return struct {
        const Self = @This();
        const max_pending = 64;

        const Sent = struct { id: FrameId, token: ?LtrToken, acked: bool };

        cfg: Config,
        stats: Stats = .{},

        history: [history_len]?Sent = @splat(null),
        last_id: ?FrameId = null,
        last_keyframe: ?FrameId = null,
        newest_acked: ?FrameId = null,

        pending_acks: [max_pending]LtrToken = undefined,
        pending_len: usize = 0,
        handed_acks: [max_pending]LtrToken = undefined,
        handed_len: usize = 0,

        /// A recovery the client is waiting for, not yet carried by an emitted frame.
        want: Force = .none,
        /// What the frame currently in the encoder was told to do.
        in_encoder: Force = .none,

        /// Newest keyframe or refresh emitted, and whether it was a keyframe.
        last_recovery: ?FrameId = null,
        last_recovery_idr: bool = false,
        gap: ?FrameId = null,
        attempts: u8 = 0,

        pub fn init(cfg: Config) Self {
            return .{ .cfg = cfg };
        }

        /// A frame ack from the client: decoded long-term references, and a recovery request
        /// while the client is frozen.
        pub fn onAck(self: *Self, ack: *const types.Ack) void {
            for (ack.slice()) |e| self.ackOne(e);
            if (ack.recovery) |r| self.onRecoveryRequest(r);
        }

        pub fn setRetryWindow(self: *Self, frames: u32) void {
            self.cfg.retry_window = frames;
        }

        fn ackOne(self: *Self, e: types.AckEntry) void {
            const slot = &self.history[e.frame_id % history_len];
            const s = if (slot.*) |*s| s else return self.stale();
            if (s.id != e.frame_id or s.token == null or s.token.? != e.token) return self.stale();
            if (self.last_keyframe) |k| if (after(k, e.frame_id)) return self.stale();
            if (s.acked) return; // repeated for redundancy
            s.acked = true;
            self.stats.acks += 1;
            if (self.newest_acked == null or after(e.frame_id, self.newest_acked.?)) self.newest_acked = e.frame_id;
            if (self.pending_len == max_pending) {
                std.mem.copyForwards(LtrToken, self.pending_acks[0 .. max_pending - 1], self.pending_acks[1..]);
                self.pending_len -= 1;
            }
            self.pending_acks[self.pending_len] = e.token;
            self.pending_len += 1;
        }

        fn stale(self: *Self) void {
            self.stats.stale_acks += 1;
        }

        pub fn onRecoveryRequest(self: *Self, req: types.RecoveryRequest) void {
            const w: Force = if (req.want_idr) .idr else .ltr_refresh;
            if (self.want != .none or self.inFlight(req)) {
                // Already answering, or the answer is on its way: a copy of the same request.
                self.stats.duplicate_requests += 1;
                if (@intFromEnum(w) > @intFromEnum(self.want) and self.want != .none) self.want = w;
                return;
            }
            self.stats.requests += 1;
            if (self.gap != null and self.gap.? == req.first_missing) {
                self.attempts +|= 1;
            } else {
                self.gap = req.first_missing;
                self.attempts = 1;
            }
            self.want = w;
        }

        fn inFlight(self: *const Self, req: types.RecoveryRequest) bool {
            const rf = self.last_recovery orelse return false;
            if (!after(rf, req.first_missing)) return false; // not an answer to this gap
            // The client decoded the refresh and it failed: it wants an IDR now.
            if (req.want_idr and !self.last_recovery_idr) return false;
            return self.last_id.? -% rf < self.cfg.retry_window;
        }

        pub fn nextEncode(self: *Self) Directive {
            std.debug.assert(self.handed_len == 0); // one frame in the encoder at a time
            const force = self.decide();
            self.in_encoder = force;
            @memcpy(self.handed_acks[0..self.pending_len], self.pending_acks[0..self.pending_len]);
            self.handed_len = self.pending_len;
            self.pending_len = 0;
            // An IDR drops every reference; acks for older frames mean nothing to the encoder.
            const acks = if (force == .idr) self.handed_acks[0..0] else self.handed_acks[0..self.handed_len];
            return .{ .force = force, .acked_tokens = acks };
        }

        fn decide(self: *const Self) Force {
            return switch (self.want) {
                .none => .none,
                .idr => .idr,
                .ltr_refresh => if (self.ltrUsable()) .ltr_refresh else .idr,
            };
        }

        fn ltrUsable(self: *const Self) bool {
            if (!self.cfg.ltr) return false;
            if (self.attempts > self.cfg.max_ltr_attempts) return false;
            const ref = self.newest_acked orelse return false;
            if (self.cfg.max_ltr_age != 0) {
                const now = self.last_id orelse return false;
                if (now -% ref > self.cfg.max_ltr_age) return false;
            }
            return true;
        }

        /// The encoder emitted a frame. `frame_id` must be one more than the previous emitted
        /// frame. Returns the flags the frame's video header carries.
        pub fn onEncoded(self: *Self, frame_id: FrameId, token: ?LtrToken, keyframe: bool) types.FrameFlags {
            if (self.last_id) |l| std.debug.assert(frame_id == l +% 1);
            self.last_id = frame_id;
            self.history[frame_id % history_len] = .{ .id = frame_id, .token = token, .acked = false };
            self.handed_len = 0;
            const forced = self.in_encoder;
            self.in_encoder = .none;

            if (keyframe) {
                self.last_keyframe = frame_id;
                self.last_recovery = frame_id;
                self.last_recovery_idr = true;
                self.newest_acked = null;
                self.pending_len = 0;
                if (forced == .none) self.stats.other_keyframes += 1 else self.stats.recovery_idrs += 1;
                self.want = .none;
                return .{ .keyframe = true };
            }
            if (forced == .ltr_refresh) {
                self.last_recovery = frame_id;
                self.last_recovery_idr = false;
                self.stats.ltr_refreshes += 1;
                self.want = .none;
                return .{ .refresh = true };
            }
            return .{};
        }

        /// The encoder will never emit the frame from the last `nextEncode`.
        pub fn onEncodeDropped(self: *Self) void {
            if (self.in_encoder != .none) self.stats.forced_dropped += 1;
            self.in_encoder = .none;
            // Hand the acks to the next frame; VideoToolbox may not have read a dropped frame's options.
            const n = @min(self.handed_len, max_pending - self.pending_len);
            std.mem.copyBackwards(LtrToken, self.pending_acks[n .. n + self.pending_len], self.pending_acks[0..self.pending_len]);
            @memcpy(self.pending_acks[0..n], self.handed_acks[self.handed_len - n .. self.handed_len]);
            self.pending_len += n;
            self.handed_len = 0;
        }

        /// The client is waiting on a recovery frame that has not been emitted yet.
        pub fn recoveryPending(self: *const Self) bool {
            return self.want != .none;
        }
    };
}

const testing = std.testing;
const H = Host(256);

fn ackOf(entries: []const types.AckEntry) types.Ack {
    var a: types.Ack = .{};
    for (entries) |e| {
        a.entries[a.len] = e;
        a.len += 1;
    }
    return a;
}

test "acks reach the encoder once and refresh uses them" {
    var h = H.init(.{});
    _ = h.nextEncode();
    try testing.expect(h.onEncoded(0, 10, true).keyframe);
    _ = h.nextEncode();
    _ = h.onEncoded(1, 11, false);

    const a = ackOf(&.{ .{ .frame_id = 0, .token = 10 }, .{ .frame_id = 1, .token = 11 } });
    h.onAck(&a);
    h.onAck(&a); // redundant copy
    const d = h.nextEncode();
    try testing.expectEqual(Force.none, d.force);
    try testing.expectEqualSlices(LtrToken, &.{ 10, 11 }, d.acked_tokens);
    _ = h.onEncoded(2, 12, false);
    try testing.expectEqual(@as(usize, 0), h.nextEncode().acked_tokens.len);
    _ = h.onEncoded(3, 13, false);

    h.onRecoveryRequest(.{ .first_missing = 2 });
    try testing.expectEqual(Force.ltr_refresh, h.nextEncode().force);
    try testing.expect(h.onEncoded(4, 14, false).refresh);
    try testing.expectEqual(Force.none, h.nextEncode().force);
    try testing.expectEqual(@as(u64, 2), h.stats.acks);
}

test "wrong token, unknown frame and pre-keyframe acks are stale" {
    var h = H.init(.{});
    _ = h.nextEncode();
    _ = h.onEncoded(0, 1, true);
    _ = h.nextEncode();
    _ = h.onEncoded(1, 2, false);
    _ = h.nextEncode();
    _ = h.onEncoded(2, 3, true); // encoder keyframe
    h.onAck(&ackOf(&.{ .{ .frame_id = 1, .token = 2 }, .{ .frame_id = 2, .token = 99 }, .{ .frame_id = 7, .token = 3 } }));
    try testing.expectEqual(@as(u64, 3), h.stats.stale_acks);
    try testing.expectEqual(@as(?FrameId, null), h.newest_acked);
    try testing.expectEqual(@as(u64, 2), h.stats.other_keyframes);
}

test "no acked LTR, no LTR support, or LTR too old falls back to IDR" {
    var h = H.init(.{});
    _ = h.nextEncode();
    _ = h.onEncoded(0, 1, true);
    h.onRecoveryRequest(.{ .first_missing = 1 });
    try testing.expectEqual(Force.idr, h.nextEncode().force);
    try testing.expect(h.onEncoded(1, 2, true).keyframe);
    try testing.expectEqual(@as(u64, 1), h.stats.recovery_idrs);

    var n = H.init(.{ .ltr = false });
    _ = n.nextEncode();
    _ = n.onEncoded(0, null, true);
    n.onAck(&ackOf(&.{.{ .frame_id = 0, .token = 0 }})); // tokenless frame: stale
    n.onRecoveryRequest(.{ .first_missing = 1 });
    try testing.expectEqual(Force.idr, n.nextEncode().force);

    var o = H.init(.{ .max_ltr_age = 10 });
    var id: FrameId = 0;
    while (id < 30) : (id += 1) {
        _ = o.nextEncode();
        _ = o.onEncoded(id, id + 100, id == 0);
        if (id == 5) o.onAck(&ackOf(&.{.{ .frame_id = 5, .token = 105 }}));
    }
    o.onRecoveryRequest(.{ .first_missing = 30 });
    try testing.expectEqual(Force.idr, o.nextEncode().force);
}

test "copies of a request are answered once; retries escalate to IDR" {
    var h = H.init(.{ .max_ltr_attempts = 2, .retry_window = 3 });
    _ = h.nextEncode();
    _ = h.onEncoded(0, 1, true);
    h.onAck(&ackOf(&.{.{ .frame_id = 0, .token = 1 }}));
    var id: FrameId = 1;
    const step = struct {
        fn f(hh: *H, i: *FrameId) Force {
            const d = hh.nextEncode().force;
            _ = hh.onEncoded(i.*, null, d == .idr);
            i.* += 1;
            return d;
        }
    }.f;
    try testing.expectEqual(Force.none, step(&h, &id)); // 1
    h.onRecoveryRequest(.{ .first_missing = 1 });
    h.onRecoveryRequest(.{ .first_missing = 1 }); // copy before the answer
    try testing.expectEqual(Force.ltr_refresh, step(&h, &id)); // 2
    h.onRecoveryRequest(.{ .first_missing = 1 }); // copy while the answer is in flight
    try testing.expectEqual(Force.none, step(&h, &id)); // 3
    try testing.expectEqual(Force.none, step(&h, &id)); // 4
    try testing.expectEqual(Force.none, step(&h, &id)); // 5: window over
    h.onRecoveryRequest(.{ .first_missing = 1 }); // retry: refresh lost
    try testing.expectEqual(Force.ltr_refresh, step(&h, &id)); // 6
    try testing.expectEqual(Force.none, step(&h, &id));
    try testing.expectEqual(Force.none, step(&h, &id));
    try testing.expectEqual(Force.none, step(&h, &id));
    h.onRecoveryRequest(.{ .first_missing = 1 }); // third attempt
    try testing.expectEqual(Force.idr, step(&h, &id));
    h.onRecoveryRequest(.{ .first_missing = 1 }); // late copy
    try testing.expectEqual(Force.none, step(&h, &id));
    try testing.expectEqual(@as(u64, 3), h.stats.duplicate_requests);
    try testing.expectEqual(@as(u64, 2), h.stats.ltr_refreshes);
    try testing.expectEqual(@as(u64, 1), h.stats.recovery_idrs);
}

test "a failed refresh asking for an IDR is answered at once" {
    var h = H.init(.{});
    _ = h.nextEncode();
    _ = h.onEncoded(0, 1, true);
    h.onAck(&ackOf(&.{.{ .frame_id = 0, .token = 1 }}));
    h.onRecoveryRequest(.{ .first_missing = 1 });
    try testing.expectEqual(Force.ltr_refresh, h.nextEncode().force);
    _ = h.onEncoded(1, 2, false);
    var a = ackOf(&.{});
    a.recovery = .{ .first_missing = 1, .want_idr = true };
    h.onAck(&a);
    try testing.expectEqual(Force.idr, h.nextEncode().force);
}

test "a force survives an encoder drop and acks are handed again" {
    var h = H.init(.{});
    _ = h.nextEncode();
    _ = h.onEncoded(0, 1, true);
    h.onAck(&ackOf(&.{.{ .frame_id = 0, .token = 1 }}));
    h.onRecoveryRequest(.{ .first_missing = 1 });
    const d = h.nextEncode();
    try testing.expectEqual(Force.ltr_refresh, d.force);
    try testing.expectEqualSlices(LtrToken, &.{1}, d.acked_tokens);
    h.onEncodeDropped();
    const d2 = h.nextEncode();
    try testing.expectEqual(Force.ltr_refresh, d2.force);
    try testing.expectEqualSlices(LtrToken, &.{1}, d2.acked_tokens);
    try testing.expect(h.onEncoded(1, 2, false).refresh);
    try testing.expectEqual(@as(u64, 1), h.stats.forced_dropped);
}

test "IDR request beats a pending refresh" {
    var h = H.init(.{});
    _ = h.nextEncode();
    _ = h.onEncoded(0, 1, true);
    h.onAck(&ackOf(&.{.{ .frame_id = 0, .token = 1 }}));
    h.onRecoveryRequest(.{ .first_missing = 1 });
    h.onRecoveryRequest(.{ .first_missing = 1, .want_idr = true }); // upgrades the pending refresh
    try testing.expectEqual(Force.idr, h.nextEncode().force);
}
