//! Lossless tiles (stage 3 of the sharp-text design; spec/refine-v0.md): exact pixels of
//! still 64x64 cells, QOI-coded, sent on the refine stream in spare bandwidth and drawn by
//! the client on a layer over the video until the video changes there.
//!
//!   qoi     the tile codec
//!   wire    tile pieces, frame damage, tile acks
//!   host    `Engine` (one per encode: damage, picker, tile cache) and `Peer` (per client)
//!   client  `Layer`: reassembly, the validity rule, and the ops a presenter applies
//!
//! Sans-I/O; builds for wasm32 (the web client runs `client` in the core's wasm build).
const std = @import("std");

pub const qoi = @import("qoi.zig");
pub const wire = @import("wire.zig");
pub const host = @import("host.zig");
pub const client = @import("client.zig");

pub const Engine = host.Engine;
pub const Peer = host.Peer;
pub const Layer = client.Layer;

test {
    std.testing.refAllDecls(@This());
}
