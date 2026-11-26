//! Refine stream messages (spec/refine-v0.md): tile pieces and frame damage on stream 6
//! (host to client), and the tile ack on control-fast kind 4 (client to host).
//!
//! Every decoder takes untrusted bytes (fuzz/refine.zig) and returns `error.Malformed`
//! (or a wire error) on anything out of range; no allocation.
const std = @import("std");
const proto = @import("../proto/root.zig");
const pwire = proto.wire;

pub const Error = pwire.DecodeError || pwire.EncodeError || error{Malformed};

/// Tile codecs (`TilePiece.codec`, and bits of the hello's tile caps).
pub const Codec = enum(u8) {
    qoi = 1,
    _,
};

/// Bits of `Hello.tiles`: the codecs a client decodes; 0 = no tiles.
pub const caps_qoi: u32 = 1 << 0;

/// The fixed cell size of v0, in pixels.
pub const cell_size = 64;

/// Largest piece payload: a piece datagram stays within `proto.max_datagram`.
pub const piece_max = 1100;
/// Pieces of one tile at most (a 64x64 cell in the worst case of QOI, 16406 bytes).
pub const max_pieces = 16;
pub const max_tile_len = max_pieces * piece_max;

/// Refine kind 1: one piece of an encoded tile.
pub const TilePiece = struct {
    /// The stream config the tile belongs to (`Config.epoch`).
    epoch: u32,
    cell: u16,
    /// The video frame id from which the cell has looked like this.
    since: u32,
    codec: Codec = .qoi,
    piece: u8,
    pieces: u8,
    /// The encoded tile's length (every piece of a tile says the same).
    total_len: u16,
    data: []const u8,

    pub const header_len = 15;

    pub fn encode(p: TilePiece, out: []u8) Error![]u8 {
        var e = pwire.Encoder.init(out);
        try e.int(u32, p.epoch);
        try e.int(u16, p.cell);
        try e.int(u32, p.since);
        try e.int(u8, @intFromEnum(p.codec));
        try e.int(u8, p.piece);
        try e.int(u8, p.pieces);
        try e.int(u16, p.total_len);
        try e.bytes(p.data);
        return e.written();
    }

    pub fn decode(b: []const u8) Error!TilePiece {
        var d = pwire.Decoder.init(b);
        const p: TilePiece = .{
            .epoch = try d.int(u32),
            .cell = try d.int(u16),
            .since = try d.int(u32),
            .codec = @enumFromInt(try d.int(u8)),
            .piece = try d.int(u8),
            .pieces = try d.int(u8),
            .total_len = try d.int(u16),
            .data = d.rest(),
        };
        if (p.pieces == 0 or p.pieces > max_pieces or p.piece >= p.pieces) return error.Malformed;
        if (p.data.len == 0 or p.data.len > piece_max) return error.Malformed;
        if (p.total_len == 0 or p.total_len > @as(u32, p.pieces) * piece_max) return error.Malformed;
        // Every piece but the last is full; the last holds the rest.
        const off = @as(u32, p.piece) * piece_max;
        if (off >= p.total_len) return error.Malformed;
        const want = @min(piece_max, p.total_len - off);
        if (p.data.len != want) return error.Malformed;
        if (std.math.divCeil(u32, p.total_len, piece_max) catch unreachable != p.pieces) return error.Malformed;
        return p;
    }
};

