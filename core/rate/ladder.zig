//! The response ladder: bitrate first, then resolution, then frame rate
//! (design doc, "Rate control": latency first, then frame rate, then
//! quality).
//!
//! The rate controller says how many bits the encoder may send. The ladder
//! turns that into an encoder setting. Every bitrate change goes to the
//! encoder as it comes, since a bitrate change needs no keyframe. When the
//! bits per pixel at the current size fall too low, the picture looks better
//! smaller, so the ladder steps down to a lower resolution. Only at the
//! lowest resolution does it give up frame rate. Going back up runs the
//! other way: frame rate first, then resolution, one rung at a time and only
//! when the next rung up would still have bits to spare.
//!
//! A resolution or frame-rate change is a reconfigure, which costs a
//! keyframe on most encoders, so changes are held back: a step down waits
//! `hold_down_us`, a step up `hold_up_us`, and there are at least
//! `min_gap_us` between reconfigures. A step down jumps straight to the
//! first rung that has enough bits, so a halving costs one keyframe, not
//! several.
//!
//! `Limits` are outside caps, for relay mode (core/media's policy): a
//! bitrate cap, a height cap the ladder moves under at once, and the FEC
//! overhead, which the encoder budget leaves room for.
//!
//! Sans-I/O: `update` takes the host clock and the controller's encoder rate
//! and returns what to tell the encoder.
const std = @import("std");

pub const Rung = struct {
    width: u32,
    height: u32,
    fps: u32,

    pub fn pixelsPerSecond(r: Rung) f64 {
        return @as(f64, @floatFromInt(r.width)) * @as(f64, @floatFromInt(r.height)) * @as(f64, @floatFromInt(r.fps));
    }

    pub fn eql(a: Rung, b: Rung) bool {
        return a.width == b.width and a.height == b.height and a.fps == b.fps;
    }
};

pub const Config = struct {
    /// The capture size and frame rate: the top rung.
    width: u32,
    height: u32,
    fps: u32 = 60,
    /// Heights to step down through, highest first. Those at or above the
    /// capture height are skipped; widths keep the capture's aspect ratio.
    heights: []const u32 = &.{ 1440, 1080, 900, 720, 540, 432, 360 },
    /// Frame rates for the bottom of the ladder, highest first, all below `fps`.
    frame_rates: []const u32 = &.{ 45, 30 },
    /// Step down when bits per pixel (bitrate / pixels per second) fall
    /// below this; step up when the next rung up would get at least
    /// `up_bpp`. Tuned for low-latency H.264 (no B-frames, one-frame VBV):
    /// 1080p60 steps down under about 6.2 Mbit/s. HEVC and AV1 need fewer
    /// bits: scale both by `codec_factor` (about 0.65).
    down_bpp: f64 = 0.05,
    up_bpp: f64 = 0.08,
    codec_factor: f64 = 1.0,
    hold_down_us: i64 = 1_000_000,
    hold_up_us: i64 = 4_000_000,
    min_gap_us: i64 = 2_000_000,
    /// Bitrate changes smaller than this fraction are not sent.
    bitrate_deadband: f64 = 0.05,
    min_bps: u64 = 300_000,
};

/// Caps from outside the rate controller (relay mode, FEC).
pub const Limits = struct {
    max_bitrate_bps: ?u64 = null,
    /// The ladder moves to a rung at most this tall at once (relay mode
    /// prefers lower resolution).
    max_height: ?u32 = null,
    /// FEC parity / data. The encoder gets target / (1 + overhead) so data
    /// plus parity fit the controller's rate.
    fec_overhead: f64 = 0,
};

/// What to tell the encoder after an `update`.
pub const Request = struct {
    /// New encoder bitrate (`EncodeParams.bitrate_bps`), 0 = unchanged.
    bitrate_bps: u64 = 0,
    /// New size and frame rate (`Encoder.configure`), null = unchanged.
    /// Expect a keyframe.
    reconfigure: ?Rung = null,
};

pub const max_rungs = 16;

