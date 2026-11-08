//! Pairing (spec/pairing-v0.md): device identity, tickets, PINs, the paired-device list,
//! the pairing exchange and a QR encoder for showing tickets. Sans-I/O like the rest of the
//! core: callers pass in random bytes, clocks and stream bytes.

const std = @import("std");

pub const id = @import("id.zig");
pub const ticket = @import("ticket.zig");
pub const pin = @import("pin.zig");
pub const allowlist = @import("allowlist.zig");
pub const exchange = @import("exchange.zig");
pub const qr = @import("qr.zig");

pub const Id = id.Id;
pub const Ticket = ticket.Ticket;
pub const Allowlist = allowlist.Allowlist;
pub const Window = exchange.Window;

test {
    std.testing.refAllDecls(@This());
}
