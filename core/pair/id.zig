//! Device identity: an endpoint ID is the device's Ed25519 public key (32 bytes), the same
//! key iroh authenticates every connection with. Text form is 64 lowercase hex digits, as
//! the shim prints it (`iroh_endpoint_id`, `iroh_conn_remote_id`).
const std = @import("std");

pub const Id = [32]u8;
pub const hex_len = 64;

/// Parses 64 hex digits (either case). Surrounding whitespace is ignored.
pub fn parseHex(text: []const u8) ?Id {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len != hex_len) return null;
    var out: Id = undefined;
    _ = std.fmt.hexToBytes(&out, t) catch return null;
    return out;
}

pub fn toHex(id: *const Id) [hex_len]u8 {
    return std.fmt.bytesToHex(id.*, .lower);
}

/// The endpoint ID iroh derives from a 32-byte secret key (Ed25519 seed).
pub fn publicFromSecret(secret: *const [32]u8) Id {
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(secret.*) catch unreachable;
    return kp.public_key.toBytes();
}

/// First 8 hex digits, for logs and prompts ("paired with a1b2c3d4").
pub fn short(id: *const Id) [8]u8 {
    return toHex(id)[0..8].*;
}

test "hex round trip, case and whitespace, bad input" {
    var id: Id = undefined;
    for (&id, 0..) |*b, i| b.* = @intCast(i * 7);
    const h = toHex(&id);
    try std.testing.expectEqual(id, parseHex(&h).?);
    var upper: [hex_len + 2]u8 = undefined;
    upper[0] = ' ';
    for (h, 0..) |c, i| upper[i + 1] = std.ascii.toUpper(c);
    upper[hex_len + 1] = '\n';
    try std.testing.expectEqual(id, parseHex(&upper).?);
    try std.testing.expect(parseHex(h[0..63]) == null);
    var bad = h;
    bad[10] = 'g';
    try std.testing.expect(parseHex(&bad) == null);
}

test "public key from secret matches RFC 8032 test vector 1" {
    var sk: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sk, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const pk = publicFromSecret(&sk);
    try std.testing.expectEqualStrings("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", &toHex(&pk));
}
