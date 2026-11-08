//! Who is in a multi-user session and whose input applies (spec/multi-user-v0.md).
//!
//! `Roster` is the host's authoritative state: members join (admitted by the host's
//! allowlist, which also says whether they may control) and leave; under the `owner` policy
//! one member holds input at a time and hands it on, or the host's own user takes it back.
//! Every change bumps `epoch`; the host then sends each member the roster (`encodeFor`).
//! `View` is a client's copy, parsed from the roster messages, for the overlay and the
//! input UI. Sans-I/O, no allocation.
const std = @import("std");
const msg = @import("msg.zig");

pub const Policy = msg.Policy;
pub const host_id = msg.host_id;
pub const max_name = msg.max_name;

pub const Config = struct {
    policy: Policy = .owner,
    /// At most `msg.max_members`.
    max_members: u8 = 8,
    /// Under `owner`, when nobody remote holds input (start, or the owner left), the next
    /// member that may control gets it without asking. Off: it stays with the host's user
    /// until someone requests it.
    auto_owner: bool = true,
};

pub const Member = struct {
    id: u16,
    may_control: bool,
    requesting: bool = false,
    relayed: bool = false,
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(m: *const Member) []const u8 {
        return m.name_buf[0..m.name_len];
    }
};

pub const GiveResult = enum { ok, not_owner, unknown_member, not_allowed, wrong_policy };

pub const Stats = struct {
    joins: u64 = 0,
    leaves: u64 = 0,
    handoffs: u64 = 0,
    refused: u64 = 0,
};

pub const Roster = struct {
    cfg: Config,
    members: [msg.max_members]Member = undefined,
    len: u8 = 0,
    owner: u16 = host_id,
    epoch: u32 = 0,
    next_id: u16 = 1,
    stats: Stats = .{},

    pub fn init(cfg: Config) Roster {
        std.debug.assert(cfg.max_members <= msg.max_members);
        return .{ .cfg = cfg };
    }

    pub fn slice(r: *const Roster) []const Member {
        return r.members[0..r.len];
    }

    pub fn find(r: *Roster, id: u16) ?*Member {
        for (r.members[0..r.len]) |*m| if (m.id == id) return m;
        return null;
    }

    fn changed(r: *Roster) void {
        r.epoch +%= 1;
    }

    /// A member the host admitted. Returns its id, or null when the session is full.
    pub fn join(r: *Roster, name: []const u8, may_control: bool) ?u16 {
        if (r.len >= r.cfg.max_members) {
            r.stats.refused += 1;
            return null;
        }
        var id = r.next_id;
        while (id == host_id or r.find(id) != null) id +%= 1;
        r.next_id = id +% 1;
        var m: Member = .{ .id = id, .may_control = may_control };
        const n: u8 = @intCast(@min(name.len, max_name));
        @memcpy(m.name_buf[0..n], name[0..n]);
        m.name_len = n;
        r.members[r.len] = m;
        r.len += 1;
        r.stats.joins += 1;
        r.changed();
        r.autoOwner();
        return id;
    }

    pub fn leave(r: *Roster, id: u16) void {
        for (r.members[0..r.len], 0..) |m, i| if (m.id == id) {
            std.mem.copyForwards(Member, r.members[i .. r.len - 1], r.members[i + 1 .. r.len]);
            r.len -= 1;
            r.stats.leaves += 1;
            if (r.owner == id) {
                r.owner = host_id;
                // A waiting requester first, else (auto_owner) the oldest member that may control.
                for (r.members[0..r.len]) |*o| if (o.requesting and o.may_control) {
                    r.setOwner(o.id);
                    break;
                };
                r.autoOwner();
            }
            r.changed();
            return;
        };
    }

    fn autoOwner(r: *Roster) void {
        if (r.cfg.policy != .owner or !r.cfg.auto_owner or r.owner != host_id) return;
        for (r.members[0..r.len]) |m| if (m.may_control) {
            r.setOwner(m.id);
            return;
        };
    }

    fn setOwner(r: *Roster, id: u16) void {
        if (r.owner == id) return;
        r.owner = id;
        if (r.find(id)) |m| m.requesting = false;
        r.stats.handoffs += 1;
        r.changed();
    }

    /// `input_request` from a member. Granted at once when nobody remote holds input.
    pub fn request(r: *Roster, id: u16, want: bool) void {
        const m = r.find(id) orelse return;
        if (r.cfg.policy != .owner or !m.may_control or r.owner == id) return;
        if (want and r.owner == host_id and r.cfg.auto_owner) return r.setOwner(id);
        if (m.requesting != want) {
            m.requesting = want;
            r.changed();
        }
    }

    /// `input_give` from member `from`: only the owner may hand input on.
    pub fn give(r: *Roster, from: u16, to: u16) GiveResult {
        if (r.cfg.policy != .owner) return .wrong_policy;
        if (r.owner != from or from == host_id) return .not_owner;
        return r.hostGive(to);
    }

    /// The host's own user hands input to `to` (`host_id`: takes it back). Always allowed.
    pub fn hostGive(r: *Roster, to: u16) GiveResult {
        if (r.cfg.policy != .owner) return .wrong_policy;
        if (to != host_id) {
            const m = r.find(to) orelse return .unknown_member;
            if (!m.may_control) return .not_allowed;
        }
        r.setOwner(to);
        return .ok;
    }

    pub fn setRelayed(r: *Roster, id: u16, relayed: bool) void {
        const m = r.find(id) orelse return;
        if (m.relayed == relayed) return;
        m.relayed = relayed;
        r.changed();
    }

    pub fn setPolicy(r: *Roster, p: Policy) void {
        if (r.cfg.policy == p) return;
        r.cfg.policy = p;
        r.owner = host_id;
        for (r.members[0..r.len]) |*m| m.requesting = false;
        r.changed();
        r.autoOwner();
    }

    /// Whether member `id`'s input is applied now.
    pub fn mayInput(r: *const Roster, id: u16) bool {
        return switch (r.cfg.policy) {
            .owner => id != host_id and r.owner == id,
            .everyone => for (r.members[0..r.len]) |m| {
                if (m.id == id) break m.may_control;
            } else false,
            else => false,
        };
    }

    /// The roster message body for member `you`.
    pub fn encodeFor(r: *const Roster, you: u16, out: *[msg.max_roster_len]u8) []const u8 {
        msg.writeHeader(out[0..msg.header_len], .{ .epoch = r.epoch, .you = you, .owner = r.owner, .policy = r.cfg.policy, .count = r.len });
        var n: usize = msg.header_len;
        for (r.members[0..r.len]) |*m| n += msg.writeEntry(out[n..], .{
            .id = m.id,
            .flags = .{ .may_control = m.may_control, .requesting = m.requesting, .relayed = m.relayed },
            .name = m.name(),
        });
        return out[0..n];
    }
};

