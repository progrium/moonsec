//! The damage lists of mlh_damage.c (PipeWire's VideoDamage meta, unions over dropped
//! buffers, crops), with no PipeWire: `zig build test` runs these on any Linux host.
const std = @import("std");
const c = @import("mlh_c");

const testing = std.testing;
const native = @import("builtin").cpu.arch.endian();

/// SPA_META_VideoDamage data: struct spa_meta_region { int32 x, y; uint32 w, h; } each.
fn metaRegions(comptime n: usize, regions: [n][4]i64) [n * 16]u8 {
    var out: [n * 16]u8 = undefined;
    for (regions, 0..) |r, i| {
        std.mem.writeInt(i32, out[i * 16 ..][0..4], @intCast(r[0]), native);
        std.mem.writeInt(i32, out[i * 16 + 4 ..][0..4], @intCast(r[1]), native);
        std.mem.writeInt(u32, out[i * 16 + 8 ..][0..4], @intCast(r[2]), native);
        std.mem.writeInt(u32, out[i * 16 + 12 ..][0..4], @intCast(r[3]), native);
    }
    return out;
}

fn expectRects(d: *const c.mlh_damage, want: []const [4]u32) !void {
    try testing.expect(d.known != 0);
    try testing.expectEqual(want.len, d.n);
    for (want, d.r[0..d.n]) |w, r| try testing.expectEqual(w, [4]u32{ r.x, r.y, r.w, r.h });
}

test "damage: VideoDamage regions end at the first empty one and are cut to the buffer" {
    var d: c.mlh_damage = undefined;
    const meta = metaRegions(4, .{ .{ 10, 20, 30, 40 }, .{ -5, 1900, 20, 500 }, .{ 0, 0, 0, 0 }, .{ 1, 1, 1, 1 } });
    c.mlh_damage_from_meta(&d, &meta, meta.len, 1920, 2000);
    try expectRects(&d, &.{ .{ 10, 20, 30, 40 }, .{ 0, 1900, 15, 100 } });

    // A region wholly off the buffer still counts as a region (the list is not empty).
    const off = metaRegions(1, .{.{ 4000, 0, 10, 10 }});
    c.mlh_damage_from_meta(&d, &off, off.len, 1920, 1080);
    try expectRects(&d, &.{});

    // No regions on a picture buffer: unknown, not "nothing changed".
    const none = metaRegions(1, .{.{ 0, 0, 0, 0 }});
    c.mlh_damage_from_meta(&d, &none, none.len, 1920, 1080);
    try testing.expectEqual(@as(u8, 0), d.known);
    c.mlh_damage_from_meta(&d, null, 0, 1920, 1080);
    try testing.expectEqual(@as(u8, 0), d.known);
}

test "damage: unions over dropped buffers, overflow grows the last rectangle, unknown wins" {
    var acc: c.mlh_damage = undefined;
    var d: c.mlh_damage = undefined;
    c.mlh_damage_reset(&acc, 1);
    c.mlh_damage_reset(&d, 1);
    c.mlh_damage_add(&d, 0, 0, 8, 8, 100, 100);
    c.mlh_damage_union(&acc, &d);
    c.mlh_damage_union(&acc, &d);
    try expectRects(&acc, &.{ .{ 0, 0, 8, 8 }, .{ 0, 0, 8, 8 } });

    c.mlh_damage_reset(&acc, 1);
    var i: i32 = 0;
    while (i < c.MLH_DAMAGE_MAX + 3) : (i += 1) c.mlh_damage_add(&acc, i * 2, i, 1, 1, 1000, 1000);
    try testing.expectEqual(@as(u32, c.MLH_DAMAGE_MAX), acc.n);
    const last = acc.r[c.MLH_DAMAGE_MAX - 1];
    const k: u32 = c.MLH_DAMAGE_MAX - 1;
    try testing.expectEqual([4]u32{ k * 2, k, 2 * 3 + 1, 3 + 1 }, [4]u32{ last.x, last.y, last.w, last.h });

    c.mlh_damage_reset(&d, 0);
    c.mlh_damage_union(&acc, &d);
    try testing.expectEqual(@as(u8, 0), acc.known);
    c.mlh_damage_reset(&d, 1);
    c.mlh_damage_add(&d, 0, 0, 8, 8, 100, 100);
    c.mlh_damage_union(&acc, &d);
    try testing.expectEqual(@as(u8, 0), acc.known);
}

test "damage: a crop moves and cuts the buffer's damage into frame pixels" {
    var in: c.mlh_damage = undefined;
    var out: c.mlh_damage = undefined;
    c.mlh_damage_reset(&in, 1);
    c.mlh_damage_add(&in, 0, 0, 50, 50, 1000, 1000);
    c.mlh_damage_add(&in, 90, 95, 30, 30, 1000, 1000);
    c.mlh_damage_add(&in, 500, 500, 10, 10, 1000, 1000);
    c.mlh_damage_crop(&in, 40, 40, 100, 70, &out);
    try expectRects(&out, &.{ .{ 0, 0, 10, 10 }, .{ 50, 55, 30, 15 } });

    c.mlh_damage_reset(&in, 0);
    c.mlh_damage_crop(&in, 0, 0, 10, 10, &out);
    try testing.expectEqual(@as(u8, 0), out.known);
}
