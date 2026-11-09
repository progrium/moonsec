//! Multi-user control-channel messages (spec/multi-user-v0.md), block 0x0300-0x03ff of the
//! control channel's registry, feature bit 16. Encode and parse only; the state is in
//! `roster.zig`.
const std = @import("std");

/// Message types (spec/control-v0.md, "Type registry": 0x0300-0x03ff).
pub const roster: u16 = 0x0300;
pub const input_request: u16 = 0x0301;
pub const input_give: u16 = 0x0302;

/// Feature bit in the control channel's `hello` (block 16-23).
pub const feature_bit: u64 = 1 << 16;

/// Member id 0: the host's own user (nobody remote).
pub const host_id: u16 = 0;
pub const max_name = 64;
/// Members a roster message can list (input masks are u32).
pub const max_members = 32;

pub const Policy = enum(u8) {
    /// One member's input applies at a time; the owner hands it on (the default).
    owner = 0,
    /// Every member allowed to control has its input applied.
    everyone = 1,
    /// No remote input; only the host's own user types.
    view_only = 2,
    _,
};

pub const EntryFlags = packed struct(u8) {
    /// The host lets this member hold input (the allowlist's say).
    may_control: bool = false,
    /// The member asked for input and has not got it yet.
    requesting: bool = false,
    /// The member's path goes through a relay.
    relayed: bool = false,
    _reserved: u5 = 0,
};

pub const Entry = struct {
    id: u16,
    flags: EntryFlags,
    name: []const u8,
};

pub const header_len = 12;
pub const entry_header_len = 4;

pub const Header = struct {
    /// Bumped on every change; a receiver keeps the newest.
    epoch: u32,
    /// The receiver's own member id.
    you: u16,
    /// Who holds input under `owner` policy (`host_id`: the host's user / nobody remote).
    owner: u16,
    policy: Policy,
    count: u8,
};

pub const Error = error{Malformed};

/// Largest roster body: header plus `max_members` entries with full names.
pub const max_roster_len = header_len + max_members * (entry_header_len + max_name);

pub fn writeHeader(out: *[header_len]u8, h: Header) void {
    std.mem.writeInt(u32, out[0..4], h.epoch, .little);
    std.mem.writeInt(u16, out[4..6], h.you, .little);
    std.mem.writeInt(u16, out[6..8], h.owner, .little);
    out[8] = @intFromEnum(h.policy);
    out[9] = h.count;
    out[10] = 0;
    out[11] = 0;
}

/// Appends one entry at `out[0..]`; returns the bytes written.
pub fn writeEntry(out: []u8, e: Entry) usize {
    const n = @min(e.name.len, max_name);
    std.debug.assert(out.len >= entry_header_len + n);
    std.mem.writeInt(u16, out[0..2], e.id, .little);
    out[2] = @bitCast(e.flags);
    out[3] = @intCast(n);
    @memcpy(out[4..][0..n], e.name[0..n]);
    return entry_header_len + n;
}

pub const RosterIterator = struct {
    rest: []const u8,
    left: u8,

    pub fn next(it: *RosterIterator) Error!?Entry {
        if (it.left == 0) return null;
        if (it.rest.len < entry_header_len) return error.Malformed;
        const n = it.rest[3];
        if (n > max_name or it.rest.len < entry_header_len + n) return error.Malformed;
        const e: Entry = .{
            .id = std.mem.readInt(u16, it.rest[0..2], .little),
            .flags = @bitCast(it.rest[2] & 0b111), // reserved bits ignored on receive
            .name = it.rest[4..][0..n],
        };
        it.rest = it.rest[entry_header_len + n ..];
        it.left -= 1;
        return e;
    }
};

pub fn parseRoster(body: []const u8) Error!struct { header: Header, entries: RosterIterator } {
    if (body.len < header_len) return error.Malformed;
    const h: Header = .{
        .epoch = std.mem.readInt(u32, body[0..4], .little),
        .you = std.mem.readInt(u16, body[4..6], .little),
        .owner = std.mem.readInt(u16, body[6..8], .little),
        .policy = @enumFromInt(body[8]),
        .count = body[9],
    };
    if (h.count > max_members) return error.Malformed;
    return .{ .header = h, .entries = .{ .rest = body[header_len..], .left = h.count } };
}

/// `input_request`: 1 = I want input, 0 = withdraw the request.
pub fn encodeRequest(want: bool) [1]u8 {
    return .{@intFromBool(want)};
}

pub fn parseRequest(body: []const u8) Error!bool {
    if (body.len < 1) return error.Malformed;
    return body[0] & 1 != 0;
}

/// `input_give`: the owner hands input to `to` (`host_id`: back to the host's user).
pub fn encodeGive(to: u16) [4]u8 {
    var b: [4]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], to, .little);
    return b;
}

pub fn parseGive(body: []const u8) Error!u16 {
    if (body.len < 2) return error.Malformed;
    return std.mem.readInt(u16, body[0..2], .little);
}

const testing = std.testing;

test "roster round trip, short and oversized bodies" {
    var buf: [max_roster_len]u8 = undefined;
    writeHeader(buf[0..header_len], .{ .epoch = 7, .you = 2, .owner = 1, .policy = .owner, .count = 2 });
    var n: usize = header_len;
    n += writeEntry(buf[n..], .{ .id = 1, .flags = .{ .may_control = true }, .name = "Alice" });
    n += writeEntry(buf[n..], .{ .id = 2, .flags = .{ .requesting = true, .relayed = true }, .name = "Bob" });
    const r = try parseRoster(buf[0..n]);
    try testing.expectEqual(@as(u32, 7), r.header.epoch);
    try testing.expectEqual(@as(u16, 2), r.header.you);
    try testing.expectEqual(Policy.owner, r.header.policy);
    var it = r.entries;
    const a = (try it.next()).?;
    try testing.expectEqualStrings("Alice", a.name);
    try testing.expect(a.flags.may_control);
    const b = (try it.next()).?;
    try testing.expect(b.flags.requesting and b.flags.relayed and !b.flags.may_control);
    try testing.expectEqual(@as(?Entry, null), try it.next());

    // Truncated entry, count over the cap, short header.
    var it2 = (try parseRoster(buf[0 .. n - 1])).entries;
    _ = try it2.next();
    try testing.expectError(error.Malformed, it2.next());
    buf[9] = max_members + 1;
    try testing.expectError(error.Malformed, parseRoster(buf[0..n]));
    try testing.expectError(error.Malformed, parseRoster(buf[0..5]));
    try testing.expectEqual(true, try parseRequest(&encodeRequest(true)));
    try testing.expectEqual(@as(u16, 3), try parseGive(&encodeGive(3)));
    try testing.expectError(error.Malformed, parseGive(&.{1}));
}

test "random roster bodies never crash" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var buf: [256]u8 = undefined;
    for (0..2000) |_| {
        const len = r.uintLessThan(usize, buf.len);
        r.bytes(buf[0..len]);
        if (len > 9) buf[9] %= 6;
        const p = parseRoster(buf[0..len]) catch continue;
        var it = p.entries;
        while (it.next() catch null) |_| {}
    }
}
