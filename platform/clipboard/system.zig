//! The system clipboard for the build target: Win32, NSPasteboard, or (built with
//! `-Dlinux-clipboard`) Wayland data-control / X11. `open` returns null where there is none
//! (no display, or Linux built without the option); callers then fall back to `Memory`.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("clipboard_options");
const root = @import("root.zig");

const os = builtin.os.tag;

const Impl = switch (os) {
    .windows => @import("win32.zig").Win32,
    .macos => @import("macos.zig").Pasteboard,
    .linux => if (options.linux) @import("linux.zig").Linux else void,
    else => void,
};

pub const available = Impl != void;

pub const System = struct {
    impl: Impl,

    pub fn open() ?System {
        if (Impl == void) return null;
        if (os == .linux) {
            const l = Impl.open(null) orelse return null;
            return .{ .impl = l };
        }
        return .{ .impl = .{} };
    }

    pub fn close(s: *System) void {
        if (os == .linux and Impl != void) s.impl.close();
    }

    pub fn clipboard(s: *System) root.Clipboard {
        if (Impl == void) unreachable;
        return s.impl.clipboard();
    }

    /// Which backend (for logs).
    pub fn name(s: *const System) []const u8 {
        return switch (os) {
            .windows => "win32",
            .macos => "nspasteboard",
            .linux => if (Impl != void) @tagName(s.impl.kind) else "none",
            else => "none",
        };
    }
};
