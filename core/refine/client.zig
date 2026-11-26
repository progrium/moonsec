//! Client side of lossless tiles: `Layer` reassembles tile pieces, keeps the host's
//! frame damage, and at each present decides which tiles show, as ops for the presenter's
//! tile layer (`Update`). The rule (spec/refine-v0.md, "Validity"): a tile of cell c with
//! `since` s shows at presented frame p only while
//!   1. p is at or after s, and
//!   2. no frame in (s, p] damaged c.
//! So a tile disappears in the same present that shows the video changing under it.
//!
//! Damage comes per frame (exact, each message repeating the two frames before) or, in
//! answer to a resync, as a union over a span of frames. A union can't tell whether a
//! cell's damage came before or after a tile's `since` inside its span: such a tile is
//! dropped and reported (`held` false) so the host sends it again.
//!
//! If damage for a presented frame is missing, the layer is hidden (the video alone is
//! always right) and a resync is asked; if it doesn't come within `resync_frames`
//! presents, the layer is cleared and the host is asked to send everything again.
//!
//! Sans-I/O; `init` allocates the grid's state, reassembly and the ready queue once.
const std = @import("std");
const damage = @import("../damage/root.zig");
const proto = @import("../proto/root.zig");
const qoi = @import("qoi.zig");
const wire = @import("wire.zig");

const Rect = damage.Rect;

pub const Op = union(enum) {
    /// Everything transparent (also: the layer's size may have changed).
    clear_all,
    /// This rectangle transparent.
    clear: Rect,
    /// Opaque pixels at `rect`, rows `rect.w * 4` bytes, in the layer's order.
    put: struct { rect: Rect, pixels: []const u8 },
};

pub const Update = struct {
    width: u32,
    height: u32,
    ops: []const Op,
    /// Draw the layer over this present's video.
    visible: bool,
};

pub const Config = struct {
    order: qoi.Order = .bgra,
    /// Presents with a damage gap before giving up on a resync and clearing the layer.
    resync_frames: u32 = 30,
    /// Ask again for a resync every this many presents while it doesn't come.
    resync_every: u32 = 8,
    /// Tiles complete but waiting for their `since` to be presented, bytes at most.
    ready_bytes: usize = 8 << 20,
    /// Tiles put per present at most (the rest wait for the next).
    puts_per_present: u32 = 64,
};

pub const Stats = struct {
    pieces: u64 = 0,
    tiles: u64 = 0,
    shown: u64 = 0,
    /// Tiles cleared by damage the same present the video changed.
    invalidated: u64 = 0,
    /// Tiles complete but stale (their cell changed before they could show).
    stale: u64 = 0,
    ambiguous: u64 = 0,
    gaps: u64 = 0,
    resyncs_asked: u64 = 0,
    clears: u64 = 0,
    malformed: u64 = 0,
    wrong_epoch: u64 = 0,
    decode_errors: u64 = 0,
    hidden_presents: u64 = 0,
};

const n_assembly = 16;
const ring = 64;

const Assembly = struct {
    active: bool = false,
    cell: u16 = 0,
    since: u32 = 0,
    total: u16 = 0,
    pieces: u8 = 0,
    got: u16 = 0,
    age: u64 = 0,
    buf: [wire.max_tile_len]u8 = undefined,
};

const Ready = struct { cell: u16, since: u32, data: []u8 };

fn before(a: u32, b: u32) bool {
    return proto.seqBefore(a, b);
}

