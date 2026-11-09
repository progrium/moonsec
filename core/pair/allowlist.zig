//! The list of paired devices (spec/pairing-v0.md, "Allowlist").
//!
//! On a host it is the allowlist: the client IDs allowed to start a session. On a client the
//! same list holds the hosts it has paired with, with the address to dial each one.
//! Persisted as text, one device per line:
//!
//!     <64 hex id> TAB <paired unix seconds> TAB <name> [TAB <address>] [TAB perms=<list>]
//!
//! `perms=` (host side) says what a client may do beyond watching: `input`, `clipboard`,
//! comma-separated, or `view` for neither. A line without it has every permission (lists
//! written before permissions existed).
//!
//! Lines starting with `#` and blank lines are ignored. Names are sanitized on the way in
//! (no control characters, at most `max_name` bytes), so a name can never break a line.
const std = @import("std");
const id_mod = @import("id.zig");

pub const Id = id_mod.Id;
pub const max_name = 64;
pub const max_addr = 1024;
pub const header = "# moonsec paired devices v0: id, paired (unix s), name, address, perms=\n";

/// What a paired client may do in a session besides watching and listening.
pub const Perms = packed struct(u8) {
    /// Keyboard, mouse and gamepad input is applied on the host.
    input: bool = true,
    /// The clipboard syncs both ways (when the session syncs it at all).
    clipboard: bool = true,
    _pad: u6 = 0,

    pub const full: Perms = .{};
    pub const view: Perms = .{ .input = false, .clipboard = false };

    pub fn eql(a: Perms, b: Perms) bool {
        return a.input == b.input and a.clipboard == b.clipboard;
    }

    /// `view`, `full`, or a comma-separated list of `input` and `clipboard`.
    pub fn parse(text: []const u8) ?Perms {
        if (std.mem.eql(u8, text, "view")) return view;
        if (std.mem.eql(u8, text, "full")) return full;
        var p: Perms = view;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |w| {
            if (std.mem.eql(u8, w, "input")) p.input = true else if (std.mem.eql(u8, w, "clipboard")) p.clipboard = true else return null;
        }
        return p;
    }

    pub fn format(p: Perms, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!p.input and !p.clipboard) return w.writeAll("view");
        if (p.input) try w.writeAll("input");
        if (p.input and p.clipboard) try w.writeByte(',');
        if (p.clipboard) try w.writeAll("clipboard");
    }
};

const perms_tag = "perms=";

pub const Entry = struct {
    id: Id,
    paired_unix_s: u64,
    name: []const u8,
    /// Where to dial the device (client side: the host's address); empty if unknown.
    addr: []const u8 = "",
    perms: Perms = .full,
};

/// Writes `name` into `buf` with control characters and tabs replaced by '?', cut to
/// `max_name` bytes at a UTF-8 boundary. Invalid UTF-8 becomes '?' too.
pub fn sanitizeName(name: []const u8, buf: *[max_name]u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const cl: usize = std.unicode.utf8ByteSequenceLength(name[i]) catch 0;
        const ok_seq = cl > 0 and i + cl <= name.len and (cl == 1 or std.unicode.utf8ValidateSlice(name[i .. i + cl]));
        const take: usize = if (ok_seq) cl else 1;
        if (n + take > max_name) break;
        if (!ok_seq or (take == 1 and (name[i] < 0x20 or name[i] == 0x7f))) {
            buf[n] = '?';
            n += 1;
        } else {
            @memcpy(buf[n..][0..take], name[i .. i + take]);
            n += take;
        }
        i += take;
    }
    return std.mem.trim(u8, buf[0..n], " ");
}

