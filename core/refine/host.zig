//! Host side of lossless tiles (docs: the lossless-tiles design, stage 3; spec/refine-v0.md).
//!
//! `Engine` is the encode side, one per encode (shared by every member of a multi-user
//! session): it folds capture damage into a 64-pixel cell grid at video frame ids, keeps a
//! short per-frame history of damaged cells for damage messages, picks still cells worth
//! a tile, and caches each cell's encoded tile keyed by the frame id it has been still
//! since (`since`). A tile is encoded once, whoever it goes to.
//!
//! `Peer` is one client's sender: what it has sent and the client acked, resends, and a
//! byte budget refilled from the spare rate (the controller's target minus the measured
//! video rate). Tiles only go out when the caller says the pacer is idle and the path is
//! calm, so a video frame never waits behind a tile.
//!
//! The tile picker:
//!   - a cell is a candidate once still for `tile_after` frames (cells that changed a few
//!     times in the last 64 frames, a caret's or a clock's, wait `busy_after`);
//!   - flat cells (one colour) are skipped: video gets them right;
//!   - photo-like cells (QOI under `photo_ratio`:1) are skipped: video is good there and
//!     lossless is expensive. The verdict holds until the cell changes;
//!   - the rest go nearest the pointer first, then by edge count.
//!
//! Sans-I/O; `init` allocates, tiles allocate their cache entries. The app reads pixels
//! (`wanted` -> `offer`), the session calls `commit` per frame and `Peer.next` to send.
const std = @import("std");
const damage = @import("../damage/root.zig");
const qoi = @import("qoi.zig");
const wire = @import("wire.zig");

const Rect = damage.Rect;
const never = damage.never;

pub const Config = struct {
    /// Frames a cell must be still before it gets a tile (300 ms at 60 fps).
    tile_after: u32 = 18,
    /// ...or this many, for a cell that changed `busy_changes` times in the last 64 frames.
    busy_after: u32 = 64,
    busy_changes: u32 = 3,
    /// A cell of at most this many colours is flat (two-colour text is not: it is the
    /// case tiles are for).
    flat_colors: u32 = 1,
    /// Raw RGB bytes over encoded bytes below this is photo-like.
    photo_ratio: u32 = 2,
    /// Cells read and encoded per frame at most.
    reads_per_frame: u32 = 8,
    /// Encoded tiles kept, bytes; the oldest are evicted past it.
    cache_bytes: usize = 16 << 20,
    /// Frames of per-frame damage history (for resync answers): 2 s at 60 fps.
    history: u32 = 128,
};

pub const Verdict = enum(u8) { none, tile, flat, photo };

const Slot = struct {
    since: u64 = never,
    verdict: Verdict = .none,
    data: []u8 = &.{},
    edges: u32 = 0,
};

