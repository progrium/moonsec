//! Clipboard sync state (spec/control-v0.md, "Clipboard"), sans-I/O.
//!
//! One `Clipboard` per endpoint, kept across connections. It decides which local changes
//! go out (`copied`), which received ones the system clipboard should take (`received`),
//! and suppresses echoes: content equal to what the clipboard already holds, whoever
//! copied it, is never sent. Ordering is latest-wins by a Lamport stamp `(clock, origin)`
//! with client > host on ties, so two sides that copy at the same time converge.
//!
//! The text is kept (up to the cap) so a side can re-send its own copy after a reconnect
//! and compare local changes against it.
const std = @import("std");
const frame = @import("frame.zig");

pub const Role = enum(u8) {
    host = 0,
    client = 1,
    _,
};

pub const msg_set: u16 = 0x0100;
pub const Format = enum(u8) {
    text = 1,
    /// Reserved: image/png.
    png = 2,
    /// Reserved: text/html.
    html = 3,
    _,
};
pub const set_header_len = 12;

pub const default_max_text: u32 = 1 << 20;

pub const Stamp = struct {
    clock: u64,
    origin: Role,

    /// `a` is newer than `b`: higher clock, or the same clock and the client's copy.
    pub fn newer(a: Stamp, b: Stamp) bool {
        if (a.clock != b.clock) return a.clock > b.clock;
        return @intFromEnum(a.origin) > @intFromEnum(b.origin);
    }
};

pub const Config = struct {
    /// Send local copies to the peer.
    send: bool = true,
    /// Take the peer's copies (advertise `clipboard_text`).
    receive: bool = true,
    /// Largest text sent or accepted, bytes.
    max_text: u32 = default_max_text,
};

pub const Stats = struct {
    /// Local changes sent / suppressed as echoes or repeats / too large to send.
    sent: u64 = 0,
    echoes: u64 = 0,
    too_large: u64 = 0,
    /// Received copies applied / dropped as stale / dropped as invalid (format, UTF-8,
    /// size, clock 0).
    applied: u64 = 0,
    stale: u64 = 0,
    invalid: u64 = 0,
};

/// A `clip_set` to send.
pub const Set = struct {
    clock: u64,
    text: []const u8,

    /// The frame body (12-byte header + text) into `buf`.
    pub fn encode(s: Set, buf: []u8) error{NoSpace}![]u8 {
        const n = set_header_len + s.text.len;
        if (buf.len < n) return error.NoSpace;
        writeSetHeader(buf[0..set_header_len], s.clock, .text);
        @memcpy(buf[set_header_len..n], s.text);
        return buf[0..n];
    }
};

pub fn writeSetHeader(out: *[set_header_len]u8, clock: u64, format: Format) void {
    std.mem.writeInt(u64, out[0..8], clock, .little);
    out[8] = @intFromEnum(format);
    @memset(out[9..12], 0);
}

pub const ParsedSet = struct { clock: u64, format: Format, data: []const u8 };

pub fn parseSet(body: []const u8) error{Malformed}!ParsedSet {
    if (body.len < set_header_len) return error.Malformed;
    return .{
        .clock = std.mem.readInt(u64, body[0..8], .little),
        .format = @enumFromInt(body[8]),
        .data = body[set_header_len..],
    };
}

