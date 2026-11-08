//! core/media: packetizer, reassembly, NACK/retransmit, Reed-Solomon FEC (fec.zig) and
//! the loss-recovery policy (policy.zig).
//!
//! Host:   Packetizer -> data shards, then parity shards per group (`Packetizer.parity`,
//!         filled from `Policy`) -> `proto.encodeVideoShard` -> transport, each shard
//!         also `History.record`ed; NACK datagram in (`nack.parse`) -> `History.resend`
//!         per seq when the policy says to answer NACKs.
//! Client: transport -> `proto.decode` -> `Receiver.onShard` (rebuilds groups from
//!         parity); `Receiver.poll` -> frames and losses in order; `Receiver.nacks` ->
//!         NACK datagram out on control-fast.
pub const packetizer = @import("packetizer.zig");
pub const reassembly = @import("reassembly.zig");
pub const nack = @import("nack.zig");
pub const retransmit = @import("retransmit.zig");
pub const receiver = @import("receiver.zig");
pub const fec = @import("fec.zig");
pub const policy = @import("policy.zig");

pub const Packetizer = packetizer.Packetizer;
pub const Reassembler = reassembly.Reassembler;
pub const Receiver = receiver.Receiver;
pub const History = retransmit.History;
pub const Shard = packetizer.Shard;
pub const ParityBuffer = packetizer.ParityBuffer;
pub const Policy = policy.Policy;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("sim_test.zig");
}
