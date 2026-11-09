//! The `moonsec` pairing commands, and session admission for `moonsec peer iroh`.
//!
//!   moonsec id [--state-dir D]
//!   moonsec pair host [--state-dir D] [--name N] [--seconds 120] [--pairings 1] [--relay]
//!                     [--pin-only | --qr-only] [--ticket-file F] [--pin-file F] [--qr-svg F]
//!   moonsec pair client (--ticket T | --ticket-file F) [--pin P] [--state-dir D] [--name N] [--relay]
//!   Both pair commands also take --relay-url URL [--relay-ca PEM] in place of --relay: that
//!   relay only, no n0 relays or discovery (a self-hosted relay; browsers pair through one).
//!   moonsec paired [--state-dir D]
//!   moonsec unpair ID-PREFIX [--state-dir D]
//!   moonsec run pair [--seconds N]      pairing and admission end to end over iroh on loopback
//!
//! `pair host` binds iroh with the device's key, opens a pairing window, and shows a QR
//! ticket (scan, or paste with `--ticket`) and a PIN (type it with the address ticket).
//! `--ticket-file F` writes the QR ticket to F and the address ticket to F.addr.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("app_options");
const core = @import("core");
const pairing = @import("pairing.zig");
const keystore = @import("keystore.zig");
const iroh = if (options.iroh) @import("iroh") else struct {};

const Io = std.Io;
const pair = core.pair;
const ex = pair.exchange;

pub const alpn = "moonsec/0";
/// iroh application error code when a host closes a connection it did not admit.
pub const close_not_paired: u32 = 0x5050;

pub const Args = struct {
    state_dir: []const u8 = "",
    name: []const u8 = "",
    ticket: []const u8 = "",
    pin: []const u8 = "",
    pin_file: []const u8 = "",
    qr_svg: []const u8 = "",
    pairings: u8 = 1,
    pin_only: bool = false,
    qr_only: bool = false,
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    p: Args,
    /// Shared with the session commands.
    ticket_file: []const u8 = "",
    relay: bool = false,
    /// A self-hosted relay (custom-only mode) and its CA's PEM file, as `peer iroh` takes them.
    relay_url: ?[:0]const u8 = null,
    relay_ca: ?[:0]const u8 = null,
    seconds: ?u32 = null,
};

fn openState(c: Ctx) !pairing.State {
    const owned = if (c.p.state_dir.len == 0) try pairing.defaultStateDir(c.gpa, c.env) else null;
    defer if (owned) |o| c.gpa.free(o);
    const path = owned orelse c.p.state_dir;
    return pairing.State.open(c.gpa, c.io, path) catch |e| {
        std.debug.print("moonsec: cannot open state directory {s}: {t}\n", .{ path, e });
        if (e == error.InsecurePermissions) std.debug.print("moonsec: group or others can write it; run `chmod go-w {s}`\n", .{path});
        return e;
    };
}

fn deviceName(c: Ctx, buf: []u8, fallback: []const u8) []const u8 {
    if (c.p.name.len > 0) return c.p.name;
    if (builtin.os.tag == .windows) {
        if (c.env.get("COMPUTERNAME")) |n| return n;
    } else if (builtin.os.tag != .wasi) {
        if (buf.len >= std.posix.HOST_NAME_MAX) {
            if (std.posix.gethostname(buf[0..std.posix.HOST_NAME_MAX])) |n| return n else |_| {}
        }
    }
    return fallback;
}

fn unixNow(io: Io) u64 {
    return @intCast(@max(0, Io.Clock.real.now(io).toSeconds()));
}

var mono_io: Io = undefined;
fn monoNow() i64 {
    return Io.Clock.awake.now(mono_io).toMicroseconds();
}

pub fn cmdId(c: Ctx, w: *Io.Writer) !bool {
    var st = try openState(c);
    defer st.close();
    const ident = try st.identity();
    try w.print("{s}\n", .{&pair.id.toHex(&ident.id)});
    if (ident.created) std.debug.print("moonsec: created a new device key\n", .{});
    return true;
}

pub fn cmdPaired(c: Ctx, w: *Io.Writer) !bool {
    var st = try openState(c);
    defer st.close();
    const ident = try st.identity();
    try w.print("this device: {s}\n", .{&pair.id.toHex(&ident.id)});
    inline for (.{ pairing.List.clients, pairing.List.hosts }) |which| {
        var l = try st.loadList(which);
        defer l.deinit();
        try w.print("{s} ({d}):\n", .{ if (which == .clients) "clients allowed to connect" else "hosts paired with", l.len() });
        for (l.entries.items) |e| try w.print("  {s}  {s}\n", .{ &pair.id.toHex(&e.id), e.name });
    }
    return true;
}

