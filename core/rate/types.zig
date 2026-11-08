//! Shared types for the rate controller.
//!
//! Times are microseconds. Send times are on the host clock and arrival
//! times on the client clock; the two are never compared directly, only
//! one-way-delay differences are used, so the clock offset cancels.
//! Rates are bits per second.

/// What the controller knows about one media packet once feedback covers it:
/// the sender's own record of it joined with the client's arrival report.
pub const PacketResult = struct {
    seq: u64,
    /// Host clock, when the packet left the pacer.
    send_us: i64,
    /// Client clock, or `lost` if feedback reported it missing.
    recv_us: i64,
    size: u32,
    /// Frame the packet belongs to, for the frame-train capacity estimate.
    frame: u32,
    /// Last packet of its frame.
    frame_last: bool,

    pub const lost: i64 = -1;

    pub fn received(r: PacketResult) bool {
        return r.recv_us >= 0;
    }
};

pub const Usage = enum { normal, overuse, underuse };
