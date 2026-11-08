//! Pairing tickets (spec/pairing-v0.md, "Tickets").
//!
//! A ticket tells a client how to reach a host and which host to expect. A QR ticket also
//! carries a one-time 128-bit pairing secret, so scanning it is enough to pair; an address
//! ticket has no secret and the user types the host's PIN instead.
//!
//! Text form: `MOONSEC1:` then the binary form in RFC 4648 base32 (upper case, no padding),
//! which fits QR alphanumeric mode. Decoding ignores case and whitespace.
const std = @import("std");
const id_mod = @import("id.zig");

pub const Id = id_mod.Id;
pub const prefix = "MOONSEC1:";
pub const secret_len = 16;
/// Longest iroh address (EndpointTicket text) a ticket carries.
pub const max_addr = 1024;
const version: u8 = 1;
const flag_secret: u8 = 1;
/// version, flags, host id, expiry, addr length, crc.
const fixed_len = 1 + 1 + 32 + 8 + 2 + 4;
pub const max_binary = fixed_len + secret_len + max_addr;
pub const max_text = prefix.len + (max_binary * 8 + 4) / 5;

pub const Ticket = struct {
    host_id: Id,
    /// One-time pairing secret (QR ticket); null for an address ticket (PIN pairing).
    secret: ?[secret_len]u8 = null,
    /// Unix seconds after which the host no longer accepts the secret; 0 = no expiry.
    expires_unix_s: u64 = 0,
    /// How to dial the host: the shim's endpoint ticket text, opaque to the core.
    addr: []const u8,

    pub fn binaryLen(t: Ticket) usize {
        return fixed_len + (if (t.secret != null) @as(usize, secret_len) else 0) + t.addr.len;
    }

    pub fn textLen(t: Ticket) usize {
        return prefix.len + base32Len(t.binaryLen());
    }

    /// Writes the text form into `out` (at least `textLen()` bytes) and returns it.
    pub fn encode(t: Ticket, out: []u8) error{ NoSpaceLeft, AddrTooLong }![]u8 {
        if (t.addr.len > max_addr) return error.AddrTooLong;
        if (out.len < t.textLen()) return error.NoSpaceLeft;
        var bin: [max_binary]u8 = undefined;
        var n: usize = 0;
        bin[0] = version;
        bin[1] = if (t.secret != null) flag_secret else 0;
        @memcpy(bin[2..34], &t.host_id);
        n = 34;
        if (t.secret) |s| {
            @memcpy(bin[n..][0..secret_len], &s);
            n += secret_len;
        }
        std.mem.writeInt(u64, bin[n..][0..8], t.expires_unix_s, .little);
        n += 8;
        std.mem.writeInt(u16, bin[n..][0..2], @intCast(t.addr.len), .little);
        n += 2;
        @memcpy(bin[n..][0..t.addr.len], t.addr);
        n += t.addr.len;
        std.mem.writeInt(u32, bin[n..][0..4], std.hash.Crc32.hash(bin[0..n]), .little);
        n += 4;
        @memcpy(out[0..prefix.len], prefix);
        const m = base32Encode(bin[0..n], out[prefix.len..]);
        return out[0 .. prefix.len + m];
    }

    pub const DecodeError = error{ BadPrefix, BadEncoding, BadChecksum, UnsupportedVersion, Malformed };

    /// Parses the text form. `addr` in the result points into `scratch`.
    pub fn decode(text: []const u8, scratch: *[max_binary]u8) DecodeError!Ticket {
        // Strip whitespace anywhere (tickets get wrapped and pasted).
        var clean: [max_text]u8 = undefined;
        var cn: usize = 0;
        for (text) |c| {
            if (std.ascii.isWhitespace(c)) continue;
            if (cn == clean.len) return error.Malformed;
            clean[cn] = std.ascii.toUpper(c);
            cn += 1;
        }
        const s = clean[0..cn];
        if (!std.mem.startsWith(u8, s, prefix)) return error.BadPrefix;
        const bin = base32Decode(s[prefix.len..], scratch) orelse return error.BadEncoding;
        if (bin.len < fixed_len) return error.Malformed;
        const body = bin[0 .. bin.len - 4];
        if (std.hash.Crc32.hash(body) != std.mem.readInt(u32, bin[bin.len - 4 ..][0..4], .little)) return error.BadChecksum;
        if (body[0] != version) return error.UnsupportedVersion;
        const flags = body[1];
        var t: Ticket = .{ .host_id = body[2..34].*, .addr = &.{} };
        var n: usize = 34;
        if (flags & flag_secret != 0) {
            if (body.len < n + secret_len) return error.Malformed;
            t.secret = body[n..][0..secret_len].*;
            n += secret_len;
        }
        if (body.len < n + 10) return error.Malformed;
        t.expires_unix_s = std.mem.readInt(u64, body[n..][0..8], .little);
        n += 8;
        const alen = std.mem.readInt(u16, body[n..][0..2], .little);
        n += 2;
        if (alen > max_addr or body.len != n + alen) return error.Malformed;
        t.addr = body[n..][0..alen];
        return t;
    }

    pub fn expired(t: Ticket, now_unix_s: u64) bool {
        return t.expires_unix_s != 0 and now_unix_s >= t.expires_unix_s;
    }
};

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn base32Len(n: usize) usize {
    return (n * 8 + 4) / 5;
}