pub fn cmdUnpair(c: Ctx, prefix: []const u8, w: *Io.Writer) !bool {
    var st = try openState(c);
    defer st.close();
    var removed: usize = 0;
    inline for (.{ pairing.List.clients, pairing.List.hosts }) |which| {
        var l = try st.loadList(which);
        defer l.deinit();
        const n = l.removePrefix(prefix);
        if (n > 1) {
            std.debug.print("moonsec: {s} matches {d} devices; give more digits\n", .{ prefix, n });
            return false;
        }
        if (n == 1) {
            try st.saveList(which, &l);
            removed += 1;
        }
    }
    try w.print("{s}\n", .{if (removed > 0) "removed" else "no paired device matches"});
    return removed > 0;
}

// --- over iroh ----------------------------------------------------------------------

const IrohStream = struct {
    s: if (options.iroh) iroh.Stream else void,
    timeout_ms: u32 = 10_000,

    fn stream(self: *IrohStream) pairing.Stream {
        return .{ .ptr = self, .writeFn = write, .readFn = read };
    }
    fn write(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *IrohStream = @ptrCast(@alignCast(ptr));
        try self.s.writeAll(bytes, self.timeout_ms);
    }
    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *IrohStream = @ptrCast(@alignCast(ptr));
        return (try self.s.read(buf, self.timeout_ms)).len;
    }

    /// Finish our side and wait (briefly) for the peer to finish theirs, so the last
    /// message is delivered before the connection closes.
    fn close(self: *IrohStream) void {
        self.s.finish() catch {};
        var junk: [256]u8 = undefined;
        for (0..16) |_| {
            const got = self.s.read(&junk, 2000) catch break;
            if (got.len == 0) break;
        }
        self.s.deinit(0);
    }
};

fn initIroh() !void {
    iroh.init(null, null) catch |e| switch (e) {
        error.Invalid => {}, // already started
        else => {
            std.debug.print("iroh init: {s}\n", .{iroh.lastError()});
            return e;
        },
    };
}

pub fn bind(c: Ctx, secret: *const [32]u8, accept: bool) !iroh.Endpoint {
    try initIroh();
    const ca_pem: ?[:0]u8 = if (c.relay_ca) |path| blk: {
        const text = Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(1 << 20)) catch |e| {
            std.debug.print("moonsec: cannot read --relay-ca {s}: {t}\n", .{ path, e });
            return e;
        };
        defer c.gpa.free(text);
        break :blk try c.gpa.dupeZ(u8, text);
    } else null;
    defer if (ca_pem) |t| c.gpa.free(t);
    const any_relay = c.relay or c.relay_url != null;
    const ep = iroh.Endpoint.bind(.{
        .secret_key = secret,
        .alpn = if (accept) alpn else "",
        .relay_mode = if (c.relay_url != null) .custom_only else if (c.relay) .default else .disabled,
        .relay_urls = if (c.relay_url) |u| u.ptr else null,
        .relay_ca_pem = if (ca_pem) |t| t.ptr else null,
        .bind_addr = if (any_relay) "0.0.0.0:0" else "127.0.0.1:0",
    }) catch |e| {
        std.debug.print("bind: {s}\n", .{iroh.lastError()});
        return e;
    };
    if (any_relay) ep.online(15_000) catch std.debug.print("moonsec: no home relay yet; the ticket may only work on this network\n", .{});
    return ep;
}

fn remoteId(conn: iroh.Conn) !pair.Id {
    var b: [128]u8 = undefined;
    return pair.id.parseHex(try conn.remoteId(&b)) orelse error.BadRemoteId;
}

/// Writes a file the host hands to a script (`--ticket-file`, `--pin-file`, `--qr-svg`). The
/// QR ticket, its SVG and the PIN are pairing secrets, so the file is private (0600 on
/// POSIX) and goes through an exclusive, randomly named temporary file in the same
/// directory: another local user can neither read it nor plant a symlink at a guessable
/// temporary name to redirect the write.
fn writeFileAtomic(c: Ctx, path: []const u8, data: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var dir = try Io.Dir.cwd().openDir(c.io, dir_path, .{});
    defer dir.close(c.io);
    try keystore.writeFileAtomic(c.io, dir, std.fs.path.basename(path), data, true);
}

