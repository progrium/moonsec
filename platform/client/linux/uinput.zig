//! A virtual keyboard and mouse through /dev/uinput, for tests and the end-to-end run:
//! it types keys into evdev the way a real keyboard does, so the client's evdev source
//! is exercised from the kernel up. Needs write access to /dev/uinput.
//!
//! The uinput plumbing and the key table are shared with the Linux host's injector
//! (platform/linux/uinput.zig, "linux_uinput").
const std = @import("std");
const shared = @import("linux_uinput");

pub const Error = shared.Error;
pub const keyCode = shared.keyCode;
pub const sleepMs = shared.sleepMs;

pub const Device = struct {
    dev: shared.Device,
    /// /dev/input/eventN of the new device.
    node: u8,

    /// Creates a keyboard (every KEY_* up to KEY_MICMUTE) with a mouse (REL_X/Y, wheels,
    /// five buttons), then waits up to 3 s for its event node to be openable (udev may
    /// still be setting its permissions).
    pub fn create(name: []const u8) Error!Device {
        const d = try shared.Device.create(.{
            .name = name,
            .key_range = shared.max_keyboard_key,
            .keys = &.{ shared.BTN_LEFT, shared.BTN_RIGHT, shared.BTN_MIDDLE, shared.BTN_SIDE, shared.BTN_EXTRA },
            .rels = &.{ shared.REL_X, shared.REL_Y, shared.REL_WHEEL, shared.REL_HWHEEL },
            .wait_readable = true,
        });
        return .{ .dev = d, .node = d.node.? };
    }

    /// A gamepad: the face buttons, shoulders, start/select and two sticks
    /// (ABS_X/Y, ABS_RX/RY at -32768..32767), as the kernel gamepad spec lays them out.
    pub fn createPad(name: []const u8) Error!Device {
        const d = try shared.Device.create(.{
            .name = name,
            .keys = &pad_keys,
            .abs = &.{
                .{ .code = shared.ABS_X, .min = -32768, .max = 32767 },
                .{ .code = shared.ABS_Y, .min = -32768, .max = 32767 },
                .{ .code = shared.ABS_RX, .min = -32768, .max = 32767 },
                .{ .code = shared.ABS_RY, .min = -32768, .max = 32767 },
            },
            .wait_readable = true,
        });
        return .{ .dev = d, .node = d.node.? };
    }

    /// BTN_SOUTH .. BTN_THUMBR (0x130..0x13e).
    const pad_keys = blk: {
        var k: [0x13e - shared.BTN_SOUTH + 1]u16 = undefined;
        for (&k, 0..) |*c, i| c.* = shared.BTN_SOUTH + i;
        break :blk k;
    };

    /// A key (KEY_* code) press or release, as its own report.
    pub fn key(d: Device, code: u16, down: bool) void {
        d.dev.key(code, down);
    }

    /// Relative motion, as its own report.
    pub fn move(d: Device, dx: i32, dy: i32) void {
        d.dev.move(dx, dy);
    }

    pub fn destroy(d: Device) void {
        d.dev.destroy();
    }
};

test "keyCode inverts hidUsage for the letters" {
    for (0..26) |i| {
        const usage: u16 = @intCast(4 + i);
        try std.testing.expectEqual(usage, shared.hidUsage(keyCode(usage)));
    }
}
