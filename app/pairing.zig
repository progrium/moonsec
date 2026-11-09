//! Pairing on a device: the state directory (identity key, paired-device lists), and the
//! pairing exchange and session admission run over any reliable byte stream
//! (spec/pairing-v0.md). The `moonsec pair` commands run these over iroh streams.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const keystore = @import("keystore.zig");

const Io = std.Io;
const pair = core.pair;
const ex = pair.exchange;

/// A reliable, ordered byte stream (an iroh bidirectional stream, or a test pipe).
pub const Stream = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
    /// Reads at least one byte, or returns 0 when the peer finished the stream. Blocks up
    /// to the stream's own timeout (which then fails with an error).
    readFn: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,

    pub fn write(s: Stream, bytes: []const u8) !void {
        return s.writeFn(s.ptr, bytes);
    }
    pub fn read(s: Stream, buf: []u8) !usize {
        return s.readFn(s.ptr, buf);
    }
};

/// The next framed message, or null at end of stream.
pub fn readMessage(s: Stream, f: *ex.Framer, out: *[ex.max_message]u8) !?[]const u8 {
    while (true) {
        if (try f.next(out)) |m| return m;
        const n = try s.read(f.buf[f.len..]);
        if (n == 0) return null;
        f.len += n;
    }
}

pub const Outcome = union(enum) {
    paired: ex.Paired,
    failed: ex.Reason,
};

/// Host side, after the first message (the client's hello) was read from `s`.
/// `now` is the clock the window's deadline uses.
pub fn serveHost(s: Stream, f: *ex.Framer, h: *ex.Host, first: []const u8, nowUs: *const fn () i64) !Outcome {
    var msg_buf: [ex.max_message]u8 = undefined;
    var msg: []const u8 = first;
    errdefer h.abort();
    while (true) {
        const step = h.onMessage(msg, nowUs());
        switch (step) {
            .more => |r| if (r) |b| try s.write(b),
            .paired => |p| {
                if (p.reply) |b| try s.write(b);
                return .{ .paired = p.paired };
            },
            .failed => |x| {
                if (x.reply) |b| s.write(b) catch {};
                return .{ .failed = x.reason };
            },
        }
        msg = (try readMessage(s, f, &msg_buf)) orelse {
            h.abort();
            return .{ .failed = .protocol };
        };
    }
}

/// Client side: runs the whole exchange on `s`.
pub fn runClient(s: Stream, c: *ex.Client) !Outcome {
    var f: ex.Framer = .{};
    var msg_buf: [ex.max_message]u8 = undefined;
    try s.write(c.start());
    while (true) {
        const msg = (try readMessage(s, &f, &msg_buf)) orelse return .{ .failed = .protocol };
        switch (c.onMessage(msg)) {
            .more => |r| if (r) |b| try s.write(b),
            .paired => |p| {
                if (p.reply) |b| try s.write(b);
                return .{ .paired = p.paired };
            },
            .failed => |x| {
                if (x.reply) |b| s.write(b) catch {};
                return .{ .failed = x.reason };
            },
        }
    }
}

/// Client side of admission: null if the host admitted this device, else the reason.
pub fn requestAdmission(s: Stream) !?ex.Reason {
    var o: ex.Out = .{};
    try s.write(ex.admitMessage(&o));
    var f: ex.Framer = .{};
    var msg_buf: [ex.max_message]u8 = undefined;
    const msg = (try readMessage(s, &f, &msg_buf)) orelse return .protocol;
    return ex.admitResult(msg);
}

pub fn reasonText(r: ex.Reason) []const u8 {
    return switch (r) {
        .no_window => "the host is not pairing right now; start `moonsec pair host` there",
        .method_not_offered => "the host is not offering this pairing method",
        .bad_proof => "wrong PIN or ticket",
        .locked => "too many wrong attempts; start pairing again on the host",
        .expired => "the pairing window on the host has closed",
        .unsupported_version => "the host runs an incompatible pairing version",
        .protocol => "the pairing exchange broke off",
        .host_proof => "the host could not prove it holds the secret",
        .not_paired => "this device is not paired with the host; run `moonsec pair client`",
        _ => "unknown reason",
    };
}

// --- state directory ------------------------------------------------------------------

pub const List = enum {
    /// Host side: the allowlist of clients that may start sessions.
    clients,
    /// Client side: hosts this device paired with, and their addresses.
    hosts,

    fn fileName(l: List) []const u8 {
        return switch (l) {
            .clients => "paired-clients",
            .hosts => "paired-hosts",
        };
    }
};