pub const Stats = struct {
    commits: u64 = 0,
    offers: u64 = 0,
    tiles: u64 = 0,
    flat: u64 = 0,
    photo: u64 = 0,
    evictions: u64 = 0,
    tile_bytes: u64 = 0,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    grid: damage.Grid,
    epoch: u32,
    slots: []Slot,
    cache_used: usize = 0,
    /// Damage captured since the last commit (a dropped encode carries it to the next).
    pending: []u8,
    pending_all: bool = true,
    /// Newest committed frame, widened to 64 bits.
    frame: u64 = never,
    hist_bits: []u8,
    hist_id: []u64,
    /// The pointer, in frame pixels, for ordering (null: the middle).
    pointer: ?struct { x: u32, y: u32 } = null,
    scratch: [qoi.maxEncodedLen(wire.cell_size, wire.cell_size)]u8 = undefined,
    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, cfg: Config, width: u32, height: u32, epoch: u32) !Engine {
        var e: Engine = .{
            .gpa = gpa,
            .cfg = cfg,
            .grid = undefined,
            .epoch = epoch,
            .slots = &.{},
            .pending = &.{},
            .hist_bits = &.{},
            .hist_id = &.{},
        };
        try e.alloc(width, height);
        return e;
    }

    fn alloc(e: *Engine, width: u32, height: u32) !void {
        e.grid = try damage.Grid.init(e.gpa, width, height, wire.cell_size);
        errdefer e.grid.deinit();
        if (e.grid.cells() > std.math.maxInt(u16)) return error.Unsupported;
        e.slots = try e.gpa.alloc(Slot, e.grid.cells());
        @memset(e.slots, .{});
        const nb = wire.Damage.bytesFor(e.grid.cells());
        e.pending = try e.gpa.alloc(u8, nb);
        @memset(e.pending, 0);
        e.hist_bits = try e.gpa.alloc(u8, nb * e.cfg.history);
        e.hist_id = try e.gpa.alloc(u64, e.cfg.history);
        @memset(e.hist_id, never);
        e.pending_all = true;
        e.frame = never;
        e.cache_used = 0;
    }

    fn free(e: *Engine) void {
        for (e.slots) |sl| if (sl.data.len > 0) e.gpa.free(sl.data);
        e.gpa.free(e.slots);
        e.gpa.free(e.pending);
        e.gpa.free(e.hist_bits);
        e.gpa.free(e.hist_id);
        e.grid.deinit();
    }

    pub fn deinit(e: *Engine) void {
        e.free();
        e.* = undefined;
    }

    /// A new stream config (size, display, codec): every tile is gone.
    pub fn reset(e: *Engine, width: u32, height: u32, epoch: u32) !void {
        e.free();
        e.epoch = epoch;
        try e.alloc(width, height);
    }

    pub fn cells(e: *const Engine) u32 {
        return e.grid.cells();
    }

    /// A captured frame's damage (`CapturedFrame.damage`; null = unknown). Call for every
    /// frame captured, before its encode; `commit` applies it at the frame's id.
    pub fn capture(e: *Engine, dmg: ?[]const Rect) void {
        const rects = dmg orelse {
            e.pending_all = true;
            return;
        };
        if (e.pending_all) return;
        for (rects) |raw| {
            const r = raw.clip(e.grid.width, e.grid.height);
            if (r.empty()) continue;
            var cy = r.y / e.grid.cell;
            while (cy <= (r.y + r.h - 1) / e.grid.cell) : (cy += 1) {
                var cx = r.x / e.grid.cell;
                while (cx <= (r.x + r.w - 1) / e.grid.cell) : (cx += 1) wire.setBit(e.pending, cy * e.grid.cols + cx);
            }
        }
    }

    /// Widens a 32-bit frame id against the newest committed frame; negative for an id
    /// from before the first frame.
    pub fn widenSigned(e: *const Engine, id: u32) i64 {
        if (e.frame == never) return id;
        const cur: u32 = @truncate(e.frame);
        const d: i32 = @bitCast(id -% cur);
        return @as(i64, @intCast(e.frame)) + d;
    }

    /// `widenSigned`, with an id from before the first frame as frame 0.
    pub fn widen(e: *const Engine, id: u32) u64 {
        return @intCast(@max(0, e.widenSigned(id)));
    }

    /// Video frame `id` was encoded (sent or held): the damage captured since the last
    /// commit happened at this frame.
    pub fn commit(e: *Engine, id: u32) void {
        const w = e.widen(id);
        if (e.frame != never and w <= e.frame) return;
        e.frame = w;
        e.stats.commits += 1;
        const nb = e.pending.len;
        const h = e.hist_bits[@as(usize, @intCast(w % e.cfg.history)) * nb ..][0..nb];
        e.hist_id[@intCast(w % e.cfg.history)] = w;
        if (e.pending_all) {
            e.grid.apply(w, null);
            @memset(h, 0xff);
        } else {
            e.grid.apply(w, &.{});
            @memcpy(h, e.pending);
            var i: u32 = 0;
            while (i < e.grid.cells()) : (i += 1) if (wire.getBit(e.pending, i)) e.grid.mark(i);
        }
        @memset(e.pending, 0);
        e.pending_all = false;
    }

    fn priority(e: *const Engine, c: u32) u32 {
        const r = e.grid.cellRect(c);
        const px = if (e.pointer) |p| p.x else e.grid.width / 2;
        const py = if (e.pointer) |p| p.y else e.grid.height / 2;
        const cx = (r.x + r.w / 2) / e.grid.cell;
        const cy = (r.y + r.h / 2) / e.grid.cell;
        const qx = px / e.grid.cell;
        const qy = py / e.grid.cell;
        const dist = @max(if (cx > qx) cx - qx else qx - cx, if (cy > qy) cy - qy else qy - cy);
        return dist;
    }

    fn stillEnough(e: *const Engine, c: u32) bool {
        if (e.frame == never) return false;
        const after = if (e.grid.changesIn(c, damage.history_frames) >= e.cfg.busy_changes) e.cfg.busy_after else e.cfg.tile_after;
        return e.grid.stillFor(c, e.frame, after);
    }

    /// Cells to read from the newest committed frame and `offer`, nearest the pointer
    /// first (at most `reads_per_frame`). Read them from that frame, before its release.
    pub fn wanted(e: *Engine, out: []u32) usize {
        const cap = @min(out.len, e.cfg.reads_per_frame);
        if (cap == 0 or e.frame == never) return 0;
        var n: usize = 0;
        var c: u32 = 0;
        while (c < e.grid.cells()) : (c += 1) {
            if (e.slots[c].since == e.grid.since[c] and e.slots[c].verdict != .none) continue;
            if (!e.stillEnough(c)) continue;
            const p = e.priority(c);
            if (n < cap) {
                out[n] = c;
                n += 1;
            } else {
                // Replace the worst kept one.
                var worst: usize = 0;
                for (out[0..n], 0..) |o, k| if (e.priority(o) > e.priority(out[worst])) {
                    worst = k;
                };
                if (p < e.priority(out[worst])) out[worst] = c;
            }
        }
        std.mem.sort(u32, out[0..n], e, struct {
            fn lt(en: *Engine, a: u32, b: u32) bool {
                return en.priority(a) < en.priority(b);
            }
        }.lt);
        return n;
    }

    /// The pixels of cell `c` (its `cellRect`, bgra8, rows `stride` apart) from the newest
    /// committed frame. Classifies and, if worth it, encodes and caches the tile.
    pub fn offer(e: *Engine, c: u32, pixels: []const u8, stride: usize) void {
        if (c >= e.grid.cells()) return;
        const since = e.grid.since[c];
        if (since == never) return;
        e.stats.offers += 1;
        const r = e.grid.cellRect(c);
        const sl = &e.slots[c];
        e.dropData(sl);
        sl.since = since;
        if (qoi.countColors(pixels, stride, r.w, r.h, e.cfg.flat_colors) <= e.cfg.flat_colors) {
            sl.verdict = .flat;
            e.stats.flat += 1;
            return;
        }
        const enc = qoi.encode(pixels, stride, r.w, r.h, &e.scratch) catch unreachable;
        const raw = @as(usize, r.w) * r.h * 3;
        if (enc.len * e.cfg.photo_ratio > raw or enc.len > wire.max_tile_len) {
            sl.verdict = .photo;
            e.stats.photo += 1;
            return;
        }
        while (e.cache_used + enc.len > e.cfg.cache_bytes) if (!e.evictOldest()) break;
        sl.data = e.gpa.dupe(u8, enc) catch {
            sl.verdict = .none;
            return;
        };
        sl.verdict = .tile;
        sl.edges = qoi.edgeScore(pixels, stride, r.w, r.h);
        e.cache_used += enc.len;
        e.stats.tiles += 1;
        e.stats.tile_bytes += enc.len;
    }

    fn dropData(e: *Engine, sl: *Slot) void {
        if (sl.data.len > 0) {
            e.cache_used -= sl.data.len;
            e.gpa.free(sl.data);
        }
        sl.data = &.{};
        sl.verdict = .none;
    }

    fn evictOldest(e: *Engine) bool {
        var best: ?usize = null;
        for (e.slots, 0..) |sl, i| if (sl.data.len > 0 and (best == null or sl.since < e.slots[best.?].since)) {
            best = i;
        };
        const b = best orelse return false;
        e.dropData(&e.slots[b]);
        e.stats.evictions += 1;
        return true;
    }

    pub const Tile = struct { since: u64, data: []const u8, edges: u32 };

    /// Cell `c`'s cached tile, if it shows the cell as it is now.
    pub fn tile(e: *const Engine, c: u32) ?Tile {
        const sl = e.slots[c];
        if (sl.verdict != .tile or sl.since != e.grid.since[c]) return null;
        return .{ .since = sl.since, .data = sl.data, .edges = sl.edges };
    }

    fn histFor(e: *const Engine, w: u64) ?[]const u8 {
        const i: usize = @intCast(w % e.cfg.history);
        if (e.hist_id[i] != w) return null;
        const nb = e.pending.len;
        return e.hist_bits[i * nb ..][0..nb];
    }

    /// The per-frame damage message for frame `id` (just committed): its bitmap and the
    /// two before it, as far as the history has them.
    pub fn damageMessage(e: *const Engine, id: u32, out: []u8) ?[]u8 {
        const w = e.widen(id);
        var maps: [wire.Damage.max_maps][]const u8 = undefined;
        var n: usize = 0;
        var k: u64 = 0;
        while (k < wire.Damage.max_maps and k <= w) : (k += 1) {
            const h = e.histFor(w - k) orelse break;
            maps[n] = h;
            n += 1;
        }
        if (n == 0) return null;
        const m: wire.Damage = .{ .epoch = e.epoch, .frame_id = id, .cells = @intCast(e.grid.cells()), .maps = maps[0..n] };
        return m.encode(out) catch null;
    }

    /// The union damage message from the frame after `covered_to` to the newest: the
    /// answer to a client's resync. `all` when the history does not reach back that far
    /// or the bitmap does not fit `out`.
    pub fn unionMessage(e: *const Engine, covered_to: u32, out: []u8) ?[]u8 {
        if (e.frame == never) return null;
        // Covered to before the first frame: everything since.
        const from_s = e.widenSigned(covered_to);
        const from: u64 = @intCast(@max(0, from_s));
        if (from_s >= 0 and from >= e.frame) return null;
        const span: u64 = e.frame - from + @intFromBool(from_s < 0);
        const id: u32 = @truncate(e.frame);
        var acc: [wire.Damage.bytesFor(std.math.maxInt(u16))]u8 = undefined;
        const nb = e.pending.len;
        @memset(acc[0..nb], 0);
        var all = from_s < 0 or span >= e.cfg.history or span > std.math.maxInt(u31);
        if (!all) {
            var w = from + 1;
            while (w <= e.frame) : (w += 1) {
                const h = e.histFor(w) orelse {
                    all = true;
                    break;
                };
                for (acc[0..nb], h) |*a, b| a.* |= b;
            }
        }
        const base: wire.Damage = .{ .epoch = e.epoch, .frame_id = id, .span = @intCast(@min(span, std.math.maxInt(u31))), .cells = @intCast(e.grid.cells()) };
        if (!all) {
            var m = base;
            m.maps = &.{acc[0..nb]};
            if (m.encode(out)) |b| return b else |_| {}
        }
        var m = base;
        m.all = true;
        return m.encode(out) catch null;
    }
};

