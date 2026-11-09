//! core/pair: ticket text, PIN and ID text, names, the paired-device list file, the
//! pairing exchange (both ends) and its framing, and session admission.
const std = @import("std");
const core = @import("core");
const c = @import("common.zig");

const pair = core.pair;
const ticket = pair.ticket;
const ex = pair.exchange;

/// Ticket text (scanned from a QR code or pasted). A ticket that decodes re-encodes to the
/// same text, upper-cased and without whitespace: there is one canonical form.
pub fn ticketText(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [ticket.max_text + 64]u8 = undefined;
    const txt = c.bytes(s, &in);
    var scratch: [ticket.max_binary]u8 = undefined;
    const t = ticket.Ticket.decode(txt, &scratch) catch return;
    var out: [ticket.max_text]u8 = undefined;
    const re = try t.encode(&out);
    var clean: [ticket.max_text + 64]u8 = undefined;
    var n: usize = 0;
    for (txt) |ch| if (!std.ascii.isWhitespace(ch)) {
        clean[n] = std.ascii.toUpper(ch);
        n += 1;
    };
    try c.expectEqualBytes(clean[0..n], re);
    var scratch2: [ticket.max_binary]u8 = undefined;
    const t2 = try ticket.Ticket.decode(re, &scratch2);
    try c.expect(std.mem.eql(u8, &t.host_id, &t2.host_id) and std.meta.eql(t.secret, t2.secret) and t.expires_unix_s == t2.expires_unix_s);
    try c.expectEqualBytes(t.addr, t2.addr);
}

fn ticketSeeds(ss: *c.Seeds) void {
    var out: [ticket.max_text]u8 = undefined;
    const id: pair.id.Id = @splat(0x11);
    ss.bytes(ss.arena.dupe(u8, (ticket.Ticket{ .host_id = id, .secret = @splat(0x5a), .expires_unix_s = 1_800_000_000, .addr = "endpointabcdefgh" }).encode(&out) catch unreachable) catch @panic("OOM"));
    ss.bytes(ss.arena.dupe(u8, (ticket.Ticket{ .host_id = id, .addr = "" }).encode(&out) catch unreachable) catch @panic("OOM"));
    const t = (ticket.Ticket{ .host_id = id, .secret = @splat(1), .addr = "x" }).encode(&out) catch unreachable;
    // Lower case and wrapped, as pasted.
    var wrapped: std.ArrayList(u8) = .empty;
    for (t, 0..) |ch, i| {
        if (i % 16 == 15) wrapped.append(ss.arena, '\n') catch @panic("OOM");
        wrapped.append(ss.arena, std.ascii.toLower(ch)) catch @panic("OOM");
    }
    ss.bytes(wrapped.items);
}

/// Typed and stored text: PINs, hex IDs, device names and the paired-device list file.
/// The list must parse, write and parse back to the same entries, within an allocation
/// bound proportional to the file.
pub fn text(gpa: std.mem.Allocator, s: *c.Smith) !void {
    var in: [4096]u8 = undefined;
    const b = c.bytes(s, &in);
    if (pair.pin.parse(b)) |p| {
        for (p) |d| try c.expect(d >= '0' and d <= '9');
        try c.expectEqual(@as(?pair.pin.Pin, p), pair.pin.parse(&pair.pin.display(&p)));
    }
    if (pair.id.parseHex(b)) |id| try c.expect(std.ascii.eqlIgnoreCase(std.mem.trim(u8, b, " \t\r\n"), &pair.id.toHex(&id)));
    var nb: [pair.allowlist.max_name]u8 = undefined;
    const name = pair.allowlist.sanitizeName(b, &nb);
    try c.expect(name.len <= pair.allowlist.max_name and std.unicode.utf8ValidateSlice(name));
    for (name) |ch| try c.expect(ch >= 0x20 and ch != 0x7f);

    var bounded: c.Bounded = .{ .child = gpa, .limit = 4 * b.len + 4096 };
    var list = pair.allowlist.Allowlist.parse(bounded.allocator(), b, null) catch |e| {
        try bounded.check();
        if (e == error.OutOfMemory) return error.AllocationBound;
        return;
    };
    defer list.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try list.write(&w.writer);
    var again = try pair.allowlist.Allowlist.parse(gpa, w.written(), null);
    defer again.deinit();
    try c.expect(list.len() == again.len());
    for (list.entries.items, again.entries.items) |x, y| {
        try c.expect(std.mem.eql(u8, &x.id, &y.id) and x.paired_unix_s == y.paired_unix_s);
        try c.expectEqualBytes(x.name, y.name);
        try c.expectEqualBytes(x.addr, y.addr);
    }
}

