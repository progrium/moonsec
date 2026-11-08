//! Values that cross between host and client recovery. The wire encoding lives in `core/proto`;
//! these are the decoded forms the state machines consume and produce.

const std = @import("std");

/// Sequence number of an encoded (sent) frame. Consecutive over every frame the encoder
/// emitted, so a hole on the client is a lost frame. Wraps; compare with `after`/`atOrAfter`.
pub const FrameId = u32;

/// Encoder long-term reference token. On VideoToolbox this is the frame's
/// `RequireLTRAcknowledgementToken` sample attachment; it travels in our video header
/// (`ltr_token`, u64 on the wire) because it is not in the bitstream.
pub const LtrToken = u64;

/// True when `a` comes after `b` in wrapping order.
pub fn after(a: FrameId, b: FrameId) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

pub fn atOrAfter(a: FrameId, b: FrameId) bool {
    return a == b or after(a, b);
}

/// What the client needs from a frame's video header to run recovery.
pub const FrameMeta = struct {
    frame_id: FrameId,
    /// IDR: decodable with no prior state.
    keyframe: bool = false,
    /// Recovery frame that references only long-term references the client acked.
    refresh: bool = false,
    /// Present when the encoder marked this frame as a long-term reference.
    ltr_token: ?LtrToken = null,

    pub fn isRecoveryPoint(m: FrameMeta) bool {
        return m.keyframe or m.refresh;
    }
};

/// Header flags the host stamps on an encoded frame (see `Host.onEncoded`).
pub const FrameFlags = struct {
    keyframe: bool = false,
    refresh: bool = false,
};

/// One decoded long-term reference, reported by the client.
pub const AckEntry = struct {
    frame_id: FrameId,
    token: LtrToken,
};

/// The client froze at `first_missing` and drops every frame until a recovery point newer
/// than it arrives.
pub const RecoveryRequest = struct {
    first_missing: FrameId,
    /// Ask for an IDR rather than an LTR refresh: no keyframe yet, or a refresh failed to decode.
    want_idr: bool = false,
};

/// Frame ack (client to host, control-fast stream; `proto.FrameAck` on the wire). Carries the
/// client's most recent decoded long-term references, repeated so a lost ack costs nothing,
/// and the recovery request while the client is frozen.
pub const Ack = struct {
    pub const max_entries = 16;

    entries: [max_entries]AckEntry = undefined,
    len: u8 = 0,
    recovery: ?RecoveryRequest = null,

    pub fn slice(a: *const Ack) []const AckEntry {
        return a.entries[0..a.len];
    }
};

test "wrapping order" {
    try std.testing.expect(after(1, 0));
    try std.testing.expect(!after(0, 0));
    try std.testing.expect(after(0, std.math.maxInt(u32)));
    try std.testing.expect(!after(std.math.maxInt(u32), 0));
    try std.testing.expect(atOrAfter(5, 5));
}