// ---------------------------------------------------------------------------
// Peer

pub const PeerConfig = struct {
    /// Resend an unacked tile after the RTT plus a frame plus this.
    resend_extra_us: i64 = 20_000,
    /// Bytes handed to the pipe per `next` round at most (the caller asks again later).
    burst_bytes: usize = 6 * 1200,
    /// The budget's bucket holds this much of the spare rate.
    bucket_us: i64 = 30_000,
    /// Use this share of the spare rate.
    share: f64 = 0.9,
    /// Window of the measured video rate.
    video_window_us: i64 = 250_000,
};

/// What the session knows about the path, for one `next` round.
pub const Path = struct {
    now: i64,
    /// The pacer has nothing queued and the controller is calm (no overuse, drain or loss
    /// cut in the last second) and the path is not stalled: tiles may go.
    ok: bool,
    /// The rate the path takes from us, bits per second.
    target_bps: f64,
    rtt_us: i64 = 0,
    frame_us: i64 = 16_667,
};

const CellState = struct {
    acked: u64 = never,
    sent: u64 = never,
    sent_at: i64 = 0,
};

pub const PeerStats = struct {
    tiles_sent: u64 = 0,
    pieces: u64 = 0,
    bytes: u64 = 0,
    resends: u64 = 0,
    acked: u64 = 0,
    dropped: u64 = 0,
    resets: u64 = 0,
    resyncs: u64 = 0,
    damage_messages: u64 = 0,
};

