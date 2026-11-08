//! core/media: packetizer, reassembly, NACK/retransmit. The FEC codec is fec.zig (item G).
//!
//! Host:   Packetizer -> shards -> `proto.encodeVideoShard` -> transport, each shard also
//!         `History.record`ed; NACK datagram in (`nack.parse`) -> `History.resend` per seq.
//! Client: transport -> `proto.decode` -> `Receiver.onShard`; `Receiver.poll` -> frames and
//!         losses in order; `Receiver.nacks` -> NACK datagram out on control-fast.
pub const packetizer = @import("packetizer.zig");
pub const reassembly = @import("reassembly.zig");
pub const nack = @import("nack.zig");
pub const retransmit = @import("retransmit.zig");
pub const receiver = @import("receiver.zig");

pub const Packetizer = packetizer.Packetizer;
pub const Reassembler = reassembly.Reassembler;
pub const Receiver = receiver.Receiver;
pub const History = retransmit.History;
pub const Shard = packetizer.Shard;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("sim_test.zig");
}