/// A device's state directory: `identity.key` (through `FileKeyStore`), `paired-clients`,
/// `paired-hosts`.
pub const State = struct {
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    files: keystore.FileKeyStore,

    /// Opens (creating, 0700 on POSIX) the state directory at `path`. On POSIX it refuses a
    /// directory that group or others can write: whoever can write it can swap
    /// `paired-clients` (and so admit their own device) or the identity key.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !State {
        const perms: Io.File.Permissions = if (comptime Io.File.Permissions.has_executable_bit) .fromMode(0o700) else .default_dir;
        _ = try Io.Dir.cwd().createDirPathStatus(io, path, perms);
        var dir = try Io.Dir.cwd().openDir(io, path, .{});
        errdefer dir.close(io);
        if (comptime Io.File.Permissions.has_executable_bit) {
            const st = try dir.stat(io);
            if (st.permissions.toMode() & 0o022 != 0) return error.InsecurePermissions;
        }
        return .{ .gpa = gpa, .io = io, .dir = dir, .files = .{ .io = io, .dir = dir } };
    }

    pub fn close(self: *State) void {
        self.dir.close(self.io);
    }

    pub fn keyStore(self: *State) keystore.KeyStore {
        return self.files.keyStore();
    }

    pub fn identity(self: *State) !keystore.Identity {
        return keystore.loadOrCreateIdentity(self.keyStore(), self.io);
    }

    /// The list, or an empty one if the file does not exist yet.
    pub fn loadList(self: *State, which: List) !pair.Allowlist {
        const text = self.dir.readFileAlloc(self.io, which.fileName(), self.gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return .init(self.gpa),
            else => return e,
        };
        defer self.gpa.free(text);
        var line: usize = 0;
        return pair.Allowlist.parse(self.gpa, text, &line) catch |e| {
            std.debug.print("moonsec: {s} line {d} is malformed\n", .{ which.fileName(), line });
            return e;
        };
    }

    pub fn saveList(self: *State, which: List, list: *const pair.Allowlist) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        try list.write(&aw.writer);
        // Private (0600 on POSIX): the lists say which devices this one trusts.
        try keystore.writeFileAtomic(self.io, self.dir, which.fileName(), aw.written(), true);
    }
};

/// The default state directory: `$MOONSEC_STATE_DIR`, else the per-user config directory
/// (`$XDG_CONFIG_HOME/moonsec` or `~/.config/moonsec` on Linux, `~/Library/Application
/// Support/moonsec` on macOS, `%APPDATA%\moonsec` on Windows).
pub fn defaultStateDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("MOONSEC_STATE_DIR")) |d| return gpa.dupe(u8, d);
    switch (builtin.os.tag) {
        .windows => if (env.get("APPDATA")) |d| return std.fs.path.join(gpa, &.{ d, "moonsec" }),
        .macos => if (env.get("HOME")) |h| return std.fs.path.join(gpa, &.{ h, "Library", "Application Support", "moonsec" }),
        else => {
            if (env.get("XDG_CONFIG_HOME")) |d| if (d.len > 0) return std.fs.path.join(gpa, &.{ d, "moonsec" });
            if (env.get("HOME")) |h| return std.fs.path.join(gpa, &.{ h, ".config", "moonsec" });
        },
    }
    return error.NoStateDir;
}

// --- tests -------------------------------------------------------------------------

const testing = std.testing;

/// One direction of an in-memory stream.
const Pipe = struct {
    buf: [4096]u8 = undefined,
    q: Io.Queue(u8) = undefined,

    fn init(p: *Pipe) void {
        p.q = .init(&p.buf);
    }
};

const End = struct {
    rx: *Pipe,
    tx: *Pipe,

    fn stream(e: *End) Stream {
        return .{ .ptr = e, .writeFn = write, .readFn = read };
    }
    fn write(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const e: *End = @ptrCast(@alignCast(ptr));
        try e.tx.q.putAll(testing.io, bytes);
    }
    fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const e: *End = @ptrCast(@alignCast(ptr));
        return e.rx.q.get(testing.io, buf, 1) catch |err| switch (err) {
            error.Closed => 0,
            else => err,
        };
    }
    fn finish(e: *End) void {
        e.tx.q.close(testing.io);
    }
};

fn zeroClock() i64 {
    return 0;
}

const host_id: pair.Id = [_]u8{0x11} ** 32;
const client_id: pair.Id = [_]u8{0x22} ** 32;

fn hostSide(end: *End, w: *ex.Window, out: *Outcome) anyerror!void {
    defer end.finish();
    var f: ex.Framer = .{};
    var mb: [ex.max_message]u8 = undefined;
    const first = (try readMessage(end.stream(), &f, &mb)) orelse return error.NoHello;
    var first_copy: [ex.max_message]u8 = undefined;
    @memcpy(first_copy[0..first.len], first);
    switch (ex.classify(first)) {
        .pair => {
            var h = ex.Host.init(w, host_id, client_id, [_]u8{3} ** 16, [_]u8{5} ** 32, "desk");
            out.* = try serveHost(end.stream(), &f, &h, first_copy[0..first.len], &zeroClock);
        },
        .admit => {
            var o: ex.Out = .{};
            try end.stream().write(ex.admitReply(&o, false));
            out.* = .{ .failed = .not_paired };
        },
        .invalid => return error.Invalid,
    }
}