pub const Allowlist = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Allowlist {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Allowlist) void {
        for (self.entries.items) |e| self.freeEntry(e);
        self.entries.deinit(self.gpa);
    }

    fn freeEntry(self: *Allowlist, e: Entry) void {
        self.gpa.free(e.name);
        self.gpa.free(e.addr);
    }

    pub fn len(self: *const Allowlist) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const Allowlist, id: *const Id) ?*const Entry {
        for (self.entries.items) |*e| if (std.mem.eql(u8, &e.id, id)) return e;
        return null;
    }

    pub fn contains(self: *const Allowlist, id: *const Id) bool {
        return self.get(id) != null;
    }

    /// Adds a device, or replaces the name, address and time of one already listed.
    pub fn put(self: *Allowlist, e: Entry) !void {
        var nb: [max_name]u8 = undefined;
        const name = try self.gpa.dupe(u8, sanitizeName(e.name, &nb));
        errdefer self.gpa.free(name);
        if (e.addr.len > max_addr or !cleanField(e.addr)) return error.BadAddress;
        const addr = try self.gpa.dupe(u8, e.addr);
        errdefer self.gpa.free(addr);
        if (std.mem.startsWith(u8, addr, perms_tag)) return error.BadAddress;
        const owned: Entry = .{ .id = e.id, .paired_unix_s = e.paired_unix_s, .name = name, .addr = addr, .perms = e.perms };
        for (self.entries.items) |*old| if (std.mem.eql(u8, &old.id, &e.id)) {
            self.freeEntry(old.*);
            old.* = owned;
            return;
        };
        try self.entries.append(self.gpa, owned);
    }

    /// The device's permissions; null if it is not listed.
    pub fn perms(self: *const Allowlist, id: *const Id) ?Perms {
        return if (self.get(id)) |e| e.perms else null;
    }

    /// Sets the permissions of every device whose hex ID starts with `prefix` (at least 4
    /// digits), if exactly one matches. Returns the number that matched.
    pub fn setPermsPrefix(self: *Allowlist, prefix: []const u8, p: Perms) usize {
        const i = self.findPrefix(prefix) orelse return self.countPrefix(prefix);
        self.entries.items[i].perms = p;
        return 1;
    }

    fn countPrefix(self: *const Allowlist, prefix: []const u8) usize {
        if (prefix.len < 4 or prefix.len > id_mod.hex_len) return 0;
        var n: usize = 0;
        for (self.entries.items) |e| {
            const h = id_mod.toHex(&e.id);
            if (std.ascii.startsWithIgnoreCase(&h, prefix)) n += 1;
        }
        return n;
    }

    fn findPrefix(self: *const Allowlist, prefix: []const u8) ?usize {
        if (self.countPrefix(prefix) != 1) return null;
        for (self.entries.items, 0..) |e, i| {
            const h = id_mod.toHex(&e.id);
            if (std.ascii.startsWithIgnoreCase(&h, prefix)) return i;
        }
        return null;
    }

    pub fn remove(self: *Allowlist, id: *const Id) bool {
        for (self.entries.items, 0..) |e, i| if (std.mem.eql(u8, &e.id, id)) {
            self.freeEntry(e);
            _ = self.entries.orderedRemove(i);
            return true;
        };
        return false;
    }

    /// Removes every device whose hex ID starts with `prefix` (at least 4 digits), if
    /// exactly one matches. Returns the number that matched.
    pub fn removePrefix(self: *Allowlist, prefix: []const u8) usize {
        if (prefix.len < 4 or prefix.len > id_mod.hex_len) return 0;
        var found: ?usize = null;
        var n: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            const h = id_mod.toHex(&e.id);
            if (std.ascii.startsWithIgnoreCase(&h, prefix)) {
                found = i;
                n += 1;
            }
        }
        if (n == 1) {
            self.freeEntry(self.entries.items[found.?]);
            _ = self.entries.orderedRemove(found.?);
        }
        return n;
    }

    pub fn write(self: *const Allowlist, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(header);
        for (self.entries.items) |e| {
            try w.print("{s}\t{d}\t{s}", .{ &id_mod.toHex(&e.id), e.paired_unix_s, e.name });
            if (e.addr.len > 0) try w.print("\t{s}", .{e.addr});
            if (!e.perms.eql(.full)) try w.print("\t" ++ perms_tag ++ "{f}", .{e.perms});
            try w.writeByte('\n');
        }
    }

    pub const ParseError = error{ BadLine, OutOfMemory, BadAddress };

    /// Parses the text form. On a bad line, `bad_line` (if given) gets its 1-based number.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8, bad_line: ?*usize) ParseError!Allowlist {
        var list: Allowlist = .init(gpa);
        errdefer list.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        var ln: usize = 0;
        while (lines.next()) |raw| {
            ln += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            errdefer if (bad_line) |p| {
                p.* = ln;
            };
            var f = std.mem.splitScalar(u8, line, '\t');
            const id = id_mod.parseHex(f.next() orelse return error.BadLine) orelse return error.BadLine;
            const t = std.fmt.parseInt(u64, f.next() orelse return error.BadLine, 10) catch return error.BadLine;
            const name = f.next() orelse return error.BadLine;
            var addr: []const u8 = "";
            var p: Perms = .full;
            var seen_perms = false;
            while (f.next()) |field| {
                if (std.mem.startsWith(u8, field, perms_tag)) {
                    if (seen_perms) return error.BadLine;
                    p = Perms.parse(field[perms_tag.len..]) orelse return error.BadLine;
                    seen_perms = true;
                } else {
                    if (addr.len > 0 or seen_perms) return error.BadLine;
                    addr = field;
                }
            }
            try list.put(.{ .id = id, .paired_unix_s = t, .name = name, .addr = addr, .perms = p });
        }
        return list;
    }
};

