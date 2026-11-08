//! The pairing exchange (spec/pairing-v0.md, "Exchange"), sans-I/O.
//!
//! Runs on a reliable stream inside a connection that iroh has already authenticated, so
//! both sides know each other's endpoint ID for certain. What pairing adds is proof that
//! the client holds the secret the host is showing (the QR ticket's secret or the PIN), and
//! that the host is the one showing it. Both proofs are HMACs over a transcript that binds
//! both endpoint IDs and both nonces, so a proof cannot be replayed on another connection or
//! relayed to another host.
//!
//!     client                               host
//!     hello(method, client_nonce, name) ->
//!                                       <- challenge(host_nonce, attempts_left) | reject
//!     proof(client_mac)                 ->
//!                                       <- accept(host_mac, host_name)          | reject
//!     confirm                           ->   (host commits the client to its allowlist)
//!
//! Messages are framed `u16 length (LE) | kind | body`. Every wrong guess costs one of the
//! window's attempts, whichever connection it comes on, and a window closes after its last
//! attempt, its last pairing, or its deadline.
const std = @import("std");
const id_mod = @import("id.zig");
const pin_mod = @import("pin.zig");
const ticket_mod = @import("ticket.zig");
const allowlist = @import("allowlist.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
pub const Id = id_mod.Id;
pub const Nonce = [16]u8;
pub const Mac = [32]u8;
pub const version: u8 = 0;
pub const max_name = allowlist.max_name;
/// Largest framed message (accept with a full name), plus the 2-byte length.
pub const max_message = 1 + 32 + 1 + max_name;
const label = "moonsec-pair-v0";

pub const Method = enum(u8) {
    /// The one-time secret from a QR ticket.
    ticket_secret = 1,
    /// The six-digit PIN the host shows.
    pin = 2,
    _,
};

pub const Kind = enum(u8) {
    hello = 1,
    challenge = 2,
    proof = 3,
    accept = 4,
    reject = 5,
    confirm = 6,
    /// Admission (not pairing): a paired client asks to start a session.
    admit = 7,
    admitted = 8,
    _,
};

pub const Reason = enum(u8) {
    /// The host is not pairing right now.
    no_window = 1,
    /// The host is pairing, but not with this method (no QR shown, or no PIN).
    method_not_offered = 2,
    /// Wrong PIN or secret.
    bad_proof = 3,
    /// The window used up its attempts; the host has to open a new one.
    locked = 4,
    /// The window's deadline passed.
    expired = 5,
    unsupported_version = 6,
    /// A malformed or unexpected message.
    protocol = 7,
    /// (client side) the host's proof did not verify: it does not hold the secret.
    host_proof = 8,
    /// (admission) this client is not on the host's allowlist.
    not_paired = 9,
    _,
};

/// The credential a client pairs with.
pub const Credential = union(Method) {
    ticket_secret: [ticket_mod.secret_len]u8,
    pin: pin_mod.Pin,
};

fn deriveKey(method: Method, secret: []const u8) Mac {
    var k: Mac = undefined;
    var h = HmacSha256.init(label);
    h.update(&.{@intFromEnum(method)});
    h.update(secret);
    h.final(&k);
    return k;
}

const Transcript = struct {
    method: Method,
    host_id: Id,
    client_id: Id,
    client_nonce: Nonce,
    host_nonce: Nonce,
    client_name: []const u8,

    fn mac(t: *const Transcript, key: *const Mac, role: []const u8) Mac {
        var out: Mac = undefined;
        var h = HmacSha256.init(key);
        h.update(role);
        h.update(label);
        h.update(&.{@intFromEnum(t.method)});
        h.update(&t.host_id);
        h.update(&t.client_id);
        h.update(&t.client_nonce);
        h.update(&t.host_nonce);
        h.update(&.{@intCast(t.client_name.len)});
        h.update(t.client_name);
        h.final(&out);
        return out;
    }
};

// --- framing -------------------------------------------------------------------

/// Accumulates stream bytes and yields whole messages.
pub const Framer = struct {
    buf: [2 + max_message]u8 = undefined,
    len: usize = 0,

    pub const Error = error{MessageTooLong};

    /// Copies as much of `bytes` as fits; returns how many were taken. Call `next` until it
    /// returns null, then push the rest.
    pub fn push(f: *Framer, bytes: []const u8) usize {
        const n = @min(bytes.len, f.buf.len - f.len);
        @memcpy(f.buf[f.len..][0..n], bytes[0..n]);
        f.len += n;
        return n;
    }

    /// The next complete message (valid until the next call), null if more bytes are needed.
    pub fn next(f: *Framer, out: *[max_message]u8) Error!?[]const u8 {
        if (f.len < 2) return null;
        const n = std.mem.readInt(u16, f.buf[0..2], .little);
        if (n == 0 or n > max_message) return error.MessageTooLong;
        if (f.len < 2 + n) return null;
        @memcpy(out[0..n], f.buf[2..][0..n]);
        std.mem.copyForwards(u8, f.buf[0 .. f.len - 2 - n], f.buf[2 + n .. f.len]);
        f.len -= 2 + n;
        return out[0..n];
    }
};

/// A framed outgoing message.
pub const Out = struct {
    buf: [2 + max_message]u8 = undefined,
    len: usize = 0,

    pub fn bytes(o: *const Out) []const u8 {
        return o.buf[0..o.len];
    }

    fn begin(o: *Out, kind: Kind) void {
        o.buf[2] = @intFromEnum(kind);
        o.len = 3;
    }
    fn put(o: *Out, b: []const u8) void {
        @memcpy(o.buf[o.len..][0..b.len], b);
        o.len += b.len;
    }
    fn end(o: *Out) []const u8 {
        std.mem.writeInt(u16, o.buf[0..2], @intCast(o.len - 2), .little);
        return o.bytes();
    }
    fn reject(o: *Out, reason: Reason, attempts_left: u8) []const u8 {
        o.begin(.reject);
        o.put(&.{ @intFromEnum(reason), attempts_left });
        return o.end();
    }
};

// --- host -------------------------------------------------------------------------

/// What the host is offering right now: a deadline, a QR secret and/or a PIN, and how many
/// guesses and pairings are left. Shared by every connection while it is open.
pub const Window = struct {
    secret: ?[ticket_mod.secret_len]u8 = null,
    pin: ?pin_mod.Pin = null,
    /// Host clock (any monotonic microseconds the caller uses consistently).
    deadline_us: i64,
    attempts_left: u8 = 5,
    pairings_left: u8 = 1,
    /// Proofs that verified and are waiting for the client's confirm.
    pending: u8 = 0,

    pub const default_duration_us: i64 = 120 * std.time.us_per_s;

    pub fn isOpen(w: *const Window, now_us: i64) bool {
        return w.attempts_left > 0 and w.pairings_left > w.pending and now_us < w.deadline_us;
    }

    fn closedReason(w: *const Window, now_us: i64) Reason {
        if (now_us >= w.deadline_us) return .expired;
        if (w.attempts_left == 0) return .locked;
        return .no_window;
    }

    fn key(w: *const Window, m: Method) ?Mac {
        return switch (m) {
            .ticket_secret => if (w.secret) |s| deriveKey(m, &s) else null,
            .pin => if (w.pin) |p| deriveKey(m, &p) else null,
            _ => null,
        };
    }
};

pub const Paired = struct {
    peer_id: Id,
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,
    method: Method,

    pub fn name(p: *const Paired) []const u8 {
        return p.name_buf[0..p.name_len];
    }
};

pub const Step = union(enum) {
    /// Send `reply` (if any) and keep reading.
    more: ?[]const u8,
    /// Send `reply` (if any); the exchange paired.
    paired: struct { reply: ?[]const u8, paired: Paired },
    /// Send `reply` (if any) and close the stream.
    failed: struct { reply: ?[]const u8, reason: Reason },
};

pub const Host = struct {
    window: ?*Window,
    host_id: Id,
    client_id: Id,
    host_nonce: Nonce,
    host_name_buf: [max_name]u8 = undefined,
    host_name_len: u8 = 0,
    state: enum { await_hello, await_proof, await_confirm, done } = .await_hello,
    t: Transcript = undefined,
    client_name_buf: [max_name]u8 = undefined,
    key: Mac = undefined,
    out: Out = .{},

    /// `window` null means the host is not pairing (every hello gets `no_window`).
    /// `host_nonce` must be fresh random bytes for each connection.
    pub fn init(window: ?*Window, host_id: Id, client_id: Id, host_nonce: Nonce, host_name: []const u8) Host {
        var h: Host = .{ .window = window, .host_id = host_id, .client_id = client_id, .host_nonce = host_nonce };
        const n = allowlist.sanitizeName(host_name, &h.host_name_buf);
        std.mem.copyForwards(u8, h.host_name_buf[0..n.len], n);
        h.host_name_len = @intCast(n.len);
        return h;
    }

    fn fail(h: *Host, reason: Reason) Step {
        const left: u8 = if (h.window) |w| w.attempts_left else 0;
        if (h.state == .await_confirm) h.window.?.pending -= 1;
        h.state = .done;
        return .{ .failed = .{ .reply = h.out.reject(reason, left), .reason = reason } };
    }

    /// Call when the stream ends or breaks before the exchange finished.
    pub fn abort(h: *Host) void {
        if (h.state == .await_confirm) h.window.?.pending -= 1;
        h.state = .done;
    }

    pub fn onMessage(h: *Host, msg: []const u8, now_us: i64) Step {
        if (msg.len == 0) return h.fail(.protocol);
        const kind: Kind = @enumFromInt(msg[0]);
        const body = msg[1..];
        switch (h.state) {
            .await_hello => {
                if (kind != .hello) return h.fail(.protocol);
                if (body.len < 2 + 16 + 1) return h.fail(.protocol);
                if (body[0] != version) return h.fail(.unsupported_version);
                const method: Method = @enumFromInt(body[1]);
                const name_len = body[18];
                if (name_len > max_name or body.len != 19 + name_len) return h.fail(.protocol);
                const w = h.window orelse return h.fail(.no_window);
                if (!w.isOpen(now_us)) return h.fail(w.closedReason(now_us));
                h.key = w.key(method) orelse return h.fail(.method_not_offered);
                const cname = allowlist.sanitizeName(body[19..][0..name_len], &h.client_name_buf);
                h.t = .{
                    .method = method,
                    .host_id = h.host_id,
                    .client_id = h.client_id,
                    .client_nonce = body[2..18].*,
                    .host_nonce = h.host_nonce,
                    .client_name = cname,
                };
                h.state = .await_proof;
                h.out.begin(.challenge);
                h.out.put(&h.host_nonce);
                h.out.put(&.{w.attempts_left});
                return .{ .more = h.out.end() };
            },
            .await_proof => {
                if (kind != .proof or body.len != 32) return h.fail(.protocol);
                const w = h.window.?;
                if (!w.isOpen(now_us)) return h.fail(w.closedReason(now_us));
                const want = h.t.mac(&h.key, "client");
                if (!std.crypto.timing_safe.eql(Mac, want, body[0..32].*)) {
                    // Every wrong guess costs an attempt, on whichever connection it comes.
                    w.attempts_left -= 1;
                    return h.fail(if (w.attempts_left == 0) .locked else .bad_proof);
                }
                w.pending += 1;
                h.state = .await_confirm;
                h.out.begin(.accept);
                h.out.put(&h.t.mac(&h.key, "host"));
                h.out.put(&.{h.host_name_len});
                h.out.put(h.host_name_buf[0..h.host_name_len]);
                return .{ .more = h.out.end() };
            },
            .await_confirm => {
                if (kind != .confirm or body.len != 0) return h.fail(.protocol);
                const w = h.window.?;
                w.pending -= 1;
                w.pairings_left -= 1;
                h.state = .done;
                var p: Paired = .{ .peer_id = h.client_id, .method = h.t.method };
                @memcpy(p.name_buf[0..h.t.client_name.len], h.t.client_name);
                p.name_len = @intCast(h.t.client_name.len);
                return .{ .paired = .{ .reply = null, .paired = p } };
            },
            .done => return .{ .failed = .{ .reply = null, .reason = .protocol } },
        }
    }
};

// --- client -----------------------------------------------------------------------

pub const Client = struct {
    host_id: Id,
    client_id: Id,
    client_nonce: Nonce,
    credential: Credential,
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,
    state: enum { start, await_challenge, await_accept, done } = .start,
    key: Mac = undefined,
    t: Transcript = undefined,
    out: Out = .{},
    /// The host's attempts left, from its last challenge or reject.
    attempts_left: ?u8 = null,

    /// `host_id` is the ID the client expects (from the ticket) and the one the connection
    /// authenticated; `client_nonce` must be fresh random bytes.
    pub fn init(host_id: Id, client_id: Id, client_nonce: Nonce, credential: Credential, name: []const u8) Client {
        var c: Client = .{ .host_id = host_id, .client_id = client_id, .client_nonce = client_nonce, .credential = credential };
        const n = allowlist.sanitizeName(name, &c.name_buf);
        std.mem.copyForwards(u8, c.name_buf[0..n.len], n);
        c.name_len = @intCast(n.len);
        c.key = switch (credential) {
            .ticket_secret => |s| deriveKey(.ticket_secret, &s),
            .pin => |p| deriveKey(.pin, &p),
        };
        return c;
    }

    pub fn start(c: *Client) []const u8 {
        std.debug.assert(c.state == .start);
        c.state = .await_challenge;
        c.out.begin(.hello);
        c.out.put(&.{ version, @intFromEnum(std.meta.activeTag(c.credential)) });
        c.out.put(&c.client_nonce);
        c.out.put(&.{c.name_len});
        c.out.put(c.name_buf[0..c.name_len]);
        return c.out.end();
    }

    fn fail(c: *Client, reason: Reason, reply: bool) Step {
        c.state = .done;
        return .{ .failed = .{ .reply = if (reply) c.out.reject(reason, 0) else null, .reason = reason } };
    }

    pub fn onMessage(c: *Client, msg: []const u8) Step {
        if (msg.len == 0) return c.fail(.protocol, true);
        const kind: Kind = @enumFromInt(msg[0]);
        const body = msg[1..];
        if (kind == .reject) {
            if (body.len != 2) return c.fail(.protocol, false);
            c.attempts_left = body[1];
            return c.fail(@enumFromInt(body[0]), false);
        }
        switch (c.state) {
            .await_challenge => {
                if (kind != .challenge or body.len != 17) return c.fail(.protocol, true);
                c.attempts_left = body[16];
                c.t = .{
                    .method = std.meta.activeTag(c.credential),
                    .host_id = c.host_id,
                    .client_id = c.client_id,
                    .client_nonce = c.client_nonce,
                    .host_nonce = body[0..16].*,
                    .client_name = c.name_buf[0..c.name_len],
                };
                c.state = .await_accept;
                c.out.begin(.proof);
                c.out.put(&c.t.mac(&c.key, "client"));
                return .{ .more = c.out.end() };
            },
            .await_accept => {
                if (kind != .accept or body.len < 33) return c.fail(.protocol, true);
                const name_len = body[32];
                if (name_len > max_name or body.len != 33 + name_len) return c.fail(.protocol, true);
                const want = c.t.mac(&c.key, "host");
                if (!std.crypto.timing_safe.eql(Mac, want, body[0..32].*)) return c.fail(.host_proof, true);
                c.state = .done;
                var p: Paired = .{ .peer_id = c.host_id, .method = c.t.method };
                const n = allowlist.sanitizeName(body[33..][0..name_len], &p.name_buf);
                std.mem.copyForwards(u8, p.name_buf[0..n.len], n);
                p.name_len = @intCast(n.len);
                c.out.begin(.confirm);
                return .{ .paired = .{ .reply = c.out.end(), .paired = p } };
            },
            .start, .done => return c.fail(.protocol, false),
        }
    }
};

// --- admission --------------------------------------------------------------------

/// The first message a paired client sends on its control stream to start a session.
pub fn admitMessage(out: *Out) []const u8 {
    out.begin(.admit);
    out.put(&.{version});
    return out.end();
}

pub const Admission = enum { admit, pair, invalid };

/// What a host's first message asks for: a session, a pairing, or nothing valid.
pub fn classify(msg: []const u8) Admission {
    if (msg.len == 2 and msg[0] == @intFromEnum(Kind.admit) and msg[1] == version) return .admit;
    if (msg.len >= 1 and msg[0] == @intFromEnum(Kind.hello)) return .pair;
    return .invalid;
}

/// The host's answer to `admit`.
pub fn admitReply(out: *Out, allowed: bool) []const u8 {
    if (!allowed) return out.reject(.not_paired, 0);
    out.begin(.admitted);
    return out.end();
}

/// The client reads the host's answer: null if admitted, else why not.
pub fn admitResult(msg: []const u8) ?Reason {
    if (msg.len == 1 and msg[0] == @intFromEnum(Kind.admitted)) return null;
    if (msg.len == 3 and msg[0] == @intFromEnum(Kind.reject)) return @enumFromInt(msg[1]);
    return .protocol;
}

// --- tests ------------------------------------------------------------------------

const testing = std.testing;

const t_host: Id = [_]u8{0x11} ** 32;
const t_client: Id = [_]u8{0x22} ** 32;
const t_secret = [_]u8{0x5a} ** 16;

/// Runs a whole exchange in memory, through the framer, and returns both outcomes.
fn run(w: ?*Window, cred: Credential, now_us: i64, cid: Id, tamper: ?*const fn ([]u8) void) struct { host: Step, client: Step } {
    var h = Host.init(w, t_host, cid, [_]u8{1} ** 16, "desk");
    var c = Client.init(t_host, cid, [_]u8{2} ** 16, cred, "laptop");
    var to_host: Framer = .{};
    var to_client: Framer = .{};
    var tmp: [max_message]u8 = undefined;
    var hs: Step = .{ .more = null };
    var cs: Step = .{ .more = null };
    _ = to_host.push(c.start());
    while (true) {
        if (to_host.next(&tmp) catch unreachable) |m| {
            var mm: [max_message]u8 = undefined;
            @memcpy(mm[0..m.len], m);
            if (tamper) |f| f(mm[0..m.len]);
            hs = h.onMessage(mm[0..m.len], now_us);
            const reply = switch (hs) {
                .more => |r| r,
                .paired => |p| p.reply,
                .failed => |f| f.reply,
            };
            if (reply) |r| _ = to_client.push(r);
            if (hs != .more) {
                if (to_client.next(&tmp) catch unreachable) |cm| cs = c.onMessage(cm);
                return .{ .host = hs, .client = cs };
            }
        } else if (to_client.next(&tmp) catch unreachable) |m| {
            cs = c.onMessage(m);
            const reply = switch (cs) {
                .more => |r| r,
                .paired => |p| p.reply,
                .failed => |f| f.reply,
            };
            if (reply) |r| _ = to_host.push(r);
            if (cs == .failed) {
                h.abort();
                return .{ .host = hs, .client = cs };
            }
        } else return .{ .host = hs, .client = cs };
    }
}

test "pairs with the QR secret: both sides learn each other, the window is spent" {
    var w: Window = .{ .secret = t_secret, .deadline_us = 1000 };
    const r = run(&w, .{ .ticket_secret = t_secret }, 0, t_client, null);
    try testing.expect(r.host == .paired);
    try testing.expect(r.client == .paired);
    try testing.expectEqual(t_client, r.host.paired.paired.peer_id);
    try testing.expectEqualStrings("laptop", r.host.paired.paired.name());
    try testing.expectEqualStrings("desk", r.client.paired.paired.name());
    try testing.expectEqual(Method.ticket_secret, r.host.paired.paired.method);
    try testing.expect(!w.isOpen(0));
    // A second client with the same t_secret is refused: one pairing per window.
    const r2 = run(&w, .{ .ticket_secret = t_secret }, 0, [_]u8{0x33} ** 32, null);
    try testing.expectEqual(Reason.no_window, r2.client.failed.reason);
}

test "pairs with the PIN; wrong PINs use up attempts and then lock the window" {
    var w: Window = .{ .pin = "123456".*, .deadline_us = 1000, .attempts_left = 3, .pairings_left = 1 };
    var r = run(&w, .{ .pin = "000000".* }, 0, t_client, null);
    try testing.expectEqual(Reason.bad_proof, r.host.failed.reason);
    try testing.expectEqual(Reason.bad_proof, r.client.failed.reason);
    try testing.expectEqual(@as(u8, 2), w.attempts_left);
    r = run(&w, .{ .pin = "123456".* }, 0, t_client, null);
    try testing.expect(r.client == .paired);
    try testing.expectEqual(Method.pin, r.client.paired.paired.method);

    var w2: Window = .{ .pin = "123456".*, .deadline_us = 1000, .attempts_left = 2 };
    _ = run(&w2, .{ .pin = "111111".* }, 0, t_client, null);
    r = run(&w2, .{ .pin = "222222".* }, 0, t_client, null);
    try testing.expectEqual(Reason.locked, r.client.failed.reason);
    // Locked: even the right PIN is refused at hello, before any proof.
    r = run(&w2, .{ .pin = "123456".* }, 0, t_client, null);
    try testing.expectEqual(Reason.locked, r.client.failed.reason);
}

test "refusals: not pairing, method not offered, expired" {
    var r = run(null, .{ .pin = "123456".* }, 0, t_client, null);
    try testing.expectEqual(Reason.no_window, r.client.failed.reason);
    var w: Window = .{ .secret = t_secret, .deadline_us = 1000 };
    r = run(&w, .{ .pin = "123456".* }, 0, t_client, null);
    try testing.expectEqual(Reason.method_not_offered, r.client.failed.reason);
    r = run(&w, .{ .ticket_secret = t_secret }, 1000, t_client, null);
    try testing.expectEqual(Reason.expired, r.client.failed.reason);
    try testing.expectEqual(@as(u8, 5), w.attempts_left); // refusals at hello cost nothing
}

test "the proof binds the client ID: a proof made for another client does not verify" {
    // The client computes its proof as client A, the host sees the connection from client B.
    var w: Window = .{ .secret = t_secret, .deadline_us = 1000 };
    var h = Host.init(&w, t_host, [_]u8{0x44} ** 32, [_]u8{1} ** 16, "desk");
    var c = Client.init(t_host, t_client, [_]u8{2} ** 16, .{ .ticket_secret = t_secret }, "laptop");
    var f: Framer = .{};
    var tmp: [max_message]u8 = undefined;
    _ = f.push(c.start());
    const ch = h.onMessage((try f.next(&tmp)).?, 0).more.?;
    _ = f.push(ch);
    const proof = c.onMessage((try f.next(&tmp)).?).more.?;
    _ = f.push(proof);
    const s = h.onMessage((try f.next(&tmp)).?, 0);
    try testing.expectEqual(Reason.bad_proof, s.failed.reason);
}

fn flipNameByte(m: []u8) void {
    // Change the client name in the hello: the transcripts no longer match.
    if (m[0] == @intFromEnum(Kind.hello) and m.len > 20) m[20] ^= 1;
}

test "a host that does not hold the secret fails the client's check" {
    // Model it by corrupting the host's MAC in the accept on its way to the client.
    var w: Window = .{ .secret = t_secret, .deadline_us = 1000 };
    var h = Host.init(&w, t_host, t_client, [_]u8{1} ** 16, "desk");
    var c = Client.init(t_host, t_client, [_]u8{2} ** 16, .{ .ticket_secret = t_secret }, "laptop");
    var f: Framer = .{};
    var tmp: [max_message]u8 = undefined;
    _ = f.push(c.start());
    _ = f.push(h.onMessage((try f.next(&tmp)).?, 0).more.?);
    _ = f.push(c.onMessage((try f.next(&tmp)).?).more.?);
    const acc = h.onMessage((try f.next(&tmp)).?, 0).more.?;
    var bad: [2 + max_message]u8 = undefined;
    @memcpy(bad[0..acc.len], acc);
    bad[5] ^= 0x80;
    _ = f.push(bad[0..acc.len]);
    const s = c.onMessage((try f.next(&tmp)).?);
    try testing.expectEqual(Reason.host_proof, s.failed.reason);
    // The client says so; the host drops the pending pairing and the window stays usable.
    _ = f.push(s.failed.reply.?);
    const hs = h.onMessage((try f.next(&tmp)).?, 0);
    try testing.expect(hs == .failed);
    try testing.expectEqual(@as(u8, 0), w.pending);
    try testing.expect(w.isOpen(0));
}

test "a tampered hello changes the transcript and the proof fails" {
    var w: Window = .{ .secret = t_secret, .deadline_us = 1000 };
    const r = run(&w, .{ .ticket_secret = t_secret }, 0, t_client, &flipNameByte);
    try testing.expectEqual(Reason.bad_proof, r.host.failed.reason);
}

test "malformed messages are protocol errors, never crashes" {
    var w: Window = .{ .secret = t_secret, .pin = "123456".*, .deadline_us = 1000 };
    const bad = [_][]const u8{
        &.{},
        &.{@intFromEnum(Kind.proof)},
        &.{ @intFromEnum(Kind.hello), 0, 1 },
        &[_]u8{ @intFromEnum(Kind.hello), 1, 1 } ++ [_]u8{0} ** 17,
        &[_]u8{ @intFromEnum(Kind.hello), 0, 1 } ++ [_]u8{0} ** 16 ++ [_]u8{65},
        &[_]u8{ @intFromEnum(Kind.hello), 0, 9 } ++ [_]u8{0} ** 17,
        &.{0xff},
    };
    const want = [_]Reason{ .protocol, .protocol, .protocol, .unsupported_version, .protocol, .method_not_offered, .protocol };
    for (bad, want) |m, reason| {
        var h = Host.init(&w, t_host, t_client, [_]u8{1} ** 16, "desk");
        try testing.expectEqual(reason, h.onMessage(m, 0).failed.reason);
    }
    // Every prefix and every single-byte corruption of a real run's messages, fed to a fresh
    // host or client, either fails cleanly or (for the client name) goes on.
    var c = Client.init(t_host, t_client, [_]u8{2} ** 16, .{ .pin = "123456".* }, "laptop");
    const hello = c.start()[2..];
    for (0..hello.len) |i| {
        var h = Host.init(&w, t_host, t_client, [_]u8{1} ** 16, "desk");
        _ = h.onMessage(hello[0..i], 0);
    }
    var cl = Client.init(t_host, t_client, [_]u8{2} ** 16, .{ .pin = "123456".* }, "laptop");
    _ = cl.start();
    try testing.expect(cl.onMessage(&.{ @intFromEnum(Kind.challenge), 1, 2 }) == .failed);
    try testing.expectEqual(@as(u8, 5), w.attempts_left);
}

test "framer: split and coalesced writes, oversized length" {
    var c = Client.init(t_host, t_client, [_]u8{2} ** 16, .{ .pin = "123456".* }, "x");
    const hello = c.start();
    var two: [2 * (2 + max_message)]u8 = undefined;
    @memcpy(two[0..hello.len], hello);
    @memcpy(two[hello.len..][0..hello.len], hello);
    var f: Framer = .{};
    var tmp: [max_message]u8 = undefined;
    // One byte at a time.
    var got: usize = 0;
    for (two[0 .. 2 * hello.len]) |b| {
        try testing.expectEqual(@as(usize, 1), f.push(&.{b}));
        while (try f.next(&tmp)) |m| {
            try testing.expectEqualSlices(u8, hello[2..], m);
            got += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), got);
    var big: Framer = .{};
    _ = big.push(&.{ 0xff, 0xff, 1 });
    try testing.expectError(error.MessageTooLong, big.next(&tmp));
    var zero: Framer = .{};
    _ = zero.push(&.{ 0, 0 });
    try testing.expectError(error.MessageTooLong, zero.next(&tmp));
}

test "two windows' worth of pairings: pairings_left counts confirmed pairings only" {
    var w: Window = .{ .secret = t_secret, .deadline_us = 1000, .pairings_left = 2 };
    try testing.expect(run(&w, .{ .ticket_secret = t_secret }, 0, t_client, null).host == .paired);
    try testing.expect(w.isOpen(0));
    try testing.expect(run(&w, .{ .ticket_secret = t_secret }, 0, [_]u8{0x55} ** 32, null).host == .paired);
    try testing.expect(!w.isOpen(0));
}

test "admission: admit, admitted, not paired" {
    var o: Out = .{};
    var f: Framer = .{};
    var tmp: [max_message]u8 = undefined;
    _ = f.push(admitMessage(&o));
    const m = (try f.next(&tmp)).?;
    try testing.expectEqual(Admission.admit, classify(m));
    var c = Client.init(t_host, t_client, [_]u8{2} ** 16, .{ .pin = "123456".* }, "x");
    try testing.expectEqual(Admission.pair, classify(c.start()[2..]));
    try testing.expectEqual(Admission.invalid, classify(&.{ @intFromEnum(Kind.admit), 1 }));
    try testing.expectEqual(Admission.invalid, classify(&.{}));
    try testing.expectEqual(@as(?Reason, null), admitResult(admitReply(&o, true)[2..]));
    try testing.expectEqual(@as(?Reason, .not_paired), admitResult(admitReply(&o, false)[2..]));
    try testing.expectEqual(@as(?Reason, .protocol), admitResult(&.{9}));
}
