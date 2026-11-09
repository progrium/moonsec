//! The reliable control channel (spec/control-v0.md): framing on one bidirectional QUIC
//! stream, the message type registry, the `hello` handshake and clipboard sync.
//! Sans-I/O; builds for wasm32 (the web client uses it too).
const std = @import("std");

pub const frame = @import("frame.zig");
pub const clipboard = @import("clipboard.zig");
pub const channel = @import("channel.zig");

pub const Frame = frame.Frame;
pub const Decoder = frame.Decoder;
pub const Channel = channel.Channel;
pub const Config = channel.Config;
pub const Event = channel.Event;
pub const Hello = channel.Hello;
pub const Known = channel.Known;
pub const CloseReason = channel.CloseReason;
pub const Clipboard = clipboard.Clipboard;
pub const Role = clipboard.Role;
pub const msg = channel.msg;
pub const feature = channel.feature;

test {
    std.testing.refAllDecls(@This());
}