/// A client's copy of the roster.
pub const View = struct {
    have: bool = false,
    epoch: u32 = 0,
    you: u16 = host_id,
    owner: u16 = host_id,
    policy: Policy = .owner,
    members: [msg.max_members]Member = undefined,
    len: u8 = 0,
    stats: struct { rosters: u64 = 0, stale: u64 = 0, malformed: u64 = 0 } = .{},

    /// A roster message from the host. Older epochs (reordered across reconnects) are ignored.
    pub fn onRoster(v: *View, body: []const u8) void {
        const p = msg.parseRoster(body) catch {
            v.stats.malformed += 1;
            return;
        };
        if (v.have and @as(i32, @bitCast(p.header.epoch -% v.epoch)) < 0) {
            v.stats.stale += 1;
            return;
        }
        var tmp: [msg.max_members]Member = undefined;
        var n: u8 = 0;
        var it = p.entries;
        while (it.next() catch {
            v.stats.malformed += 1;
            return;
        }) |e| {
            var m: Member = .{ .id = e.id, .may_control = e.flags.may_control, .requesting = e.flags.requesting, .relayed = e.flags.relayed };
            @memcpy(m.name_buf[0..e.name.len], e.name);
            m.name_len = @intCast(e.name.len);
            tmp[n] = m;
            n += 1;
        }
        @memcpy(v.members[0..n], tmp[0..n]);
        v.len = n;
        v.have = true;
        v.epoch = p.header.epoch;
        v.you = p.header.you;
        v.owner = p.header.owner;
        v.policy = p.header.policy;
        v.stats.rosters += 1;
    }

    pub fn slice(v: *const View) []const Member {
        return v.members[0..v.len];
    }

    pub fn find(v: *const View, id: u16) ?*const Member {
        for (v.members[0..v.len]) |*m| if (m.id == id) return m;
        return null;
    }

    /// Whether this client's input is applied (as of the last roster).
    pub fn haveInput(v: *const View) bool {
        if (!v.have) return false;
        return switch (v.policy) {
            .owner => v.owner == v.you,
            .everyone => if (v.find(v.you)) |m| m.may_control else false,
            else => false,
        };
    }

    /// One overlay line: "3 here · input: Alice (you)" / "· view only". Cut to `buf`.
    pub fn presence(v: *const View, buf: []u8) []const u8 {
        if (!v.have) return "";
        var w = std.Io.Writer.fixed(buf);
        w.print("{d} here", .{v.len}) catch return w.buffered();
        switch (v.policy) {
            .owner => {
                const who: []const u8 = if (v.owner == host_id) "host" else if (v.find(v.owner)) |m| m.name() else "?";
                w.print(" \u{b7} input: {s}{s}", .{ who, if (v.owner == v.you) " (you)" else "" }) catch {};
            },
            .everyone => w.writeAll(" \u{b7} input: everyone") catch {},
            else => w.writeAll(" \u{b7} view only") catch {},
        }
        return w.buffered();
    }
};

