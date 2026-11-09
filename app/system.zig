//! The OS backends behind MOONSEC_BACKEND_SYSTEM (app/abi.zig): one opener per OS for the
//! host (screen capture, encoder, audio, input injection) and the client (decoder,
//! window and presenter, audio, input). Built in with `-Dabi-system` (abi/build.zig),
//! which adds the backend modules as "system_host" and "system_client".
//!
//!   Linux    host: ScreenCast portal + PipeWire, VAAPI / NVENC / libx264, uinput
//!            (platform/host/linux/backend.zig); client: libavcodec, Wayland + EGL,
//!            PipeWire, evdev (platform/client/linux).
//!   Windows  host: Desktop Duplication, NVENC / Media Foundation, WASAPI loopback,
//!            SendInput (platform/host/windows); client: Media Foundation / D3D11VA, a
//!            flip-model swapchain, WASAPI, Raw Input and XInput (platform/client/windows).
//!   macOS    host: ScreenCaptureKit, VideoToolbox, CGEvent (platform/host/macos); client:
//!            VideoToolbox, a Metal window, CoreAudio, GameController
//!            (platform/client/macos). The window is created on the main thread, which
//!            must run its run loop.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("app_options");
const api = @import("platform");

pub const available = options.system_backend;

const host_mod = if (available) @import("system_host") else struct {};
const client_mod = if (available) @import("system_client") else struct {};

pub const HostConfig = struct {
    audio: bool = true,
    input: bool = true,
    /// The host's state directory, if it has one (Linux: the portal's restore token
    /// is kept there, so an unattended host asks the user once).
    state_dir: ?[]const u8 = null,
};

pub const ClientConfig = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "moonsec",
    audio: bool = true,
    /// Read the OS's keyboard, mouse and gamepads.
    input: bool = true,
};

pub const Error = error{ Unsupported, Backend, OutOfMemory };

pub fn openHost(gpa: std.mem.Allocator, cfg: HostConfig) Error!api.HostBackend {
    if (!available) return error.Unsupported;
    switch (builtin.os.tag) {
        .linux => {
            const token = if (cfg.state_dir) |d| host_mod.tokenPath(gpa, d) catch return error.OutOfMemory else null;
            defer if (token) |t| gpa.free(t);
            const h = host_mod.backend.open(gpa, .{
                .capture = .portal,
                .encoder = .auto,
                .audio = cfg.audio,
                .input = cfg.input,
                .token_path = token,
            }) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.NoEncoder, error.Unsupported => error.Unsupported,
                else => error.Backend,
            };
            return h.backend();
        },
        .windows, .macos => return host_mod.openHost(gpa, .{ .audio = cfg.audio, .input = cfg.input }) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unsupported => error.Unsupported,
            else => error.Backend,
        },
        else => return error.Unsupported,
    }
}

/// The host's displays without opening a bundle (no encoder, audio or input device):
/// what `openHost`'s capture would list, with the same ids. Linux has no list before the
/// ScreenCast portal session starts (the user picks the monitors there): `Unsupported`.
pub fn hostDisplays(out: []api.DisplayInfo) Error!usize {
    if (!available) return error.Unsupported;
    const r: api.Error!usize = switch (builtin.os.tag) {
        .windows => host_mod.listDisplays(null, 0, out),
        .macos => host_mod.listDisplays(out),
        else => error.Unsupported,
    };
    return r catch |e| mapErr(e);
}

pub fn openClient(gpa: std.mem.Allocator, cfg: ClientConfig) Error!api.ClientBackend {
    if (!available) return error.Unsupported;
    switch (builtin.os.tag) {
        .linux => {
            const cl = client_mod.open(gpa, .{ .width = cfg.width, .height = cfg.height, .title = cfg.title, .evdev = cfg.input, .gamepads = cfg.input }) catch |e| return mapErr(e);
            var be = cl.backend();
            // The app fails to start when its sink does: check PipeWire now and play
            // nothing when it is not there.
            if (cfg.audio) {
                if (cl.audio.start(.{})) |_| cl.audio.stop() else |_| be.audio = null;
            } else be.audio = null;
            return be;
        },
        .windows => return client_mod.openClient(gpa, .{ .width = cfg.width, .height = cfg.height, .title = cfg.title, .raw_input = cfg.input, .gamepads = cfg.input }) catch |e| mapErr(e),
        .macos => return client_mod.openClient(gpa, .{ .width = cfg.width, .height = cfg.height, .title = cfg.title, .gamepads = cfg.input }) catch |e| mapErr(e),
        else => return error.Unsupported,
    }
}

fn mapErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.Backend,
    };
}
