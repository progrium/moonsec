//! core/refine (lossless tiles): the QOI decoder, the refine wire messages, the client's
//! tile layer fed whatever the host sends, and the host engine and peer fed whatever tile
//! acks a client sends.
const std = @import("std");
const core = @import("core");
const c = @import("common.zig");

const refine = core.refine;
const qoi = refine.qoi;
const wire = refine.wire;
const cell = wire.cell_size;

/// A QOI tile of any bytes: decoding never writes past the buffer; what decodes encodes
/// again and decodes to the same pixels.
pub fn qoiDecode(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [wire.max_tile_len + 64]u8 = undefined;
    const data = c.bytes(s, &in);
    const w = s.valueRangeAtMost(u32, 1, cell);
    const h = s.valueRangeAtMost(u32, 1, cell);
    const order: qoi.Order = if (s.value(bool)) .bgra else .rgba;
    var px: [cell * cell * 4]u8 = undefined;
    qoi.decode(data, w, h, &px, w * 4, order) catch return;
    if (order == .rgba) return;
    var enc: [qoi.maxEncodedLen(cell, cell)]u8 = undefined;
    const again = try qoi.encode(&px, w * 4, w, h, &enc);
    var px2: [cell * cell * 4]u8 = undefined;
    try qoi.decode(again, w, h, &px2, w * 4, .bgra);
    try c.expectEqualBytes(px[0 .. w * h * 4], px2[0 .. w * h * 4]);
}

