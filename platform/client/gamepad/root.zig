//! Gamepad capture for the client backends, one per OS:
//!   - Windows: XInput (`xinput.Source`)
//!   - macOS: GameController.framework (`gamecontroller.Source`, gc.m)
//!   - Linux: evdev (`evdev.Source`)
//! Each `Source` has `poll(out: []api.InputEvent) api.Error!usize` and emits
//! only `.pad` events, so a client backend can call it from its own
//! `InputSource.poll` after keyboard and mouse, or bind it alone with
//! `api.bind(api.InputSource, ...)`. `pads.zig` holds what they share.

const std = @import("std");
const builtin = @import("builtin");

pub const pads = @import("pads.zig");
pub const xinput = @import("xinput.zig");
pub const evdev = @import("evdev.zig");
pub const gamecontroller = @import("gamecontroller.zig");

/// This OS's gamepad source type.
pub const Native = switch (builtin.os.tag) {
    .windows => xinput.Source,
    .macos => gamecontroller.Source,
    .linux => evdev.Source,
    else => void,
};

test {
    _ = pads;
    _ = xinput;
    _ = evdev;
    _ = gamecontroller;
    if (builtin.os.tag == .linux) _ = @import("uinput_test.zig");
}
