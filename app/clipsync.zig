//! Moves text between the system clipboard (platform/clipboard) and the session's control
//! channel: polls the backend's change count, reads the text when it moved, and writes what
//! the peer copied. The first read is the starting content and is not sent.
const std = @import("std");
const clipboard = @import("clipboard");
const Control = @import("control.zig").Control;

const Micros = i64;

pub const Stats = struct { reads: u64 = 0, writes: u64 = 0, errors: u64 = 0 };

pub const Sync = struct {
    cb: clipboard.Clipboard,
    interval_us: Micros = 250_000,
    next_poll: ?Micros = null,
    last_count: ?u64 = null,
    seeded: bool = false,
    stats: Stats = .{},

    pub fn pump(y: *Sync, gpa: std.mem.Allocator, ctl: *Control, now: Micros) void {
        if (ctl.takeClipboard()) |t| {
            y.cb.writeText(t) catch {
                y.stats.errors += 1;
            };
            y.stats.writes += 1;
        }
        if (y.next_poll) |n| if (now < n) return;
        y.next_poll = now + y.interval_us;
        const cnt = y.cb.changeCount();
        if (y.last_count) |l| if (l == cnt) return;
        y.last_count = cnt;
        const text = y.cb.readText(gpa) catch {
            y.stats.errors += 1;
            return;
        };
        const first = !y.seeded;
        y.seeded = true;
        const t = text orelse return;
        defer gpa.free(t);
        y.stats.reads += 1;
        (if (first) ctl.seedClipboard(t) else ctl.clipboardChanged(t)) catch {
            y.stats.errors += 1;
        };
    }
};
