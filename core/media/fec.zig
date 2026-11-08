//! Systematic Reed-Solomon erasure code over GF(2^8) for the media FEC layer.
//!
//! A block has `k` data shards and `m` parity shards (`k + m <= 256`), all the
//! same length. Any `k` of the `n = k + m` shards recover every data shard.
//! The packetizer pads the last data shard of a frame to the shard length.
//!
//! The parity rows come from a Cauchy matrix, scaled so that the first parity
//! shard is the plain XOR of the data shards (cheap single-loss recovery).
//! Every square submatrix of a Cauchy matrix is invertible, which is what makes
//! "any k of n" hold. Decoding inverts only the e×e submatrix for the e lost
//! data shards, with the closed-form Cauchy inverse, so it needs no heap and no
//! Gaussian elimination.
//!
//! Pure and allocation-free: the caller owns every buffer. Coefficients are
//! computed on the fly, so a `Codec` is two integers.

const std = @import("std");

pub const max_shards = 256;

pub const Error = error{
    /// k must be at least 1 and k + m at most 256.
    InvalidShardCount,
    /// The slice of shards does not have k (data), m (parity) or n entries.
    WrongShardCount,
    /// Shards in one block differ in length.
    ShardSizeMismatch,
    /// Fewer than k shards are present; the block cannot be recovered.
    TooFewShards,
};

pub const Codec = struct {
    k: u16,
    m: u16,

    pub fn init(k: usize, m: usize) Error!Codec {
        if (k == 0 or k + m > max_shards) return error.InvalidShardCount;
        return .{ .k = @intCast(k), .m = @intCast(m) };
    }

    pub fn n(self: Codec) usize {
        return @as(usize, self.k) + self.m;
    }

    /// Coefficient of data shard `j` in parity shard `i`.
    pub fn coefficient(self: Codec, i: usize, j: usize) u8 {
        return gf.mul(cauchy(self.k, i, j), colScale(self.k, j));
    }

    /// Fill `parity` (m shards) from `data` (k shards). All shards must have
    /// the same length.
    pub fn encode(self: Codec, data: []const []const u8, parity: []const []u8) Error!void {
        if (data.len != self.k or parity.len != self.m) return error.WrongShardCount;
        const len = data[0].len;
        for (data) |d| if (d.len != len) return error.ShardSizeMismatch;
        for (parity) |p| if (p.len != len) return error.ShardSizeMismatch;

        var coefs: [group][max_shards]u8 = undefined;
        var o: usize = 0;
        while (o < parity.len) : (o += group) {
            const g = @min(group, parity.len - o);
            for (0..g) |gi| for (0..data.len) |j| {
                coefs[gi][j] = self.coefficient(o + gi, j);
            };
            combine(parity[o..][0..g], data, &coefs);
        }
    }

    /// Rebuild every missing data shard in place. `shards` holds all n shards
    /// (data first, then parity) and `present[i]` says whether shard i arrived.
    /// Missing data shards are overwritten; parity shards are only read, and
    /// missing ones stay as they are (call `encode` to regenerate them).
    pub fn reconstruct(self: Codec, shards: []const []u8, present: []const bool) Error!void {
        const k: usize = self.k;
        const nn = self.n();
        if (shards.len != nn or present.len != nn) return error.WrongShardCount;
        const len = shards[0].len;
        for (shards) |s| if (s.len != len) return error.ShardSizeMismatch;

        // Lost data shards (E) and the parity shards that replace them (P).
        var lost: [max_shards]u8 = undefined;
        var e: usize = 0;
        for (0..k) |j| if (!present[j]) {
            lost[e] = @intCast(j);
            e += 1;
        };
        if (e == 0) return;
        var xs: [max_shards]u8 = undefined; // Cauchy x of each parity shard used
        var p: usize = 0;
        for (0..self.m) |i| {
            if (p == e) break;
            if (present[k + i]) {
                xs[p] = @intCast(k + i);
                p += 1;
            }
        }
        if (p < e) return error.TooFewShards;

        // Cauchy points: parity row i is x = k + i, data column j is y = j.
        // The e×e matrix A[r][c] = 1/(X_r + Y_c), X = xs, Y = lost, has the
        // closed-form inverse B[c][r] = a[r]·b[c] / (X_r + Y_c).
        var a: [max_shards]u8 = undefined;
        var b: [max_shards]u8 = undefined;
        for (0..e) |r| {
            var num: u8 = 1;
            var den: u8 = 1;
            for (0..e) |t| {
                num = gf.mul(num, xs[r] ^ lost[t]);
                if (t != r) den = gf.mul(den, xs[r] ^ xs[t]);
            }
            a[r] = gf.div(num, den);
        }
        for (0..e) |c| {
            var num: u8 = 1;
            var den: u8 = 1;
            for (0..e) |t| {
                num = gf.mul(num, xs[t] ^ lost[c]);
                if (t != c) den = gf.mul(den, lost[c] ^ lost[t]);
            }
            // Fold in the column scale: G = C·diag(s), so G⁻¹ = diag(1/s)·C⁻¹.
            b[c] = gf.div(num, gf.mul(den, colScale(self.k, lost[c])));
        }

        // Lost shard c is a combination of the e parity shards and the k − e
        // surviving data shards l:
        //   d_c = Σ_r Bg[c][r]·par_r + Σ_l (Σ_r Bg[c][r]·G[r][l])·d_l
        // With S(y) = Σ_r a_r/(X_r + y), partial fractions collapse the inner
        // sum to b_c·s_l·(S(Y_c) + S(y_l))/(Y_c + y_l), so all coefficients
        // cost O(e·k) instead of O(e²·k).
        var s_at: [max_shards]u8 = undefined; // S(y) for every data column y
        for (0..k) |y| {
            var acc: u8 = 0;
            for (0..e) |r| acc ^= gf.div(a[r], xs[r] ^ @as(u8, @intCast(y)));
            s_at[y] = acc;
        }

        var ins: [max_shards][]const u8 = undefined;
        for (0..e) |r| ins[r] = shards[xs[r]];
        var n_in = e;
        for (0..k) |l| if (present[l]) {
            ins[n_in] = shards[l];
            n_in += 1;
        };

        var outs: [group][]u8 = undefined;
        var coefs: [group][max_shards]u8 = undefined;
        var c0: usize = 0;
        while (c0 < e) : (c0 += group) {
            const g = @min(group, e - c0);
            for (0..g) |gi| {
                const c = c0 + gi;
                const yc = lost[c];
                outs[gi] = shards[yc];
                for (0..e) |r| coefs[gi][r] = gf.div(gf.mul(a[r], b[c]), xs[r] ^ yc);
                var col = e;
                for (0..k) |l| if (present[l]) {
                    const yl: u8 = @intCast(l);
                    const t = gf.div(s_at[yc] ^ s_at[l], yc ^ yl);
                    coefs[gi][col] = gf.mul(b[c], gf.mul(colScale(self.k, l), t));
                    col += 1;
                };
            }
            combine(outs[0..g], ins[0..n_in], &coefs);
        }
    }
};

