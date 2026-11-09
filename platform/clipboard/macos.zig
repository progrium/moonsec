//! NSPasteboard backend (pasteboard.m): the general pasteboard's string type, with
//! `changeCount` for change detection (it moves on our own writes too; the control channel's
//! echo check drops those). Text is UTF-8 with LF line breaks already.
const std = @import("std");
const root = @import("root.zig");

extern fn msc_pb_change_count() c_long;
extern fn msc_pb_read_text(out: *?[*]u8, len: *usize) c_int;
extern fn msc_pb_write_text(text: [*]const u8, len: usize) c_int;
extern fn msc_pb_free(p: ?[*]u8) void;

pub const Pasteboard = struct {
    pub fn clipboard(self: *Pasteboard) root.Clipboard {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn changeCount(_: *anyopaque) u64 {
        return @bitCast(@as(i64, msc_pb_change_count()));
    }

    fn readText(_: *anyopaque, gpa: std.mem.Allocator) root.Error!?[]u8 {
        var p: ?[*]u8 = null;
        var n: usize = 0;
        const r = msc_pb_read_text(&p, &n);
        if (r < 0) return error.OutOfMemory;
        if (r == 0) return null;
        defer msc_pb_free(p);
        return try gpa.dupe(u8, p.?[0..n]);
    }

    fn writeText(_: *anyopaque, text: []const u8) root.Error!void {
        if (msc_pb_write_text(text.ptr, text.len) != 1) return error.Unavailable;
    }

    const vtable = root.Clipboard.VTable{ .changeCount = changeCount, .readText = readText, .writeText = writeText };
};
