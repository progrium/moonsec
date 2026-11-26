//! The web client's side of lossless tiles (app/web.zig): the tile layer's per-present
//! ops flattened into extern structs JavaScript reads (web/src/core.ts `tilePresent`),
//! and the decoder configs waiting for their first presented frame.
//!
//! Why the wait: natively the decode stage configures the decoder and calls
//! `ClientSession.decoderConfigured` (which configures, and so clears, the tile layer)
//! right before decoding the config's first frame, and frames present in that order. In
//! the browser, WebCodecs decodes asynchronously: when the core hands out the first frame
//! of a new config, frames of the old one may still be inside the decoder. So the config
//! is recorded with its first frame's id and applied at the first present at or after it,
//! the same order of events the native client sees.
//!
//! Sans-I/O and free of the wasm imports, so the native app tests cover it.
const std = @import("std");
const core = @import("core");
const wire = @import("wire.zig");

const Update = core.refine.client.Update;

/// A pointer into wasm memory (u32 on wasm32; usize so the native tests build).
pub const Ptr = usize;

/// One op (`core.refine.client.Op`), web/src/core.ts `TileOp`.
pub const TileOp = extern struct {
    pub const clear_all: u32 = 0;
    pub const clear: u32 = 1;
    pub const put: u32 = 2;

    kind: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    _pad: u32 = 0,
    /// put: RGBA pixels, rows `w * 4` bytes, `len` bytes; else 0.
    pixels: Ptr = 0,
    len: Ptr = 0,
};

/// A present's update (`core.refine.client.Update`), web/src/core.ts `TileUpdate`.
pub const TilesOut = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    visible: u32 = 0,
    n_ops: u32 = 0,
    ops: Ptr = 0,
};

/// The ops of `u` into `ops` (reused between presents) and the header into `out`. The
/// pixel pointers point into the layer's buffers: valid until its next `present`.
pub fn flatten(gpa: std.mem.Allocator, ops: *std.ArrayList(TileOp), u: Update, out: *TilesOut) !void {
    ops.clearRetainingCapacity();
    try ops.ensureTotalCapacity(gpa, u.ops.len);
    for (u.ops) |op| ops.appendAssumeCapacity(switch (op) {
        .clear_all => .{ .kind = TileOp.clear_all, .x = 0, .y = 0, .w = u.width, .h = u.height },
        .clear => |r| .{ .kind = TileOp.clear, .x = r.x, .y = r.y, .w = r.w, .h = r.h },
        .put => |p| .{ .kind = TileOp.put, .x = p.rect.x, .y = p.rect.y, .w = p.rect.w, .h = p.rect.h, .pixels = @intFromPtr(p.pixels.ptr), .len = p.pixels.len },
    });
    out.* = .{
        .width = u.width,
        .height = u.height,
        .visible = @intFromBool(u.visible),
        .n_ops = @intCast(ops.items.len),
        .ops = @intFromPtr(ops.items.ptr),
    };
}