/// Outputs computed per pass over the inputs.
const group = 4;

/// outs[o] = Σ_i coefs[o][i]·ins[i] for up to `group` outputs at once, so
/// each input chunk is loaded once and accumulators stay in registers.
fn combine(outs: []const []u8, ins: []const []const u8, coefs: *const [group][max_shards]u8) void {
    switch (outs.len) {
        inline 1...group => |g| combineN(g, outs[0..g], ins, coefs),
        else => unreachable,
    }
}

fn combineN(comptime g: usize, outs: *const [g][]u8, ins: []const []const u8, coefs: *const [group][max_shards]u8) void {
    const len = outs[0].len;
    var i: usize = 0;
    if (comptime have_shuffle) {
        const W = if (avx2) 32 else 16;
        const V = @Vector(W, u8);
        const mask: V = @splat(0x0F);
        while (i + W <= len) : (i += W) {
            var acc: [g]V = @splat(@splat(0));
            for (ins, 0..) |in, j| {
                const v: V = in[i..][0..W].*;
                const lo_n = v & mask;
                const hi_n = (v >> @splat(4)) & mask;
                inline for (0..g) |o| {
                    const c = coefs[o][j];
                    if (c == 1) {
                        acc[o] ^= v;
                    } else if (c != 0) {
                        acc[o] ^= lookupW(W, nibble_tables.lo[c], lo_n) ^ lookupW(W, nibble_tables.hi[c], hi_n);
                    }
                }
            }
            inline for (0..g) |o| outs[o][i..][0..W].* = acc[o];
        }
    } else {
        // Portable path: one slice at a time.
        inline for (0..g) |o| {
            for (ins, 0..) |in, j| {
                if (j == 0) mulSlice(outs[o], in, coefs[o][j], .set) else mulSlice(outs[o], in, coefs[o][j], .add);
            }
        }
        return;
    }
    inline for (0..g) |o| {
        for (ins, 0..) |in, j| {
            if (j == 0) tailMul(outs[o][i..], in[i..], coefs[o][j], .set) else tailMul(outs[o][i..], in[i..], coefs[o][j], .add);
        }
    }
}

