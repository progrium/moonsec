//! What the client does with the host's session config and access units on the synthetic
//! backend (platform/synthetic): configure the passthrough decoder with the host's
//! dimensions, then decode whatever arrives.
const std = @import("std");
const api = @import("platform");
const synthetic = @import("synthetic");
const c = @import("common.zig");

fn zeroClock(_: ?*anyopaque) api.Micros {
    return 0;
}

/// Width and height come from the host (`app/wire.zig` Config), so any pair must either
/// configure or fail cleanly, within a memory bound; access units are any bytes.
pub fn passthroughDecoder(gpa: std.mem.Allocator, s: *c.Smith) !void {
    var bounded: c.Bounded = .{ .child = gpa, .limit = 8 << 20 };
    var d: synthetic.Decoder = .{ .gpa = bounded.allocator(), .clock = .{ .nowFn = zeroClock } };
    defer d.deinit();
    const small = s.value(bool);
    const w: u32 = if (small) s.valueRangeAtMost(u32, 0, 1024) else s.value(u32);
    const h: u32 = if (small) s.valueRangeAtMost(u32, 0, 1024) else s.value(u32);
    d.configure(.{ .codec = .passthrough, .width = w, .height = h }) catch return;
    var frame: u32 = 0;
    while (!s.eosWeightedSimple(16, 1)) {
        var in: [4096]u8 = undefined;
        const data = c.bytes(s, &in);
        const au: api.AccessUnit = .{ .codec = .passthrough, .frame_id = frame, .data = data, .keyframe = s.value(bool), .capture_us = 0, .received_us = 0 };
        frame +%= 1;
        if (d.decode(&au) catch null) |f| {
            try c.expect(f.image.width == w and f.image.height == h);
            d.release(&f);
        }
    }
}

fn passthroughSeeds(ss: *c.Seeds) void {
    var hb: [synthetic.header_len]u8 = undefined;
    (synthetic.AuHeader{ .flags = .{ .keyframe = true }, .width = 128, .height = 64, .stamp = .{ .time_us = 0, .frame = 0 }, .seq = 0, .ref = 0, .pixel_crc = 0, .total_len = synthetic.header_len, .ltr_token = 0 }).encode(&hb);
    const sd = ss.new();
    sd.int(true);
    sd.int(@as(u32, 128));
    sd.int(@as(u32, 64));
    sd.eos(false);
    sd.slice(&hb);
    sd.int(true);
    sd.eos(true);
}

test "video_passthrough_decoder" {
    try c.fuzz("video_passthrough_decoder", passthroughDecoder, passthroughSeeds);
}