/// Decoder configs handed out with a frame (`takeDecoderConfig`) and not yet presented.
pub const PendingConfigs = struct {
    const cap = 4;
    first: [cap]u32 = undefined,
    configs: [cap]wire.Config = undefined,
    len: usize = 0,

    fn same(a: wire.Config, b: wire.Config) bool {
        return a.sameStream(b) and a.epoch == b.epoch;
    }

    /// `c` applies from frame `first` on. The session asks again for every frame until
    /// `decoderConfigured`: a repeat of the newest one is dropped.
    pub fn push(q: *PendingConfigs, first: u32, c: wire.Config) void {
        if (q.len > 0 and same(q.configs[q.len - 1], c)) return;
        if (q.len == cap) {
            // Never presented: the newer ones supersede it.
            std.mem.copyForwards(u32, q.first[0 .. cap - 1], q.first[1..cap]);
            std.mem.copyForwards(wire.Config, q.configs[0 .. cap - 1], q.configs[1..cap]);
            q.len -= 1;
        }
        q.first[q.len] = first;
        q.configs[q.len] = c;
        q.len += 1;
    }

    /// The oldest config due at presented frame `id` (call until null), or null.
    pub fn due(q: *PendingConfigs, id: u32) ?wire.Config {
        if (q.len == 0 or core.proto.seqBefore(id, q.first[0])) return null;
        const c = q.configs[0];
        std.mem.copyForwards(u32, q.first[0 .. q.len - 1], q.first[1..q.len]);
        std.mem.copyForwards(wire.Config, q.configs[0 .. q.len - 1], q.configs[1..q.len]);
        q.len -= 1;
        return c;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "flatten: clear_all covers the layer, puts point at their pixels" {
    var ops: std.ArrayList(TileOp) = .empty;
    defer ops.deinit(testing.allocator);
    const px = [_]u8{ 1, 2, 3, 255 } ** (2 * 3);
    const in = [_]core.refine.client.Op{
        .clear_all,
        .{ .clear = .{ .x = 64, .y = 0, .w = 64, .h = 64 } },
        .{ .put = .{ .rect = .{ .x = 128, .y = 64, .w = 2, .h = 3 }, .pixels = &px } },
    };
    var out: TilesOut = .{};
    try flatten(testing.allocator, &ops, .{ .width = 200, .height = 100, .ops = &in, .visible = true }, &out);
    try testing.expectEqual(@as(u32, 3), out.n_ops);
    try testing.expectEqual(@as(u32, 1), out.visible);
    const got: [*]const TileOp = @ptrFromInt(out.ops);
    try testing.expectEqual(TileOp{ .kind = TileOp.clear_all, .x = 0, .y = 0, .w = 200, .h = 100 }, got[0]);
    try testing.expectEqual(TileOp{ .kind = TileOp.clear, .x = 64, .y = 0, .w = 64, .h = 64 }, got[1]);
    try testing.expectEqual(TileOp.put, got[2].kind);
    try testing.expectEqual(@as(Ptr, px.len), got[2].len);
    const p: [*]const u8 = @ptrFromInt(got[2].pixels);
    try testing.expectEqualSlices(u8, &px, p[0..got[2].len]);
    // Hidden, no ops.
    try flatten(testing.allocator, &ops, .{ .width = 200, .height = 100, .ops = &.{}, .visible = false }, &out);
    try testing.expectEqual(@as(u32, 0), out.n_ops);
    try testing.expectEqual(@as(u32, 0), out.visible);
}

test "pending configs apply at their first presented frame, in order, once" {
    var q: PendingConfigs = .{};
    const a: wire.Config = .{ .nonce = 1, .codec = .h264, .slices = 1, .fps = 60, .width = 640, .height = 360, .bitrate_bps = 1, .epoch = 1 };
    var b = a;
    b.width = 1280;
    b.height = 720;
    b.epoch = 2;
    q.push(10, a);
    q.push(11, a); // asked again: dropped
    try testing.expectEqual(@as(usize, 1), q.len);
    try testing.expect(q.due(9) == null); // an older frame still in the decoder
    try testing.expectEqual(@as(u32, 640), q.due(10).?.width);
    try testing.expect(q.due(10) == null);
    // Two configs before either presented (the first's frames all failed).
    q.push(20, a);
    q.push(25, b);
    try testing.expect(q.due(19) == null);
    try testing.expectEqual(@as(u32, 640), q.due(26).?.width);
    try testing.expectEqual(@as(u32, 1280), q.due(26).?.width);
    try testing.expect(q.due(26) == null);
    // Across the id wrap.
    q.push(0xffff_fffe, a);
    try testing.expect(q.due(0xffff_fffd) == null);
    try testing.expect(q.due(1) != null);
    // Full: the oldest goes.
    for (0..6) |i| {
        var c = a;
        c.epoch = @intCast(10 + i);
        q.push(@intCast(100 + i), c);
    }
    try testing.expectEqual(@as(usize, 4), q.len);
    try testing.expectEqual(@as(u32, 12), q.due(200).?.epoch);
}

test "a host engine's tiles reach the page's ops in RGBA, pixel exact" {
    const refine = core.refine;
    const gpa = testing.allocator;
    const w: u32 = 100; // two cells across, the second 36 wide
    const h: u32 = 64;
    var e = try refine.Engine.init(gpa, .{ .tile_after = 2 }, w, h, 3);
    defer e.deinit();
    var peer = refine.Peer.init(gpa, .{ .burst_bytes = 1 << 20 });
    defer peer.deinit();
    var l = refine.Layer.init(gpa, .{ .order = .rgba });
    defer l.deinit();
    try l.configure(3, w, h);
    // What the host captures: bgra8.
    const px = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(px);
    for (0..w * h) |i| {
        const v: u32 = @intCast(i);
        px[i * 4 ..][0..4].* = .{ @truncate(v), @truncate(v >> 3), @truncate(v >> 6), 255 };
    }
    var ops: std.ArrayList(TileOp) = .empty;
    defer ops.deinit(gpa);
    var out: TilesOut = .{};
    var puts: u32 = 0;
    var cleared_all = false;
    var id: u32 = 0;
    var now: i64 = 0;
    while (id < 20) : (id += 1) {
        now += 16_667;
        e.capture(if (id == 0) null else &.{});
        e.commit(id);
        var want: [8]u32 = undefined;
        for (want[0..e.wanted(&want)]) |c| {
            const r = e.grid.cellRect(c);
            e.offer(c, px[(r.y * w + r.x) * 4 ..], w * 4);
        }
        var buf: [1200]u8 = undefined;
        if (e.damageMessage(id, &buf)) |m| l.onRefine(@intFromEnum(core.proto.RefineKind.damage), m);
        var round: usize = 0;
        while (peer.next(&e, .{ .now = now, .ok = true, .target_bps = 50e6 }, round, &buf)) |b| {
            round += b.len;
            l.onRefine(@intFromEnum(core.proto.RefineKind.tile_piece), b);
        }
        try flatten(gpa, &ops, l.present(id), &out);
        try testing.expectEqual(w, out.width);
        const got: [*]const TileOp = @ptrFromInt(out.ops);
        for (got[0..out.n_ops]) |op| switch (op.kind) {
            TileOp.clear_all => cleared_all = true,
            TileOp.put => {
                try testing.expect(cleared_all);
                try testing.expect(out.visible == 1);
                try testing.expectEqual(@as(Ptr, op.w * op.h * 4), op.len);
                const p: [*]const u8 = @ptrFromInt(op.pixels);
                for (0..op.h) |y| for (0..op.w) |x| {
                    const s = px[((op.y + y) * w + op.x + x) * 4 ..][0..4];
                    const d = p[(y * op.w + x) * 4 ..][0..4];
                    try testing.expectEqualSlices(u8, &.{ s[2], s[1], s[0], 255 }, d);
                };
                puts += 1;
            },
            else => {},
        };
    }
    try testing.expectEqual(@as(u32, 2), puts);
}
