//! moonsec pairing for the browser: `core/pair` (tickets, PINs, the client side of the
//! exchange, admission) compiled to a small wasm32-freestanding module, so the browser runs
//! the same code as `moonsec pair client` rather than a second implementation.
//! `zig build web-pair` builds it; `shim-web/js/pair.js` drives it over a shim-web stream.
//!
//! One pairing at a time per module instance. JS writes inputs into `mp_in` and reads results
//! from `mp_out` (pointers into this module's memory); lengths go through arguments and return
//! values. Returns below 0 are errors.
const std = @import("std");
const core = @import("core");
const pair = core.pair;
const ex = pair.exchange;

const io_len = 4096;
var in_buf: [io_len]u8 = undefined;
var out_buf: [io_len]u8 = undefined;

var ticket_scratch: [pair.ticket.max_binary]u8 = undefined;
var ticket: ?pair.Ticket = null;

var framer: ex.Framer = .{};
var client: ex.Client = undefined;
var paired_name: [ex.max_name]u8 = undefined;
var paired_name_len: usize = 0;
var reason: u8 = 0;
var attempts_left: i32 = -1;

export fn mp_in() [*]u8 {
    return &in_buf;
}
export fn mp_out() [*]u8 {
    return &out_buf;
}
export fn mp_io_len() usize {
    return io_len;
}

// --- tickets ------------------------------------------------------------------------------

/// Decodes the `MOONSEC1:` ticket text in `mp_in[0..len]`. 0 = ok; -1 bad prefix,
/// -2 bad encoding, -3 bad checksum, -4 unsupported version, -5 malformed.
export fn mp_ticket_decode(len: usize) i32 {
    ticket = null;
    if (len > io_len) return -5;
    const t = pair.Ticket.decode(in_buf[0..len], &ticket_scratch) catch |e| return switch (e) {
        error.BadPrefix => -1,
        error.BadEncoding => -2,
        error.BadChecksum => -3,
        error.UnsupportedVersion => -4,
        error.Malformed => -5,
    };
    ticket = t;
    return 0;
}

/// Copies the decoded ticket's host ID (32 bytes) to `mp_out`.
export fn mp_ticket_host_id() i32 {
    const t = ticket orelse return -1;
    @memcpy(out_buf[0..32], &t.host_id);
    return 32;
}

/// 1 if the ticket carries a pairing secret (QR ticket), 0 if not (address ticket: PIN).
export fn mp_ticket_has_secret() i32 {
    const t = ticket orelse return -1;
    return @intFromBool(t.secret != null);
}

/// The ticket's expiry in unix seconds (0 = none), as a double for JS.
export fn mp_ticket_expires() f64 {
    const t = ticket orelse return -1;
    return @floatFromInt(t.expires_unix_s);
}

/// Copies the ticket's address (the shim's endpoint ticket text) to `mp_out`.
export fn mp_ticket_addr() i32 {
    const t = ticket orelse return -1;
    @memcpy(out_buf[0..t.addr.len], t.addr);
    return @intCast(t.addr.len);
}

// --- the client exchange -------------------------------------------------------------------

/// Starts a pairing with the decoded ticket. `mp_in` holds, in order: the client's ID (32),
/// a fresh random nonce (16), 32 fresh secret random bytes (the PIN method's CPace scalar),
/// the PIN text (`pin_len` bytes; 0 = use the ticket's secret),
/// then the client's name (`name_len` bytes). Writes the framed `hello` to `mp_out` and
/// returns its length. -1 no ticket, -2 bad PIN, -3 the ticket has no secret and no PIN.
export fn mp_client_start(pin_len: usize, name_len: usize) i32 {
    const t = ticket orelse return -1;
    if (80 + pin_len + name_len > io_len) return -2;
    const client_id: pair.Id = in_buf[0..32].*;
    const nonce: ex.Nonce = in_buf[32..48].*;
    const seed: ex.Seed = in_buf[48..80].*;
    @memset(in_buf[48..80], 0);
    const pin_text = in_buf[80..][0..pin_len];
    const name = in_buf[80 + pin_len ..][0..name_len];
    const cred: ex.Credential = if (pin_len > 0)
        .{ .pin = pair.pin.parse(pin_text) orelse return -2 }
    else if (t.secret) |s|
        .{ .ticket_secret = s }
    else
        return -3;
    framer = .{};
    reason = 0;
    attempts_left = -1;
    paired_name_len = 0;
    client = ex.Client.init(t.host_id, client_id, nonce, seed, cred, name);
    return out(client.start());
}

