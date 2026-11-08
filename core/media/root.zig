//! core/media: packetizer, reassembly, NACK/retransmit. The FEC codec is fec.zig (item G).
//!
//! Host:   Packetizer -> packets -> transport, each also `History.record`ed;
//!         NACK message in -> `History.resend` for each seq -> transport.
//! Client: transport -> `Receiver.onPacket`; `Receiver.poll` -> frames/losses in order;
//!         `Receiver.nacks` -> NACK message out on control-fast.
pub const header = @import("header.zig");
pub const packetizer = @import("packetizer.zig");
pub const reassembly = @import("reassembly.zig");
pub const nack = @import("nack.zig");
pub const retransmit = @import("retransmit.zig");
pub const receiver = @import("receiver.zig");

pub const Packetizer = packetizer.Packetizer;
pub const Reassembler = reassembly.Reassembler;
pub const Receiver = receiver.Receiver;
pub const History = retransmit.History;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("sim_test.zig");
}