fn pipePair(a: *Pipe, b: *Pipe) [2]End {
    a.init();
    b.init();
    return .{ .{ .rx = a, .tx = b }, .{ .rx = b, .tx = a } };
}

test "the exchange over a byte stream: PIN pairs, then admission is refused for a stranger" {
    var a: Pipe = .{};
    var b: Pipe = .{};
    var ends = pipePair(&a, &b);
    var w: ex.Window = .{ .pin = "424242".*, .deadline_us = 1 };
    var host_out: Outcome = undefined;
    var task = try testing.io.concurrent(hostSide, .{ &ends[0], &w, &host_out });
    var c = ex.Client.init(host_id, client_id, [_]u8{4} ** 16, [_]u8{6} ** 32, .{ .pin = "424242".* }, "laptop");
    const r = try runClient(ends[1].stream(), &c);
    ends[1].finish();
    try task.await(testing.io);
    try testing.expectEqualStrings("desk", r.paired.name());
    try testing.expectEqualStrings("laptop", host_out.paired.name());

    var a2: Pipe = .{};
    var b2: Pipe = .{};
    var ends2 = pipePair(&a2, &b2);
    var task2 = try testing.io.concurrent(hostSide, .{ &ends2[0], &w, &host_out });
    const why = try requestAdmission(ends2[1].stream());
    ends2[1].finish();
    try task2.await(testing.io);
    try testing.expectEqual(@as(?ex.Reason, .not_paired), why);
}

test "the exchange over a byte stream: a wrong PIN fails on both sides" {
    var a: Pipe = .{};
    var b: Pipe = .{};
    var ends = pipePair(&a, &b);
    var w: ex.Window = .{ .pin = "424242".*, .deadline_us = 1 };
    var host_out: Outcome = undefined;
    var task = try testing.io.concurrent(hostSide, .{ &ends[0], &w, &host_out });
    var c = ex.Client.init(host_id, client_id, [_]u8{4} ** 16, [_]u8{6} ** 32, .{ .pin = "000000".* }, "laptop");
    const r = try runClient(ends[1].stream(), &c);
    ends[1].finish();
    try task.await(testing.io);
    try testing.expectEqual(ex.Reason.bad_proof, r.failed);
    try testing.expectEqual(ex.Reason.bad_proof, host_out.failed);
    try testing.expectEqual(@as(u8, 4), w.attempts_left);
}

test "state directory: identity and both lists persist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = pb[0..try tmp.dir.realPath(testing.io, &pb)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state" });
    defer testing.allocator.free(path);
    var st = try State.open(testing.allocator, testing.io, path);
    defer st.close();
    const id1 = try st.identity();
    try testing.expect(id1.created);
    var l = try st.loadList(.clients);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.len());
    try l.put(.{ .id = client_id, .paired_unix_s = 7, .name = "laptop" });
    try st.saveList(.clients, &l);

    var st2 = try State.open(testing.allocator, testing.io, path);
    defer st2.close();
    const id2 = try st2.identity();
    try testing.expect(!id2.created);
    try testing.expectEqual(id1.id, id2.id);
    var l2 = try st2.loadList(.clients);
    defer l2.deinit();
    try testing.expect(l2.contains(&client_id));
    var h = try st2.loadList(.hosts);
    defer h.deinit();
    try testing.expectEqual(@as(usize, 0), h.len());
}

test "state directory: lists are private, a group-writable directory is refused" {
    if (comptime !Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = pb[0..try tmp.dir.realPath(testing.io, &pb)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state" });
    defer testing.allocator.free(path);
    {
        var st = try State.open(testing.allocator, testing.io, path);
        defer st.close();
        var l = try st.loadList(.clients);
        defer l.deinit();
        try l.put(.{ .id = client_id, .paired_unix_s = 7, .name = "laptop" });
        try st.saveList(.clients, &l);
        const fst = try st.dir.statFile(testing.io, "paired-clients", .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), fst.permissions.toMode() & 0o777);
    }
    try tmp.dir.setFilePermissions(testing.io, "state", .fromMode(0o770), .{});
    try testing.expectError(error.InsecurePermissions, State.open(testing.allocator, testing.io, path));
    try tmp.dir.setFilePermissions(testing.io, "state", .fromMode(0o750), .{});
    var st = try State.open(testing.allocator, testing.io, path);
    st.close();
}

test "default state directory" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("MOONSEC_STATE_DIR", "/x/y");
    const d = try defaultStateDir(testing.allocator, &env);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("/x/y", d);
}
