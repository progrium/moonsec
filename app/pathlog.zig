//! A short log of what the pipe's path did during a session (stalls, path changes,
//! reconnects), printed with the session report: the timeline of a lab run.
const std = @import("std");

const Micros = i64;

pub const Kind = enum { stall, resume_, path, reconnect, redial };

pub const Entry = struct { t: Micros, kind: Kind, relayed: bool };

pub const Log = struct {
    entries: [cap]Entry = undefined,
    n: usize = 0,
    dropped: u64 = 0,
    start: ?Micros = null,

    const cap = 64;

    pub fn add(l: *Log, t: Micros, kind: Kind, relayed: bool) void {
        if (l.n == cap) {
            l.dropped += 1;
            return;
        }
        l.entries[l.n] = .{ .t = t, .kind = kind, .relayed = relayed };
        l.n += 1;
    }

    pub fn print(l: *const Log, w: *std.Io.Writer, who: []const u8) !void {
        if (l.n == 0) return;
        const t0 = l.start orelse l.entries[0].t;
        try w.print("  {s} path log:", .{who});
        for (l.entries[0..l.n]) |e| {
            const name = switch (e.kind) {
                .stall => "stall",
                .resume_ => "resume",
                .path => if (e.relayed) "relay" else "direct",
                .reconnect => "reconnected",
                .redial => "redial",
            };
            try w.print(" {d:.2}s {s}", .{ @as(f64, @floatFromInt(e.t - t0)) / 1e6, name });
        }
        if (l.dropped > 0) try w.print(" (+{d} more)", .{l.dropped});
        try w.writeAll("\n");
    }
};