fn textSeeds(ss: *c.Seeds) void {
    ss.bytes("123 456");
    ss.bytes("123-456\n");
    ss.bytes("00112233445566778899aabbccddeeff00112233445566778899AABBCCDDEEFF");
    ss.bytes("laptop \xe2\x9c\x93\t\x01");
    ss.bytes(pair.allowlist.header ++
        "1111111111111111111111111111111111111111111111111111111111111111\t1700000000\tlaptop\n" ++
        "2222222222222222222222222222222222222222222222222222222222222222\t1700000001\tdesk \xc3\xa9\tendpointabc\r\n" ++
        "# comment\n\n");
}

const ExOp = enum(u8) { connect, send, abort, _ };

/// The host's side of pairing with up to four connections at once sharing one window, each
/// fed any bytes through the framer. The window's counters must stay consistent, and a
/// connection pairs only after a proof made with the window's own secret or PIN.
pub fn exchangeHost(_: std.mem.Allocator, s: *c.Smith) !void {
    const pin: pair.pin.Pin = "123456".*;
    const secret: [ticket.secret_len]u8 = @splat(0x5a);
    var window: ex.Window = .{
        .secret = if (s.value(bool)) secret else null,
        .pin = if (s.value(bool)) pin else null,
        .deadline_us = 60_000_000,
        .attempts_left = s.valueRangeAtMost(u8, 0, 5),
        .pairings_left = s.valueRangeAtMost(u8, 0, 2),
    };
    const start_pairings = window.pairings_left;
    const host_id: ex.Id = @splat(0x11);
    var conns: [4]?ex.Host = @splat(null);
    var framers: [4]ex.Framer = @splat(.{});
    var clients: [4]?ex.Client = @splat(null);
    var paired: u8 = 0;
    var now: i64 = 0;
    while (!s.eosWeightedSimple(32, 1)) {
        now += s.valueRangeAtMost(u32, 0, 10_000_000);
        const i = s.valueRangeLessThan(u8, 0, 4);
        switch (s.value(ExOp)) {
            .connect => {
                const cid: ex.Id = @splat(@intCast(0x20 + i));
                conns[i] = ex.Host.init(&window, host_id, cid, @splat(i), "desk");
                framers[i] = .{};
                // Half the time an honest client (right or wrong credential) drives it.
                clients[i] = if (s.value(bool)) ex.Client.init(host_id, cid, @splat(0x40 + i), switch (s.valueRangeAtMost(u8, 0, 3)) {
                    0 => .{ .pin = pin },
                    1 => .{ .ticket_secret = secret },
                    2 => .{ .pin = "000000".* },
                    else => .{ .ticket_secret = @splat(0) },
                }, "laptop") else null;
                if (clients[i]) |*cl| _ = framers[i].push(cl.start());
            },
            .send => {
                const h = if (conns[i]) |*h| h else continue;
                var in: [ex.max_message + 8]u8 = undefined;
                const extra = c.bytes(s, &in);
                if (clients[i] == null or s.valueRangeAtMost(u8, 0, 7) == 0) _ = framers[i].push(extra);
                var msg: [ex.max_message]u8 = undefined;
                while (true) {
                    const m = (framers[i].next(&msg) catch {
                        h.abort();
                        conns[i] = null;
                        break;
                    }) orelse break;
                    const step = h.onMessage(m, now);
                    // `reply` points into the connection's state: use it before dropping
                    // the connection.
                    var reply: ?[]const u8 = null;
                    var done = false;
                    switch (step) {
                        .more => |r| reply = r,
                        .paired => |p| {
                            paired += 1;
                            done = true;
                            // Only an honest client holding the window's credential gets here.
                            const cl = clients[i] orelse return error.CheckFailed;
                            switch (cl.credential) {
                                .pin => |cp| try c.expect(window.pin != null and std.mem.eql(u8, &cp, &window.pin.?)),
                                .ticket_secret => |cs| try c.expect(window.secret != null and std.mem.eql(u8, &cs, &window.secret.?)),
                            }
                            try c.expectEqualBytes("laptop", p.paired.name());
                        },
                        .failed => |f| {
                            reply = f.reply;
                            done = true;
                        },
                    }
                    // The honest client answers through its own framer.
                    if (reply) |r| if (clients[i]) |*cl| {
                        var cf: ex.Framer = .{};
                        _ = cf.push(r);
                        var cm: [ex.max_message]u8 = undefined;
                        const got = (try cf.next(&cm)).?;
                        switch (cl.onMessage(got)) {
                            .more => |out| if (out) |o| {
                                _ = framers[i].push(o);
                            },
                            .paired => |cp| if (cp.reply) |o| {
                                _ = framers[i].push(o);
                            },
                            .failed => clients[i] = null,
                        }
                    };
                    if (done) {
                        conns[i] = null;
                        break;
                    }
                }
            },
            .abort, _ => if (conns[i]) |*h| {
                h.abort();
                conns[i] = null;
            },
        }
        try c.expect(window.pending <= 4 and paired + window.pairings_left == start_pairings);
    }
    for (&conns) |*maybe| if (maybe.*) |*h| h.abort();
    try c.expect(window.pending == 0);
}

