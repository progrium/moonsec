//! System clipboard backends for clipboard sync (spec/control-v0.md, "Clipboard").
//!
//! The app polls `changeCount` from its network stage (a few times a second) and reads the
//! text only when the count moved; it writes what the peer copied with `writeText`. Every
//! call is short and non-blocking in the common case; a backend that has to wait on another
//! process (X11 selection transfers) bounds the wait.
//!
//! Backends: `Memory` (tests, sim, headless hosts), Win32 (`win32.zig`), NSPasteboard
//! (`macos.zig` + `pasteboard.m`), Wayland data-control with an X11 fallback (`linux.zig`).
//! `System` picks the one for the build target.
const std = @import("std");

pub const System = @import("system.zig").System;
pub const system_available = @import("system.zig").available;

pub const Error = error{
    /// The clipboard is busy (another process holds it) or the call failed; try later.
    Unavailable,
    OutOfMemory,
};

pub const Clipboard = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Dispatch pending events (backends that learn about changes from events); may be
        /// a no-op. Returns the current change count: it differs from the last value
        /// whenever the clipboard may have changed (it may also move for writes of our own).
        changeCount: *const fn (ptr: *anyopaque) u64,
        /// The clipboard's text as UTF-8, or null when it holds no text. Caller frees.
        readText: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) Error!?[]u8,
        /// Puts UTF-8 text on the clipboard (we become its owner).
        writeText: *const fn (ptr: *anyopaque, text: []const u8) Error!void,
    };

    pub fn changeCount(c: Clipboard) u64 {
        return c.vtable.changeCount(c.ptr);
    }
    pub fn readText(c: Clipboard, gpa: std.mem.Allocator) Error!?[]u8 {
        return c.vtable.readText(c.ptr, gpa);
    }
    pub fn writeText(c: Clipboard, text: []const u8) Error!void {
        return c.vtable.writeText(c.ptr, text);
    }
};

/// An in-memory clipboard: what the sim and tests use, and the fallback where no system
/// clipboard is reachable. `set` models the user copying.
pub const Memory = struct {
    gpa: std.mem.Allocator,
    text: ?[]u8 = null,
    count: u64 = 0,
    writes: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Memory {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Memory) void {
        if (m.text) |t| m.gpa.free(t);
        m.text = null;
    }

    pub fn clipboard(m: *Memory) Clipboard {
        return .{ .ptr = m, .vtable = &vtable };
    }

    /// The user copied `text`.
    pub fn set(m: *Memory, text: []const u8) !void {
        const copy = try m.gpa.dupe(u8, text);
        if (m.text) |t| m.gpa.free(t);
        m.text = copy;
        m.count += 1;
    }

    pub fn get(m: *const Memory) ?[]const u8 {
        return m.text;
    }

    fn changeCount(p: *anyopaque) u64 {
        const m: *Memory = @ptrCast(@alignCast(p));
        return m.count;
    }
    fn readText(p: *anyopaque, gpa: std.mem.Allocator) Error!?[]u8 {
        const m: *Memory = @ptrCast(@alignCast(p));
        const t = m.text orelse return null;
        return try gpa.dupe(u8, t);
    }
    fn writeText(p: *anyopaque, text: []const u8) Error!void {
        const m: *Memory = @ptrCast(@alignCast(p));
        m.set(text) catch return error.OutOfMemory;
        m.writes += 1;
    }
    const vtable = Clipboard.VTable{ .changeCount = changeCount, .readText = readText, .writeText = writeText };
};

test "memory clipboard" {
    const gpa = std.testing.allocator;
    var m = Memory.init(gpa);
    defer m.deinit();
    const c = m.clipboard();
    try std.testing.expectEqual(@as(?[]u8, null), try c.readText(gpa));
    const c0 = c.changeCount();
    try c.writeText("hi");
    try std.testing.expect(c.changeCount() != c0);
    const t = (try c.readText(gpa)).?;
    defer gpa.free(t);
    try std.testing.expectEqualStrings("hi", t);
}

test {
    _ = @import("text.zig");
}
