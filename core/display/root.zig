//! Displays: the host's display list, the client's choice of display and size, and the
//! bookkeeping for a stream whose size changes mid-session (spec/wire-v0.md, "Displays").
//!
//! The host lists its displays (`DisplayList`); the client picks one, or caps the size
//! and frame rate, with `SelectDisplay`; the host answers with a new stream config that
//! takes effect at a given frame (`config.first_frame`, an IDR), and the client acks it
//! with `ConfigAck`. The rate ladder's resolution and frame-rate steps use the same
//! mid-stream config. `Schedule` is the client's side of that: configs can arrive before
//! or after their first frame, and frames before it still use the old config.
//!
//! Sans-I/O and allocation-free; builds for wasm32 (the web client takes the same messages).
const std = @import("std");

/// Control-channel message types for these bodies (spec/control-v0.md registry block
/// 0x0200-0x02ff; bodies in spec/display-v0.md). Until the session runs on the control
/// channel, the same bodies ride control-fast datagrams (spec/wire-v0.md, "Session").
pub const msg = struct {
    pub const display_list: u16 = 0x0200;
    pub const select_display: u16 = 0x0201;
    pub const stream_config: u16 = 0x0202;
    pub const config_ack: u16 = 0x0203;
};

/// `hello` feature bit (block 8-15): "I take the display messages and mid-stream configs".
pub const feature_displays: u64 = 1 << 8;

/// "Keep the current display" in `SelectDisplay.display`.
pub const keep_display: u32 = 0xffff_ffff;

/// One display the host can capture.
pub const DisplayInfo = struct {
    /// The backend's id for it, which `CaptureConfig.display` takes. Stable while the
    /// display stays connected; ids of displays that come back may differ.
    id: u32,
    /// Current mode, in pixels, and refresh rate in millihertz (0 = unknown).
    width: u32,
    height: u32,
    refresh_mhz: u32 = 0,
    /// Top-left corner on the host's desktop.
    x: i32 = 0,
    y: i32 = 0,
    primary: bool = false,
    name_buf: [name_max]u8 = @splat(0),
    name_len: u8 = 0,

    pub const name_max = 24;
    pub const wire_len = 52;

    pub fn name(d: *const DisplayInfo) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    /// Copies `n`, cut to `name_max` bytes (at a UTF-8 boundary).
    pub fn setName(d: *DisplayInfo, n: []const u8) void {
        var len = @min(n.len, name_max);
        while (len > 0 and len < n.len and n[len] & 0xc0 == 0x80) len -= 1;
        d.name_buf = @splat(0);
        @memcpy(d.name_buf[0..len], n[0..len]);
        d.name_len = @intCast(len);
    }

    pub fn eql(a: DisplayInfo, b: DisplayInfo) bool {
        return a.id == b.id and a.width == b.width and a.height == b.height and a.refresh_mhz == b.refresh_mhz and
            a.x == b.x and a.y == b.y and a.primary == b.primary and std.mem.eql(u8, a.name(), b.name());
    }

    fn encode(d: DisplayInfo, out: *[wire_len]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], d.id, .little);
        std.mem.writeInt(u32, out[4..8], d.width, .little);
        std.mem.writeInt(u32, out[8..12], d.height, .little);
        std.mem.writeInt(u32, out[12..16], d.refresh_mhz, .little);
        std.mem.writeInt(i32, out[16..20], d.x, .little);
        std.mem.writeInt(i32, out[20..24], d.y, .little);
        out[24] = @intFromBool(d.primary);
        out[25] = d.name_len;
        @memcpy(out[28..52], &d.name_buf);
    }

    fn decode(b: *const [wire_len]u8) ?DisplayInfo {
        var d: DisplayInfo = .{
            .id = std.mem.readInt(u32, b[0..4], .little),
            .width = std.mem.readInt(u32, b[4..8], .little),
            .height = std.mem.readInt(u32, b[8..12], .little),
            .refresh_mhz = std.mem.readInt(u32, b[12..16], .little),
            .x = std.mem.readInt(i32, b[16..20], .little),
            .y = std.mem.readInt(i32, b[20..24], .little),
            .primary = b[24] & 1 != 0,
            .name_len = b[25],
        };
        if (d.width == 0 or d.height == 0 or d.name_len > name_max) return null;
        @memcpy(&d.name_buf, b[28..52]);
        if (!std.unicode.utf8ValidateSlice(d.name())) return null;
        return d;
    }
};

pub fn sameList(a: []const DisplayInfo, b: []const DisplayInfo) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