inline fn lookupW(comptime W: usize, table: [16]u8, idx: @Vector(W, u8)) @Vector(W, u8) {
    const t: V16 = table;
    return if (W == 32) lookup32(std.simd.join(t, t), idx) else lookup16(t, idx);
}

/// Cauchy entry 1/(x_i + y_j) with x_i = k + i and y_j = j.
inline fn cauchy(k: u16, i: usize, j: usize) u8 {
    return gf.inv(@intCast((k + i) ^ j));
}

/// Column scale that turns parity row 0 into all ones: 1/C[0][j] = k ^ j.
inline fn colScale(k: u16, j: usize) u8 {
    return @intCast(k ^ j);
}

const Mode = enum { set, add };

/// dst = c·src (set) or dst ^= c·src (add), bytewise in GF(2^8).
fn mulSlice(dst: []u8, src: []const u8, c: u8, comptime mode: Mode) void {
    std.debug.assert(dst.len == src.len);
    if (c == 0) {
        if (mode == .set) @memset(dst, 0);
        return;
    }
    if (c == 1) {
        if (mode == .set) {
            @memcpy(dst, src);
        } else {
            xorSlice(dst, src);
        }
        return;
    }
    if (comptime have_shuffle) return shuffleMulSlice(dst, src, c, mode);

    // Portable vector path: shift-and-add multiplication, one xtime per bit of c.
    const V = @Vector(vec_len, u8);
    var i: usize = 0;
    while (i + vec_len <= src.len) : (i += vec_len) {
        var v: V = src[i..][0..vec_len].*;
        var acc: V = if (mode == .add) dst[i..][0..vec_len].* else @splat(0);
        var cc = c;
        while (true) {
            if (cc & 1 != 0) acc ^= v;
            cc >>= 1;
            if (cc == 0) break;
            v = (v << @splat(1)) ^ ((v >> @splat(7)) * @as(V, @splat(0x1D)));
        }
        dst[i..][0..vec_len].* = acc;
    }
    tailMul(dst[i..], src[i..], c, mode);
}

fn tailMul(dst: []u8, src: []const u8, c: u8, comptime mode: Mode) void {
    for (dst, src) |*d, s| {
        const prod = gf.mul(c, s);
        d.* = if (mode == .add) d.* ^ prod else prod;
    }
}

fn xorSlice(dst: []u8, src: []const u8) void {
    const V = @Vector(vec_len, u8);
    var i: usize = 0;
    while (i + vec_len <= src.len) : (i += vec_len) {
        const a: V = dst[i..][0..vec_len].*;
        const s: V = src[i..][0..vec_len].*;
        dst[i..][0..vec_len].* = a ^ s;
    }
    for (dst[i..], src[i..]) |*d, s| d.* ^= s;
}

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

// ---------------------------------------------------------------------------
// Table-lookup fast path (pshufb on x86 SSSE3/AVX2, tbl on aarch64 NEON):
// c·v = lo[c][v & 15] ^ hi[c][v >> 4], two 16-entry lookups per byte.

const builtin = @import("builtin");
const arch = builtin.cpu.arch;
const have_shuffle = switch (arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon),
    else => false,
};
const avx2 = arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

const nibble_tables = blk: {
    @setEvalBranchQuota(100_000);
    var lo: [256][16]u8 = undefined;
    var hi: [256][16]u8 = undefined;
    for (0..256) |c| for (0..16) |x| {
        lo[c][x] = gf.mul(c, x);
        hi[c][x] = gf.mul(c, x << 4);
    };
    break :blk .{ .lo = lo, .hi = hi };
};

const V16 = @Vector(16, u8);
const V32 = @Vector(32, u8);

inline fn lookup16(table: V16, idx: V16) V16 {
    return switch (arch) {
        .x86_64 => asm ("pshufb %[idx], %[t]"
            : [t] "=x" (-> V16),
            : [idx] "x" (idx),
              [_] "0" (table),
        ),
        .aarch64 => asm ("tbl %[r].16b, {%[t].16b}, %[idx].16b"
            : [r] "=w" (-> V16),
            : [t] "w" (table),
              [idx] "w" (idx),
        ),
        else => unreachable,
    };
}

