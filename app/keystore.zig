//! Where a device keeps its secret key (spec/pairing-v0.md, "Key storage").
//!
//! `KeyStore` is the interface; `FileKeyStore` keeps each key in its own file in the state
//! directory, readable only by the user on POSIX (0600, and loading refuses a key file
//! that group or others can read, as ssh does). On Windows the file inherits the state
//! directory's ACL, which under %APPDATA% is the user's. DPAPI (Windows) and Keychain
//! (macOS) stores come later behind the same interface.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const Io = std.Io;
const pair = core.pair;

pub const Error = error{
    /// The stored key is not a key file this version understands.
    Corrupt,
    /// POSIX: the key file is readable by group or others.
    InsecurePermissions,
    Io,
};

pub const KeyStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Fills `out` and returns true, or returns false if there is no key by that name.
        load: *const fn (ptr: *anyopaque, name: []const u8, out: *[32]u8) Error!bool,
        store: *const fn (ptr: *anyopaque, name: []const u8, key: *const [32]u8) Error!void,
        remove: *const fn (ptr: *anyopaque, name: []const u8) Error!void,
    };

    pub fn load(ks: KeyStore, name: []const u8, out: *[32]u8) Error!bool {
        return ks.vtable.load(ks.ptr, name, out);
    }
    pub fn store(ks: KeyStore, name: []const u8, key: *const [32]u8) Error!void {
        return ks.vtable.store(ks.ptr, name, key);
    }
    pub fn remove(ks: KeyStore, name: []const u8) Error!void {
        return ks.vtable.remove(ks.ptr, name);
    }
};

/// A device's identity: the secret key iroh binds with, and the endpoint ID it gives.
pub const Identity = struct {
    secret: [32]u8,
    id: pair.Id,
    /// True when this call generated the key.
    created: bool = false,
};

pub const identity_name = "identity";

/// Loads the device key, or generates and stores one on first use.
pub fn loadOrCreateIdentity(ks: KeyStore, io: Io) (Error || Io.RandomSecureError)!Identity {
    var secret: [32]u8 = undefined;
    if (try ks.load(identity_name, &secret)) return .{ .secret = secret, .id = pair.id.publicFromSecret(&secret) };
    try io.randomSecure(&secret);
    try ks.store(identity_name, &secret);
    return .{ .secret = secret, .id = pair.id.publicFromSecret(&secret), .created = true };
}

const file_header = "moonsec secret key v0\n";

/// One file per key, `<name>.key`, in `dir`: the header line, then 64 hex digits.
pub const FileKeyStore = struct {
    io: Io,
    dir: Io.Dir,

    pub fn keyStore(self: *FileKeyStore) KeyStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: KeyStore.VTable = .{ .load = load, .store = store, .remove = remove };

    fn fileName(name: []const u8, buf: []u8) Error![]const u8 {
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.Io;
        return std.fmt.bufPrint(buf, "{s}.key", .{name}) catch error.Io;
    }

    fn load(ptr: *anyopaque, name: []const u8, out: *[32]u8) Error!bool {
        const self: *FileKeyStore = @ptrCast(@alignCast(ptr));
        var nb: [80]u8 = undefined;
        const fname = try fileName(name, &nb);
        var f = self.dir.openFile(self.io, fname, .{}) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return error.Io,
        };
        defer f.close(self.io);
        if (comptime Io.File.Permissions.has_executable_bit) {
            const st = f.stat(self.io) catch return error.Io;
            if (st.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
        }
        var buf: [file_header.len + 64 + 2]u8 = undefined;
        var r = f.reader(self.io, &.{});
        const n = r.interface.readSliceShort(&buf) catch return error.Io;
        const text = buf[0..n];
        if (!std.mem.startsWith(u8, text, file_header)) return error.Corrupt;
        const hex = std.mem.trimEnd(u8, text[file_header.len..], "\r\n");
        if (hex.len != 64) return error.Corrupt;
        _ = std.fmt.hexToBytes(out, hex) catch return error.Corrupt;
        return true;
    }

    fn store(ptr: *anyopaque, name: []const u8, key: *const [32]u8) Error!void {
        const self: *FileKeyStore = @ptrCast(@alignCast(ptr));
        var nb: [80]u8 = undefined;
        const fname = try fileName(name, &nb);
        var text: [file_header.len + 65]u8 = undefined;
        @memcpy(text[0..file_header.len], file_header);
        text[file_header.len..][0..64].* = std.fmt.bytesToHex(key.*, .lower);
        text[text.len - 1] = '\n';
        writeFileAtomic(self.io, self.dir, fname, &text, true) catch return error.Io;
    }

    fn remove(ptr: *anyopaque, name: []const u8) Error!void {
        const self: *FileKeyStore = @ptrCast(@alignCast(ptr));
        var nb: [80]u8 = undefined;
        const fname = try fileName(name, &nb);
        self.dir.deleteFile(self.io, fname) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return error.Io,
        };
    }
};

