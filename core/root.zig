//! moonsec core: the pure, sans-I/O Zig core. It takes packets, frames and timestamps in
//! and returns packets, encoder settings and present decisions out; it never touches
//! sockets, clocks or threads, so it runs unchanged on every target, wasm32 included.
//!
//! Modules land here as they are built (design doc, "Architecture"): proto, media, rate,
//! recovery, pacing, input, clock.

const std = @import("std");

/// Wire protocol v0 (spec/wire-v0.md).
pub const proto = @import("proto/root.zig");

/// Loss recovery: LTR acks, freeze on gap, LTR refresh or IDR (docs/design.md, "Loss recovery").
pub const recovery = @import("recovery/root.zig");

/// Rate controller: S11's gcc-hybrid (target, encoder and pacing rates).
pub const rate = @import("rate/root.zig");

test {
    std.testing.refAllDecls(@This());
}