pub fn cmdPairHost(c: Ctx, w: *Io.Writer) !bool {
    if (c.p.pin_only and c.p.qr_only) return error.Usage;
    mono_io = c.io;
    var st = try openState(c);
    defer st.close();
    const ident = try st.identity();
    var clients = try st.loadList(.clients);
    defer clients.deinit();
    var nb: [256]u8 = undefined;
    const name = deviceName(c, &nb, "moonsec host");

    const ep = try bind(c, &ident.secret, true);
    defer ep.deinit();
    var abuf: [4096]u8 = undefined;
    const addr = try ep.ticket(&abuf);

    var rnd: [32]u8 = undefined;
    try c.io.randomSecure(&rnd);
    const pin = while (true) {
        if (pair.pin.fromRandom(rnd[16..32])) |p| break p;
        try c.io.randomSecure(rnd[16..32]);
    };
    const seconds: i64 = c.seconds orelse 120;
    var window: ex.Window = .{
        .secret = if (c.p.pin_only) null else rnd[0..16].*,
        .pin = if (c.p.qr_only) null else pin,
        .deadline_us = monoNow() + seconds * std.time.us_per_s,
        .pairings_left = c.p.pairings,
    };
    const expires = unixNow(c.io) + @as(u64, @intCast(seconds));
    var qbuf: [pair.ticket.max_text]u8 = undefined;
    var tbuf: [pair.ticket.max_text]u8 = undefined;
    const addr_ticket = try (pair.Ticket{ .host_id = ident.id, .addr = addr }).encode(&tbuf);
    const qr_ticket: ?[]u8 = if (window.secret) |s| try (pair.Ticket{ .host_id = ident.id, .secret = s, .expires_unix_s = expires, .addr = addr }).encode(&qbuf) else null;

    try w.print("Pairing {s} ({s}) for {d} s; up to {d} device(s).\n\n", .{ name, &pair.id.short(&ident.id), seconds, c.p.pairings });
    if (qr_ticket) |t| {
        var code: pair.qr.Code = undefined;
        try code.encode(t, .{ .ecc = .low });
        try code.writeText(w, 2);
        try w.print("\nScan the code, or on the other device run:\n  moonsec pair client --ticket {s}\n\n", .{t});
        if (c.p.qr_svg.len > 0) {
            var aw: Io.Writer.Allocating = .init(c.gpa);
            defer aw.deinit();
            try code.writeSvg(&aw.writer, 4);
            try writeFileAtomic(c, c.p.qr_svg, aw.written());
        }
    }
    if (window.pin) |p| {
        try w.print("PIN: {s}\n  moonsec pair client --ticket {s} --pin {s}\n\n", .{ &pair.pin.display(&p), addr_ticket, &p });
    }
    try w.flush();
    if (c.ticket_file.len > 0) {
        var fb: [512]u8 = undefined;
        try writeFileAtomic(c, try std.fmt.bufPrint(&fb, "{s}.addr", .{c.ticket_file}), addr_ticket);
        if (qr_ticket) |t| try writeFileAtomic(c, c.ticket_file, t);
    }
    if (c.p.pin_file.len > 0) if (window.pin) |p| try writeFileAtomic(c, c.p.pin_file, &p);

    var paired: usize = 0;
    while (window.isOpen(monoNow())) {
        const left_ms: u32 = @intCast(@max(1, @divTrunc(window.deadline_us - monoNow(), 1000)));
        const conn = ep.accept(left_ms) catch |e| switch (e) {
            error.Timeout, error.Closed => break,
            else => {
                std.debug.print("accept: {s}\n", .{iroh.lastError()});
                continue;
            },
        };
        defer conn.deinit(0);
        const peer_id = remoteId(conn) catch continue;
        var s: IrohStream = .{ .s = conn.acceptBi(10_000) catch continue };
        defer s.close();
        var f: ex.Framer = .{};
        var mb: [ex.max_message]u8 = undefined;
        const first = (readFirst(s.stream(), &f, &mb) catch continue) orelse continue;
        var nonce: ex.Nonce = undefined;
        try c.io.randomSecure(&nonce);
        switch (ex.classify(first)) {
            .pair => {
                var h = ex.Host.init(&window, ident.id, peer_id, nonce, name);
                const out = pairing.serveHost(s.stream(), &f, &h, first, &monoNow) catch |e| {
                    std.debug.print("pairing with {s}: stream error {t}\n", .{ &pair.id.short(&peer_id), e });
                    continue;
                };
                switch (out) {
                    .paired => |p| {
                        try clients.put(.{ .id = p.peer_id, .paired_unix_s = unixNow(c.io), .name = p.name() });
                        try st.saveList(.clients, &clients);
                        paired += 1;
                        try w.print("paired with {s} ({s}) by {s}\n", .{ p.name(), &pair.id.short(&p.peer_id), if (p.method == .pin) "PIN" else "QR ticket" });
                    },
                    .failed => |why| try w.print("refused {s}: {s} ({d} attempts left)\n", .{ &pair.id.short(&peer_id), pairing.reasonText(why), window.attempts_left }),
                }
                try w.flush();
            },
            .admit => {
                var o: ex.Out = .{};
                s.stream().write(ex.admitReply(&o, false)) catch {};
            },
            .invalid => {},
        }
    }
    try w.print("pairing window closed: {d} device(s) paired\n", .{paired});
    return paired > 0;
}

