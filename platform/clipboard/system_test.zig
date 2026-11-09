//! The system clipboard backend on a real clipboard (`zig build test-clipboard`): a write
//! through one handle is seen, with its change count, through a second one (on Linux a
//! second display connection, so the text crosses between clients). Skips where no system
//! clipboard is reachable (no display, or Linux built without -Dlinux-clipboard).
const std = @import("std");
const clipboard = @import("clipboard");

const gpa = std.testing.allocator;

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

fn sleepMs(ms: u64) void {
    if (@import("builtin").os.tag == .windows) {
        Sleep(@intCast(ms));
    } else {
        var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = std.c.nanosleep(&ts, null);
    }
}

/// Waits up to 3 s for `c` to hold `want`.
fn waitFor(c: clipboard.Clipboard, want: []const u8) !void {
    var last: ?[]u8 = null;
    defer if (last) |l| gpa.free(l);
    for (0..300) |_| {
        if (last) |l| gpa.free(l);
        last = try c.readText(gpa);
        if (last) |t| if (std.mem.eql(u8, t, want)) return;
        sleepMs(10);
    }
    std.debug.print("clipboard holds {?s}, want {s}\n", .{ last, want });
    return error.TestUnexpectedResult;
}

test "write on one handle, read on another, change count moves" {
    var a = clipboard.System.open() orelse return error.SkipZigTest;
    defer a.close();
    var b = clipboard.System.open() orelse return error.SkipZigTest;
    defer b.close();
    const ca = a.clipboard();
    const cb = b.clipboard();

    const c0 = cb.changeCount();
    const t1 = "moonsec clipboard test: ünïcödé ✓ 😀\nsecond line";
    try ca.writeText(t1);
    try waitFor(cb, t1);
    try std.testing.expect(cb.changeCount() != c0);
    try waitFor(ca, t1);

    // The other direction, and a larger text.
    const big = try gpa.alloc(u8, 200_000);
    defer gpa.free(big);
    for (big, 0..) |*x, i| x.* = "abcdefghij\n"[i % 11];
    const c1 = ca.changeCount();
    try cb.writeText(big);
    try waitFor(ca, big);
    try std.testing.expect(ca.changeCount() != c1);
}
