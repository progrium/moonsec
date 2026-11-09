//! Linux clipboard backend: Wayland data-control (ext-data-control-v1 or
//! wlr-data-control-unstable-v1) when the compositor offers it, otherwise X11 (Xwayland or
//! an X server) with XFixes. Both run a thread of their own (linux_wayland.c, linux_x11.c),
//! so paste requests from other apps are answered at once; this side only reads the cached
//! text and the change count.
//!
//! GNOME (Mutter) offers neither data-control protocol, so there the X11 path through
//! Xwayland is used; that combination is untested.
const std = @import("std");
const root = @import("root.zig");

const msc_clip = opaque {};
extern fn msc_clip_open_wayland() ?*msc_clip;
extern fn msc_clip_open_x11() ?*msc_clip;
extern fn msc_clip_close(c: *msc_clip) void;
extern fn msc_clip_count(c: *msc_clip) u64;
extern fn msc_clip_read(c: *msc_clip, out: *?[*]u8, len: *usize) c_int;
extern fn msc_clip_write(c: *msc_clip, text: [*]const u8, len: usize) c_int;
extern fn msc_clip_free(p: ?[*]u8) void;
extern fn msc_clip_dead(c: *msc_clip) c_int;

pub const Kind = enum { wayland, x11 };

pub const Linux = struct {
    c: *msc_clip,
    kind: Kind,

    /// Wayland first (when WAYLAND_DISPLAY is set), then X11 (DISPLAY). Null when neither works.
    pub fn open(prefer: ?Kind) ?Linux {
        if (prefer != .x11) if (msc_clip_open_wayland()) |c| return .{ .c = c, .kind = .wayland };
        if (prefer != .wayland) if (msc_clip_open_x11()) |c| return .{ .c = c, .kind = .x11 };
        return null;
    }

    pub fn close(self: *Linux) void {
        msc_clip_close(self.c);
    }

    pub fn clipboard(self: *Linux) root.Clipboard {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn dead(self: *const Linux) bool {
        return msc_clip_dead(self.c) != 0;
    }

    fn changeCount(p: *anyopaque) u64 {
        const self: *Linux = @ptrCast(@alignCast(p));
        return msc_clip_count(self.c);
    }

    fn readText(p: *anyopaque, gpa: std.mem.Allocator) root.Error!?[]u8 {
        const self: *Linux = @ptrCast(@alignCast(p));
        var out: ?[*]u8 = null;
        var n: usize = 0;
        const r = msc_clip_read(self.c, &out, &n);
        if (r < 0) return error.OutOfMemory;
        if (r == 0) return null;
        defer msc_clip_free(out);
        return try gpa.dupe(u8, out.?[0..n]);
    }

    fn writeText(p: *anyopaque, text: []const u8) root.Error!void {
        const self: *Linux = @ptrCast(@alignCast(p));
        if (msc_clip_write(self.c, text.ptr, text.len) != 1) return error.Unavailable;
    }

    const vtable = root.Clipboard.VTable{ .changeCount = changeCount, .readText = readText, .writeText = writeText };
};
