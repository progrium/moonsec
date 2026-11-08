//! Virtual displays for a headless host (docs/design.md, Phase 5: "headless host works").
//!
//! A host with no monitor attached has nothing to capture. The Windows backend then adds
//! a display through its IddCx driver (platform/windows/idd), the macOS backend through
//! CGVirtualDisplay (platform/host/macos/vdisplay.m), at the client's size, and captures
//! it like any other display. This file holds the part every backend shares: when to
//! create one, at which mode, and what to do when creation fails. It is pure Zig and
//! tested with the platform interface (`zig build test`).
//!
//! Lifecycle, for every backend:
//!   - `Capture.start` creates the display (or changes its mode when it exists already),
//!     then captures it. `Capture.stop` removes it.
//!   - A host that dies without `stop` must not leave a display behind: Windows' driver
//!     removes displays whose owner stopped pinging, and the software device that hosts
//!     them goes away with the process; macOS removes a CGVirtualDisplay when its owning
//!     process exits.
//!   - When creation fails the backend falls back to the physical display, if there is
//!     one, and logs why. With no physical display either, `start` fails.
const std = @import("std");

pub const Policy = enum(u8) {
    /// Capture the physical display `CaptureConfig.display`.
    off,
    /// Create a virtual display only when the host has no physical display attached.
    when_headless,
    /// Always stream a virtual display of its own (sized to the client); the physical
    /// displays stay as they are.
    always,
};

pub const Mode = struct {
    width: u32,
    height: u32,
    refresh_hz: u32,

    pub fn eql(a: Mode, b: Mode) bool {
        return a.width == b.width and a.height == b.height and a.refresh_hz == b.refresh_hz;
    }
};

/// The mode when the client gave no size.
pub const default_mode: Mode = .{ .width = 1920, .height = 1080, .refresh_hz = 60 };
pub const min_width = 640;
pub const min_height = 360;
pub const max_width = 7680;
pub const max_height = 4320;
pub const min_refresh_hz = 24;
pub const max_refresh_hz = 240;

/// The mode to create for a capture request: the client's size (0 = default), rounded
/// down to even numbers (4:2:0 encoders want them) and clamped to what both drivers
/// advertise; the frame rate clamped the same way.
pub fn modeFor(width: u32, height: u32, fps: u32) Mode {
    const w = if (width == 0) default_mode.width else width;
    const h = if (height == 0) default_mode.height else height;
    const hz = if (fps == 0) default_mode.refresh_hz else fps;
    return .{
        .width = std.math.clamp(w, min_width, max_width) & ~@as(u32, 1),
        .height = std.math.clamp(h, min_height, max_height) & ~@as(u32, 1),
        .refresh_hz = std.math.clamp(hz, min_refresh_hz, max_refresh_hz),
    };
}

/// Whether to try creating a virtual display, given how many physical displays the host
/// has attached right now.
pub fn shouldCreate(policy: Policy, physical_displays: u32) bool {
    return switch (policy) {
        .off => false,
        .when_headless => physical_displays == 0,
        .always => true,
    };
}

pub const Fallback = enum {
    /// Capture physical display `CaptureConfig.display` instead.
    physical,
    /// Nothing to capture: fail `start`.
    fail,
};

/// What to do when creating (or capturing) the virtual display failed.
pub fn onCreateFailed(physical_displays: u32) Fallback {
    return if (physical_displays > 0) .physical else .fail;
}

/// What a backend's capture is streaming, for logs and tests.
pub const Source = enum { physical, virtual };

test "modeFor: client size, defaults, rounding and clamps" {
    try std.testing.expectEqual(default_mode, modeFor(0, 0, 0));
    try std.testing.expectEqual(Mode{ .width = 2560, .height = 1440, .refresh_hz = 120 }, modeFor(2560, 1440, 120));
    try std.testing.expectEqual(Mode{ .width = 1366, .height = 768, .refresh_hz = 60 }, modeFor(1367, 769, 60));
    try std.testing.expectEqual(Mode{ .width = min_width, .height = min_height, .refresh_hz = min_refresh_hz }, modeFor(100, 100, 5));
    try std.testing.expectEqual(Mode{ .width = max_width, .height = max_height, .refresh_hz = max_refresh_hz }, modeFor(10000, 10000, 1000));
    try std.testing.expectEqual(Mode{ .width = 1920, .height = 1200, .refresh_hz = 60 }, modeFor(1920, 1200, 0));
}

test "shouldCreate and onCreateFailed" {
    try std.testing.expect(!shouldCreate(.off, 0));
    try std.testing.expect(shouldCreate(.when_headless, 0));
    try std.testing.expect(!shouldCreate(.when_headless, 1));
    try std.testing.expect(shouldCreate(.always, 2));
    try std.testing.expectEqual(Fallback.fail, onCreateFailed(0));
    try std.testing.expectEqual(Fallback.physical, onCreateFailed(1));
}