inline fn lookup32(table: V32, idx: V32) V32 {
    return asm ("vpshufb %[idx], %[t], %[r]"
        : [r] "=x" (-> V32),
        : [t] "x" (table),
          [idx] "x" (idx),
    );
}

fn shuffleMulSlice(dst: []u8, src: []const u8, c: u8, comptime mode: Mode) void {
    const lo16: V16 = nibble_tables.lo[c];
    const hi16: V16 = nibble_tables.hi[c];
    var i: usize = 0;
    if (avx2) {
        const lo: V32 = std.simd.join(lo16, lo16);
        const hi: V32 = std.simd.join(hi16, hi16);
        const mask: V32 = @splat(0x0F);
        while (i + 32 <= src.len) : (i += 32) {
            const v: V32 = src[i..][0..32].*;
            var prod = lookup32(lo, v & mask) ^ lookup32(hi, (v >> @splat(4)) & mask);
            if (mode == .add) prod ^= @as(V32, dst[i..][0..32].*);
            dst[i..][0..32].* = prod;
        }
    }
    const mask: V16 = @splat(0x0F);
    while (i + 16 <= src.len) : (i += 16) {
        const v: V16 = src[i..][0..16].*;
        var prod = lookup16(lo16, v & mask) ^ lookup16(hi16, v >> @splat(4));
        if (mode == .add) prod ^= @as(V16, dst[i..][0..16].*);
        dst[i..][0..16].* = prod;
    }
    tailMul(dst[i..], src[i..], c, mode);
}

// ---------------------------------------------------------------------------
// GF(2^8) with the polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D), generator 2.

