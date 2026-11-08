//! moonsec core: the pure, sans-I/O Zig core. It takes packets, frames and timestamps in
//! and returns packets, encoder settings and present decisions out; it never touches
//! sockets, clocks or threads, so it runs unchanged on every target, wasm32 included.
//!
//! Modules land here as they are built (design doc, "Architecture"): proto, media, rate,
//! recovery, pacing, input, clock.

const std = @import("std");

/// Wire protocol v0 (spec/wire-v0.md).
pub const proto = @import("proto/root.zig");

/// Packetizer, reassembly, NACK/retransmit (and the FEC codec).
pub const media = @import("media/root.zig");

/// Loss recovery: LTR acks, freeze on gap, LTR refresh or IDR (docs/design.md, "Loss recovery").
pub const recovery = @import("recovery/root.zig");

/// Input events with redundancy, motion totals and gamepad snapshots.
pub const input = @import("input/root.zig");

/// Host/client clock offset and skew from round trips.
pub const clock = @import("clock/root.zig");

/// Per-frame stage timing and rolling stats for the latency overlay.
pub const telemetry = @import("telemetry/root.zig");

test {
    std.testing.refAllDecls(@This());
}