/// Refine kind 2: which cells the frames up to `frame_id` damaged.
///
/// Two forms. Per frame (`span` 0): up to three exact bitmaps, for `frame_id`,
/// `frame_id - 1` and `frame_id - 2` (`frames`), so a lost damage datagram is covered by
/// the next one. Union (`span` > 0, an answer to a client's resync request): one bitmap,
/// the cells damaged in any frame of (`frame_id - span`, `frame_id`]; `all` = every cell
/// (the history did not reach back that far, or the bitmap did not fit).
///
/// Each bitmap is run-length coded over the grid in cell order: uvarint run lengths,
/// alternately clean and damaged, starting with clean, summing to `cells`.
pub const Damage = struct {
    epoch: u32,
    frame_id: u32,
    span: u32 = 0,
    /// Grid size in cells (a check against the client's own grid).
    cells: u16,
    all: bool = false,
    /// Per-frame bitmaps, newest first; for the union form exactly one.
    maps: []const []const u8 = &.{},

    pub const max_maps = 3;

    const flag_all: u8 = 1;
    const flag_union: u8 = 2;

    pub fn encode(m: Damage, out: []u8) Error![]u8 {
        var e = pwire.Encoder.init(out);
        try e.int(u32, m.epoch);
        try e.int(u32, m.frame_id);
        try e.int(u16, m.cells);
        try e.int(u8, (if (m.all) flag_all else 0) | (if (m.span > 0) flag_union else 0));
        if (m.span > 0) try e.uvarint(m.span);
        if (m.all) return e.written();
        if (m.maps.len == 0 or m.maps.len > max_maps or (m.span > 0 and m.maps.len != 1)) return error.Malformed;
        try e.int(u8, @intCast(m.maps.len));
        for (m.maps) |bits| try rle(&e, bits, m.cells);
        return e.written();
    }

    /// Decodes into `maps_out` (each `bytesFor(cells)` long, zeroed here).
    pub fn decode(b: []const u8, maps_out: *[max_maps][]u8) Error!Damage {
        var d = pwire.Decoder.init(b);
        var m: Damage = .{ .epoch = try d.int(u32), .frame_id = try d.int(u32), .cells = try d.int(u16) };
        const flags = try d.int(u8);
        if (flags & flag_union != 0) {
            const span = try d.uvarint();
            if (span == 0 or span > std.math.maxInt(u31)) return error.Malformed;
            m.span = @intCast(span);
        }
        if (flags & flag_all != 0) {
            m.all = true;
            if (d.rest().len != 0) return error.Malformed;
            return m;
        }
        if (m.cells == 0) return error.Malformed;
        const n = try d.int(u8);
        if (n == 0 or n > max_maps or (m.span > 0 and n != 1)) return error.Malformed;
        const nb = bytesFor(m.cells);
        for (maps_out[0..n]) |mo| {
            if (mo.len < nb) return error.Malformed;
            @memset(mo[0..nb], 0);
            try unrle(&d, mo[0..nb], m.cells);
        }
        if (d.rest().len != 0) return error.Malformed;
        m.maps = @ptrCast(maps_out[0..n]);
        return m;
    }

    pub fn bytesFor(cells: u32) usize {
        return (cells + 7) / 8;
    }
};

pub fn getBit(bits: []const u8, i: u32) bool {
    return (bits[i / 8] >> @intCast(i % 8)) & 1 != 0;
}

pub fn setBit(bits: []u8, i: u32) void {
    bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
}

fn rle(e: *pwire.Encoder, bits: []const u8, cells: u32) Error!void {
    var i: u32 = 0;
    var want = false;
    while (i < cells) {
        var n: u32 = 0;
        while (i + n < cells and getBit(bits, i + n) == want) n += 1;
        try e.uvarint(n);
        i += n;
        want = !want;
    }
}

fn unrle(d: *pwire.Decoder, out: []u8, cells: u32) Error!void {
    var i: u32 = 0;
    var dirty = false;
    var first = true;
    while (i < cells) {
        const n = try d.uvarint();
        // Only the first (clean) run may be empty; an empty run later is a waste of bytes
        // no encoder writes, and refusing it bounds the loop.
        if (n == 0 and !first) return error.Malformed;
        first = false;
        if (n > cells - i) return error.Malformed;
        const k: u32 = @intCast(n);
        if (dirty) {
            var j: u32 = 0;
            while (j < k) : (j += 1) setBit(out, i + j);
        }
        i += k;
        dirty = !dirty;
    }
}

/// One entry of a tile ack.
pub const AckEntry = struct {
    cell: u16,
    since: u32,
    /// True: the client completed this tile. False: it dropped it without its cell
    /// changing (it could not tell from a union damage message), so the host should send
    /// it again if the cell is still the same.
    held: bool = true,
};

/// Control-fast kind 4, client to host.
pub const TileAck = struct {
    epoch: u32,
    /// The client cleared its whole tile layer: send every tile again.
    reset: bool = false,
    /// The client is missing damage for frames after `covered_to`: answer with a union
    /// damage message from there to the newest frame.
    resync: bool = false,
    covered_to: u32 = 0,
    entries: []const AckEntry = &.{},

    pub const max_entries = 120;
    const entry_len = 7;

    pub fn encode(a: TileAck, out: []u8) Error![]u8 {
        if (a.entries.len > max_entries) return error.Malformed;
        var e = pwire.Encoder.init(out);
        try e.int(u32, a.epoch);
        try e.int(u8, @as(u8, @intFromBool(a.reset)) | @as(u8, @intFromBool(a.resync)) << 1);
        try e.int(u32, a.covered_to);
        try e.int(u8, @intCast(a.entries.len));
        for (a.entries) |en| {
            try e.int(u16, en.cell);
            try e.int(u32, en.since);
            try e.int(u8, @intFromBool(en.held));
        }
        return e.written();
    }

    pub fn decode(b: []const u8, entries_out: *[max_entries]AckEntry) Error!TileAck {
        var d = pwire.Decoder.init(b);
        var a: TileAck = .{ .epoch = try d.int(u32) };
        const flags = try d.int(u8);
        a.reset = flags & 1 != 0;
        a.resync = flags & 2 != 0;
        a.covered_to = try d.int(u32);
        const n = try d.int(u8);
        if (n > max_entries) return error.Malformed;
        for (entries_out[0..n]) |*en| {
            en.* = .{ .cell = try d.int(u16), .since = try d.int(u32), .held = (try d.int(u8)) & 1 != 0 };
        }
        if (d.rest().len != 0) return error.Malformed;
        a.entries = entries_out[0..n];
        return a;
    }
};