pub const gf = struct {
    const tables = blk: {
        @setEvalBranchQuota(10_000);
        var exp: [512]u8 = undefined;
        var log: [256]u8 = undefined;
        var x: u16 = 1;
        for (0..255) |i| {
            exp[i] = @intCast(x);
            log[x] = @intCast(i);
            x <<= 1;
            if (x & 0x100 != 0) x ^= 0x11D;
        }
        for (255..512) |i| exp[i] = exp[i - 255];
        log[0] = 0; // unused: zero is special-cased
        break :blk .{ .exp = exp, .log = log };
    };

    pub fn mul(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return tables.exp[@as(usize, tables.log[a]) + tables.log[b]];
    }

    pub fn inv(a: u8) u8 {
        std.debug.assert(a != 0);
        return tables.exp[255 - @as(usize, tables.log[a])];
    }

    pub fn div(a: u8, b: u8) u8 {
        std.debug.assert(b != 0);
        if (a == 0) return 0;
        return tables.exp[@as(usize, tables.log[a]) + 255 - tables.log[b]];
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "gf: field identities" {
    for (1..256) |a| {
        const x: u8 = @intCast(a);
        try testing.expectEqual(@as(u8, 1), gf.mul(x, gf.inv(x)));
        try testing.expectEqual(x, gf.div(gf.mul(x, 7), 7));
    }
    // Spot-check against carry-less multiply with reduction.
    for (0..256) |a| for (0..256) |b| {
        var r: u16 = 0;
        var aa: u16 = @intCast(a);
        var bb: u16 = @intCast(b);
        while (bb != 0) : (bb >>= 1) {
            if (bb & 1 != 0) r ^= aa;
            aa <<= 1;
            if (aa & 0x100 != 0) aa ^= 0x11D;
        }
        try testing.expectEqual(@as(u8, @intCast(r)), gf.mul(@intCast(a), @intCast(b)));
    };
}

test "mulSlice matches scalar for every coefficient and odd lengths" {
    var src: [203]u8 = undefined;
    var dst: [203]u8 = undefined;
    var ref: [203]u8 = undefined;
    for (&src, 0..) |*s, i| s.* = @truncate(i * 37 + 11);
    for (0..256) |c| {
        for (&dst, &ref, 0..) |*d, *r, i| {
            d.* = @truncate(i * 5 + c);
            r.* = d.* ^ gf.mul(@intCast(c), src[i]);
        }
        mulSlice(&dst, &src, @intCast(c), .add);
        try testing.expectEqualSlices(u8, &ref, &dst);
        mulSlice(&dst, &src, @intCast(c), .set);
        for (&ref, src) |*r, s| r.* = gf.mul(@intCast(c), s);
        try testing.expectEqualSlices(u8, &ref, &dst);
    }
}

test "first parity shard is XOR of data" {
    const codec = try Codec.init(37, 5);
    for (0..37) |j| try testing.expectEqual(@as(u8, 1), codec.coefficient(0, j));
}

test "init rejects bad shard counts" {
    try testing.expectError(error.InvalidShardCount, Codec.init(0, 4));
    try testing.expectError(error.InvalidShardCount, Codec.init(200, 57));
    _ = try Codec.init(200, 56);
    _ = try Codec.init(1, 0);
    _ = try Codec.init(1, 255);
}

const TestBlock = struct {
    store: []u8,
    shards: [][]u8,
    orig: []u8,

    fn init(alloc: std.mem.Allocator, codec: Codec, len: usize, rng: std.Random) !TestBlock {
        const nn = codec.n();
        const store = try alloc.alloc(u8, nn * len);
        const shards = try alloc.alloc([]u8, nn);
        for (shards, 0..) |*s, i| s.* = store[i * len ..][0..len];
        rng.bytes(store[0 .. codec.k * len]);
        try codec.encode(@ptrCast(shards[0..codec.k]), shards[codec.k..]);
        const orig = try alloc.dupe(u8, store);
        return .{ .store = store, .shards = shards, .orig = orig };
    }

    fn deinit(self: TestBlock, alloc: std.mem.Allocator) void {
        alloc.free(self.store);
        alloc.free(self.shards);
        alloc.free(self.orig);
    }

    /// Scribble over the missing shards, reconstruct, and compare data.
    fn check(self: TestBlock, codec: Codec, present: []const bool) !void {
        const len = self.shards[0].len;
        for (present, 0..) |p, i| if (!p) @memset(self.shards[i], 0xA5);
        try codec.reconstruct(self.shards, present);
        try testing.expectEqualSlices(u8, self.orig[0 .. codec.k * len], self.store[0 .. codec.k * len]);
        @memcpy(self.store, self.orig);
    }
};

test "recovers from every erasure pattern with at least k shards (small codes)" {
    var prng = std.Random.DefaultPrng.init(1);
    const alloc = testing.allocator;
    for (1..7) |k| for (0..6) |m| {
        const codec = try Codec.init(k, m);
        const block = try TestBlock.init(alloc, codec, 67, prng.random());
        defer block.deinit(alloc);
        const nn = codec.n();
        var mask: usize = 0;
        while (mask < (@as(usize, 1) << @intCast(nn))) : (mask += 1) {
            if (@popCount(mask) < k) continue;
            var present: [16]bool = undefined;
            for (0..nn) |i| present[i] = (mask >> @intCast(i)) & 1 != 0;
            try block.check(codec, present[0..nn]);
        }
    };
}

test "fails cleanly with fewer than k shards" {
    var prng = std.Random.DefaultPrng.init(2);
    const alloc = testing.allocator;
    const codec = try Codec.init(4, 2);
    const block = try TestBlock.init(alloc, codec, 32, prng.random());
    defer block.deinit(alloc);
    const present = [_]bool{ false, true, false, true, true, false };
    try testing.expectError(error.TooFewShards, codec.reconstruct(block.shards, &present));
}

test "random erasures on large codes, including k + m = 256" {
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    const alloc = testing.allocator;
    const cases = [_][2]usize{ .{ 10, 3 }, .{ 50, 15 }, .{ 128, 128 }, .{ 200, 56 }, .{ 1, 255 }, .{ 255, 1 } };
    for (cases) |km| {
        const codec = try Codec.init(km[0], km[1]);
        const block = try TestBlock.init(alloc, codec, 1150, rng);
        defer block.deinit(alloc);
        const nn = codec.n();
        for (0..20) |_| {
            // Keep exactly k random shards: the hardest case.
            var order: [max_shards]u8 = undefined;
            for (0..nn) |i| order[i] = @intCast(i);
            rng.shuffle(u8, order[0..nn]);
            var present: [max_shards]bool = @splat(false);
            for (order[0..codec.k]) |i| present[i] = true;
            try block.check(codec, present[0..nn]);
        }
    }
}

test "shape errors" {
    const codec = try Codec.init(2, 1);
    var a: [4]u8 = .{ 1, 2, 3, 4 };
    var b: [3]u8 = .{ 1, 2, 3 };
    var p: [4]u8 = undefined;
    try testing.expectError(error.ShardSizeMismatch, codec.encode(&.{ &a, &b }, &.{&p}));
    try testing.expectError(error.WrongShardCount, codec.encode(&.{&a}, &.{&p}));
}