pub const Ladder = struct {
    cfg: Config,
    rungs: [max_rungs]Rung = undefined,
    n: usize = 0,
    /// Current rung, 0 = top.
    cur: usize = 0,
    bitrate_bps: u64 = 0,
    /// When the current want-down / want-up condition began, -1 = not now.
    down_since_us: i64 = -1,
    up_since_us: i64 = -1,
    last_change_us: i64 = std.math.minInt(i64),
    steps_down: u32 = 0,
    steps_up: u32 = 0,

    pub fn init(cfg: Config) Ladder {
        std.debug.assert(cfg.width > 0 and cfg.height > 0 and cfg.fps > 0);
        var l = Ladder{ .cfg = cfg };
        l.add(.{ .width = cfg.width, .height = cfg.height, .fps = cfg.fps });
        for (cfg.heights) |h| {
            if (h >= cfg.height) continue;
            l.add(.{ .width = scaleWidth(cfg.width, cfg.height, h), .height = h, .fps = cfg.fps });
        }
        const bottom = l.rungs[l.n - 1];
        for (cfg.frame_rates) |f| {
            if (f >= cfg.fps) continue;
            l.add(.{ .width = bottom.width, .height = bottom.height, .fps = f });
        }
        return l;
    }

    fn add(l: *Ladder, r: Rung) void {
        if (l.n == max_rungs) return;
        l.rungs[l.n] = r;
        l.n += 1;
    }

    pub fn current(l: *const Ladder) Rung {
        return l.rungs[l.cur];
    }

    pub fn ladder(l: *const Ladder) []const Rung {
        return l.rungs[0..l.n];
    }

    /// The encoder budget for a controller encoder rate under `lim`.
    pub fn budget(l: *const Ladder, encoder_bps: f64, lim: Limits) f64 {
        var b = encoder_bps;
        if (lim.max_bitrate_bps) |m| b = @min(b, @as(f64, @floatFromInt(m)));
        b /= 1 + @max(lim.fec_overhead, 0);
        return @max(b, @as(f64, @floatFromInt(l.cfg.min_bps)));
    }

    fn bpp(l: *const Ladder, bps: f64, r: Rung) f64 {
        return bps / r.pixelsPerSecond() / l.cfg.codec_factor;
    }

    /// The highest rung allowed under `lim`.
    fn topAllowed(l: *const Ladder, lim: Limits) usize {
        const mh = lim.max_height orelse return 0;
        for (l.rungs[0..l.n], 0..) |r, i| if (r.height <= mh) return i;
        return l.n - 1;
    }

    /// Feed the controller's encoder rate (`Controller.encoderBps`) and the
    /// current limits, once per frame or per feedback.
    pub fn update(l: *Ladder, now_us: i64, encoder_bps: f64, lim: Limits) Request {
        var req = Request{};
        const b = l.budget(encoder_bps, lim);
        const top = l.topAllowed(lim);
        var next = l.cur;

        if (l.cur < top) {
            // A cap came in: move under it now, no hold.
            next = l.fitFrom(top, b);
        } else {
            const r = l.rungs[l.cur];
            const spaced = l.last_change_us == std.math.minInt(i64) or now_us - l.last_change_us >= l.cfg.min_gap_us;
            // Down: too few bits here.
            if (l.cur + 1 < l.n and l.bpp(b, r) < l.cfg.down_bpp) {
                if (l.down_since_us < 0) l.down_since_us = now_us;
                if (spaced and now_us - l.down_since_us >= l.cfg.hold_down_us) next = l.fitFrom(l.cur + 1, b);
            } else l.down_since_us = -1;
            // Up: the next rung up would still have bits to spare.
            if (l.cur > top and l.bpp(b, l.rungs[l.cur - 1]) >= l.cfg.up_bpp) {
                if (l.up_since_us < 0) l.up_since_us = now_us;
                if (spaced and now_us - l.up_since_us >= l.cfg.hold_up_us) next = l.cur - 1;
            } else l.up_since_us = -1;
        }

        if (next != l.cur) {
            if (next > l.cur) l.steps_down += 1 else l.steps_up += 1;
            l.cur = next;
            l.last_change_us = now_us;
            l.down_since_us = -1;
            l.up_since_us = -1;
            req.reconfigure = l.rungs[next];
        }
        const nb: u64 = @intFromFloat(b);
        const old: f64 = @floatFromInt(l.bitrate_bps);
        if (req.reconfigure != null or l.bitrate_bps == 0 or @abs(b - old) > l.cfg.bitrate_deadband * old) {
            l.bitrate_bps = nb;
            req.bitrate_bps = nb;
        }
        return req;
    }

    /// The first rung from `from` down with enough bits, or the bottom one.
    fn fitFrom(l: *const Ladder, from: usize, b: f64) usize {
        var i = from;
        while (i + 1 < l.n and l.bpp(b, l.rungs[i]) < l.cfg.down_bpp) i += 1;
        return i;
    }
};

/// Width for height `h` at the aspect ratio of `w0` x `h0`, rounded to even.
fn scaleWidth(w0: u32, h0: u32, h: u32) u32 {
    const w = (@as(u64, w0) * h + h0 / 2) / h0;
    return @intCast(@max(2, (w + 1) & ~@as(u64, 1)));
}

const testing = std.testing;
const S = 1_000_000;

fn ladder1080() Ladder {
    return Ladder.init(.{ .width = 1920, .height = 1080 });
}

test "rungs: resolutions at 60 fps, then frame rates at the bottom" {
    const l = ladder1080();
    const r = l.ladder();
    try testing.expectEqual(@as(usize, 8), r.len);
    try testing.expect(r[0].eql(.{ .width = 1920, .height = 1080, .fps = 60 }));
    try testing.expect(r[1].eql(.{ .width = 1600, .height = 900, .fps = 60 }));
    try testing.expect(r[2].eql(.{ .width = 1280, .height = 720, .fps = 60 }));
    try testing.expect(r[4].eql(.{ .width = 768, .height = 432, .fps = 60 }));
    try testing.expect(r[5].eql(.{ .width = 640, .height = 360, .fps = 60 }));
    try testing.expect(r[6].eql(.{ .width = 640, .height = 360, .fps = 45 }));
    try testing.expect(r[7].eql(.{ .width = 640, .height = 360, .fps = 30 }));
    // An odd aspect ratio still gives even widths.
    try testing.expectEqual(@as(u32, 1068), scaleWidth(1366, 768, 600));
}