/// Copies the first message out of the framer's scratch so later reads can't clobber it.
fn readFirst(s: pairing.Stream, f: *ex.Framer, out: *[ex.max_message]u8) !?[]const u8 {
    var tmp: [ex.max_message]u8 = undefined;
    const m = (try pairing.readMessage(s, f, &tmp)) orelse return null;
    @memcpy(out[0..m.len], m);
    return out[0..m.len];
}

fn loadTicketText(c: Ctx, buf: *std.ArrayList(u8)) ![]const u8 {
    if (c.p.ticket.len > 0) return c.p.ticket;
    if (c.ticket_file.len == 0) return error.Usage;
    const t = Io.Dir.cwd().readFileAlloc(c.io, c.ticket_file, c.gpa, .limited(16384)) catch |e| {
        std.debug.print("moonsec: cannot read {s}: {t}\n", .{ c.ticket_file, e });
        return e;
    };
    buf.* = .fromOwnedSlice(t);
    return t;
}

pub fn cmdPairClient(c: Ctx, w: *Io.Writer) !bool {
    var st = try openState(c);
    defer st.close();
    const ident = try st.identity();
    var nb: [256]u8 = undefined;
    const name = deviceName(c, &nb, "moonsec client");
    var tb: std.ArrayList(u8) = .empty;
    defer tb.deinit(c.gpa);
    const text = try loadTicketText(c, &tb);
    var scratch: [pair.ticket.max_binary]u8 = undefined;
    const t = pair.Ticket.decode(text, &scratch) catch |e| {
        std.debug.print("moonsec: not a moonsec pairing ticket ({t})\n", .{e});
        return false;
    };
    if (t.expired(unixNow(c.io))) {
        std.debug.print("moonsec: this ticket has expired; start pairing on the host again\n", .{});
        return false;
    }
    const cred: ex.Credential = if (t.secret) |s| .{ .ticket_secret = s } else blk: {
        const pin = pair.pin.parse(c.p.pin) orelse {
            std.debug.print("moonsec: this ticket has no secret; give the host's PIN with --pin\n", .{});
            return false;
        };
        break :blk .{ .pin = pin };
    };

    const ep = try bind(c, &ident.secret, false);
    defer ep.deinit();
    const addr_z = try c.gpa.dupeZ(u8, t.addr);
    defer c.gpa.free(addr_z);
    const conn = ep.connect(addr_z, alpn, 30_000) catch |e| {
        std.debug.print("connect: {s}\n", .{iroh.lastError()});
        return e;
    };
    defer conn.deinit(0);
    const rid = try remoteId(conn);
    if (!std.mem.eql(u8, &rid, &t.host_id)) {
        std.debug.print("moonsec: the host at that address is not the one in the ticket\n", .{});
        return false;
    }
    var s: IrohStream = .{ .s = try conn.openBi(10_000) };
    defer s.close();
    var nonce: ex.Nonce = undefined;
    try c.io.randomSecure(&nonce);
    var cl = ex.Client.init(t.host_id, ident.id, nonce, cred, name);
    const out = try pairing.runClient(s.stream(), &cl);
    switch (out) {
        .paired => |p| {
            var hosts = try st.loadList(.hosts);
            defer hosts.deinit();
            try hosts.put(.{ .id = t.host_id, .paired_unix_s = unixNow(c.io), .name = p.name(), .addr = t.addr });
            try st.saveList(.hosts, &hosts);
            try w.print("paired with {s} ({s})\n", .{ p.name(), &pair.id.short(&t.host_id) });
            return true;
        },
        .failed => |why| {
            try w.print("pairing failed: {s}", .{pairing.reasonText(why)});
            if (cl.attempts_left) |n| if (why == .bad_proof) try w.print(" ({d} attempts left)", .{n});
            try w.writeByte('\n');
            return false;
        },
    }
}

