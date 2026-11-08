//! core/rate: the host's rate controller.
//!
//! `Controller` is S11's `gcc-hybrid`: libwebrtc's delay-based GCC (with
//! burst grouping) on our own one-way delays, plus the frame-train capacity
//! estimate and the standing-queue drain. See `controller.zig` for the three
//! rates it produces and docs/design.md "Rate control" for why.

pub const types = @import("types.zig");
pub const PacketResult = types.PacketResult;
pub const Usage = types.Usage;

pub const AckedRate = @import("acked.zig").AckedRate;
pub const OwdTracker = @import("owd.zig").OwdTracker;
pub const TrainCap = @import("train.zig").TrainCap;
pub const gcc = @import("gcc.zig");
pub const Gcc = gcc.Gcc;
pub const history = @import("history.zig");
pub const SendHistory = history.SendHistory;
pub const Arrival = history.Arrival;

const controller = @import("controller.zig");
pub const Controller = controller.Controller;
pub const Config = controller.Config;
pub const Telemetry = controller.Telemetry;

test {
    _ = @import("acked.zig");
    _ = @import("owd.zig");
    _ = @import("train.zig");
    _ = @import("gcc.zig");
    _ = @import("history.zig");
    _ = @import("controller.zig");
    _ = @import("loop_test.zig");
}