/// Host to client: the displays, the one being streamed, and a generation that changes
/// whenever the list does (hotplug, a mode change).
pub const DisplayList = struct {
    gen: u32,
    /// Id of the display being streamed.
    current: u32,
    displays: []const DisplayInfo,

    pub const header_len = 12;
    /// Fits a 1200-byte datagram with room to spare.
    pub const max_displays = 16;

    pub fn encodedLen(l: DisplayList) usize {
        return header_len + l.displays.len * DisplayInfo.wire_len;
    }

    pub fn encode(l: DisplayList, out: []u8) error{ NoSpace, TooMany }![]u8 {
        if (l.displays.len > max_displays) return error.TooMany;
        const n = l.encodedLen();
        if (out.len < n) return error.NoSpace;
        std.mem.writeInt(u32, out[0..4], l.gen, .little);
        std.mem.writeInt(u32, out[4..8], l.current, .little);
        out[8] = @intCast(l.displays.len);
        @memset(out[9..12], 0);
        for (l.displays, 0..) |d, i| d.encode(out[header_len + i * DisplayInfo.wire_len ..][0..DisplayInfo.wire_len]);
        return out[0..n];
    }

    pub const Decoded = struct { gen: u32, current: u32, n: usize };

    /// Entries go to `out` (at least `max_displays` long to take any list).
    pub fn decode(b: []const u8, out: []DisplayInfo) ?Decoded {
        if (b.len < header_len) return null;
        const n = b[8];
        if (n > max_displays or n > out.len or b.len != header_len + @as(usize, n) * DisplayInfo.wire_len) return null;
        for (0..n) |i| out[i] = DisplayInfo.decode(b[header_len + i * DisplayInfo.wire_len ..][0..DisplayInfo.wire_len]) orelse return null;
        return .{ .gen = std.mem.readInt(u32, b[0..4], .little), .current = std.mem.readInt(u32, b[4..8], .little), .n = n };
    }
};

/// Client to host: stream this display (or `keep_display`), at most this big and this
/// fast (0 = no cap). Repeated until a config with `request` at least this arrives.
pub const SelectDisplay = struct {
    /// Increments per new choice; the host echoes the newest it applied in `config.request`.
    request: u32,
    display: u32 = keep_display,
    max_width: u32 = 0,
    max_height: u32 = 0,
    max_fps: u16 = 0,

    pub const len = 20;

    pub fn encode(s: SelectDisplay, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], s.request, .little);
        std.mem.writeInt(u32, out[4..8], s.display, .little);
        std.mem.writeInt(u32, out[8..12], s.max_width, .little);
        std.mem.writeInt(u32, out[12..16], s.max_height, .little);
        std.mem.writeInt(u16, out[16..18], s.max_fps, .little);
        out[18] = 0;
        out[19] = 0;
    }

    pub fn decode(b: []const u8) ?SelectDisplay {
        if (b.len != len) return null;
        return .{
            .request = std.mem.readInt(u32, b[0..4], .little),
            .display = std.mem.readInt(u32, b[4..8], .little),
            .max_width = std.mem.readInt(u32, b[8..12], .little),
            .max_height = std.mem.readInt(u32, b[12..16], .little),
            .max_fps = std.mem.readInt(u16, b[16..18], .little),
        };
    }
};

/// Client to host: the newest config epoch and display-list generation the client has.
/// Sent on every config and display list that arrives; the host repeats both until acked.
pub const ConfigAck = struct {
    nonce: u32,
    epoch: u32,
    display_gen: u32,

    pub const len = 12;

    pub fn encode(a: ConfigAck, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], a.nonce, .little);
        std.mem.writeInt(u32, out[4..8], a.epoch, .little);
        std.mem.writeInt(u32, out[8..12], a.display_gen, .little);
    }

    pub fn decode(b: []const u8) ?ConfigAck {
        if (b.len != len) return null;
        return .{
            .nonce = std.mem.readInt(u32, b[0..4], .little),
            .epoch = std.mem.readInt(u32, b[4..8], .little),
            .display_gen = std.mem.readInt(u32, b[8..12], .little),
        };
    }
};

/// `a` is newer than `b` (wrapping u32 counters: epochs, frame ids).
pub fn newer(a: u32, b: u32) bool {
    return @as(i32, @bitCast(b -% a)) < 0;
}

/// The largest size with the aspect ratio of `w`×`h` that fits `max_w`×`max_h` (0 = no
/// cap) and does not grow it; even dimensions, as 4:2:0 encoders need.
pub fn fit(w: u32, h: u32, max_w: u32, max_h: u32) struct { width: u32, height: u32 } {
    var sw: u64 = w;
    var sh: u64 = h;
    if (max_w != 0 and sw > max_w) {
        sh = sh * max_w / sw;
        sw = max_w;
    }
    if (max_h != 0 and sh > max_h) {
        sw = sw * max_h / sh;
        sh = max_h;
    }
    const ew: u32 = @intCast(sw & ~@as(u64, 1));
    const eh: u32 = @intCast(sh & ~@as(u64, 1));
    return .{ .width = @max(ew, 2), .height = @max(eh, 2) };
}