fn out(b: []const u8) i32 {
    @memcpy(out_buf[0..b.len], b);
    return @intCast(b.len);
}

/// Feeds `mp_in[0..len]` (bytes read from the stream) to the framer. Returns how many it
/// took; push the rest after `mp_client_step` has consumed a message.
export fn mp_push(len: usize) i32 {
    return @intCast(framer.push(in_buf[0..len]));
}

/// Runs the exchange on the next whole message, if one has arrived.
///   0  need more bytes (push, then step again)
///   1  write `mp_out[0..mp_reply_len()]` and keep reading
///   2  paired: write the reply (`confirm`), then finish the stream; mp_paired_name has the host's name
///   3  failed: write the reply if mp_reply_len() > 0, then close; mp_reason() says why
///   -1 malformed framing (close the stream)
var reply_len: usize = 0;
export fn mp_client_step() i32 {
    var msg: [ex.max_message]u8 = undefined;
    const m = (framer.next(&msg) catch return -1) orelse return 0;
    const step = client.onMessage(m);
    if (client.attempts_left) |n| attempts_left = n;
    switch (step) {
        .more => |r| {
            reply_len = if (r) |b| @intCast(out(b)) else 0;
            return 1;
        },
        .paired => |p| {
            reply_len = if (p.reply) |b| @intCast(out(b)) else 0;
            const n = p.paired.name();
            @memcpy(paired_name[0..n.len], n);
            paired_name_len = n.len;
            return 2;
        },
        .failed => |f| {
            reply_len = if (f.reply) |b| @intCast(out(b)) else 0;
            reason = @intFromEnum(f.reason);
            return 3;
        },
    }
}

export fn mp_reply_len() usize {
    return reply_len;
}
/// Why the last exchange failed (spec/pairing-v0.md reject reasons), 0 if it did not.
export fn mp_reason() u8 {
    return reason;
}
/// The host's attempts left from its last challenge or reject, -1 if unknown.
export fn mp_attempts_left() i32 {
    return attempts_left;
}
/// Copies the paired host's (sanitized) name to `mp_out`.
export fn mp_paired_name() i32 {
    return out(paired_name[0..paired_name_len]);
}

// --- admission -----------------------------------------------------------------------------

/// Resets the framer and writes the framed `admit` message to `mp_out`.
export fn mp_admit_start() i32 {
    framer = .{};
    reason = 0;
    var o: ex.Out = .{};
    return out(ex.admitMessage(&o));
}

/// The host's answer, once whole: 0 need more bytes, 1 admitted, 2 refused (mp_reason), -1 bad framing.
export fn mp_admit_step() i32 {
    var msg: [ex.max_message]u8 = undefined;
    const m = (framer.next(&msg) catch return -1) orelse return 0;
    if (ex.admitResult(m)) |r| {
        reason = @intFromEnum(r);
        return 2;
    }
    return 1;
}

// --- identity ------------------------------------------------------------------------------

/// The endpoint ID (public key) for the 32-byte secret key in `mp_in`, written to `mp_out`.
/// Lets the page show its ID before binding, and checks shim-web derives IDs the same way.
export fn mp_public_from_secret() i32 {
    const id = pair.id.publicFromSecret(in_buf[0..32]);
    return out(&id);
}