// --- session admission ------------------------------------------------------------------

/// Host side of `peer iroh host --state-dir`: accepts connections until one comes from a
/// paired client that asks for a session, refusing (and closing) the rest.
pub fn acceptAdmitted(c: Ctx, ep: iroh.Endpoint, clients: *const pair.Allowlist, timeout_ms: u32) !iroh.Conn {
    mono_io = c.io;
    const deadline = monoNow() + @as(i64, timeout_ms) * 1000;
    while (true) {
        const left: i64 = @divTrunc(deadline - monoNow(), 1000);
        if (left <= 0) return error.Timeout;
        const conn = ep.accept(@intCast(left)) catch |e| {
            std.debug.print("accept: {s}\n", .{iroh.lastError()});
            return e;
        };
        const ok = admitOne(conn, clients) catch false;
        if (ok) return conn;
        conn.deinit(close_not_paired);
    }
}

fn admitOne(conn: iroh.Conn, clients: *const pair.Allowlist) !bool {
    const peer_id = try remoteId(conn);
    var s: IrohStream = .{ .s = try conn.acceptBi(5_000) };
    defer s.close();
    var f: ex.Framer = .{};
    var mb: [ex.max_message]u8 = undefined;
    const first = (try pairing.readMessage(s.stream(), &f, &mb)) orelse return false;
    const allowed = ex.classify(first) == .admit and clients.contains(&peer_id);
    var o: ex.Out = .{};
    try s.stream().write(ex.admitReply(&o, allowed));
    if (!allowed) std.debug.print("refused {s}: not on the allowlist\n", .{&pair.id.short(&peer_id)});
    return allowed;
}

/// Client side: checks that the host is one this device paired with, then asks it for a
/// session. Returns false (with a message) if either fails.
pub fn requestSession(conn: iroh.Conn, hosts: *const pair.Allowlist) !bool {
    const rid = try remoteId(conn);
    if (!hosts.contains(&rid)) {
        std.debug.print("moonsec: host {s} is not paired with this device; run `moonsec pair client`\n", .{&pair.id.short(&rid)});
        return false;
    }
    var s: IrohStream = .{ .s = try conn.openBi(5_000) };
    defer s.close();
    if (try pairing.requestAdmission(s.stream())) |why| {
        std.debug.print("moonsec: host refused the session: {s}\n", .{pairing.reasonText(why)});
        return false;
    }
    return true;
}

pub fn openStateFor(c: Ctx) !pairing.State {
    return openState(c);
}

// --- end to end -------------------------------------------------------------------------

fn spawnSelf(io: Io, argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit });
}