/// The client's view of mid-stream configs: each takes effect at its `first_frame`.
/// `offer` the configs as they arrive (in any order, repeats welcome); `forFrame` says
/// which one a frame uses and moves `current` forward. `T` is the config payload.
pub fn Schedule(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { epoch: u32, first_frame: u32, value: T };
        pub const capacity = 4;

        current: ?Entry = null,
        pending: [capacity]?Entry = @splat(null),
        /// Configs that came after a newer one had taken effect, or were pushed out.
        stale: u64 = 0,

        /// A config from the host. Returns true when it is new.
        pub fn offer(s: *Self, e: Entry) bool {
            if (s.current) |c| if (!newer(e.epoch, c.epoch)) {
                if (e.epoch != c.epoch) s.stale += 1;
                return false;
            };
            for (s.pending) |p| if (p) |x| if (x.epoch == e.epoch) return false;
            // A free slot, else replace the oldest epoch.
            var slot: usize = 0;
            for (s.pending, 0..) |p, i| {
                const x = p orelse {
                    slot = i;
                    break;
                };
                if (newer(s.pending[slot].?.epoch, x.epoch)) slot = i;
            } else s.stale += 1;
            s.pending[slot] = e;
            if (s.current == null) _ = s.forFrame(e.first_frame);
            return true;
        }

        /// The config frame `id` uses; null before any config. Pending configs whose first
        /// frame is at or before `id` take effect (the newest of them wins).
        pub fn forFrame(s: *Self, id: u32) ?Entry {
            var best: ?usize = null;
            for (s.pending, 0..) |p, i| if (p) |x| {
                if (newer(x.first_frame, id)) continue;
                if (best == null or newer(x.epoch, s.pending[best.?].?.epoch)) best = i;
            };
            if (best) |b| {
                const e = s.pending[b].?;
                s.current = e;
                // Drop it and anything older.
                for (&s.pending) |*p| if (p.*) |x| if (!newer(x.epoch, e.epoch)) {
                    p.* = null;
                };
            }
            return s.current;
        }

        /// The newest epoch heard of, applied or not.
        pub fn newestEpoch(s: *const Self) ?u32 {
            var n: ?u32 = if (s.current) |c| c.epoch else null;
            for (s.pending) |p| if (p) |x| if (n == null or newer(x.epoch, n.?)) {
                n = x.epoch;
            };
            return n;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn info(id: u32, w: u32, h: u32, n: []const u8) DisplayInfo {
    var d: DisplayInfo = .{ .id = id, .width = w, .height = h, .refresh_mhz = 60_000, .x = @intCast(id * w), .primary = id == 0 };
    d.setName(n);
    return d;
}

test "display list round trip and malformed input" {
    const ds = [_]DisplayInfo{ info(0, 2560, 1440, "DELL U2720Q"), info(1, 1920, 1080, "Built-in Retina Display (long name)") };
    try testing.expectEqualStrings("Built-in Retina Display ", ds[1].name());
    var buf: [1200]u8 = undefined;
    const b = try (DisplayList{ .gen = 7, .current = 1, .displays = &ds }).encode(&buf);
    try testing.expectEqual(@as(usize, 12 + 2 * 52), b.len);
    var out: [DisplayList.max_displays]DisplayInfo = undefined;
    const d = DisplayList.decode(b, &out).?;
    try testing.expectEqual(@as(u32, 7), d.gen);
    try testing.expectEqual(@as(u32, 1), d.current);
    try testing.expect(sameList(&ds, out[0..d.n]));
    try testing.expectEqual(@as(?DisplayList.Decoded, null), DisplayList.decode(b[0 .. b.len - 1], &out));
    var bad = buf;
    bad[12 + 4 .. 12 + 8].* = .{ 0, 0, 0, 0 };
    try testing.expectEqual(@as(?DisplayList.Decoded, null), DisplayList.decode(bad[0..b.len], &out));
    bad = buf;
    bad[12 + 25] = 25;
    try testing.expectEqual(@as(?DisplayList.Decoded, null), DisplayList.decode(bad[0..b.len], &out));
    bad = buf;
    bad[8] = 17;
    try testing.expectEqual(@as(?DisplayList.Decoded, null), DisplayList.decode(bad[0..b.len], &out));
    const many: [17]DisplayInfo = @splat(ds[0]);
    try testing.expectError(error.TooMany, (DisplayList{ .gen = 0, .current = 0, .displays = &many }).encode(&buf));
    // 16 fit a datagram with an envelope.
    try testing.expect((DisplayList{ .gen = 0, .current = 0, .displays = many[0..16] }).encodedLen() + 8 <= 1200);
}

test "names cut at a UTF-8 boundary" {
    var d: DisplayInfo = .{ .id = 0, .width = 1, .height = 1 };
    d.setName("aaaaaaaaaaaaaaaaaaaaaaa\u{e9}x"); // é straddles byte 24
    try testing.expectEqual(@as(u8, 23), d.name_len);
    try testing.expect(std.unicode.utf8ValidateSlice(d.name()));
}

test "select and ack round trip" {
    var sb: [SelectDisplay.len]u8 = undefined;
    const s: SelectDisplay = .{ .request = 3, .display = 2, .max_width = 1280, .max_height = 720, .max_fps = 30 };
    s.encode(&sb);
    try testing.expectEqual(@as(?SelectDisplay, s), SelectDisplay.decode(&sb));
    try testing.expectEqual(@as(?SelectDisplay, null), SelectDisplay.decode(sb[1..]));
    var ab: [ConfigAck.len]u8 = undefined;
    const a: ConfigAck = .{ .nonce = 1, .epoch = 4, .display_gen = 9 };
    a.encode(&ab);
    try testing.expectEqual(@as(?ConfigAck, a), ConfigAck.decode(&ab));
}

test "fit keeps the aspect ratio and never grows" {
    try testing.expectEqual(@as(u32, 1280), fit(2560, 1440, 1280, 0).width);
    try testing.expectEqual(@as(u32, 720), fit(2560, 1440, 1280, 0).height);
    try testing.expectEqual(@as(u32, 1920), fit(1920, 1080, 0, 0).width);
    try testing.expectEqual(@as(u32, 1920), fit(1920, 1080, 3840, 2160).width);
    const r = fit(3440, 1440, 1920, 1080); // ultrawide into 1080p: width-bound
    try testing.expect(r.width <= 1920 and r.height <= 1080 and r.width % 2 == 0 and r.height % 2 == 0);
    try testing.expectEqual(@as(u32, 1920), r.width);
}

test "schedule: configs apply at their first frame, in any arrival order" {
    var s: Schedule(u32) = .{};
    try testing.expectEqual(@as(?Schedule(u32).Entry, null), s.forFrame(0));
    try testing.expect(s.offer(.{ .epoch = 0, .first_frame = 0, .value = 100 }));
    try testing.expect(!s.offer(.{ .epoch = 0, .first_frame = 0, .value = 100 }));
    // Epoch 2 arrives before epoch 1.
    try testing.expect(s.offer(.{ .epoch = 2, .first_frame = 50, .value = 300 }));
    try testing.expect(s.offer(.{ .epoch = 1, .first_frame = 20, .value = 200 }));
    try testing.expectEqual(@as(u32, 100), s.forFrame(19).?.value);
    try testing.expectEqual(@as(u32, 200), s.forFrame(20).?.value);
    try testing.expectEqual(@as(u32, 200), s.forFrame(49).?.value);
    try testing.expectEqual(@as(?u32, 2), s.newestEpoch());
    // Frames jump past both (the frames between were lost): the newest wins.
    var t: Schedule(u32) = .{};
    _ = t.offer(.{ .epoch = 0, .first_frame = 0, .value = 1 });
    _ = t.offer(.{ .epoch = 1, .first_frame = 10, .value = 2 });
    _ = t.offer(.{ .epoch = 2, .first_frame = 12, .value = 3 });
    try testing.expectEqual(@as(u32, 3), t.forFrame(13).?.value);
    // A late repeat of epoch 1 is stale.
    try testing.expect(!t.offer(.{ .epoch = 1, .first_frame = 10, .value = 2 }));
    try testing.expectEqual(@as(u64, 1), t.stale);
    try testing.expectEqual(@as(u32, 300), s.forFrame(60).?.value);
}

test "schedule wraps frame ids and epochs" {
    var s: Schedule(u8) = .{};
    _ = s.offer(.{ .epoch = 0xffff_ffff, .first_frame = 0xffff_fff0, .value = 1 });
    _ = s.offer(.{ .epoch = 0, .first_frame = 5, .value = 2 });
    try testing.expectEqual(@as(u8, 1), s.forFrame(0xffff_fffe).?.value);
    try testing.expectEqual(@as(u8, 1), s.forFrame(4).?.value);
    try testing.expectEqual(@as(u8, 2), s.forFrame(5).?.value);
}
