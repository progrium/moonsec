//! core/audio: the audio stream (design doc, "Audio"; wire format in spec/audio-v0.md).
//!
//! Host:   capture -> codec (codec/opus) -> `Sender.frame` -> transport, then
//!         `Sender.parity` for the light Reed-Solomon parity every k frames.
//! Client: transport -> `proto.decode` -> `Receiver.onMessage`; the audio stage calls
//!         `Receiver.pull` per device frame and runs the action on its decoder.
//!
//! Codec-agnostic and allocation-free; the codec binding lives outside the core
//! because it links libopus (C, libc), and the core stays pure Zig.
const std = @import("std");

pub const wire = @import("wire.zig");
pub const sender = @import("sender.zig");
pub const receiver = @import("receiver.zig");

pub const Kind = wire.Kind;
pub const FrameHeader = wire.FrameHeader;
pub const Frame = wire.Frame;
pub const Sender = sender.Sender;
pub const Receiver = receiver.Receiver;
pub const Action = receiver.Action;

test {
    std.testing.refAllDecls(@This());
}