fn cleanField(s: []const u8) bool {
    for (s) |c| if (c < 0x21 or c == 0x7f) return false;
    return true;
}

const testing = std.testing;

fn testId(seed: u8) Id {
    return [_]u8{seed} ** 32;
}

test "put, replace, get, remove" {
    var l: Allowlist = .init(testing.allocator);
    defer l.deinit();
    try l.put(.{ .id = testId(1), .paired_unix_s = 10, .name = "laptop" });
    try l.put(.{ .id = testId(2), .paired_unix_s = 11, .name = "phone", .addr = "endpointabc" });
    try testing.expect(l.contains(&testId(1)));
    try testing.expect(!l.contains(&testId(3)));
    try l.put(.{ .id = testId(1), .paired_unix_s = 20, .name = "new name" });
    try testing.expectEqual(@as(usize, 2), l.len());
    try testing.expectEqualStrings("new name", l.get(&testId(1)).?.name);
    try testing.expectEqual(@as(u64, 20), l.get(&testId(1)).?.paired_unix_s);
    try testing.expect(l.remove(&testId(1)));
    try testing.expect(!l.remove(&testId(1)));
    try testing.expectEqual(@as(usize, 1), l.len());
    try testing.expectError(error.BadAddress, l.put(.{ .id = testId(5), .paired_unix_s = 0, .name = "x", .addr = "has space" }));
}

test "remove by unique hex prefix" {
    var l: Allowlist = .init(testing.allocator);
    defer l.deinit();
    try l.put(.{ .id = testId(0xab), .paired_unix_s = 1, .name = "a" });
    try l.put(.{ .id = testId(0xac), .paired_unix_s = 1, .name = "b" });
    try testing.expectEqual(@as(usize, 0), l.removePrefix("ab")); // too short
    try testing.expectEqual(@as(usize, 2), l.removePrefix("abab") + l.removePrefix("ACAC"));
    try testing.expectEqual(@as(usize, 0), l.len());
}

test "names are sanitized: control bytes, tabs, newlines, length, bad UTF-8" {
    var b: [max_name]u8 = undefined;
    try testing.expectEqualStrings("a?b?c", sanitizeName("a\tb\nc", &b));
    try testing.expectEqualStrings("caf\xc3\xa9", sanitizeName("caf\xc3\xa9", &b));
    try testing.expectEqualStrings("?x", sanitizeName("\xffx", &b));
    const long = "0123456789" ** 7;
    try testing.expectEqual(@as(usize, max_name), sanitizeName(long, &b).len);
    // A multi-byte character that would straddle the limit is dropped whole.
    const edge = "x" ** 63 ++ "\xc3\xa9";
    try testing.expectEqual(@as(usize, 63), sanitizeName(edge, &b).len);
}

