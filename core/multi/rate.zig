//! The shared encoder's bitrate when one encode goes to several clients.
//!
//! Each client's rate controller estimates what its own path carries; the encoder can only
//! run at one rate. `lowest` (the default) keeps every client's path uncongested at the cost
//! of quality for all; `median` favours the majority and leaves the slowest members to
//! their pacer, NACK/FEC and recovery. `floor_bps` stops one bad path from dragging the
//! stream below a useful rate: a member whose estimate is under it gets more than its path
//! carries and recovers from its losses alone (its recovery frames are LTR refreshes the
//! others decode as ordinary frames).
const std = @import("std");

pub const Rule = enum { lowest, median };

pub const Config = struct {
    rule: Rule = .lowest,
    floor_bps: u64 = 0,
};

/// The shared rate from the members' estimates (bits/s; 0 = no estimate yet, ignored).
/// Null when no member has an estimate.
pub fn combine(cfg: Config, estimates: []const u64) ?u64 {
    var buf: [32]u64 = undefined;
    var n: usize = 0;
    for (estimates) |e| if (e > 0 and n < buf.len) {
        buf[n] = e;
        n += 1;
    };
    if (n == 0) return null;
    const v = buf[0..n];
    std.mem.sort(u64, v, {}, std.sort.asc(u64));
    const pick = switch (cfg.rule) {
        .lowest => v[0],
        .median => v[(n - 1) / 2],
    };
    return @max(pick, cfg.floor_bps);
}

test combine {
    const t = std.testing;
    try t.expectEqual(@as(?u64, null), combine(.{}, &.{ 0, 0 }));
    try t.expectEqual(@as(?u64, 3), combine(.{}, &.{ 5, 0, 3, 9 }));
    try t.expectEqual(@as(?u64, 5), combine(.{ .rule = .median }, &.{ 5, 3, 9 }));
    // Even count: the lower middle (err on the side of the slower half).
    try t.expectEqual(@as(?u64, 3), combine(.{ .rule = .median }, &.{ 5, 3, 9, 1 }));
    try t.expectEqual(@as(?u64, 4), combine(.{ .floor_bps = 4 }, &.{ 5, 3 }));
}