fn runSelf(io: Io, argv: []const []const u8) !bool {
    var ch = try spawnSelf(io, argv);
    return switch (try ch.wait(io)) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn waitFile(c: Ctx, path: []const u8, buf: []u8) ![]u8 {
    for (0..1200) |_| {
        if (Io.Dir.cwd().readFile(c.io, path, buf)) |d| {
            if (d.len > 0) return d;
        } else |_| {}
        c.io.sleep(.fromMilliseconds(25), .awake) catch {};
    }
    return error.Timeout;
}

/// `moonsec run pair`: pairs two clients with a host (QR ticket; wrong then right PIN),
/// then runs a session from a paired client after the host has refused an unpaired one.
pub fn runPairE2E(c: Ctx, self_exe: []const u8) !bool {
    std.debug.print("== pairing and admission over iroh, loopback, relays off ==\n", .{});
    var bb: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&bb, ".moonsec-pair-{d}", .{Io.Clock.awake.now(c.io).toNanoseconds()});
    try Io.Dir.cwd().createDirPath(c.io, base);
    defer Io.Dir.cwd().deleteTree(c.io, base) catch {};
    var pbuf: [8][256]u8 = undefined;
    const host_dir = try std.fmt.bufPrint(&pbuf[0], "{s}/host", .{base});
    const c1 = try std.fmt.bufPrint(&pbuf[1], "{s}/qr-client", .{base});
    const c2 = try std.fmt.bufPrint(&pbuf[2], "{s}/pin-client", .{base});
    const c3 = try std.fmt.bufPrint(&pbuf[3], "{s}/stranger", .{base});
    const tfile = try std.fmt.bufPrint(&pbuf[4], "{s}/ticket", .{base});
    const tfile_addr = try std.fmt.bufPrint(&pbuf[5], "{s}/ticket.addr", .{base});
    const pin_file = try std.fmt.bufPrint(&pbuf[6], "{s}/pin", .{base});
    const sess_ticket = try std.fmt.bufPrint(&pbuf[7], "{s}/session-ticket", .{base});

    var ok = true;
    var host = try spawnSelf(c.io, &.{ self_exe, "pair", "host", "--state-dir", host_dir, "--name", "desk", "--ticket-file", tfile, "--pin-file", pin_file, "--pairings", "2", "--seconds", "60" });
    var host_waited = false;
    defer if (!host_waited) {
        host.kill(c.io);
    };
    var pin_buf: [16]u8 = undefined;
    const pin = try waitFile(c, pin_file, &pin_buf);
    var junk: [8192]u8 = undefined;
    _ = try waitFile(c, tfile, &junk);
    var wrong: [6]u8 = pin[0..6].*;
    wrong[5] = '0' + (wrong[5] - '0' + 1) % 10;

    const step = struct {
        fn f(name: []const u8, want: bool, got: bool, all: *bool) void {
            std.debug.print("  {s}: {s}\n", .{ name, if (got == want) "ok" else "FAIL" });
            if (got != want) all.* = false;
        }
    }.f;
    step("pair by QR ticket", true, try runSelf(c.io, &.{ self_exe, "pair", "client", "--state-dir", c1, "--name", "qr-laptop", "--ticket-file", tfile }), &ok);
    step("wrong PIN is refused", false, try runSelf(c.io, &.{ self_exe, "pair", "client", "--state-dir", c2, "--name", "pin-laptop", "--ticket-file", tfile_addr, "--pin", &wrong }), &ok);
    step("pair by PIN", true, try runSelf(c.io, &.{ self_exe, "pair", "client", "--state-dir", c2, "--name", "pin-laptop", "--ticket-file", tfile_addr, "--pin", pin[0..6] }), &ok);
    const host_ok = switch (try host.wait(c.io)) {
        .exited => |code| code == 0,
        else => false,
    };
    host_waited = true;
    step("host closes its window after two pairings", true, host_ok, &ok);

    // The host's allowlist has both clients; each client lists the host.
    {
        var st = try pairing.State.open(c.gpa, c.io, host_dir);
        defer st.close();
        var l = try st.loadList(.clients);
        defer l.deinit();
        step("host allowlist has both clients", true, l.len() == 2, &ok);
    }
    // The stranger has a device key and believes it is paired (copies the QR client's
    // host list) but the host never paired it.
    {
        var st = try pairing.State.open(c.gpa, c.io, c3);
        defer st.close();
        _ = try st.identity();
        var st1 = try pairing.State.open(c.gpa, c.io, c1);
        defer st1.close();
        var hosts = try st1.loadList(.hosts);
        defer hosts.deinit();
        try st.saveList(.hosts, &hosts);
    }

    const secs = c.seconds orelse 3;
    var sb: [16]u8 = undefined;
    const secs_s = try std.fmt.bufPrint(&sb, "{d}", .{secs});
    var sess_host = try spawnSelf(c.io, &.{ self_exe, "peer", "iroh", "host", "--state-dir", host_dir, "--ticket-file", sess_ticket, "--seconds", secs_s });
    var sess_waited = false;
    defer if (!sess_waited) {
        sess_host.kill(c.io);
    };
    _ = try waitFile(c, sess_ticket, &junk);
    step("unpaired client is refused a session", false, try runSelf(c.io, &.{ self_exe, "peer", "iroh", "client", "--state-dir", c3, "--ticket-file", sess_ticket, "--seconds", secs_s }), &ok);
    step("paired client streams", true, try runSelf(c.io, &.{ self_exe, "peer", "iroh", "client", "--state-dir", c1, "--ticket-file", sess_ticket, "--seconds", secs_s }), &ok);
    const sess_ok = switch (try sess_host.wait(c.io)) {
        .exited => |code| code == 0,
        else => false,
    };
    sess_waited = true;
    step("host streamed to the paired client", true, sess_ok, &ok);
    std.debug.print("pairing over iroh: {s}\n\n", .{if (ok) "pass" else "FAIL"});
    return ok;
}