pub const Clipboard = struct {
    role: Role,
    cfg: Config,
    /// Lamport clock: the highest clock seen or used.
    lamport: u64 = 0,
    /// Stamp of what the system clipboard holds now; null before anything is known.
    stamp: ?Stamp = null,
    /// That content (valid when `have_text`). A local copy too large to send clears it.
    text: std.ArrayList(u8) = .empty,
    have_text: bool = false,
    stats: Stats = .{},

    pub fn init(role: Role, cfg: Config) Clipboard {
        return .{ .role = role, .cfg = cfg };
    }

    pub fn deinit(c: *Clipboard, gpa: std.mem.Allocator) void {
        c.text.deinit(gpa);
    }

    fn holds(c: *const Clipboard, text: []const u8) bool {
        return c.have_text and std.mem.eql(u8, c.text.items, text);
    }

    fn keep(c: *Clipboard, gpa: std.mem.Allocator, text: []const u8) !void {
        c.text.clearRetainingCapacity();
        try c.text.appendSlice(gpa, text);
        c.have_text = true;
    }

    /// The system clipboard's content when the app starts watching it: remembered, not
    /// sent (connecting must not overwrite the peer's clipboard with whatever was there).
    pub fn seed(c: *Clipboard, gpa: std.mem.Allocator, text: []const u8) !void {
        if (text.len > c.cfg.max_text) return;
        try c.keep(gpa, text);
        c.stamp = .{ .clock = 0, .origin = c.role };
    }

    /// The local system clipboard now holds `text`. Returns the `clip_set` to send, or
    /// null when nothing should go out (an echo of a received copy, a repeat, too large,
    /// not UTF-8, or sending is off). The returned text points into the clipboard and stays
    /// valid until the next call.
    pub fn copied(c: *Clipboard, gpa: std.mem.Allocator, text: []const u8) !?Set {
        if (c.holds(text)) {
            c.stats.echoes += 1;
            return null;
        }
        c.lamport += 1;
        c.stamp = .{ .clock = c.lamport, .origin = c.role };
        if (text.len > c.cfg.max_text or !std.unicode.utf8ValidateSlice(text)) {
            // The peer keeps its old content; ours is newer, so its older copies stay stale.
            c.text.clearRetainingCapacity();
            c.have_text = false;
            c.stats.too_large += 1;
            return null;
        }
        try c.keep(gpa, text);
        if (!c.cfg.send) return null;
        c.stats.sent += 1;
        return .{ .clock = c.lamport, .text = c.text.items };
    }

    /// A `clip_set` from the peer. Returns the text the system clipboard should take (it
    /// points into the clipboard), or null when the copy is stale, invalid, or receiving is
    /// off.
    pub fn received(c: *Clipboard, gpa: std.mem.Allocator, peer: Role, s: ParsedSet) !?[]const u8 {
        if (s.clock == 0 or s.format != .text or s.data.len > c.cfg.max_text or !std.unicode.utf8ValidateSlice(s.data)) {
            c.stats.invalid += 1;
            return null;
        }
        c.lamport = @max(c.lamport, s.clock);
        const st: Stamp = .{ .clock = s.clock, .origin = peer };
        if (!c.cfg.receive) return null;
        if (c.stamp) |cur| if (!st.newer(cur)) {
            c.stats.stale += 1;
            return null;
        };
        c.stamp = st;
        try c.keep(gpa, s.data);
        c.stats.applied += 1;
        return c.text.items;
    }

    /// What to re-send when a new channel comes up: our own copy made since the start, if
    /// we hold it. The peer applies it only if it is newer than what it has.
    pub fn resend(c: *const Clipboard) ?Set {
        const st = c.stamp orelse return null;
        if (!c.cfg.send or st.origin != c.role or st.clock == 0 or !c.have_text) return null;
        return .{ .clock = st.clock, .text = c.text.items };
    }
};

// --- tests ---------------------------------------------------------------------------

const testing = std.testing;
const tgpa = testing.allocator;

fn deliver(to: *Clipboard, from: Role, s: Set) !?[]const u8 {
    var buf: [256]u8 = undefined;
    return to.received(tgpa, from, try parseSet(try s.encode(&buf)));
}

test "a copy on one side reaches the other, and the write is not echoed back" {
    var h = Clipboard.init(.host, .{});
    defer h.deinit(tgpa);
    var c = Clipboard.init(.client, .{});
    defer c.deinit(tgpa);
    try h.seed(tgpa, "host start");
    try c.seed(tgpa, "client start");
    // Re-reading the seeded content is not a copy.
    try testing.expectEqual(@as(?Set, null), try h.copied(tgpa, "host start"));

    const s = (try c.copied(tgpa, "from client")).?;
    try testing.expectEqual(@as(u64, 1), s.clock);
    try testing.expectEqualStrings("from client", (try deliver(&h, .client, s)).?);
    // The host app writes it to the system clipboard, which reports a change: an echo.
    try testing.expectEqual(@as(?Set, null), try h.copied(tgpa, "from client"));
    try testing.expectEqual(@as(u64, 2), h.stats.echoes); // the seed re-read, then the echo

    // Host copies next: its clock passed the client's.
    const s2 = (try h.copied(tgpa, "from host")).?;
    try testing.expectEqual(@as(u64, 2), s2.clock);
    try testing.expectEqualStrings("from host", (try deliver(&c, .host, s2)).?);
    try testing.expectEqual(@as(?Set, null), try c.copied(tgpa, "from host"));
}