pub const Layer = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    epoch: ?u32 = null,
    width: u32 = 0,
    height: u32 = 0,
    cols: u32 = 0,
    cells: u32 = 0,
    // Per cell.
    shown: []bool = &.{},
    shown_since: []u32 = &.{},
    /// The newest damage applied (presented) for the cell: frames (lo-1, hi] — lo == hi
    /// for an exact one.
    dmg_hi: []u32 = &.{},
    dmg_lo: []u32 = &.{},
    has_dmg: []bool = &.{},
    asm_: []Assembly = &.{},
    asm_age: u64 = 0,
    ready: std.ArrayList(Ready) = .empty,
    ready_used: usize = 0,
    /// Exact per-frame damage, by frame id mod `ring`.
    exact_id: [ring]u32 = undefined,
    exact_ok: [ring]bool = @splat(false),
    exact_bits: []u8 = &.{},
    /// Union damage waiting for the next present.
    unions: std.ArrayList(struct { frame: u32, span: u32, all: bool, bits: []u8 }) = .empty,
    /// Every frame up to here has had its damage applied (null before the first present).
    checked_to: ?u32 = null,
    /// The host sent damage at least once: it streams tiles. Until then (a host without
    /// tiles, or one that turned them down) the layer stays hidden and never asks for a
    /// resync.
    heard: bool = false,
    gap_presents: u32 = 0,
    clear_pending: bool = true,
    // Tile acks to send.
    acks: std.ArrayList(wire.AckEntry) = .empty,
    reset_pending: bool = false,
    resync_pending: bool = false,
    // Per present.
    ops: std.ArrayList(Op) = .empty,
    pixels: std.ArrayList(u8) = .empty,
    puts: std.ArrayList(struct { rect: Rect, off: usize }) = .empty,
    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, cfg: Config) Layer {
        return .{ .gpa = gpa, .cfg = cfg };
    }

    pub fn deinit(l: *Layer) void {
        l.freeGrid();
        l.ready.deinit(l.gpa);
        l.unions.deinit(l.gpa);
        l.acks.deinit(l.gpa);
        l.ops.deinit(l.gpa);
        l.pixels.deinit(l.gpa);
        l.puts.deinit(l.gpa);
        if (l.asm_.len > 0) l.gpa.free(l.asm_);
    }

    fn freeGrid(l: *Layer) void {
        if (l.cells == 0) return;
        l.gpa.free(l.shown);
        l.gpa.free(l.shown_since);
        l.gpa.free(l.dmg_hi);
        l.gpa.free(l.dmg_lo);
        l.gpa.free(l.has_dmg);
        l.gpa.free(l.exact_bits);
        l.cells = 0;
    }

    fn dropReady(l: *Layer) void {
        for (l.ready.items) |r| l.gpa.free(r.data);
        l.ready.clearRetainingCapacity();
        l.ready_used = 0;
        for (l.unions.items) |u| l.gpa.free(u.bits);
        l.unions.clearRetainingCapacity();
    }

    fn bytes(l: *const Layer) usize {
        return wire.Damage.bytesFor(l.cells);
    }

    /// The stream config the next presented frames belong to (from the decoder's config).
    /// A new epoch or size clears the layer.
    pub fn configure(l: *Layer, epoch: u32, width: u32, height: u32) !void {
        if (l.epoch == epoch and l.width == width and l.height == height) return;
        if (l.asm_.len == 0) {
            l.asm_ = try l.gpa.alloc(Assembly, n_assembly);
            for (l.asm_) |*a| a.active = false;
        }
        for (l.asm_) |*a| a.active = false;
        l.dropReady();
        l.freeGrid();
        l.epoch = epoch;
        l.width = width;
        l.height = height;
        l.cols = std.math.divCeil(u32, width, wire.cell_size) catch unreachable;
        const rows = std.math.divCeil(u32, height, wire.cell_size) catch unreachable;
        const n = l.cols * rows;
        l.shown = try l.gpa.alloc(bool, n);
        l.shown_since = try l.gpa.alloc(u32, n);
        l.dmg_hi = try l.gpa.alloc(u32, n);
        l.dmg_lo = try l.gpa.alloc(u32, n);
        l.has_dmg = try l.gpa.alloc(bool, n);
        l.exact_bits = try l.gpa.alloc(u8, wire.Damage.bytesFor(n) * ring);
        l.cells = n;
        @memset(l.shown, false);
        @memset(l.has_dmg, false);
        l.exact_ok = @splat(false);
        l.checked_to = null;
        l.gap_presents = 0;
        l.clear_pending = true;
        l.acks.clearRetainingCapacity();
        l.reset_pending = false;
        l.resync_pending = false;
    }

    fn cellRect(l: *const Layer, c: u32) Rect {
        const x = (c % l.cols) * wire.cell_size;
        const y = (c / l.cols) * wire.cell_size;
        return .{ .x = x, .y = y, .w = @min(wire.cell_size, l.width - x), .h = @min(wire.cell_size, l.height - y) };
    }

    fn ack(l: *Layer, e: wire.AckEntry) void {
        if (l.acks.items.len >= 4 * wire.TileAck.max_entries) return; // the host resends anyway
        l.acks.append(l.gpa, e) catch {};
    }

    // --- receive -----------------------------------------------------------

    /// A refine-stream datagram's payload (after the envelope), by kind.
    pub fn onRefine(l: *Layer, kind: u8, payload: []const u8) void {
        switch (@as(proto.RefineKind, @enumFromInt(kind))) {
            .tile_piece => l.onPiece(wire.TilePiece.decode(payload) catch {
                l.stats.malformed += 1;
                return;
            }),
            .damage => {
                if (l.cells == 0) return;
                var maps: [wire.Damage.max_maps][]u8 = undefined;
                var store: [wire.Damage.max_maps][wire.Damage.bytesFor(std.math.maxInt(u16))]u8 = undefined;
                for (&maps, &store) |*m, *s| m.* = s[0..l.bytes()];
                const m = wire.Damage.decode(payload, &maps) catch {
                    l.stats.malformed += 1;
                    return;
                };
                l.heard = true;
                l.onDamage(m);
            },
            _ => {},
        }
    }

    pub fn onPiece(l: *Layer, p: wire.TilePiece) void {
        if (l.epoch == null or p.epoch != l.epoch.? or l.cells == 0) {
            l.stats.wrong_epoch += 1;
            return;
        }
        if (p.cell >= l.cells or p.codec != .qoi) {
            l.stats.malformed += 1;
            return;
        }
        l.stats.pieces += 1;
        // Older than what shows already: a resend that crossed a newer tile.
        if (l.shown[p.cell] and !before(l.shown_since[p.cell], p.since)) {
            // Our ack got lost: say it again, once per resend.
            if (l.shown_since[p.cell] == p.since and p.piece == 0) l.ack(.{ .cell = p.cell, .since = p.since });
            return;
        }
        var slot: ?*Assembly = null;
        var oldest: *Assembly = &l.asm_[0];
        for (l.asm_) |*a| {
            if (a.active and a.cell == p.cell and a.since == p.since and a.total == p.total_len and a.pieces == p.pieces) {
                slot = a;
                break;
            }
            if (!a.active or (oldest.active and a.age < oldest.age)) oldest = a;
        }
        const a = slot orelse blk: {
            // A newer tile for the cell replaces an older one in progress.
            for (l.asm_) |*o| if (o.active and o.cell == p.cell and before(o.since, p.since)) {
                o.active = false;
            };
            oldest.* = .{ .active = true, .cell = p.cell, .since = p.since, .total = p.total_len, .pieces = p.pieces, .got = 0 };
            break :blk oldest;
        };
        l.asm_age += 1;
        a.age = l.asm_age;
        const bit = @as(u16, 1) << @intCast(p.piece);
        if (a.got & bit != 0) return;
        @memcpy(a.buf[@as(usize, p.piece) * wire.piece_max ..][0..p.data.len], p.data);
        a.got |= bit;
        if (a.got != (@as(u32, 1) << @intCast(a.pieces)) - 1) return;
        a.active = false;
        l.complete(a.cell, a.since, a.buf[0..a.total]);
    }

    fn complete(l: *Layer, cell: u16, since: u32, data: []const u8) void {
        l.stats.tiles += 1;
        // One ready tile per cell: the newest.
        var i: usize = 0;
        while (i < l.ready.items.len) {
            const r = l.ready.items[i];
            if (r.cell == cell) {
                if (!before(r.since, since)) {
                    if (r.since == since) l.ack(.{ .cell = cell, .since = since });
                    return;
                }
                l.ready_used -= r.data.len;
                l.gpa.free(r.data);
                _ = l.ready.swapRemove(i);
            } else i += 1;
        }
        while (l.ready_used + data.len > l.cfg.ready_bytes and l.ready.items.len > 0) {
            const r = l.ready.orderedRemove(0);
            l.ready_used -= r.data.len;
            l.gpa.free(r.data);
            l.ack(.{ .cell = r.cell, .since = r.since, .held = false });
        }
        const d = l.gpa.dupe(u8, data) catch return;
        l.ready.append(l.gpa, .{ .cell = cell, .since = since, .data = d }) catch {
            l.gpa.free(d);
            return;
        };
        l.ready_used += d.len;
        l.ack(.{ .cell = cell, .since = since });
    }

    pub fn onDamage(l: *Layer, m: wire.Damage) void {
        if (l.epoch == null or m.epoch != l.epoch.?) {
            l.stats.wrong_epoch += 1;
            return;
        }
        if (m.cells != l.cells) {
            l.stats.malformed += 1;
            return;
        }
        const nb = l.bytes();
        if (m.span > 0) {
            if (l.unions.items.len >= 8) return;
            const bits = l.gpa.alloc(u8, nb) catch return;
            if (m.all) @memset(bits, 0xff) else @memcpy(bits, m.maps[0][0..nb]);
            l.unions.append(l.gpa, .{ .frame = m.frame_id, .span = m.span, .all = m.all, .bits = bits }) catch l.gpa.free(bits);
            return;
        }
        for (m.maps, 0..) |bits, k| {
            const f = m.frame_id -% @as(u32, @intCast(k));
            // Frames already applied need nothing.
            if (l.checked_to) |c| if (!before(c, f)) continue;
            const slot = f % ring;
            l.exact_id[slot] = f;
            l.exact_ok[slot] = true;
            @memcpy(l.exact_bits[slot * nb ..][0..nb], bits[0..nb]);
        }
    }

    // --- present -----------------------------------------------------------

    fn kill(l: *Layer, c: u32) void {
        if (!l.shown[c]) return;
        l.shown[c] = false;
        l.ops.append(l.gpa, .{ .clear = l.cellRect(c) }) catch {};
    }

    /// Exact damage of frame f.
    fn applyExact(l: *Layer, f: u32, bits: []const u8) void {
        var c: u32 = 0;
        while (c < l.cells) : (c += 1) {
            if (!wire.getBit(bits, c)) continue;
            l.dmg_hi[c] = f;
            l.dmg_lo[c] = f;
            l.has_dmg[c] = true;
            if (l.shown[c] and before(l.shown_since[c], f)) {
                l.kill(c);
                l.stats.invalidated += 1;
            }
        }
    }

    /// Union damage of frames (g - span, g].
    fn applyUnion(l: *Layer, g: u32, span: u32, bits: []const u8) void {
        const lo = g -% span +% 1;
        var c: u32 = 0;
        while (c < l.cells) : (c += 1) {
            if (!wire.getBit(bits, c)) continue;
            if (!l.has_dmg[c] or before(l.dmg_hi[c], g)) {
                l.dmg_hi[c] = g;
                l.dmg_lo[c] = lo;
                l.has_dmg[c] = true;
            }
            if (!l.shown[c] or !before(l.shown_since[c], g)) continue;
            const s = l.shown_since[c];
            if (!before(s, lo -% 1)) {
                // Inside the span: maybe still right, but there is no telling.
                l.ack(.{ .cell = @intCast(c), .since = s, .held = false });
                l.stats.ambiguous += 1;
            } else l.stats.invalidated += 1;
            l.kill(c);
        }
    }

    fn clearAll(l: *Layer) void {
        l.ops.append(l.gpa, .clear_all) catch {};
        @memset(l.shown, false);
        @memset(l.has_dmg, false);
        l.stats.clears += 1;
    }

    /// Frame `p` is about to be presented: the ops that bring the layer to what shows with
    /// it. Valid until the next call.
    pub fn present(l: *Layer, p: u32) Update {
        l.ops.clearRetainingCapacity();
        l.pixels.clearRetainingCapacity();
        if (l.cells == 0 or !l.heard) return .{ .width = l.width, .height = l.height, .ops = &.{}, .visible = false };
        if (l.clear_pending) {
            l.clear_pending = false;
            l.clearAll();
        }
        if (l.checked_to == null) l.checked_to = p -% 1;
        // Resync answers: applied at once (conservatively), and they cover their span.
        for (l.unions.items) |u| {
            l.applyUnion(u.frame, u.span, u.bits);
            const c = l.checked_to.?;
            if (!before(c, u.frame -% u.span) and before(c, u.frame)) l.checked_to = u.frame;
            l.gpa.free(u.bits);
        }
        l.unions.clearRetainingCapacity();
        // Walk the frames up to p in order.
        const nb = l.bytes();
        while (before(l.checked_to.?, p)) {
            const f = l.checked_to.? +% 1;
            const slot = f % ring;
            if (!l.exact_ok[slot] or l.exact_id[slot] != f) break;
            l.applyExact(f, l.exact_bits[slot * nb ..][0..nb]);
            l.exact_ok[slot] = false;
            l.checked_to = f;
        }
        if (before(l.checked_to.?, p)) {
            // Damage missing for a frame we show: hide the layer, ask for it.
            if (l.gap_presents == 0) l.stats.gaps += 1;
            if (l.gap_presents % l.cfg.resync_every == 0) {
                l.resync_pending = true;
                l.stats.resyncs_asked += 1;
            }
            l.gap_presents += 1;
            l.stats.hidden_presents += 1;
            if (l.gap_presents < l.cfg.resync_frames)
                return .{ .width = l.width, .height = l.height, .ops = l.ops.items, .visible = false };
            // It didn't come: start over.
            l.clearAll();
            l.dropReady();
            for (l.asm_) |*a| a.active = false;
            l.acks.clearRetainingCapacity();
            l.reset_pending = true;
            l.resync_pending = false;
            l.checked_to = p;
            l.gap_presents = 0;
            l.exact_ok = @splat(false);
        }
        l.gap_presents = 0;
        l.promote(p);
        return .{ .width = l.width, .height = l.height, .ops = l.ops.items, .visible = true };
    }

    fn promote(l: *Layer, p: u32) void {
        var puts: u32 = 0;
        l.puts.clearRetainingCapacity();
        var i: usize = 0;
        while (i < l.ready.items.len) {
            const r = l.ready.items[i];
            const c: u32 = r.cell;
            if (before(p, r.since)) {
                i += 1;
                continue;
            }
            var keep = true;
            if (l.has_dmg[c] and before(r.since, l.dmg_hi[c])) {
                keep = false;
                if (!before(r.since, l.dmg_lo[c] -% 1)) {
                    l.ack(.{ .cell = r.cell, .since = r.since, .held = false });
                    l.stats.ambiguous += 1;
                } else l.stats.stale += 1;
            }
            if (l.shown[c] and !before(l.shown_since[c], r.since)) keep = false;
            if (keep and puts >= l.cfg.puts_per_present) {
                i += 1;
                continue;
            }
            if (keep) {
                const rect = l.cellRect(c);
                const n = @as(usize, rect.w) * rect.h * 4;
                const start = l.pixels.items.len;
                if (l.pixels.resize(l.gpa, start + n)) {
                    if (qoi.decode(r.data, rect.w, rect.h, l.pixels.items[start..][0..n], @as(usize, rect.w) * 4, l.cfg.order)) {
                        l.shown[c] = true;
                        l.shown_since[c] = r.since;
                        l.puts.append(l.gpa, .{ .rect = rect, .off = start }) catch {};
                        l.stats.shown += 1;
                        puts += 1;
                    } else |_| {
                        l.pixels.shrinkRetainingCapacity(start);
                        l.stats.decode_errors += 1;
                    }
                } else |_| {}
            }
            l.ready_used -= r.data.len;
            l.gpa.free(r.data);
            _ = l.ready.orderedRemove(i);
        }
        // Pixel slices are taken only now: the arena may have moved while it grew.
        for (l.puts.items) |pt| l.ops.append(l.gpa, .{ .put = .{ .rect = pt.rect, .pixels = l.pixels.items[pt.off..][0 .. @as(usize, pt.rect.w) * pt.rect.h * 4] } }) catch {};
    }

    /// The tile ack to send (control-fast kind 4 body) into `out`, or null for none.
    pub fn takeAck(l: *Layer, out: []u8) ?[]u8 {
        if (l.epoch == null) return null;
        if (l.acks.items.len == 0 and !l.reset_pending and !l.resync_pending) return null;
        const n = @min(l.acks.items.len, wire.TileAck.max_entries);
        const body = (wire.TileAck{
            .epoch = l.epoch.?,
            .reset = l.reset_pending,
            .resync = l.resync_pending,
            .covered_to = l.checked_to orelse 0,
            .entries = l.acks.items[0..n],
        }).encode(out) catch return null;
        l.acks.replaceRangeAssumeCapacity(0, n, &.{});
        l.reset_pending = false;
        l.resync_pending = false;
        return body;
    }
};

