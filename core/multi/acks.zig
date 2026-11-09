//! Long-term reference acks across several clients of one encoder.
//!
//! An LTR refresh references a long-term reference the encoder was told is acked. With one
//! encode fanned out to N clients, the refresh goes to all of them, so the reference must be
//! one every client decoded: a token reaches `recovery.Host` only once every member that
//! was receiving when the frame was sent has acked it (the intersection). A member that
//! leaves stops counting, which can release frames that only waited on it. Recovery
//! requests do not wait: any member's request makes a recovery frame for everyone (a
//! refresh is decodable by every member that has the reference, which is all of them).
//!
//! Frames sent before a member joined do not need its ack: a joiner starts at an IDR,
//! which drops every older reference anyway. Frames between its join and that IDR do need
//! it and are never released, which is right: the joiner cannot decode them.
//!
//! A frozen or lossy member holds back new common references, so refreshes reference an
//! older frame (still decodable by everyone) until it catches up, or fall back to an IDR
//! when `recovery.Host`'s `max_ltr_age` says the reference is too old.
const std = @import("std");
const types = @import("../recovery/types.zig");

const FrameId = types.FrameId;
const LtrToken = types.LtrToken;
const AckEntry = types.AckEntry;

pub const Mask = u32;

pub const Stats = struct {
    /// Acks from one member for frames other members have not acked yet.
    held: u64 = 0,
    /// Tokens handed on to recovery (every required member acked).
    released: u64 = 0,
    /// Acks for frames not in history, with a wrong token, or from a member the frame did
    /// not wait for.
    stale: u64 = 0,
};

pub fn AckJoin(comptime history_len: usize) type {
    std.debug.assert(std.math.isPowerOfTwo(history_len));
    return struct {
        const Self = @This();

        const Slot = struct { id: FrameId, token: LtrToken, required: Mask, acked: Mask, released: bool };

        slots: [history_len]?Slot = @splat(null),
        stats: Stats = .{},

        /// A frame left the encoder for the members in `required` (bit i = member slot i).
        /// Frames without a token are never acked.
        pub fn onEncoded(self: *Self, id: FrameId, token: ?LtrToken, required: Mask) void {
            const t = token orelse {
                self.slots[id % history_len] = null;
                return;
            };
            self.slots[id % history_len] = .{ .id = id, .token = t, .required = required, .acked = 0, .released = false };
        }

        /// Member `bit` decoded the LTR `e`. Calls `sink.onAckEntry(e)` once every member
        /// the frame waited for has.
        pub fn onAck(self: *Self, bit: u5, e: AckEntry, sink: anytype) void {
            const m: Mask = @as(Mask, 1) << bit;
            const slot = &self.slots[e.frame_id % history_len];
            const s = if (slot.*) |*s| s else return self.stale();
            if (s.id != e.frame_id or s.token != e.token or s.required & m == 0) return self.stale();
            if (s.acked & m != 0) return; // repeated for redundancy
            s.acked |= m;
            if (!self.tryRelease(s, sink)) self.stats.held += 1;
        }

        fn tryRelease(self: *Self, s: *Slot, sink: anytype) bool {
            if (s.released or s.required == 0 or s.acked & s.required != s.required) return false;
            s.released = true;
            self.stats.released += 1;
            sink.onAckEntry(.{ .frame_id = s.id, .token = s.token });
            return true;
        }

        /// Member `bit` left: no frame waits for it any more, and frames only it held back
        /// are released, oldest first.
        pub fn remove(self: *Self, bit: u5, newest: ?FrameId, sink: anytype) void {
            const m: Mask = @as(Mask, 1) << bit;
            const last = newest orelse return;
            var i: usize = history_len;
            while (i > 0) : (i -= 1) {
                const id = last -% @as(FrameId, @intCast(i - 1));
                const slot = &self.slots[id % history_len];
                const s = if (slot.*) |*s| s else continue;
                if (s.id != id) continue;
                s.required &= ~m;
                s.acked &= ~m;
                _ = self.tryRelease(s, sink);
            }
        }

        fn stale(self: *Self) void {
            self.stats.stale += 1;
        }

        /// The view `recovery.wire.applyFrameAck` takes for one member: acks go through the
        /// join, recovery requests straight to `rec`.
        pub fn member(self: *Self, bit: u5, rec: anytype) Member(@TypeOf(rec)) {
            return .{ .join = self, .bit = bit, .rec = rec };
        }

        pub fn Member(comptime Rec: type) type {
            return struct {
                join: *Self,
                bit: u5,
                rec: Rec,

                pub fn onAckEntry(v: @This(), e: AckEntry) void {
                    v.join.onAck(v.bit, e, v.rec);
                }

                pub fn onRecoveryRequest(v: @This(), r: types.RecoveryRequest) void {
                    v.rec.onRecoveryRequest(r);
                }
            };
        }
    };
}

