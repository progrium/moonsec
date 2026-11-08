//! Loss recovery: long-term reference (LTR) bookkeeping and acks on the host, freeze-on-gap
//! and recovery requests on the client, LTR refresh first and IDR as the fallback.
//!
//! Flow (docs/design.md, "Loss recovery"):
//!   - The client acks the LTR token of every frame it decodes (`Ack`, the wire's frame ack,
//!     repeating recent entries for redundancy). The host hands newly acked tokens to the
//!     encoder with the next frame.
//!   - When a frame is lost (a hole in frame IDs, reassembly giving up, or a decode error) the
//!     client freezes: it drops every frame until a recovery point newer than the gap. Its next
//!     ack carries a `RecoveryRequest`, repeated if nothing arrives within RTT + 2 frames. The
//!     host treats repeats inside its retry window (about one RTT) as copies in flight.
//!   - The host answers with an LTR refresh against the newest acked reference
//!     (`ForceLTRRefresh` on VideoToolbox). It sends an IDR instead when the backend has no LTR,
//!     nothing is acked yet, the acked reference is too old, the client asked for one, or LTR
//!     refreshes for the same gap already failed `max_ltr_attempts` times.

pub const types = @import("types.zig");
pub const host = @import("host.zig");
pub const client = @import("client.zig");

pub const FrameId = types.FrameId;
pub const LtrToken = types.LtrToken;
pub const FrameMeta = types.FrameMeta;
pub const FrameFlags = types.FrameFlags;
pub const Ack = types.Ack;
pub const AckEntry = types.AckEntry;
pub const RecoveryRequest = types.RecoveryRequest;

/// Host recovery with 512 frames of history (8.5 s at 60 fps); acks older than that are ignored.
pub const Host = host.Host(512);
pub const Client = client.Client;

test {
    _ = types;
    _ = host;
    _ = client;
    _ = @import("sim_test.zig");
}