// ---------------------------------------------------------------------------
// Tests: the host engine and peer against the layer, frame by frame.

const host = @import("host.zig");
const testing = std.testing;

const Sim = struct {
    e: host.Engine,
    peer: host.Peer,
    l: Layer,
    /// The source picture's per-cell "version" (what a cell shows), and per frame.
    version: []u32,
    at: std.AutoHashMap(u64, []u32),
    pixels: []u8,
    w: u32,
    h: u32,
    r: std.Random.DefaultPrng,
    loss: u32 = 0,
    now: i64 = 0,
    mismatches: u32 = 0,
    shown_checks: u64 = 0,

    fn init(w: u32, h: u32, loss: u32) !Sim {
        var e = try host.Engine.init(testing.allocator, .{ .tile_after = 4 }, w, h, 0);
        errdefer e.deinit();
        var l = Layer.init(testing.allocator, .{});
        try l.configure(0, w, h);
        const v = try testing.allocator.alloc(u32, e.cells());
        @memset(v, 0);
        const px = try testing.allocator.alloc(u8, w * h * 4);
        return .{ .e = e, .peer = host.Peer.init(testing.allocator, .{ .burst_bytes = 1 << 20 }), .l = l, .version = v, .at = .init(testing.allocator), .pixels = px, .w = w, .h = h, .r = .init(42), .loss = loss };
    }

    fn deinit(s: *Sim) void {
        var it = s.at.valueIterator();
        while (it.next()) |v| testing.allocator.free(v.*);
        s.at.deinit();
        testing.allocator.free(s.version);
        testing.allocator.free(s.pixels);
        s.e.deinit();
        s.peer.deinit();
        s.l.deinit();
    }

    fn render(s: *Sim) void {
        var c: u32 = 0;
        while (c < s.e.cells()) : (c += 1) {
            const rect = s.e.grid.cellRect(c);
            var y: u32 = 0;
            while (y < rect.h) : (y += 1) {
                var x: u32 = 0;
                while (x < rect.w) : (x += 1) {
                    const glyph = std.hash.Wyhash.hash(s.version[c], std.mem.asBytes(&[2]u32{ (rect.x + x) / 6, (rect.y + y) / 10 }));
                    const ink = x % 6 < 5 and y % 10 < 7 and (glyph >> @intCast((y % 10) * 5 + x % 6)) & 1 == 1;
                    std.mem.writeInt(u32, s.pixels[((rect.y + y) * s.w + rect.x + x) * 4 ..][0..4], if (ink) 0xff101010 else 0xfff8f8f8 ^ c, .little);
                }
            }
        }
    }

    fn lost(s: *Sim) bool {
        return s.loss > 0 and s.r.random().uintLessThan(u32, 100) < s.loss;
    }

    /// One frame: change `changes` (cell ids), commit, offer reads, send damage, send
    /// tiles, deliver to the client, present.
    fn frame(s: *Sim, id: u32, changes: []const u32) !void {
        s.now += 16_667;
        var rects: [16]Rect = undefined;
        for (changes, 0..) |c, i| {
            s.version[c] += 1;
            rects[i] = s.e.grid.cellRect(c);
        }
        s.render();
        s.e.capture(if (id == 0) null else rects[0..changes.len]);
        s.e.commit(id);
        try s.at.put(id, try testing.allocator.dupe(u32, s.version));
        var want: [8]u32 = undefined;
        const n = s.e.wanted(&want);
        for (want[0..n]) |c| {
            const r = s.e.grid.cellRect(c);
            s.e.offer(c, s.pixels[(r.y * s.w + r.x) * 4 ..], s.w * 4);
        }
        var buf: [1200]u8 = undefined;
        if (s.e.damageMessage(id, &buf)) |m| if (!s.lost()) s.l.onRefine(@intFromEnum(proto.RefineKind.damage), m);
        var round: usize = 0;
        while (s.peer.next(&s.e, .{ .now = s.now, .ok = true, .target_bps = 50e6 }, round, &buf)) |b| {
            round += b.len;
            if (!s.lost()) s.l.onRefine(@intFromEnum(proto.RefineKind.tile_piece), b);
        }
        // The client presents the frame and acks.
        const u = s.l.present(id);
        try s.check(id, u);
        var ab: [1200]u8 = undefined;
        while (s.l.takeAck(&ab)) |a| {
            if (s.lost()) continue;
            var es: [wire.TileAck.max_entries]wire.AckEntry = undefined;
            const ack = try wire.TileAck.decode(a, &es);
            if (s.peer.onAck(&s.e, ack)) if (s.e.unionMessage(ack.covered_to, &buf)) |m| s.l.onRefine(@intFromEnum(proto.RefineKind.damage), m);
        }
    }

    /// Every tile that shows is of the cell's content at the presented frame, bit for bit.
    fn check(s: *Sim, id: u32, u: Update) !void {
        for (u.ops) |op| switch (op) {
            .put => |pt| {
                const c = (pt.rect.y / 64) * s.e.grid.cols + pt.rect.x / 64;
                var y: u32 = 0;
                while (y < pt.rect.h) : (y += 1) {
                    const src = s.pixels[((pt.rect.y + y) * s.w + pt.rect.x) * 4 ..][0 .. pt.rect.w * 4];
                    const got = pt.pixels[y * pt.rect.w * 4 ..][0 .. pt.rect.w * 4];
                    var x: u32 = 0;
                    while (x < pt.rect.w) : (x += 1) {
                        if (!std.mem.eql(u8, src[x * 4 ..][0..3], got[x * 4 ..][0..3])) {
                            s.mismatches += 1;
                            break;
                        }
                    }
                }
                _ = c;
            },
            else => {},
        };
        if (!u.visible) return;
        // Shown tiles: their since's version equals the version now.
        const now_v = s.at.get(id).?;
        var c: u32 = 0;
        while (c < s.l.cells) : (c += 1) {
            if (!s.l.shown[c]) continue;
            s.shown_checks += 1;
            const then = s.at.get(s.l.shown_since[c]) orelse return error.TestUnexpectedResult;
            if (then[c] != now_v[c]) s.mismatches += 1;
        }
    }
};