fn base32Encode(in: []const u8, out: []u8) usize {
    var acc: u16 = 0;
    var bits: u4 = 0;
    var n: usize = 0;
    for (in) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            out[n] = alphabet[(acc >> bits) & 31];
            n += 1;
        }
        acc &= (@as(u16, 1) << bits) - 1;
    }
    if (bits > 0) {
        out[n] = alphabet[(acc << (5 - bits)) & 31];
        n += 1;
    }
    return n;
}

fn base32Decode(in: []const u8, out: []u8) ?[]u8 {
    var acc: u16 = 0;
    var bits: u4 = 0;
    var n: usize = 0;
    for (in) |c| {
        const v: u16 = switch (c) {
            'A'...'Z' => c - 'A',
            '2'...'7' => c - '2' + 26,
            else => return null,
        };
        acc = (acc << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            if (n == out.len) return null;
            out[n] = @intCast((acc >> bits) & 0xff);
            n += 1;
        }
        acc &= (@as(u16, 1) << bits) - 1;
    }
    // Leftover bits must be zero padding, and fewer than 5 of them.
    if (bits >= 5 or acc != 0) return null;
    return out[0..n];
}

const testing = std.testing;

fn testId(seed: u8) Id {
    var id: Id = undefined;
    for (&id, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
    return id;
}

test "base32 matches RFC 4648 vectors" {
    const cases = [_][2][]const u8{
        .{ "", "" },            .{ "f", "MY" },           .{ "fo", "MZXQ" },           .{ "foo", "MZXW6" },
        .{ "foob", "MZXW6YQ" }, .{ "fooba", "MZXW6YTB" }, .{ "foobar", "MZXW6YTBOI" },
    };
    for (cases) |c| {
        var out: [32]u8 = undefined;
        const n = base32Encode(c[0], &out);
        try testing.expectEqualStrings(c[1], out[0..n]);
        var back: [32]u8 = undefined;
        try testing.expectEqualStrings(c[0], base32Decode(c[1], &back).?);
    }
    var back: [8]u8 = undefined;
    try testing.expect(base32Decode("MZ", &back) == null); // nonzero padding bits
    try testing.expect(base32Decode("M1", &back) == null);
}

test "QR and address tickets round trip, survive case and wrapping" {
    const addr = "endpointaaaabbbbccccddddeeee";
    const qr: Ticket = .{ .host_id = testId(3), .secret = [_]u8{0xA5} ** secret_len, .expires_unix_s = 1_800_000_000, .addr = addr };
    var buf: [max_text]u8 = undefined;
    const text = try qr.encode(&buf);
    try testing.expectEqual(qr.textLen(), text.len);
    try testing.expect(std.mem.startsWith(u8, text, prefix));
    for (text) |c| try testing.expect(std.mem.indexOfScalar(u8, alphabet ++ "MOONSEC1:", c) != null);
    var scratch: [max_binary]u8 = undefined;
    const back = try Ticket.decode(text, &scratch);
    try testing.expectEqual(qr.host_id, back.host_id);
    try testing.expectEqual(qr.secret.?, back.secret.?);
    try testing.expectEqual(qr.expires_unix_s, back.expires_unix_s);
    try testing.expectEqualStrings(addr, back.addr);
    try testing.expect(!back.expired(1_799_999_999));
    try testing.expect(back.expired(1_800_000_000));

    // Lower case with line breaks still decodes.
    var messy: [max_text * 2]u8 = undefined;
    var n: usize = 0;
    for (text, 0..) |c, i| {
        messy[n] = std.ascii.toLower(c);
        n += 1;
        if (i % 20 == 19) {
            messy[n] = '\n';
            n += 1;
        }
    }
    const back2 = try Ticket.decode(messy[0..n], &scratch);
    try testing.expectEqual(qr.host_id, back2.host_id);

    const plain: Ticket = .{ .host_id = testId(9), .addr = addr };
    const t2 = try plain.encode(&buf);
    const b2 = try Ticket.decode(t2, &scratch);
    try testing.expect(b2.secret == null);
    try testing.expect(!b2.expired(std.math.maxInt(u64)));
}

test "ticket decode rejects typos, truncation, bad prefix and versions" {
    const t: Ticket = .{ .host_id = testId(1), .secret = [_]u8{7} ** secret_len, .addr = "endpointxyz" };
    var buf: [max_text]u8 = undefined;
    const text = try t.encode(&buf);
    var scratch: [max_binary]u8 = undefined;
    // One changed character anywhere after the prefix fails the CRC (or the encoding).
    for (prefix.len..text.len) |i| {
        var bad: [max_text]u8 = undefined;
        @memcpy(bad[0..text.len], text);
        bad[i] = if (text[i] == 'A') 'B' else 'A';
        try testing.expect(std.meta.isError(Ticket.decode(bad[0..text.len], &scratch)));
    }
    try testing.expectError(error.BadPrefix, Ticket.decode("MOONSEC2:AAAA", &scratch));
    try testing.expectError(error.BadPrefix, Ticket.decode("endpointabc", &scratch));
    try testing.expect(std.meta.isError(Ticket.decode(text[0 .. text.len - 3], &scratch)));
    try testing.expectError(error.Malformed, Ticket.decode(prefix ++ "AAAA", &scratch));

    const long = [_]u8{'x'} ** (max_addr + 1);
    const too_long: Ticket = .{ .host_id = testId(1), .addr = &long };
    var big: [max_text + 8]u8 = undefined;
    try testing.expectError(error.AddrTooLong, too_long.encode(&big));
    var small: [10]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, t.encode(&small));
}