fn qoiSeeds(ss: *c.Seeds) void {
    var px: [16 * 16 * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = if (i % 4 == 3) 255 else @truncate((i / 4) % 7 * 40);
    var enc: [qoi.maxEncodedLen(16, 16)]u8 = undefined;
    const e = qoi.encode(&px, 16 * 4, 16, 16, &enc) catch unreachable;
    const sd = ss.new();
    sd.slice(e);
    sd.int(@as(u32, 15)); // valueRangeAtMost stores the offset from 1
    sd.int(@as(u32, 15));
    sd.int(true);
}

const WireKind = enum(u8) { piece, damage, ack, _ };

/// Refine messages of any bytes: what decodes encodes again to a message that decodes to
/// the same thing.
pub fn wireMessages(_: std.mem.Allocator, s: *c.Smith) !void {
    var in: [1500]u8 = undefined;
    while (!s.eosWeightedSimple(16, 1)) {
        const kind = s.value(WireKind);
        const b = c.bytes(s, &in);
        var out: [1500]u8 = undefined;
        switch (kind) {
            .piece => {
                const p = wire.TilePiece.decode(b) catch continue;
                const e = try p.encode(&out);
                const q = try wire.TilePiece.decode(e);
                try c.expect(p.epoch == q.epoch and p.cell == q.cell and p.since == q.since and p.piece == q.piece and p.pieces == q.pieces and p.total_len == q.total_len);
                try c.expectEqualBytes(p.data, q.data);
            },
            .damage => {
                var maps: [wire.Damage.max_maps][]u8 = undefined;
                var store: [wire.Damage.max_maps][wire.Damage.bytesFor(std.math.maxInt(u16))]u8 = undefined;
                const cells: u16 = s.value(u16);
                for (&maps, &store) |*m, *st| m.* = st[0..wire.Damage.bytesFor(cells)];
                const m = wire.Damage.decode(b, &maps) catch continue;
                if (m.cells != cells) continue;
                var big: [wire.Damage.max_maps * wire.Damage.bytesFor(std.math.maxInt(u16)) + 64]u8 = undefined;
                const e = m.encode(&big) catch continue;
                var maps2: [wire.Damage.max_maps][]u8 = undefined;
                var store2: [wire.Damage.max_maps][wire.Damage.bytesFor(std.math.maxInt(u16))]u8 = undefined;
                for (&maps2, &store2) |*m2, *st| m2.* = st[0..wire.Damage.bytesFor(cells)];
                const m2 = try wire.Damage.decode(e, &maps2);
                try c.expect(m.epoch == m2.epoch and m.frame_id == m2.frame_id and m.span == m2.span and m.all == m2.all and m.maps.len == m2.maps.len);
                for (m.maps, m2.maps) |x, y| try c.expectEqualBytes(x, y);
            },
            .ack, _ => {
                var entries: [wire.TileAck.max_entries]wire.AckEntry = undefined;
                const a = wire.TileAck.decode(b, &entries) catch continue;
                const e = try a.encode(&out);
                var entries2: [wire.TileAck.max_entries]wire.AckEntry = undefined;
                const a2 = try wire.TileAck.decode(e, &entries2);
                try c.expect(a.epoch == a2.epoch and a.reset == a2.reset and a.resync == a2.resync and a.covered_to == a2.covered_to and a.entries.len == a2.entries.len);
                for (a.entries, a2.entries) |x, y| try c.expectEqual(x, y);
            },
        }
    }
}

fn wireSeeds(ss: *c.Seeds) void {
    var buf: [1500]u8 = undefined;
    const sd = ss.new();
    sd.eos(false);
    sd.int(WireKind.piece);
    sd.slice((wire.TilePiece{ .epoch = 1, .cell = 3, .since = 7, .piece = 0, .pieces = 1, .total_len = 4, .data = "abcd" }).encode(&buf) catch unreachable);
    sd.eos(false);
    sd.int(WireKind.damage);
    const bits = [_]u8{ 0b1010_0001, 0x0f };
    sd.slice((wire.Damage{ .epoch = 1, .frame_id = 9, .cells = 15, .maps = &.{&bits} }).encode(&buf) catch unreachable);
    sd.int(@as(u16, 15));
    sd.eos(false);
    sd.int(WireKind.ack);
    const entries = [_]wire.AckEntry{ .{ .cell = 3, .since = 7 }, .{ .cell = 4, .since = 8, .held = false } };
    sd.slice((wire.TileAck{ .epoch = 1, .resync = true, .covered_to = 5, .entries = &entries }).encode(&buf) catch unreachable);
    sd.eos(true);
}

const LayerOp = enum(u8) { refine, present, configure, ack, _ };

/// The client's tile layer fed any refine datagrams and presents: every op stays inside
/// the layer, puts carry whole rows, and memory stays within its config's bounds.
pub fn layer(gpa: std.mem.Allocator, s: *c.Smith) !void {
    var bounded: c.Bounded = .{ .child = gpa, .limit = 24 << 20 };
    var l: refine.Layer = .init(bounded.allocator(), .{ .ready_bytes = 1 << 20 });
    defer l.deinit();
    var w: u32 = 256;
    var h: u32 = 128;
    var epoch: u32 = 1;
    l.configure(epoch, w, h) catch return;
    var frame: u32 = s.value(u32);
    var in: [1500]u8 = undefined;
    while (!s.eosWeightedSimple(64, 1)) switch (s.value(LayerOp)) {
        .refine => {
            const kind: u8 = s.valueRangeAtMost(u8, 0, 3);
            l.onRefine(kind, c.bytes(s, &in));
        },
        .present => {
            frame +%= s.valueRangeAtMost(u32, 0, 3);
            const u = l.present(frame);
            for (u.ops) |op| switch (op) {
                .clear_all => {},
                .clear => |r| try c.expect(r.x + r.w <= u.width and r.y + r.h <= u.height),
                .put => |p| {
                    try c.expect(p.rect.x + p.rect.w <= u.width and p.rect.y + p.rect.h <= u.height);
                    try c.expect(p.pixels.len == @as(usize, p.rect.w) * p.rect.h * 4);
                },
            };
        },
        .configure => {
            epoch +%= 1;
            w = s.valueRangeAtMost(u32, 1, 1024);
            h = s.valueRangeAtMost(u32, 1, 1024);
            l.configure(epoch, w, h) catch return;
        },
        .ack, _ => {
            var out: [1500]u8 = undefined;
            if (l.takeAck(&out)) |a| {
                var entries: [wire.TileAck.max_entries]wire.AckEntry = undefined;
                _ = try wire.TileAck.decode(a, &entries);
            }
        },
    };
    try bounded.check();
}

fn layerSeeds(ss: *c.Seeds) void {
    // A host engine's real messages for a small screen: damage, then a tile in pieces.
    const gpa = std.heap.page_allocator;
    var e = refine.Engine.init(gpa, .{ .tile_after = 1 }, 256, 128, 1) catch unreachable;
    defer e.deinit();
    var px: [cell * cell * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = if (i % 4 == 3) 255 else if ((i / 4) % 5 == 0) 20 else 230;
    const sd = ss.new();
    sd.int(@as(u32, 0));
    var buf: [1500]u8 = undefined;
    var id: u32 = 0;
    while (id < 4) : (id += 1) {
        e.capture(if (id == 0) null else &.{});
        e.commit(id);
        if (e.damageMessage(id, &buf)) |m| {
            sd.eos(false);
            sd.int(LayerOp.refine);
            sd.int(@as(u8, @intFromEnum(core.proto.RefineKind.damage)));
            sd.slice(m);
        }
        var want: [8]u32 = undefined;
        for (want[0..e.wanted(&want)]) |cl| e.offer(cl, &px, cell * 4);
        sd.eos(false);
        sd.int(LayerOp.present);
        sd.int(@as(u32, if (id == 0) 0 else 1));
    }
    var p = refine.Peer.init(gpa, .{});
    defer p.deinit();
    var round: usize = 0;
    while (p.next(&e, .{ .now = 1_000_000, .ok = true, .target_bps = 100e6, .rtt_us = 1000, .frame_us = 16_667 }, round, &buf)) |body| {
        round += body.len;
        sd.eos(false);
        sd.int(LayerOp.refine);
        sd.int(@as(u8, @intFromEnum(core.proto.RefineKind.tile_piece)));
        sd.slice(body);
    }
    for (0..3) |_| {
        sd.eos(false);
        sd.int(LayerOp.present);
        sd.int(@as(u32, 1));
        sd.eos(false);
        sd.int(LayerOp.ack);
    }
    sd.eos(true);
}

const HostOp = enum(u8) { frame, ack, send, _ };

/// The host's engine and a peer fed any tile acks from a client between frames: the
/// pieces and damage it sends decode, and resync answers are well formed.
pub fn hostAcks(gpa: std.mem.Allocator, s: *c.Smith) !void {
    var e = refine.Engine.init(gpa, .{ .tile_after = 1 }, 256, 128, 1) catch return;
    defer e.deinit();
    var p = refine.Peer.init(gpa, .{});
    defer p.deinit();
    var px: [cell * cell * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = if (i % 4 == 3) 255 else if ((i / 4) % 3 == 0) 0 else 200;
    var id: u32 = s.value(u32);
    var now: i64 = 1_000_000;
    var in: [1500]u8 = undefined;
    var out: [1500]u8 = undefined;
    while (!s.eosWeightedSimple(64, 1)) switch (s.value(HostOp)) {
        .frame => {
            e.capture(if (s.value(bool)) null else &.{.{ .x = s.value(u8), .y = s.value(u8) % 128, .w = 64, .h = 64 }});
            e.commit(id);
            if (e.damageMessage(id, &out)) |m| {
                var maps: [wire.Damage.max_maps][]u8 = undefined;
                var store: [wire.Damage.max_maps][wire.Damage.bytesFor(std.math.maxInt(u16))]u8 = undefined;
                for (&maps, &store) |*mm, *st| mm.* = st[0..wire.Damage.bytesFor(e.cells())];
                _ = try wire.Damage.decode(m, &maps);
            }
            var want: [8]u32 = undefined;
            for (want[0..e.wanted(&want)]) |cl| e.offer(cl, &px, cell * 4);
            id +%= 1;
            now += 16_667;
        },
        .ack => {
            var entries: [wire.TileAck.max_entries]wire.AckEntry = undefined;
            const a = wire.TileAck.decode(c.bytes(s, &in), &entries) catch continue;
            if (p.onAck(&e, a)) if (e.unionMessage(a.covered_to, &out)) |m| {
                var maps: [wire.Damage.max_maps][]u8 = undefined;
                var store: [wire.Damage.max_maps][wire.Damage.bytesFor(std.math.maxInt(u16))]u8 = undefined;
                for (&maps, &store) |*mm, *st| mm.* = st[0..wire.Damage.bytesFor(e.cells())];
                const d = try wire.Damage.decode(m, &maps);
                try c.expect(d.all or d.maps.len == 1);
            };
        },
        .send, _ => {
            now += s.valueRangeAtMost(u32, 0, 100_000);
            var round: usize = 0;
            while (p.next(&e, .{ .now = now, .ok = true, .target_bps = 50e6, .rtt_us = 10_000, .frame_us = 16_667 }, round, &out)) |body| {
                round += body.len;
                _ = try wire.TilePiece.decode(body);
            }
        },
    };
}

fn hostSeeds(ss: *c.Seeds) void {
    var buf: [1500]u8 = undefined;
    const sd = ss.new();
    sd.int(@as(u32, 0xffff_fff0));
    for (0..3) |_| {
        sd.eos(false);
        sd.int(HostOp.frame);
        sd.int(false);
        sd.int(@as(u8, 0));
        sd.int(@as(u8, 0));
    }
    sd.eos(false);
    sd.int(HostOp.send);
    sd.int(@as(u32, 50_000));
    sd.eos(false);
    sd.int(HostOp.ack);
    const entries = [_]wire.AckEntry{.{ .cell = 1, .since = 0 }};
    sd.slice((wire.TileAck{ .epoch = 1, .resync = true, .covered_to = 0xffff_ffff, .entries = &entries }).encode(&buf) catch unreachable);
    sd.eos(false);
    sd.int(HostOp.ack);
    sd.slice((wire.TileAck{ .epoch = 1, .reset = true }).encode(&buf) catch unreachable);
    sd.eos(true);
}

test "refine_qoi" {
    try c.fuzz("refine_qoi", qoiDecode, qoiSeeds);
}

test "refine_wire" {
    try c.fuzz("refine_wire", wireMessages, wireSeeds);
}

test "refine_layer" {
    try c.fuzz("refine_layer", layer, layerSeeds);
}

test "refine_host_acks" {
    try c.fuzz("refine_host_acks", hostAcks, hostSeeds);
}