test "bitrate changes pass through without a reconfigure, past a deadband" {
    var l = ladder1080();
    var r = l.update(0, 20e6, .{});
    try testing.expectEqual(@as(u64, 20_000_000), r.bitrate_bps);
    try testing.expect(r.reconfigure == null);
    r = l.update(100_000, 20.5e6, .{}); // 2.5%: below the deadband
    try testing.expectEqual(@as(u64, 0), r.bitrate_bps);
    r = l.update(200_000, 15e6, .{});
    try testing.expectEqual(@as(u64, 15_000_000), r.bitrate_bps);
    try testing.expect(r.reconfigure == null);
}

test "a halving steps resolution down once, after the hold" {
    var l = ladder1080();
    _ = l.update(0, 10e6, .{});
    // 1080p60 at 3 Mbit/s is 0.024 bpp: wants down, waits out the hold.
    try testing.expect(l.update(100_000, 3e6, .{}).reconfigure == null);
    try testing.expect(l.update(900_000, 3e6, .{}).reconfigure == null);
    const r = l.update(1_200_000, 3e6, .{});
    // Straight to the first rung with 0.05 bpp: 720p60 has 0.054.
    try testing.expect(r.reconfigure.?.eql(.{ .width = 1280, .height = 720, .fps = 60 }));
    try testing.expectEqual(@as(u64, 3_000_000), r.bitrate_bps);
    try testing.expectEqual(@as(u32, 1), l.steps_down);
}

test "frame rate goes only after the lowest resolution" {
    var l = ladder1080();
    var t: i64 = 0;
    var last: ?Rung = null;
    while (t < 10 * S) : (t += 100_000) {
        if (l.update(t, 500_000, .{}).reconfigure) |r| last = r;
    }
    // 0.5 Mbit/s: 360p at 30 fps (0.072 bpp) is the bottom.
    try testing.expect(last.?.eql(.{ .width = 640, .height = 360, .fps = 30 }));
    // Coming back, frame rate returns before resolution.
    var ups: [8]Rung = undefined;
    var nu: usize = 0;
    while (t < 60 * S) : (t += 100_000) {
        if (l.update(t, 20e6, .{}).reconfigure) |r| {
            ups[nu] = r;
            nu += 1;
        }
    }
    try testing.expect(ups[0].eql(.{ .width = 640, .height = 360, .fps = 45 }));
    try testing.expect(ups[1].eql(.{ .width = 640, .height = 360, .fps = 60 }));
    try testing.expect(ups[nu - 1].eql(.{ .width = 1920, .height = 1080, .fps = 60 }));
    // One rung at a time, each held 4 s.
    try testing.expectEqual(@as(usize, 7), nu);
}

test "hysteresis: a rate between the thresholds holds the rung" {
    var l = ladder1080();
    var t: i64 = 0;
    while (t < 3 * S) : (t += 100_000) _ = l.update(t, 3e6, .{});
    try testing.expectEqual(@as(u32, 720), l.current().height);
    // 4.2 Mbit/s: 720p has plenty, but 900p would get only 0.049 bpp.
    while (t < 30 * S) : (t += 100_000) try testing.expect(l.update(t, 4.2e6, .{}).reconfigure == null);
    try testing.expectEqual(@as(u32, 720), l.current().height);
}

test "relay limits: height cap at once, bitrate cap and FEC room in the budget" {
    var l = ladder1080();
    _ = l.update(0, 20e6, .{});
    const lim = Limits{ .max_height = 720, .max_bitrate_bps = 6_000_000, .fec_overhead = 0.2 };
    const r = l.update(100_000, 20e6, lim);
    try testing.expect(r.reconfigure.?.eql(.{ .width = 1280, .height = 720, .fps = 60 }));
    try testing.expectEqual(@as(u64, 5_000_000), r.bitrate_bps);
    // It doesn't climb back over the cap.
    var t: i64 = 200_000;
    while (t < 20 * S) : (t += 100_000) try testing.expect(l.update(t, 20e6, lim).reconfigure == null);
    // Cap lifted: back up, one rung at a time.
    var top: u32 = 0;
    while (t < 40 * S) : (t += 100_000) if (l.update(t, 20e6, .{}).reconfigure) |x| {
        top = x.height;
    };
    try testing.expectEqual(@as(u32, 1080), top);
}

test "a capture smaller than every listed height is a one-resolution ladder" {
    var l = Ladder.init(.{ .width = 640, .height = 360, .fps = 60 });
    try testing.expectEqual(@as(usize, 3), l.ladder().len);
    var t: i64 = 0;
    while (t < 10 * S) : (t += 100_000) _ = l.update(t, 100_000, .{});
    try testing.expectEqual(@as(u32, 30), l.current().fps);
}