const testing = std.testing;

test "first member that may control owns input; handoff, leave and requests" {
    var r = Roster.init(.{});
    const viewer = r.join("Viewer", false).?;
    try testing.expectEqual(host_id, r.owner);
    const a = r.join("Alice", true).?;
    const b = r.join("Bob", true).?;
    try testing.expectEqual(a, r.owner);
    try testing.expect(r.mayInput(a) and !r.mayInput(b) and !r.mayInput(viewer));

    // Only the owner gives; not to a view-only member.
    try testing.expectEqual(GiveResult.not_owner, r.give(b, b));
    try testing.expectEqual(GiveResult.not_allowed, r.give(a, viewer));
    r.request(b, true);
    try testing.expect(r.find(b).?.requesting);
    const e = r.epoch;
    try testing.expectEqual(GiveResult.ok, r.give(a, b));
    try testing.expect(r.epoch != e);
    try testing.expect(r.mayInput(b) and !r.mayInput(a));
    try testing.expect(!r.find(b).?.requesting);

    // The host takes it back, then gives it to Alice; Bob asks again and Alice leaves.
    try testing.expectEqual(GiveResult.ok, r.hostGive(host_id));
    try testing.expect(!r.mayInput(b));
    _ = r.hostGive(a);
    r.request(b, true);
    r.leave(a);
    try testing.expectEqual(b, r.owner);
    r.leave(b);
    try testing.expectEqual(host_id, r.owner);
    try testing.expectEqual(@as(u8, 1), r.len);
}

test "auto_owner off: input stays with the host until requested" {
    var r = Roster.init(.{ .auto_owner = false });
    const a = r.join("A", true).?;
    try testing.expectEqual(host_id, r.owner);
    r.request(a, true);
    try testing.expect(r.find(a).?.requesting);
    try testing.expectEqual(GiveResult.ok, r.hostGive(a));
    try testing.expect(r.mayInput(a));
}

test "everyone and view_only policies; full roster refuses" {
    var r = Roster.init(.{ .policy = .everyone, .max_members = 2 });
    const a = r.join("A", true).?;
    const v = r.join("V", false).?;
    try testing.expectEqual(@as(?u16, null), r.join("C", true));
    try testing.expect(r.mayInput(a) and !r.mayInput(v));
    try testing.expectEqual(GiveResult.wrong_policy, r.give(a, v));
    r.setPolicy(.view_only);
    try testing.expect(!r.mayInput(a));
    r.setPolicy(.owner);
    try testing.expect(r.mayInput(a));
}

test "the client view follows the roster and ignores stale epochs" {
    var r = Roster.init(.{});
    const a = r.join("Alice", true).?;
    const b = r.join("Bob", true).?;
    var buf: [msg.max_roster_len]u8 = undefined;
    var vb: View = .{};
    vb.onRoster(r.encodeFor(b, &buf));
    try testing.expect(!vb.haveInput());
    var pb: [64]u8 = undefined;
    try testing.expectEqualStrings("2 here \u{b7} input: Alice", vb.presence(&pb));
    var old: [msg.max_roster_len]u8 = undefined;
    const old_body = old[0..r.encodeFor(b, &old).len];
    _ = r.give(a, b);
    vb.onRoster(r.encodeFor(b, &buf));
    try testing.expect(vb.haveInput());
    try testing.expectEqualStrings("2 here \u{b7} input: Bob (you)", vb.presence(&pb));
    vb.onRoster(old_body);
    try testing.expectEqual(@as(u64, 1), vb.stats.stale);
    try testing.expect(vb.haveInput());
}