/// Keys in memory, for tests and for throwaway identities.
pub const MemoryKeyStore = struct {
    names: [4][32]u8 = undefined,
    name_lens: [4]u8 = @splat(0),
    keys: [4][32]u8 = undefined,

    pub fn keyStore(self: *MemoryKeyStore) KeyStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: KeyStore.VTable = .{ .load = load, .store = store, .remove = remove };

    fn find(self: *MemoryKeyStore, name: []const u8) ?usize {
        for (0..4) |i| if (self.name_lens[i] > 0 and std.mem.eql(u8, self.names[i][0..self.name_lens[i]], name)) return i;
        return null;
    }

    fn load(ptr: *anyopaque, name: []const u8, out: *[32]u8) Error!bool {
        const self: *MemoryKeyStore = @ptrCast(@alignCast(ptr));
        const i = self.find(name) orelse return false;
        out.* = self.keys[i];
        return true;
    }

    fn store(ptr: *anyopaque, name: []const u8, key: *const [32]u8) Error!void {
        const self: *MemoryKeyStore = @ptrCast(@alignCast(ptr));
        if (name.len == 0 or name.len > 32) return error.Io;
        const i = self.find(name) orelse (std.mem.indexOfScalar(u8, &self.name_lens, 0) orelse return error.Io);
        @memcpy(self.names[i][0..name.len], name);
        self.name_lens[i] = @intCast(name.len);
        self.keys[i] = key.*;
    }

    fn remove(ptr: *anyopaque, name: []const u8) Error!void {
        const self: *MemoryKeyStore = @ptrCast(@alignCast(ptr));
        if (self.find(name)) |i| self.name_lens[i] = 0;
    }
};

/// Writes `data` to `dir/name` through a temporary file and a rename, so readers see the
/// old file or the new one, never a torn one. `private`: 0600 on POSIX.
pub fn writeFileAtomic(io: Io, dir: Io.Dir, name: []const u8, data: []const u8, private: bool) !void {
    var tb: [256]u8 = undefined;
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.bufPrint(&tb, ".{s}.{x}.tmp", .{ name, std.mem.readInt(u32, &rnd, .little) });
    const perms: Io.File.Permissions = if (private and comptime Io.File.Permissions.has_executable_bit) .fromMode(0o600) else .default_file;
    {
        var f = try dir.createFile(io, tmp, .{ .exclusive = true, .permissions = perms });
        defer f.close(io);
        errdefer dir.deleteFile(io, tmp) catch {};
        try f.writeStreamingAll(io, data);
        f.sync(io) catch {};
    }
    errdefer dir.deleteFile(io, tmp) catch {};
    try Io.Dir.rename(dir, tmp, dir, name, io);
}

const testing = std.testing;

test "memory store: identity is created once, then loaded" {
    var m: MemoryKeyStore = .{};
    const a = try loadOrCreateIdentity(m.keyStore(), testing.io);
    try testing.expect(a.created);
    const b = try loadOrCreateIdentity(m.keyStore(), testing.io);
    try testing.expect(!b.created);
    try testing.expectEqual(a.secret, b.secret);
    try testing.expectEqual(pair.id.publicFromSecret(&a.secret), b.id);
    try m.keyStore().remove(identity_name);
    const c = try loadOrCreateIdentity(m.keyStore(), testing.io);
    try testing.expect(c.created);
    try testing.expect(!std.mem.eql(u8, &a.secret, &c.secret));
}

test "file store: round trip, private permissions, refuses a readable or corrupt key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs: FileKeyStore = .{ .io = testing.io, .dir = tmp.dir };
    const ks = fs.keyStore();
    var k: [32]u8 = undefined;
    try testing.expect(!try ks.load("identity", &k));
    const a = try loadOrCreateIdentity(ks, testing.io);
    try testing.expect(a.created);
    const b = try loadOrCreateIdentity(ks, testing.io);
    try testing.expect(!b.created);
    try testing.expectEqual(a.id, b.id);
    if (comptime Io.File.Permissions.has_executable_bit) {
        const st = try tmp.dir.statFile(testing.io, "identity.key", .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
        // Group-readable: refuse it.
        var f = try tmp.dir.openFile(testing.io, "identity.key", .{});
        try f.setPermissions(testing.io, .fromMode(0o640));
        f.close(testing.io);
        try testing.expectError(error.InsecurePermissions, ks.load("identity", &k));
        f = try tmp.dir.openFile(testing.io, "identity.key", .{});
        try f.setPermissions(testing.io, .fromMode(0o600));
        f.close(testing.io);
    }
    try testing.expect(try ks.load("identity", &k));
    try testing.expectEqual(a.secret, k);
    try writeFileAtomic(testing.io, tmp.dir, "identity.key", "moonsec secret key v0\nnothex\n", true);
    try testing.expectError(error.Corrupt, ks.load("identity", &k));
    try writeFileAtomic(testing.io, tmp.dir, "identity.key", "garbage", true);
    try testing.expectError(error.Corrupt, ks.load("identity", &k));
    try ks.remove("identity");
    try ks.remove("identity");
    try testing.expect(!try ks.load("identity", &k));
    try testing.expectError(error.Io, ks.load("../escape", &k));
}
