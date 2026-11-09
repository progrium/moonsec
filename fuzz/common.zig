//! Shared pieces for the fuzz harnesses: the seed builder, the allocation bound and the
//! wrapper that turns a harness into a `std.testing.fuzz` test.
//!
//! A harness is `fn (gpa: std.mem.Allocator, s: *Smith) anyerror!void`. It draws every
//! input from `s`, so the same function runs under the fuzzer (`zig build fuzz --fuzz`),
//! on its seed corpus in a plain test run, and on one saved input in `fuzz-repro`.
const std = @import("std");
const builtin = @import("builtin");

pub const Smith = std.testing.Smith;
pub const Harness = fn (gpa: std.mem.Allocator, s: *Smith) anyerror!void;

/// Builds one input in the byte format `Smith` reads when it replays an input (the
/// format the fuzzer saves crashes in): `int` is 8 bytes little-endian, `slice` is a u32
/// length then the bytes, `eos` is one byte, `bytes` is raw.
pub const Seed = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    /// For `Smith.value` of an int, bool or enum (signed ints are their bit pattern).
    /// Not for `valueRangeAtMost` on signed ints, which Smith stores offset from the minimum.
    pub fn int(s: *Seed, v: anytype) void {
        const T = @TypeOf(v);
        const x: u64 = switch (@typeInfo(T)) {
            .int => |i| @as(std.meta.Int(.unsigned, i.bits), @bitCast(v)),
            .comptime_int => v,
            .bool => @intFromBool(v),
            .@"enum" => @intFromEnum(v),
            else => @compileError("unsupported seed value " ++ @typeName(T)),
        };
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, x, .little);
        s.buf.appendSlice(s.gpa, &b) catch @panic("OOM");
    }

    pub fn slice(s: *Seed, b: []const u8) void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(b.len), .little);
        s.buf.appendSlice(s.gpa, &len) catch @panic("OOM");
        s.buf.appendSlice(s.gpa, b) catch @panic("OOM");
    }

    pub fn raw(s: *Seed, b: []const u8) void {
        s.buf.appendSlice(s.gpa, b) catch @panic("OOM");
    }

    pub fn eos(s: *Seed, done: bool) void {
        s.buf.append(s.gpa, @intFromBool(done)) catch @panic("OOM");
    }
};

/// Collects a harness's seeds. Memory comes from a process-lifetime arena: the fuzzer
/// keeps referring to its corpus after `std.testing.fuzz` returns.
pub const Seeds = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,
    pending: std.ArrayList(*Seed) = .empty,

    pub fn new(ss: *Seeds) *Seed {
        const s = ss.arena.create(Seed) catch @panic("OOM");
        s.* = .{ .gpa = ss.arena };
        ss.pending.append(ss.arena, s) catch @panic("OOM");
        return s;
    }

    /// A seed for a harness whose first draw is one `slice`.
    pub fn bytes(ss: *Seeds, b: []const u8) void {
        ss.new().slice(b);
    }

    fn finish(ss: *Seeds) []const []const u8 {
        for (ss.pending.items) |s| ss.list.append(ss.arena, s.buf.items) catch @panic("OOM");
        return ss.list.items;
    }
};

var seed_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// The seed inputs for a harness: what `seeds` builds plus the files committed under
/// fuzz/corpus/<name>/ (saved crashes, kept as regression tests).
pub fn corpus(comptime name: []const u8, comptime seeds: fn (*Seeds) void) []const []const u8 {
    var ss: Seeds = .{ .arena = seed_arena.allocator() };
    seeds(&ss);
    const files = @import("fuzz_corpus");
    if (@hasDecl(files, name)) for (@field(files, name)) |f| ss.list.append(ss.arena, f) catch @panic("OOM");
    return ss.finish();
}

/// Runs `harness` under `std.testing.fuzz` with its corpus. In a plain `zig build test`
/// (no --fuzz) this replays the corpus once, so every seed and saved crash is a test.
pub fn fuzz(comptime name: []const u8, comptime harness: Harness, comptime seeds: fn (*Seeds) void) !void {
    try std.testing.fuzz(std.testing.allocator, harness, .{ .corpus = corpus(name, seeds) });
}

/// Fails the input when live allocations pass `limit`: what one peer can make the
/// receiver hold must stay bounded by its config, whatever it sends.
pub const Bounded = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    exceeded: bool = false,

    pub fn allocator(b: *Bounded) std.mem.Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn take(b: *Bounded, n: usize) bool {
        if (b.live + n > b.limit) {
            b.exceeded = true;
            return false;
        }
        b.live += n;
        b.peak = @max(b.peak, b.live);
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        if (!b.take(len)) return null;
        return b.child.rawAlloc(len, a, ra) orelse {
            b.live -= len;
            return null;
        };
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and !b.take(new_len - mem.len)) return false;
        if (!b.child.rawResize(mem, a, new_len, ra)) {
            if (new_len > mem.len) b.live -= new_len - mem.len;
            return false;
        }
        if (new_len < mem.len) b.live -= mem.len - new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and !b.take(new_len - mem.len)) return null;
        const p = b.child.rawRemap(mem, a, new_len, ra) orelse {
            if (new_len > mem.len) b.live -= new_len - mem.len;
            return null;
        };
        if (new_len < mem.len) b.live -= mem.len - new_len;
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        b.live -= mem.len;
        b.child.rawFree(mem, a, ra);
    }

    pub fn check(b: *const Bounded) error{AllocationBound}!void {
        if (b.exceeded) return error.AllocationBound;
    }
};

pub fn expect(ok: bool) error{CheckFailed}!void {
    if (!ok) return error.CheckFailed;
}

pub fn expectEqual(a: anytype, b: @TypeOf(a)) error{CheckFailed}!void {
    if (!std.meta.eql(a, b)) return error.CheckFailed;
}

pub fn expectEqualBytes(a: []const u8, b: []const u8) error{CheckFailed}!void {
    if (!std.mem.eql(u8, a, b)) return error.CheckFailed;
}

/// A byte slice of at most `buf.len` from the smith.
pub fn bytes(s: *Smith, buf: []u8) []u8 {
    return buf[0..s.slice(buf)];
}
