//! Multi-user sessions (spec/multi-user-v0.md): several clients watching one host, one
//! encode fanned out to all of them.
//!
//! - `roster`: who is in the session and whose input applies (the input policy), and the
//!   client's copy of it for the overlay.
//! - `msg`: the control-channel messages (types 0x0300-0x03ff, feature bit 16).
//! - `acks`: LTR acks intersected across clients, so a refresh references a frame every
//!   client has.
//! - `rate`: the shared encoder's bitrate from the clients' estimates.
//!
//! Sans-I/O; builds for wasm32 (a web client is a member like any other).
const std = @import("std");

pub const msg = @import("msg.zig");
pub const roster = @import("roster.zig");
pub const acks = @import("acks.zig");
pub const rate = @import("rate.zig");

pub const Roster = roster.Roster;
pub const View = roster.View;
pub const Policy = msg.Policy;
pub const host_id = msg.host_id;
pub const max_members = msg.max_members;
pub const feature_bit = msg.feature_bit;
/// Same history as `recovery.Host` (512 frames).
pub const AckJoin = acks.AckJoin(512);

/// Control-channel types this feature handles (for `control.Config.known`).
pub const known = [_]@import("../control/root.zig").Known{
    .{ .type = msg.roster },
    .{ .type = msg.input_request },
    .{ .type = msg.input_give },
};

test {
    std.testing.refAllDecls(@This());
}