pub const Peer = struct {
    gpa: std.mem.Allocator,
    cfg: PeerConfig,
    states: []CellState = &.{},
    epoch: u32 = 0,
    /// The tile going out piece by piece.
    cur: ?struct { cell: u32, since: u64, next: u8, pieces: u8 } = null,
    tokens: f64 = 0,
    last_refill: ?i64 = null,
    video_bytes: u64 = 0,
    video_since: ?i64 = null,
    video_bps: f64 = 0,
    stats: PeerStats = .{},

    pub fn init(gpa: std.mem.Allocator, cfg: PeerConfig) Peer {
        return .{ .gpa = gpa, .cfg = cfg };
    }

    pub fn deinit(p: *Peer) void {
        if (p.states.len > 0) p.gpa.free(p.states);
        p.states = &.{};
    }

    /// Follow the engine's grid and epoch (a new config clears what was sent).
    fn sync(p: *Peer, e: *const Engine) bool {
        if (p.states.len == e.cells() and p.epoch == e.epoch) return true;
        if (p.states.len > 0) p.gpa.free(p.states);
        p.states = p.gpa.alloc(CellState, e.cells()) catch {
            p.states = &.{};
            return false;
        };
        @memset(p.states, .{});
        p.epoch = e.epoch;
        p.cur = null;
        return true;
    }

    /// Video bytes sent to this client (for the spare-rate budget).
    pub fn onVideo(p: *Peer, now: i64, bytes: usize) void {
        const t0 = p.video_since orelse blk: {
            p.video_since = now;
            break :blk now;
        };
        p.video_bytes += bytes;
        const dt = now - t0;
        if (dt >= p.cfg.video_window_us) {
            const r = @as(f64, @floatFromInt(p.video_bytes)) * 8e6 / @as(f64, @floatFromInt(dt));
            p.video_bps = if (p.video_bps == 0) r else 0.5 * p.video_bps + 0.5 * r;
            p.video_bytes = 0;
            p.video_since = now;
        }
    }

    fn spareBps(p: *const Peer, target: f64, now: i64) f64 {
        var v = p.video_bps;
        // A still screen sends almost nothing: let the measured rate decay when idle.
        if (p.video_since) |t| if (now - t > 2 * p.cfg.video_window_us) {
            v = @as(f64, @floatFromInt(p.video_bytes)) * 8e6 / @as(f64, @floatFromInt(now - t));
        };
        return @max(0, (target - v) * p.cfg.share);
    }

    fn refill(p: *Peer, path: Path) void {
        const last = p.last_refill orelse path.now;
        p.last_refill = path.now;
        const rate = p.spareBps(path.target_bps, path.now);
        const cap = @max(rate * @as(f64, @floatFromInt(p.cfg.bucket_us)) / 8e6, wire.piece_max + 64);
        p.tokens = @min(cap, p.tokens + rate * @as(f64, @floatFromInt(@max(path.now - last, 0))) / 8e6);
    }

    fn rto(path: Path, cfg: PeerConfig) i64 {
        return @max(path.rtt_us, 0) + path.frame_us + cfg.resend_extra_us;
    }

    fn pick(p: *Peer, e: *const Engine, path: Path) ?u32 {
        var best: ?u32 = null;
        var best_p: u32 = 0;
        var best_edges: u32 = 0;
        const timeout = rto(path, p.cfg);
        var c: u32 = 0;
        while (c < e.cells()) : (c += 1) {
            const t = e.tile(c) orelse continue;
            const st = p.states[c];
            if (st.acked == t.since) continue;
            if (st.sent == t.since and path.now - st.sent_at < timeout) continue;
            const pr = e.priority(c);
            if (best == null or pr < best_p or (pr == best_p and t.edges > best_edges)) {
                best = c;
                best_p = pr;
                best_edges = t.edges;
            }
        }
        return best;
    }

    /// The next tile piece's body (refine kind 1, without the envelope) into `out`, or null
    /// when there is nothing to send now (no tile wanted, no budget, path not ok, or this
    /// round's burst is spent: `round_bytes` counts what this round sent so far).
    pub fn next(p: *Peer, e: *const Engine, path: Path, round_bytes: usize, out: []u8) ?[]u8 {
        if (!p.sync(e)) return null;
        p.refill(path);
        if (!path.ok or round_bytes >= p.cfg.burst_bytes) return null;
        if (p.cur) |cur| {
            // Its cell changed under it: the rest would be useless.
            const t = e.tile(cur.cell);
            if (t == null or t.?.since != cur.since) p.cur = null;
        }
        if (p.cur == null) {
            const c = p.pick(e, path) orelse return null;
            const t = e.tile(c).?;
            if (p.states[c].sent == t.since) p.stats.resends += 1;
            p.cur = .{ .cell = c, .since = t.since, .next = 0, .pieces = @intCast(std.math.divCeil(usize, t.data.len, wire.piece_max) catch unreachable) };
        }
        const cur = &p.cur.?;
        const t = e.tile(cur.cell).?;
        const off = @as(usize, cur.next) * wire.piece_max;
        const chunk = t.data[off..@min(off + wire.piece_max, t.data.len)];
        const need = @as(f64, @floatFromInt(chunk.len + wire.TilePiece.header_len + 8));
        if (p.tokens < need) return null;
        const body = (wire.TilePiece{
            .epoch = e.epoch,
            .cell = @intCast(cur.cell),
            .since = @truncate(cur.since),
            .piece = cur.next,
            .pieces = cur.pieces,
            .total_len = @intCast(t.data.len),
            .data = chunk,
        }).encode(out) catch return null;
        p.tokens -= need;
        p.stats.pieces += 1;
        p.stats.bytes += body.len;
        cur.next += 1;
        if (cur.next == cur.pieces) {
            p.states[cur.cell].sent = cur.since;
            p.states[cur.cell].sent_at = path.now;
            p.stats.tiles_sent += 1;
            p.cur = null;
        }
        return body;
    }

    /// A tile ack from the client. Returns true when it asks for a resync (the caller then
    /// sends `Engine.unionMessage(ack.covered_to)`).
    pub fn onAck(p: *Peer, e: *const Engine, a: wire.TileAck) bool {
        if (!p.sync(e) or a.epoch != e.epoch) return false;
        if (a.reset) {
            @memset(p.states, .{});
            p.cur = null;
            p.stats.resets += 1;
        }
        for (a.entries) |en| {
            if (en.cell >= p.states.len) continue;
            const st = &p.states[en.cell];
            const w = e.widen(en.since);
            if (en.held) {
                st.acked = w;
                p.stats.acked += 1;
            } else {
                if (st.acked == w) st.acked = never;
                if (st.sent == w) st.sent = never;
                p.stats.dropped += 1;
            }
        }
        if (a.resync) p.stats.resyncs += 1;
        return a.resync;
    }

    /// Tiles in the cache this client does not hold yet (for the session's wake timer).
    pub fn wants(p: *const Peer, e: *const Engine) bool {
        if (p.cur != null) return true;
        if (p.states.len != e.cells() or p.epoch != e.epoch) return e.stats.tiles > 0;
        var c: u32 = 0;
        while (c < e.cells()) : (c += 1) {
            const t = e.tile(c) orelse continue;
            if (p.states[c].acked != t.since) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn textCell(buf: []u8, stride: usize, w: u32, h: u32, seed: u64) void {
    var y: usize = 0;
    while (y < h) : (y += 1) for (0..w) |x| {
        // 6x10 character cells of 5x7 glyphs, glyph bits from the cell's hash.
        const glyph = std.hash.Wyhash.hash(seed, std.mem.asBytes(&[2]usize{ x / 6, y / 10 }));
        const gx = x % 6;
        const gy = y % 10;
        const ink = gx < 5 and gy < 7 and (glyph >> @intCast(gy * 5 + gx)) & 1 == 1;
        const v: u32 = if (ink) 0xff10_1010 else 0xfff0_f0f0;
        std.mem.writeInt(u32, buf[y * stride + x * 4 ..][0..4], v, .little);
    };
}

test "engine picks still cells, classifies, and caches tiles by since" {
    var e = try Engine.init(testing.allocator, .{ .tile_after = 3 }, 256, 128, 0);
    defer e.deinit();
    var frame: [256 * 128 * 4]u8 = undefined;
    textCell(&frame, 256 * 4, 256, 128, 1);
    // Cell 3 is flat.
    for (0..64) |y| for (192..256) |x| std.mem.writeInt(u32, frame[y * 1024 + x * 4 ..][0..4], 0xffffffff, .little);
    e.capture(null);
    e.commit(10);
    var want: [8]u32 = undefined;
    try testing.expectEqual(@as(usize, 0), e.wanted(&want));
    var id: u32 = 11;
    while (id < 14) : (id += 1) {
        e.capture(&.{});
        e.commit(id);
    }
    const n = e.wanted(&want);
    try testing.expectEqual(@as(usize, 8), n);
    for (want[0..n]) |c| {
        const r = e.grid.cellRect(c);
        e.offer(c, frame[r.y * 1024 + r.x * 4 ..], 1024);
    }
    try testing.expect(e.tile(3) == null);
    try testing.expectEqual(Verdict.flat, e.slots[3].verdict);
    try testing.expect(e.tile(0) != null);
    try testing.expectEqual(@as(u64, 10), e.tile(0).?.since);
    // Classified cells are not wanted again until they change.
    try testing.expectEqual(@as(usize, 0), e.wanted(&want));
    // Damage cell 0 at frame 14: its tile is gone.
    e.capture(&.{.{ .x = 3, .y = 3, .w = 1, .h = 1 }});
    e.commit(14);
    try testing.expect(e.tile(0) == null);
    try testing.expect(e.tile(1) != null);
}

test "damage messages carry three frames; union answers a resync" {
    var e = try Engine.init(testing.allocator, .{}, 256, 128, 2);
    defer e.deinit();
    e.capture(null);
    e.commit(0);
    e.capture(&.{.{ .x = 0, .y = 0, .w = 1, .h = 1 }});
    e.commit(1);
    e.capture(&.{.{ .x = 70, .y = 0, .w = 1, .h = 1 }});
    e.commit(2);
    var buf: [1200]u8 = undefined;
    const m = e.damageMessage(2, &buf).?;
    var s: [3][16]u8 = undefined;
    var outs: [3][]u8 = .{ &s[0], &s[1], &s[2] };
    const d = try wire.Damage.decode(m, &outs);
    try testing.expectEqual(@as(usize, 3), d.maps.len);
    try testing.expect(wire.getBit(d.maps[0], 1) and !wire.getBit(d.maps[0], 0));
    try testing.expect(wire.getBit(d.maps[1], 0));
    try testing.expect(wire.getBit(d.maps[2], 7)); // frame 0: everything
    const u = try wire.Damage.decode(e.unionMessage(0, &buf).?, &outs);
    try testing.expectEqual(@as(u32, 2), u.span);
    try testing.expect(wire.getBit(u.maps[0], 0) and wire.getBit(u.maps[0], 1) and !wire.getBit(u.maps[0], 2));
    // Beyond the history: all.
    var id: u32 = 3;
    while (id < 200) : (id += 1) {
        e.capture(&.{});
        e.commit(id);
    }
    try testing.expect((try wire.Damage.decode(e.unionMessage(2, &buf).?, &outs)).all);
}

test "peer sends pieces within the budget, resends unacked, stops on ack" {
    var e = try Engine.init(testing.allocator, .{ .tile_after = 1 }, 64, 64, 0);
    defer e.deinit();
    var frame: [64 * 64 * 4]u8 = undefined;
    var r = std.Random.DefaultPrng.init(3);
    r.random().bytes(&frame); // noisy, but force it in: photo ratio off
    e.cfg.photo_ratio = 0;
    e.capture(null);
    e.commit(0);
    e.capture(&.{});
    e.commit(1);
    var want: [1]u32 = undefined;
    try testing.expectEqual(@as(usize, 1), e.wanted(&want));
    e.offer(0, &frame, 256);
    const t = e.tile(0).?;
    const pieces = std.math.divCeil(usize, t.data.len, wire.piece_max) catch unreachable;
    var p = Peer.init(testing.allocator, .{ .burst_bytes = 1 << 20 });
    defer p.deinit();
    var buf: [1200]u8 = undefined;
    // No budget at first (bucket empty), then 10 ms of 100 Mbit/s spare.
    try testing.expect(p.next(&e, .{ .now = 0, .ok = true, .target_bps = 100e6 }, 0, &buf) == null);
    var sent: usize = 0;
    var round: usize = 0;
    while (p.next(&e, .{ .now = 10_000, .ok = true, .target_bps = 100e6 }, round, &buf)) |b| {
        _ = try wire.TilePiece.decode(b);
        sent += 1;
        round += b.len;
    }
    try testing.expectEqual(pieces, sent);
    try testing.expectEqual(@as(u64, 1), p.stats.tiles_sent);
    // Not ok: nothing.
    try testing.expect(p.next(&e, .{ .now = 200_000, .ok = false, .target_bps = 100e6 }, 0, &buf) == null);
    // Unacked past the timeout: resent.
    try testing.expect(p.next(&e, .{ .now = 300_000, .ok = true, .target_bps = 100e6 }, 0, &buf) != null);
    try testing.expectEqual(@as(u64, 1), p.stats.resends);
    // Acked: nothing more once the tile in progress is done.
    _ = p.onAck(&e, .{ .epoch = 0, .entries = &.{.{ .cell = 0, .since = 0 }} });
    while (p.next(&e, .{ .now = 300_000, .ok = true, .target_bps = 100e6 }, 0, &buf)) |_| {}
    try testing.expect(p.next(&e, .{ .now = 900_000, .ok = true, .target_bps = 100e6 }, 0, &buf) == null);
    try testing.expect(!p.wants(&e));
    // A reset asks for it all again.
    _ = p.onAck(&e, .{ .epoch = 0, .reset = true });
    try testing.expect(p.wants(&e));
}

test "a tile whose cell changes is never sent" {
    var e = try Engine.init(testing.allocator, .{ .tile_after = 1 }, 64, 64, 0);
    defer e.deinit();
    var frame: [64 * 64 * 4]u8 = undefined;
    textCell(&frame, 256, 64, 64, 9);
    e.capture(null);
    e.commit(0);
    e.capture(&.{});
    e.commit(1);
    e.offer(0, &frame, 256);
    try testing.expect(e.tile(0) != null);
    e.capture(&.{.{ .x = 0, .y = 0, .w = 64, .h = 64 }});
    e.commit(2);
    var p = Peer.init(testing.allocator, .{});
    defer p.deinit();
    var buf: [1200]u8 = undefined;
    try testing.expect(p.next(&e, .{ .now = 1_000_000, .ok = true, .target_bps = 100e6 }, 0, &buf) == null);
}

test "a resync from before the first frame answers with all damage, not a crash" {
    var e = try Engine.init(std.testing.allocator, .{}, 128, 128, 1);
    defer e.deinit();
    e.capture(null);
    e.commit(3);
    var b: [256]u8 = undefined;
    const m = e.unionMessage(0xffff_fff0, &b) orelse return error.TestUnexpectedResult;
    var maps: [wire.Damage.max_maps][]u8 = undefined;
    const d = try wire.Damage.decode(m, &maps);
    try std.testing.expect(d.all);
}