test "layer shows tiles only while their cells are unchanged, no loss" {
    var s = try Sim.init(320, 200, 0);
    defer s.deinit();
    var id: u32 = 0;
    while (id < 300) : (id += 1) {
        // Cell 0 changes every 3rd frame (never gets a tile); cell 7 every 50.
        var ch: [2]u32 = undefined;
        var n: usize = 0;
        if (id % 3 == 0) {
            ch[n] = 0;
            n += 1;
        }
        if (id % 50 == 25) {
            ch[n] = 7;
            n += 1;
        }
        try s.frame(id, ch[0..n]);
    }
    try testing.expectEqual(@as(u32, 0), s.mismatches);
    try testing.expect(s.l.stats.shown >= s.e.cells() - 1);
    try testing.expect(s.l.stats.invalidated >= 4);
    try testing.expect(!s.l.shown[0]);
    try testing.expectEqual(@as(u64, 0), s.l.stats.gaps);
}

test "layer under 10% loss: gaps resync, tiles still never stale" {
    var s = try Sim.init(320, 200, 10);
    defer s.deinit();
    var id: u32 = 0;
    while (id < 600) : (id += 1) {
        var ch: [3]u32 = undefined;
        var n: usize = 0;
        if (id % 3 == 0) {
            ch[n] = 0;
            n += 1;
        }
        if (id % 40 == 10) {
            ch[n] = 7;
            n += 1;
            ch[n] = 8;
            n += 1;
        }
        try s.frame(id, ch[0..n]);
    }
    try testing.expectEqual(@as(u32, 0), s.mismatches);
    try testing.expect(s.shown_checks > 1000);
    try testing.expect(s.l.stats.shown > s.e.cells());
}

test "a host that never sends damage gets no resync requests" {
    var l: Layer = .init(std.testing.allocator, .{});
    defer l.deinit();
    try l.configure(1, 256, 128);
    var p: u32 = 0;
    while (p < 100) : (p += 1) {
        const u = l.present(p);
        try std.testing.expect(!u.visible);
    }
    var b: [256]u8 = undefined;
    try std.testing.expect(l.takeAck(&b) == null);
    try std.testing.expectEqual(@as(u64, 0), l.stats.resyncs_asked);
    try std.testing.expectEqual(@as(u64, 0), l.stats.gaps);
}