const testing = std.testing;
const Host = @import("../recovery/host.zig").Host(64);
const J = AckJoin(64);

test "a token reaches the encoder only when every member acked it" {
    var h = Host.init(.{});
    var j: J = .{};
    var id: FrameId = 0;
    while (id < 4) : (id += 1) {
        _ = h.nextEncode();
        _ = h.onEncoded(id, 100 + id, id == 0);
        j.onEncoded(id, 100 + id, 0b011);
    }
    j.onAck(0, .{ .frame_id = 2, .token = 102 }, &h);
    j.onAck(0, .{ .frame_id = 2, .token = 102 }, &h); // redundant copy
    try testing.expectEqual(@as(usize, 0), h.nextEncode().acked_tokens.len);
    _ = h.onEncoded(4, 104, false);
    j.onEncoded(4, 104, 0b011);
    j.onAck(1, .{ .frame_id = 2, .token = 102 }, &h);
    try testing.expectEqualSlices(LtrToken, &.{102}, h.nextEncode().acked_tokens);
    _ = h.onEncoded(5, 105, false);
    j.onEncoded(5, 105, 0b011);
    try testing.expectEqual(@as(?FrameId, 2), h.newest_acked);
    // A wrong token and a member the frame did not wait for are stale.
    j.onAck(2, .{ .frame_id = 3, .token = 103 }, &h);
    j.onAck(0, .{ .frame_id = 3, .token = 999 }, &h);
    try testing.expectEqual(@as(u64, 2), j.stats.stale);
    try testing.expectEqual(@as(u64, 1), j.stats.held);
}

test "a member leaving releases what only it held back" {
    var h = Host.init(.{});
    var j: J = .{};
    var id: FrameId = 0;
    while (id < 6) : (id += 1) {
        _ = h.nextEncode();
        _ = h.onEncoded(id, 100 + id, id == 0);
        j.onEncoded(id, 100 + id, 0b101);
    }
    // Member 0 decoded frames 1..4; member 2 is frozen and acked nothing.
    for (1..5) |i| j.onAck(0, .{ .frame_id = @intCast(i), .token = 100 + i }, &h);
    try testing.expectEqual(@as(?FrameId, null), h.newest_acked);
    // A recovery request now must fall back to an IDR: no common reference.
    h.onRecoveryRequest(.{ .first_missing = 6 });
    try testing.expectEqual(@import("../recovery/host.zig").Force.idr, h.nextEncode().force);
    h.onEncodeDropped();
    j.remove(2, 5, &h);
    try testing.expectEqual(@as(?FrameId, 4), h.newest_acked);
    try testing.expectEqual(@import("../recovery/host.zig").Force.ltr_refresh, h.nextEncode().force);
}

test "applyFrameAck through a member view" {
    var h = Host.init(.{});
    var j: J = .{};
    _ = h.nextEncode();
    _ = h.onEncoded(0, 7, true);
    j.onEncoded(0, 7, 0b1);
    const v = j.member(0, &h);
    v.onAckEntry(.{ .frame_id = 0, .token = 7 });
    v.onRecoveryRequest(.{ .first_missing = 1 });
    try testing.expect(h.recoveryPending());
    try testing.expectEqual(@as(?FrameId, 0), h.newest_acked);
}