/// A whole datagram: envelope plus message.
pub fn datagram(buf: []u8, stream: proto.StreamId, kind: u8, seq: u32, body: []const u8) []u8 {
    var e = pwire.Encoder.init(buf);
    (proto.Envelope{ .stream = stream, .kind = kind, .seq = seq }).encode(&e) catch unreachable;
    e.bytes(body) catch unreachable;
    return e.written();
}

const testing = std.testing;

test "tile piece round trip and checks" {
    var buf: [proto.max_datagram]u8 = undefined;
    const data: [piece_max]u8 = @splat(9);
    const p: TilePiece = .{ .epoch = 3, .cell = 509, .since = 1000, .piece = 0, .pieces = 2, .total_len = piece_max + 10, .data = &data };
    const b = try p.encode(&buf);
    try testing.expect(b.len + proto.Envelope.size <= proto.max_datagram);
    const q = try TilePiece.decode(b);
    try testing.expectEqual(p.since, q.since);
    try testing.expectEqual(@as(u16, 509), q.cell);
    // The last piece holds the rest exactly.
    const last: TilePiece = .{ .epoch = 3, .cell = 1, .since = 1, .piece = 1, .pieces = 2, .total_len = piece_max + 10, .data = data[0..10] };
    _ = try TilePiece.decode(try last.encode(&buf));
    var bad = last;
    bad.data = data[0..11];
    try testing.expectError(error.Malformed, TilePiece.decode(try bad.encode(&buf)));
    bad = last;
    bad.pieces = 3;
    try testing.expectError(error.Malformed, TilePiece.decode(try bad.encode(&buf)));
}

test "damage round trip, per frame and union" {
    var a: [64]u8 = @splat(0);
    var b2: [64]u8 = @splat(0);
    setBit(&a, 0);
    setBit(&a, 5);
    setBit(&a, 509);
    for (100..140) |i| setBit(&b2, @intCast(i));
    var buf: [proto.max_datagram]u8 = undefined;
    const m: Damage = .{ .epoch = 1, .frame_id = 77, .cells = 510, .maps = &.{ &a, &b2 } };
    const enc = try m.encode(&buf);
    var s0: [64]u8 = undefined;
    var s1: [64]u8 = undefined;
    var s2: [64]u8 = undefined;
    var outs: [Damage.max_maps][]u8 = .{ &s0, &s1, &s2 };
    const d = try Damage.decode(enc, &outs);
    try testing.expectEqual(@as(usize, 2), d.maps.len);
    try testing.expectEqualSlices(u8, a[0..64], d.maps[0][0..64]);
    try testing.expectEqualSlices(u8, b2[0..64], d.maps[1][0..64]);
    const u: Damage = .{ .epoch = 1, .frame_id = 90, .span = 40, .cells = 510, .maps = &.{&a} };
    const du = try Damage.decode(try u.encode(&buf), &outs);
    try testing.expectEqual(@as(u32, 40), du.span);
    const all: Damage = .{ .epoch = 1, .frame_id = 90, .span = 200, .cells = 510, .all = true };
    try testing.expect((try Damage.decode(try all.encode(&buf), &outs)).all);
}

test "damage decoder refuses runs past the grid and trailing bytes" {
    var s0: [64]u8 = undefined;
    var s1: [64]u8 = undefined;
    var s2: [64]u8 = undefined;
    var outs: [Damage.max_maps][]u8 = .{ &s0, &s1, &s2 };
    // epoch, frame, cells=10, flags 0, 1 map, runs 5 then 6 (overflows).
    const bad = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 1, 5, 6 };
    try testing.expectError(error.Malformed, Damage.decode(&bad, &outs));
    const ok = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 1, 5, 5 };
    _ = try Damage.decode(&ok, &outs);
    try testing.expectError(error.Malformed, Damage.decode(&(ok ++ [_]u8{0}), &outs));
    const zero_run = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 1, 5, 0, 5 };
    try testing.expectError(error.Malformed, Damage.decode(&zero_run, &outs));
}

test "tile ack round trip" {
    var buf: [proto.max_datagram]u8 = undefined;
    const es = [_]AckEntry{ .{ .cell = 1, .since = 5 }, .{ .cell = 2, .since = 6, .held = false } };
    const a: TileAck = .{ .epoch = 2, .resync = true, .covered_to = 99, .entries = &es };
    var out: [TileAck.max_entries]AckEntry = undefined;
    const d = try TileAck.decode(try a.encode(&buf), &out);
    try testing.expect(d.resync and !d.reset);
    try testing.expectEqual(@as(u32, 99), d.covered_to);
    try testing.expectEqual(@as(usize, 2), d.entries.len);
    try testing.expect(!d.entries[1].held);
    try testing.expect(TileAck.max_entries * 7 + 10 + proto.Envelope.size <= proto.max_datagram);
}