test "simultaneous copies converge: higher clock wins, then the client" {
    var h = Clipboard.init(.host, .{});
    defer h.deinit(tgpa);
    var c = Clipboard.init(.client, .{});
    defer c.deinit(tgpa);
    // Same clock on both sides: the client's copy wins everywhere.
    const hs = (try h.copied(tgpa, "H")).?;
    const cs = (try c.copied(tgpa, "C")).?;
    try testing.expectEqualStrings("C", (try deliver(&h, .client, cs)).?);
    try testing.expectEqual(@as(?[]const u8, null), try deliver(&c, .host, hs));
    try testing.expectEqualStrings("C", h.text.items);
    try testing.expectEqualStrings("C", c.text.items);

    // The host copies twice before the client's next copy arrives: the host's later copy
    // has the higher clock and wins on both sides.
    const h1 = (try h.copied(tgpa, "H1")).?;
    _ = h1;
    const h2 = (try h.copied(tgpa, "H2")).?;
    const h2c = h2.clock;
    const c2 = (try c.copied(tgpa, "C2")).?;
    try testing.expect(h2c > c2.clock);
    try testing.expectEqual(@as(?[]const u8, null), try deliver(&h, .client, c2));
    var buf: [64]u8 = undefined;
    const h2_body = try (Set{ .clock = h2c, .text = "H2" }).encode(&buf);
    try testing.expectEqualStrings("H2", (try c.received(tgpa, .host, try parseSet(h2_body))).?);
    try testing.expectEqualStrings("H2", h.text.items);
    try testing.expectEqualStrings("H2", c.text.items);
    try testing.expectEqual(@as(u64, 1), h.stats.stale);
}

test "caps, invalid input and policy" {
    var c = Clipboard.init(.client, .{ .max_text = 4 });
    defer c.deinit(tgpa);
    try testing.expectEqual(@as(?Set, null), try c.copied(tgpa, "too long"));
    try testing.expectEqual(@as(u64, 1), c.stats.too_large);
    // A later small copy still goes out with the next clock.
    try testing.expectEqual(@as(u64, 2), (try c.copied(tgpa, "ok")).?.clock);
    // Invalid UTF-8, unknown format, clock 0 and oversize are dropped.
    try testing.expectEqual(@as(?[]const u8, null), try c.received(tgpa, .host, .{ .clock = 9, .format = .text, .data = "\xff" }));
    try testing.expectEqual(@as(?[]const u8, null), try c.received(tgpa, .host, .{ .clock = 9, .format = .png, .data = "x" }));
    try testing.expectEqual(@as(?[]const u8, null), try c.received(tgpa, .host, .{ .clock = 0, .format = .text, .data = "x" }));
    try testing.expectEqual(@as(?[]const u8, null), try c.received(tgpa, .host, .{ .clock = 9, .format = .text, .data = "12345" }));
    try testing.expectEqual(@as(u64, 4), c.stats.invalid);
    try testing.expectError(error.Malformed, parseSet("short"));

    var quiet = Clipboard.init(.host, .{ .send = false, .receive = false });
    defer quiet.deinit(tgpa);
    try testing.expectEqual(@as(?Set, null), try quiet.copied(tgpa, "x"));
    try testing.expectEqual(@as(?[]const u8, null), try quiet.received(tgpa, .client, .{ .clock = 5, .format = .text, .data = "y" }));
    // The clock still advances, so its next copies order after what it has seen.
    try testing.expectEqual(@as(u64, 5), quiet.lamport);
}

test "resend after a reconnect carries the original stamp" {
    var c = Clipboard.init(.client, .{});
    defer c.deinit(tgpa);
    try testing.expectEqual(@as(?Set, null), c.resend());
    try c.seed(tgpa, "seed");
    try testing.expectEqual(@as(?Set, null), c.resend());
    _ = (try c.copied(tgpa, "offline copy")).?;
    const r = c.resend().?;
    try testing.expectEqual(@as(u64, 1), r.clock);
    try testing.expectEqualStrings("offline copy", r.text);
    // A copy from the peer replaces ours: nothing of ours to re-send.
    _ = (try c.received(tgpa, .host, .{ .clock = 3, .format = .text, .data = "peer" })).?;
    try testing.expectEqual(@as(?Set, null), c.resend());
}