test "text round trip, comments, bad lines" {
    var l: Allowlist = .init(testing.allocator);
    defer l.deinit();
    try l.put(.{ .id = testId(1), .paired_unix_s = 1_700_000_000, .name = "Jeff's laptop" });
    try l.put(.{ .id = testId(2), .paired_unix_s = 5, .name = "tab\there", .addr = "endpointqqq" });
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l.write(&w);
    const text = w.buffered();
    try testing.expect(std.mem.startsWith(u8, text, header));

    var back = try Allowlist.parse(testing.allocator, text, null);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.len());
    try testing.expectEqualStrings("Jeff's laptop", back.get(&testId(1)).?.name);
    try testing.expectEqualStrings("tab?here", back.get(&testId(2)).?.name);
    try testing.expectEqualStrings("endpointqqq", back.get(&testId(2)).?.addr);

    var line: usize = 0;
    try testing.expectError(error.BadLine, Allowlist.parse(testing.allocator, "# c\n\nzz\t1\tx\n", &line));
    try testing.expectEqual(@as(usize, 3), line);
    try testing.expectError(error.BadLine, Allowlist.parse(testing.allocator, &id_mod.toHex(&testId(1)) ++ "\tx\tname\n", null));
    try testing.expectError(error.BadLine, Allowlist.parse(testing.allocator, &id_mod.toHex(&testId(1)) ++ "\t1\tn\ta\textra\n", null));
    try testing.expectError(error.BadLine, Allowlist.parse(testing.allocator, &id_mod.toHex(&testId(1)) ++ "\t1\tn\tperms=root\n", null));
    try testing.expectError(error.BadLine, Allowlist.parse(testing.allocator, &id_mod.toHex(&testId(1)) ++ "\t1\tn\tperms=view\tperms=view\n", null));
    var empty = try Allowlist.parse(testing.allocator, "", null);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.len());
}

test "permissions: default full, round trip, old lines, set by prefix" {
    var l: Allowlist = .init(testing.allocator);
    defer l.deinit();
    try l.put(.{ .id = testId(1), .paired_unix_s = 1, .name = "tv", .perms = .view });
    try l.put(.{ .id = testId(2), .paired_unix_s = 1, .name = "laptop" });
    try l.put(.{ .id = testId(3), .paired_unix_s = 1, .name = "tablet", .addr = "endpointx", .perms = .{ .clipboard = false } });
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l.write(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\tperms=view\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\tendpointx\tperms=input\n") != null);
    var back = try Allowlist.parse(testing.allocator, w.buffered(), null);
    defer back.deinit();
    try testing.expect(back.perms(&testId(1)).?.eql(.view));
    try testing.expect(back.perms(&testId(2)).?.eql(.full));
    try testing.expect(back.perms(&testId(3)).?.eql(.{ .clipboard = false }));
    try testing.expectEqual(@as(?Perms, null), back.perms(&testId(9)));
    // A line from before permissions has all of them.
    var old = try Allowlist.parse(testing.allocator, &id_mod.toHex(&testId(4)) ++ "\t1\told\n", null);
    defer old.deinit();
    try testing.expect(old.perms(&testId(4)).?.eql(.full));
    try testing.expectEqual(@as(usize, 1), back.setPermsPrefix("0101", .full));
    try testing.expect(back.perms(&testId(1)).?.eql(.full));
    try testing.expectEqual(@as(usize, 0), back.setPermsPrefix("ffff", .view));
    try testing.expect(Perms.parse("clipboard,input").?.eql(.full));
    try testing.expectEqual(@as(?Perms, null), Perms.parse(""));
    try testing.expectError(error.BadAddress, l.put(.{ .id = testId(5), .paired_unix_s = 0, .name = "x", .addr = "perms=view" }));
}
