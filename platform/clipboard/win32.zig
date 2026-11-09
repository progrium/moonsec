//! Win32 clipboard backend: CF_UNICODETEXT through OpenClipboard/GetClipboardData, change
//! detection with GetClipboardSequenceNumber (a counter Windows bumps on every change, ours
//! included, readable without opening the clipboard).
//!
//! Text crosses as UTF-8 with LF line breaks (spec/control-v0.md): CRLF becomes LF on read
//! and LF becomes CRLF on write. OpenClipboard fails while another process holds the
//! clipboard; that reads as `error.Unavailable` after a few short retries, and the next poll
//! tries again.
const std = @import("std");
const root = @import("root.zig");
const text_mod = @import("text.zig");
const fromWide = text_mod.fromWide;
const toWide = text_mod.toWide;

const BOOL = c_int;
const HANDLE = ?*anyopaque;

const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;

extern "user32" fn OpenClipboard(hwnd: ?*anyopaque) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) HANDLE;
extern "user32" fn SetClipboardData(format: u32, mem: HANDLE) callconv(.winapi) HANDLE;
extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) BOOL;
extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) u32;
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalFree(mem: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalLock(mem: HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(mem: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalSize(mem: HANDLE) callconv(.winapi) usize;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

fn ok(b: BOOL) bool {
    return b != 0;
}

pub const Win32 = struct {
    pub fn clipboard(self: *Win32) root.Clipboard {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn open() root.Error!void {
        for (0..5) |_| {
            if (ok(OpenClipboard(null))) return;
            Sleep(2);
        }
        return error.Unavailable;
    }

    fn changeCount(_: *anyopaque) u64 {
        return GetClipboardSequenceNumber();
    }

    fn readText(_: *anyopaque, gpa: std.mem.Allocator) root.Error!?[]u8 {
        if (!ok(IsClipboardFormatAvailable(CF_UNICODETEXT))) return null;
        try open();
        defer _ = CloseClipboard();
        const h = GetClipboardData(CF_UNICODETEXT) orelse return null;
        const p = GlobalLock(h) orelse return error.Unavailable;
        defer _ = GlobalUnlock(h);
        const units = GlobalSize(h) / 2;
        const wide: [*]const u16 = @ptrCast(@alignCast(p));
        // The text ends at the first NUL (the block may be larger).
        const n = std.mem.indexOfScalar(u16, wide[0..units], 0) orelse units;
        return try fromWide(gpa, wide[0..n]);
    }

    fn writeText(_: *anyopaque, text: []const u8) root.Error!void {
        // Build the UTF-16 copy first, with CRLF line breaks and a terminating NUL.
        var buf: std.ArrayList(u16) = .empty;
        defer buf.deinit(std.heap.page_allocator);
        toWide(std.heap.page_allocator, text, &buf) catch return error.OutOfMemory;
        const bytes = buf.items.len * 2;
        const h = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
        {
            const p = GlobalLock(h) orelse {
                _ = GlobalFree(h);
                return error.OutOfMemory;
            };
            @memcpy(@as([*]u8, @ptrCast(p))[0..bytes], std.mem.sliceAsBytes(buf.items));
            _ = GlobalUnlock(h);
        }
        open() catch |e| {
            _ = GlobalFree(h);
            return e;
        };
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
        // On success the system owns `h`.
        if (SetClipboardData(CF_UNICODETEXT, h) == null) {
            _ = GlobalFree(h);
            return error.Unavailable;
        }
    }

    const vtable = root.Clipboard.VTable{ .changeCount = changeCount, .readText = readText, .writeText = writeText };
};