fn exchangeSeeds(ss: *c.Seeds) void {
    // An honest PIN pairing, then a wrong secret on a second connection.
    for ([_]u8{ 0, 3 }) |cred| {
        const sd = ss.new();
        sd.int(true);
        sd.int(true);
        sd.int(@as(u8, 5));
        sd.int(@as(u8, 1));
        sd.eos(false);
        sd.int(@as(u32, 1000));
        sd.int(@as(u8, 0));
        sd.int(ExOp.connect);
        sd.int(false);
        sd.int(cred);
        for (0..3) |_| {
            sd.eos(false);
            sd.int(@as(u32, 1000));
            sd.int(@as(u8, 0));
            sd.int(ExOp.send);
            sd.slice("");
            sd.int(@as(u8, 1));
        }
        sd.eos(true);
    }
}

/// A client mid-pairing fed any host messages, and the framer and admission parsers on
/// the same bytes.
pub fn exchangeClient(_: std.mem.Allocator, s: *c.Smith) !void {
    var cl = ex.Client.init(@splat(0x11), @splat(0x22), @splat(2), if (s.value(bool)) .{ .pin = "123456".* } else .{ .ticket_secret = @splat(7) }, "laptop");
    _ = cl.start();
    var f: ex.Framer = .{};
    while (!s.eosWeightedSimple(16, 1)) {
        var in: [ex.max_message + 8]u8 = undefined;
        const b = c.bytes(s, &in);
        _ = ex.classify(b);
        _ = ex.admitResult(b);
        const taken = f.push(b);
        try c.expect(taken <= b.len);
        var msg: [ex.max_message]u8 = undefined;
        while (true) {
            const m = (f.next(&msg) catch {
                f = .{};
                break;
            }) orelse break;
            try c.expect(m.len > 0 and m.len <= ex.max_message);
            switch (cl.onMessage(m)) {
                .more => |r| if (r) |o| try c.expect(o.len <= 2 + ex.max_message),
                .paired => |p| try c.expect(p.paired.name_len <= pair.allowlist.max_name),
                .failed => |fl| if (fl.reply) |o| try c.expect(o.len <= 2 + ex.max_message),
            }
        }
    }
}

fn exchangeClientSeeds(ss: *c.Seeds) void {
    // A challenge, then a reject, framed.
    const sd = ss.new();
    sd.int(true);
    sd.eos(false);
    sd.slice(&[_]u8{ 18, 0, @intFromEnum(ex.Kind.challenge) } ++ [_]u8{9} ** 16 ++ [_]u8{5});
    sd.eos(false);
    sd.slice(&.{ 3, 0, @intFromEnum(ex.Kind.reject), @intFromEnum(ex.Reason.bad_proof), 4 });
    sd.eos(true);
}

test "pair_ticket" {
    try c.fuzz("pair_ticket", ticketText, ticketSeeds);
}

test "pair_text" {
    try c.fuzz("pair_text", text, textSeeds);
}

test "pair_exchange_host" {
    try c.fuzz("pair_exchange_host", exchangeHost, exchangeSeeds);
}

test "pair_exchange_client" {
    try c.fuzz("pair_exchange_client", exchangeClient, exchangeClientSeeds);
}
