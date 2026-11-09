//! Linux host capture and audio tests (`zig build test-linux-host`). Run them inside
//! platform/host/linux/headless.sh: a headless sway with xdg-desktop-portal-wlr (chooser
//! off, so the portal picks the one output without a dialog) and PipeWire with a null
//! sink. A fullscreen wl_shm window shows the measurement test pattern with the current
//! time; the capture test reads the stamps back out of the captured frames.
//!
//! Without a portal, a compositor or PipeWire a test skips and says so, unless
//! MOONSEC_REQUIRE=portal,pipewire names it: then it fails. The dma-buf path needs a GPU
//! (llvmpipe and the pixman renderer have no modifiers), so it is compile-only here.

const std = @import("std");
const api = @import("platform");
const host = @import("host_linux");
const client = @import("client_linux");
const tw = @import("testwin_c");
const c = host.c;
const pattern = api.pattern;

const testing = std.testing;

fn required(what: []const u8) bool {
    const v = std.c.getenv("MOONSEC_REQUIRE") orelse return false;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(v), ',');
    while (it.next()) |w| if (std.mem.eql(u8, w, what)) return true;
    return false;
}

fn skip(what: []const u8, why: []const u8) error{ SkipZigTest, TestUnexpectedResult } {
    if (required(what)) {
        std.debug.print("{s} required but unavailable: {s}\n", .{ what, why });
        return error.TestUnexpectedResult;
    }
    std.debug.print("no {s} ({s}): skipping\n", .{ what, why });
    return error.SkipZigTest;
}

fn sleepUs(us: i64) void {
    const ts: std.c.timespec = .{ .sec = @intCast(@divTrunc(us, 1_000_000)), .nsec = @intCast(@mod(us, 1_000_000) * 1000) };
    _ = std.c.nanosleep(&ts, null);
}

/// The headless desktop's size, from headless.sh (MOONSEC_HEADLESS_SIZE=WxH).
fn headlessSize() ?api.Size {
    const v = std.mem.span(std.c.getenv("MOONSEC_HEADLESS_SIZE") orelse return null);
    const x = std.mem.indexOfScalar(u8, v, 'x') orelse return null;
    return .{
        .width = std.fmt.parseInt(u32, v[0..x], 10) catch return null,
        .height = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch return null,
    };
}

/// Draws the test pattern, stamped with the time, into a fullscreen window at ~60 fps on
/// its own thread until `stop` is set.
const PatternWindow = struct {
    win: *tw.mlh_testwin,
    width: u32,
    height: u32,
    stop: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    drawn: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    fn open() !*PatternWindow {
        var w: u32 = 0;
        var h: u32 = 0;
        var win: ?*tw.mlh_testwin = null;
        const rc = tw.mlh_testwin_create("moonsec-test", &w, &h, &win);
        if (rc != 0) return error.NoWindow;
        const self = try testing.allocator.create(PatternWindow);
        self.* = .{ .win = win.?, .width = w, .height = h };
        // Draw once before capture starts so the first frame has the pattern.
        self.draw();
        _ = tw.mlh_testwin_dispatch(self.win, 50);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn draw(self: *PatternWindow) void {
        var stride: u32 = 0;
        const px = tw.mlh_testwin_buffer(self.win, &stride) orelse return;
        const n = self.drawn.load(.monotonic) + 1;
        pattern.render(px[0 .. @as(usize, stride) * self.height], self.width, self.height, stride, .{ .time_us = @intCast(host.nowUs()), .frame = n });
        if (tw.mlh_testwin_commit(self.win) == 0) self.drawn.store(n, .monotonic);
    }

    fn run(self: *PatternWindow) void {
        var next = host.nowUs();
        while (!self.stop.load(.monotonic)) {
            if (!self.paused.load(.monotonic)) self.draw();
            next += 16_667;
            while (true) {
                const left = next - host.nowUs();
                if (left <= 0) break;
                if (tw.mlh_testwin_dispatch(self.win, @intCast(@divTrunc(left, 1000) + 1)) < 0) return;
            }
        }
    }

    fn close(self: *PatternWindow) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
        tw.mlh_testwin_destroy(self.win);
        testing.allocator.destroy(self);
    }
};

fn haveDisplay() bool {
    return std.c.getenv("WAYLAND_DISPLAY") != null;
}

fn envU32(name: [*:0]const u8) ?u32 {
    const v = std.c.getenv(name) orelse return null;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch null;
}

/// Under headless.sh, serves the portal's ScreenCast backend (testwin/testportal.c) with
/// Weston's output node; elsewhere the desktop's own portal answers (and may ask).
fn usingTestPortal() bool {
    return std.c.getenv("MOONSEC_TEST_PORTAL") != null;
}

/// Starts capture, or skips the test when there is no portal.
fn startCapture(cap: *host.Capture, cfg: api.CaptureConfig) !api.Size {
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return skip("portal", "no session bus");
    if (usingTestPortal()) {
        const node = envU32("MOONSEC_HEADLESS_NODE") orelse return error.NoHeadlessNode;
        const sz = headlessSize() orelse return error.NoHeadlessSize;
        const all = c.MLH_CURSOR_HIDDEN | c.MLH_CURSOR_EMBEDDED | c.MLH_CURSOR_METADATA;
        if (tw.mlh_testportal_start(node, sz.width, sz.height, all) != 0) return error.TestPortal;
    }
    return cap.start(cfg) catch |e| switch (e) {
        error.Unsupported => skip("portal", host.lastError()),
        else => e,
    };
}

fn tokenFile(buf: []u8) ![:0]const u8 {
    const dir = std.mem.span(std.c.getenv("XDG_RUNTIME_DIR") orelse "/tmp");
    // Fixed, so a second run on a real desktop restores the first run's choice.
    return std.fmt.bufPrintSentinel(buf, "{s}/moonsec-host-test/screencast.token", .{dir}, 0);
}

fn loadToken(path: [:0]const u8, buf: []u8) ?[]const u8 {
    if (c.mlh_token_load(path.ptr, buf.ptr, buf.len) != c.MLH_OK) return null;
    return std.mem.sliceTo(buf, 0);
}

test "capture: the test pattern through the ScreenCast portal" {
    if (!haveDisplay()) return skip("portal", "no Wayland display");
    var win = PatternWindow.open() catch return skip("portal", "no test window (compositor lacks wl_shm or xdg-shell)");
    defer win.close();

    var path_buf: [512]u8 = undefined;
    const token_path = try tokenFile(&path_buf);
    var cap = host.Capture.init(.{ .token_path = token_path });
    defer cap.deinit();
    const size = try startCapture(&cap, .{ .fps = 60 });
    std.debug.print("capture: portal v{d}, node {d}, {d}x{d}, cursor mode {d}\n", .{ cap.portalVersion(), cap.streamInfo().node_id, size.width, size.height, cap.cursorMode() });
    if (headlessSize()) |hs| {
        try testing.expectEqual(hs.width, size.width);
        try testing.expectEqual(hs.height, size.height);
    }
    try testing.expectEqual(win.width, size.width);

    // Two seconds of frames: every one must carry a readable stamp drawn before it was
    // captured, frame numbers must not go back, seq must go up.
    var frames: u32 = 0;
    var readable: u32 = 0;
    var last_seq: u64 = 0;
    var last_frame: u32 = 0;
    var lat: [256]i64 = undefined;
    var n_lat: usize = 0;
    const until = host.nowUs() + 2_000_000;
    while (host.nowUs() < until) {
        const f = (try cap.acquire(200_000)) orelse continue;
        defer cap.release(&f);
        if (f.repeat) continue; // a cursor-only update
        frames += 1;
        try testing.expect(f.seq > last_seq);
        last_seq = f.seq;
        try testing.expect(f.capture_start_us <= f.captured_us or f.captured_us <= host.nowUs());
        const cpu = f.image.cpu orelse return error.NoPixels;
        try testing.expectEqual(api.PixelFormat.bgra8, f.image.format);
        const s = pattern.read(cpu.data, f.image.width, f.image.height, cpu.stride) orelse continue;
        readable += 1;
        try testing.expect(s.frame >= last_frame);
        last_frame = s.frame;
        const l = f.captured_us - @as(i64, @intCast(s.time_us));
        try testing.expect(l >= 0);
        if (n_lat < lat.len) {
            lat[n_lat] = l;
            n_lat += 1;
        }
    }
    const st = cap.stats();
    std.mem.sort(i64, lat[0..n_lat], {}, std.sort.asc(i64));
    std.debug.print("capture: {d} frames in 2 s, {d} stamps read, {d} drawn; dropped {d}, cursor-only {d}, {s}; draw->capture median {d} us, max {d} us\n", .{
        frames,                                readable,                              win.drawn.load(.monotonic),
        st.dropped,                            st.cursor_only,                        if (st.dmabuf != 0) "dma-buf" else "memory",
        if (n_lat > 0) lat[n_lat / 2] else -1, if (n_lat > 0) lat[n_lat - 1] else -1,
    });
    try testing.expect(frames >= 30);
    try testing.expect(readable * 10 >= frames * 9);
    try testing.expect(n_lat > 0 and lat[n_lat / 2] < 200_000);

    // A static screen: the compositor sends nothing, and repeatLast keeps the picture.
    win.paused.store(true, .monotonic);
    sleepUs(300_000);
    while (try cap.acquire(0)) |f| cap.release(&f);
    var quiet: u32 = 0;
    for (0..5) |_| {
        if (try cap.acquire(100_000)) |f| {
            cap.release(&f);
        } else quiet += 1;
    }
    std.debug.print("capture: static screen, {d} of 5 waits had no frame\n", .{quiet});
    const r = (try cap.repeatLast()) orelse return error.NoRepeat;
    defer cap.release(&r);
    try testing.expect(r.repeat);
    const rs = pattern.read(r.image.cpu.?.data, r.image.width, r.image.height, r.image.cpu.?.stride) orelse return error.RepeatUnreadable;
    try testing.expect(rs.frame >= last_frame);
}

test "capture: a restore token is stored and works for the next start" {
    if (!haveDisplay()) return skip("portal", "no Wayland display");
    var path_buf: [512]u8 = undefined;
    const token_path = try tokenFile(&path_buf);
    var t1_buf: [512]u8 = undefined;
    var t2_buf: [512]u8 = undefined;

    var cap = host.Capture.init(.{ .token_path = token_path });
    defer cap.deinit();
    _ = try startCapture(&cap, .{});
    if (cap.portalVersion() < 4) return skip("portal", "ScreenCast before version 4 has no restore tokens");
    const t1 = loadToken(token_path, &t1_buf) orelse return skip("portal", "this portal backend gives no restore token");
    cap.stop();

    // Restarted: the stored token goes back to the portal. The spec calls tokens single
    // use; xdg-desktop-portal 1.18 hands the same one back, others may give a new one.
    _ = try startCapture(&cap, .{});
    const t2 = loadToken(token_path, &t2_buf) orelse return error.TokenGone;
    std.debug.print("restore token: {s} then {s}\n", .{ t1, t2 });
    if (usingTestPortal()) {
        // The frontend turned the token back into the backend's restore data, which is
        // what lets a real backend skip its dialog; and it asked for "until revoked".
        var starts: u32 = 0;
        var restored: u32 = 0;
        var cursor: u32 = 0;
        var persist: u32 = 0;
        tw.mlh_testportal_counts(&starts, &restored, &cursor, &persist);
        std.debug.print("test portal: {d} starts, {d} restored, cursor mode {d}, persist mode {d}\n", .{ starts, restored, cursor, persist });
        try testing.expect(restored >= 1);
        try testing.expectEqual(@as(u32, c.MLH_PERSIST_PERMANENT), persist);
        try testing.expectEqual(@as(u32, c.MLH_CURSOR_METADATA), cursor);
    }
    const f = (try cap.acquire(1_000_000)) orelse (try cap.repeatLast()) orelse return error.NoFrame;
    cap.release(&f);
}

test "audio: a tone played into the default sink comes back from its monitor" {
    var src = host.AudioSource.init(.{});
    _ = src.iface().start(.{}) catch |e| switch (e) {
        error.Unsupported => return skip("pipewire", host.lastError()),
        else => return e,
    };
    defer src.stop();
    var sink: client.AudioSink = .{ .ring_ms = 200, .quantum = 256 };
    _ = sink.start(.{}) catch return skip("pipewire", "no playback stream");
    defer sink.stop();

    // 440 Hz at amplitude 0.25 for 1.5 s; read the monitor meanwhile.
    var tone: [480 * 2]f32 = undefined;
    var phase: f32 = 0;
    var buf: [1024 * 2]f32 = undefined;
    var got: usize = 0;
    var sum_sq: f64 = 0;
    var counted: usize = 0;
    var last_time: i64 = 0;
    var pending: []const f32 = &.{};
    const t0 = host.nowUs();
    while (host.nowUs() - t0 < 1_500_000) {
        // Keep the sink's ring topped up.
        while (true) {
            if (pending.len == 0) {
                for (0..480) |i| {
                    const v: f32 = 0.25 * @sin(phase);
                    tone[2 * i] = v;
                    tone[2 * i + 1] = v;
                    phase += 2 * std.math.pi * 440.0 / 48_000.0;
                    if (phase > 2 * std.math.pi) phase -= 2 * std.math.pi;
                }
                pending = &tone;
            }
            const n = try sink.write(pending);
            if (n == 0) break;
            pending = pending[n * 2 ..];
        }
        const ch = try src.iface().read(&buf, 20_000);
        if (ch.frames == 0) continue;
        const now = host.nowUs();
        try testing.expect(ch.time_us <= now);
        try testing.expect(now - ch.time_us < 1_000_000);
        if (last_time != 0) try testing.expect(ch.time_us + 2_000 >= last_time);
        last_time = ch.time_us;
        got += ch.frames;
        // Skip the first half second (the links come up, silence before the tone).
        if (now - t0 > 500_000) {
            for (buf[0 .. ch.frames * 2]) |v| sum_sq += v * v;
            counted += ch.frames * 2;
        }
    }
    const info = src.info().?;
    const rms = if (counted > 0) @sqrt(sum_sq / @as(f64, @floatFromInt(counted))) else 0;
    std.debug.print("audio: {d} frames in 1.5 s, quantum {d}, overruns {d}, rms {d:.3} (tone 0.177)\n", .{ got, info.quantum, info.overruns, rms });
    if (got == 0) return skip("pipewire", "the capture stream got no data (no sink to monitor?)");
    try testing.expect(got > 48_000); // most of 1.5 s at 48 kHz
    try testing.expect(rms > 0.12 and rms < 0.24);
}

test "capture: cursor metadata, cursor-only updates and RGB swizzle (PipeWire test source)" {
    // A source we drive, captured without the portal: what a compositor in the portal's
    // metadata cursor mode sends (Weston's PipeWire output has no cursor metadata).
    var src: ?*tw.mlh_testsource = null;
    var node: u32 = 0;
    if (tw.mlh_testsource_create(64, 48, &src, &node) != 0) return skip("pipewire", "no PipeWire daemon");
    defer tw.mlh_testsource_destroy(src);
    const cc: c.mlh_capture_config = .{ .fd = -1, .node_id = node, .fps = 60, .modifiers = null, .n_modifiers = 0, .cursor_meta = 1, .timeout_ms = 5000 };
    var cap: ?*c.mlh_capture = null;
    if (c.mlh_capture_start(&cc, &cap) != c.MLH_OK) return error.CaptureStart;
    defer c.mlh_capture_destroy(cap);
    if (tw.mlh_testsource_wait_streaming(src, 5000) != 0) return error.NotStreaming;

    var f: c.mlh_frame = undefined;
    // Pushes until the capture side sees something (the first buffers can race the link).
    const Push = struct {
        fn untilFrame(s: ?*tw.mlh_testsource, h: ?*c.mlh_capture, out: *c.mlh_frame, picture: bool, rgb: [3]u8, x: i32, y: i32, serial: u32) !void {
            for (0..20) |_| {
                _ = tw.mlh_testsource_push(s, @intFromBool(picture), rgb[0], rgb[1], rgb[2], x, y, serial);
                const rc = c.mlh_capture_acquire(h, 200_000, out);
                if (rc == c.MLH_OK) return;
                if (rc != c.MLH_TIMEOUT) return error.Acquire;
            }
            return error.NoFrame;
        }
    };

    // A red picture (RGBx from the source) with the cursor at (10, 20) and a bitmap.
    try Push.untilFrame(src, cap, &f, true, .{ 255, 0, 0 }, 10, 20, 1);
    try testing.expectEqual(@as(u32, c.MLH_FRAME_MEMORY), f.kind);
    try testing.expectEqual(@as(u8, 0), f.repeat);
    try testing.expectEqual(@as(u32, 64), f.width);
    try testing.expectEqual(@as(u32, c.MLH_FOURCC_XRGB8888), f.fourcc); // swizzled to B, G, R
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, f.data[0..3]);
    try testing.expect(f.pts_us <= f.arrived_us);
    try testing.expectEqual(@as(u8, 1), f.has_cursor);
    try testing.expectEqual(@as(u8, 1), f.cursor.visible);
    try testing.expectEqual(@as(i32, 10), f.cursor.x);
    try testing.expectEqual(@as(i32, 20), f.cursor.y);
    try testing.expectEqual(@as(i32, 2), f.cursor.hot_x);
    try testing.expectEqual(@as(i32, 3), f.cursor.hot_y);
    try testing.expectEqual(@as(u32, 16), f.cursor.width);
    const bm = f.cursor.bitmap orelse return error.NoBitmap;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, bm[0..4]); // RGBA red -> BGRA
    try testing.expectEqual(@as(u8, 0), bm[15 * 16 * 4 + 3]); // transparent bottom half
    const serial = f.cursor.serial;
    const seq = f.seq;
    c.mlh_capture_release(cap, &f);

    // The pointer moved, the picture did not: a repeat with the new position, same bitmap.
    try Push.untilFrame(src, cap, &f, false, .{ 0, 0, 0 }, 30, 40, 1);
    try testing.expectEqual(@as(u8, 1), f.repeat);
    try testing.expectEqual(seq, f.seq);
    try testing.expectEqual(@as(i32, 30), f.cursor.x);
    try testing.expectEqual(@as(i32, 40), f.cursor.y);
    try testing.expectEqual(serial, f.cursor.serial);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, f.data[0..3]);
    c.mlh_capture_release(cap, &f);

    // A green picture: a new frame.
    try Push.untilFrame(src, cap, &f, true, .{ 0, 255, 0 }, 30, 40, 1);
    try testing.expectEqual(@as(u8, 0), f.repeat);
    try testing.expect(f.seq > seq);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0 }, f.data[0..3]);
    c.mlh_capture_release(cap, &f);

    var st: c.mlh_capture_stats = undefined;
    c.mlh_capture_get_stats(cap, &st);
    std.debug.print("test source: {d} frames, {d} cursor-only, {d} dropped\n", .{ st.frames, st.cursor_only, st.dropped });
    try testing.expect(st.cursor_only >= 1);
}

test "capture: dma-buf on a GPU desktop (MOONSEC_HW=1)" {
    // The hardware check (README): on GNOME or KDE with a GPU. The first run shows the
    // portal's dialog; the second must not (the restore token from the first).
    if (std.c.getenv("MOONSEC_HW") == null) return error.SkipZigTest;
    var path_buf: [512]u8 = undefined;
    const token_path = try tokenFile(&path_buf);
    var tok_buf: [512]u8 = undefined;
    const had_token = loadToken(token_path, &tok_buf) != null;
    var cap = host.Capture.init(.{ .token_path = token_path, .modifiers = &.{ c.MLH_MOD_LINEAR, c.MLH_MOD_INVALID } });
    defer cap.deinit();
    const t0 = host.nowUs();
    const size = try startCapture(&cap, .{ .fps = 60 });
    const start_ms = @divTrunc(host.nowUs() - t0, 1000);
    var frames: u32 = 0;
    var dmabuf: u32 = 0;
    var cursors: u32 = 0;
    var late_max: i64 = 0;
    const until = host.nowUs() + 3_000_000;
    while (host.nowUs() < until) {
        const f = (try cap.acquire(100_000)) orelse continue;
        defer cap.release(&f);
        frames += 1;
        if (f.image.gpu != null) dmabuf += 1;
        if (f.cursor != null) cursors += 1;
        late_max = @max(late_max, f.capture_start_us - f.captured_us);
    }
    const st = cap.stats();
    std.debug.print(
        \\hardware: portal v{d}, {d}x{d}, start took {d} ms ({s} restore token before), cursor mode {d}
        \\hardware: {d} frames in 3 s (move a window to make some), {d} dma-buf (modifier 0x{x}), {d} with cursor metadata, dropped {d}
        \\
    , .{ cap.portalVersion(), size.width, size.height, start_ms, if (had_token) "had a" else "no", cap.cursorMode(), frames, dmabuf, st.modifier, cursors, st.dropped });
    try testing.expect(frames > 0);
    if (std.c.getenv("MOONSEC_HW_DMABUF") != null) try testing.expect(dmabuf == frames);
}

test "token path" {
    const p = try host.tokenPath(testing.allocator, "/home/u/.config/moonsec");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/home/u/.config/moonsec/screencast.token", p);
}

// ---------------------------------------------------------------------------
// Input injection (uinput): the injector on real devices, read back from their
// /dev/input/event* nodes the way a compositor reads them. Needs write access to
// /dev/uinput and read access to the event nodes (linux.yml sets both up); without them
// these skip, unless MOONSEC_REQUIRE names `uinput`. The cloud containers have none.

const ui = host.uinput;
const input = host.input;

/// Every non-SYN event read from `r` within `ms`, until `want` of them arrived.
fn collect(r: ui.Reader, want: usize, ms: u32, out: []ui.Event) []ui.Event {
    var n: usize = 0;
    var waited: u32 = 0;
    var buf: [64]ui.Event = undefined;
    while (n < want and waited < ms) {
        const got = r.read(&buf);
        if (got.len == 0) {
            ui.sleepMs(2);
            waited += 2;
            continue;
        }
        for (got) |e| {
            if (e.type == ui.EV_SYN or e.type == ui.EV_MSC or n == out.len) continue;
            out[n] = e;
            n += 1;
        }
    }
    return out[0..n];
}

fn expectEvent(e: ui.Event, t: u16, code: u16, value: i32) !void {
    testing.expectEqual(t, e.type) catch |err| {
        std.debug.print("event: type {d} code {d} value {d}\n", .{ e.type, e.code, e.value });
        return err;
    };
    try testing.expectEqual(code, e.code);
    try testing.expectEqual(value, e.value);
}

fn reader(d: ui.Device) ?ui.Reader {
    return ui.Reader.open(d.node orelse return null, 3000);
}

test "uinput: keyboard and mouse actions arrive on their event nodes" {
    var j = input.Injector.init(input.Opener.uinput) catch |e| return skip("uinput", @errorName(e));
    defer j.deinit();
    const kb = reader(j.keyboard) orelse return skip("uinput", "cannot read the keyboard's event node");
    defer kb.close();
    const mouse = reader(j.mouse) orelse return skip("uinput", "cannot read the mouse's event node");
    defer mouse.close();

    try j.inject(.{ .key = .{ .code = 0x04, .down = true, .time = 0 } });
    try j.inject(.{ .key = .{ .code = 0x04, .down = false, .time = 0 } });
    try j.inject(.{ .key = .{ .code = 0xE0, .down = true, .time = 0 } }); // left ctrl
    try j.inject(.{ .key = .{ .code = 0xE0, .down = false, .time = 0 } });
    var buf: [32]ui.Event = undefined;
    const keys = collect(kb, 4, 1000, &buf);
    try testing.expectEqual(@as(usize, 4), keys.len);
    try expectEvent(keys[0], ui.EV_KEY, ui.KEY_A, 1);
    try expectEvent(keys[1], ui.EV_KEY, ui.KEY_A, 0);
    try expectEvent(keys[2], ui.EV_KEY, 29, 1);
    try expectEvent(keys[3], ui.EV_KEY, 29, 0);

    try j.inject(.{ .motion = .{ .dx = 5, .dy = -4 } });
    try j.inject(.{ .button = .{ .code = 2, .down = true, .time = 0 } });
    try j.inject(.{ .button = .{ .code = 2, .down = false, .time = 0 } });
    try j.inject(.{ .scroll = .{ .dx = 0, .dy = -120, .time = 0 } });
    const m = collect(mouse, 6, 1000, &buf);
    try testing.expectEqual(@as(usize, 6), m.len);
    try expectEvent(m[0], ui.EV_REL, ui.REL_X, 5);
    try expectEvent(m[1], ui.EV_REL, ui.REL_Y, -4);
    try expectEvent(m[2], ui.EV_KEY, ui.BTN_RIGHT, 1);
    try expectEvent(m[3], ui.EV_KEY, ui.BTN_RIGHT, 0);
    try expectEvent(m[4], ui.EV_REL, ui.REL_WHEEL_HI_RES, -120);
    try expectEvent(m[5], ui.EV_REL, ui.REL_WHEEL, -1);
}

test "uinput: absolute positions on the tablet, over the output's pixels" {
    var j = input.Injector.init(input.Opener.uinput) catch |e| return skip("uinput", @errorName(e));
    defer j.deinit();
    j.setOutput(.{ .width = 800, .height = 600 });
    // The first position creates the tablet; read the ones after it.
    try j.inject(.{ .abs = .{ .x = 0, .y = 0 } });
    const t = reader(j.tablet.?) orelse return skip("uinput", "cannot read the tablet's event node");
    defer t.close();
    try j.inject(.{ .abs = .{ .x = 65535, .y = 32768 } });
    var buf: [8]ui.Event = undefined;
    const ev = collect(t, 2, 1000, &buf);
    try testing.expectEqual(@as(usize, 2), ev.len);
    try expectEvent(ev[0], ui.EV_ABS, ui.ABS_X, 799);
    try expectEvent(ev[1], ui.EV_ABS, ui.ABS_Y, 300);
}

test "uinput: a gamepad appears on connect, reports the Xbox 360 layout, goes on disconnect" {
    var j = input.Injector.init(input.Opener.uinput) catch |e| return skip("uinput", @errorName(e));
    defer j.deinit();
    try j.inject(.{ .pad = .{ .index = 0, .connected = true, .state = .{} } });
    const node = j.pads[0].?.node orelse return skip("uinput", "the pad has no event node");
    const r = ui.Reader.open(node, 3000) orelse return skip("uinput", "cannot read the pad's event node");
    defer r.close();
    const B = input.PadButton;
    try j.inject(.{ .pad = .{ .index = 0, .connected = true, .state = .{ .buttons = B.a | B.dpad_left, .lx = -20000, .ly = 20000, .rt = 65535 } } });
    var buf: [16]ui.Event = undefined;
    // Only changes are reported: A, LX, LY, RZ, HAT0X.
    const ev = collect(r, 5, 1000, &buf);
    try testing.expectEqual(@as(usize, 5), ev.len);
    try expectEvent(ev[0], ui.EV_KEY, ui.BTN_SOUTH, 1);
    try expectEvent(ev[1], ui.EV_ABS, ui.ABS_X, -20000);
    try expectEvent(ev[2], ui.EV_ABS, ui.ABS_Y, -20000);
    try expectEvent(ev[3], ui.EV_ABS, ui.ABS_RZ, input.trigger_max);
    try expectEvent(ev[4], ui.EV_ABS, ui.ABS_HAT0X, -1);

    try j.inject(.{ .pad = .{ .index = 0, .connected = false, .state = .{} } });
    try testing.expectEqual(@as(?ui.Device, null), j.pads[0]);
    // The node goes away with the device.
    var gone = false;
    var waited: u32 = 0;
    while (!gone and waited < 2000) : (waited += 10) {
        var p: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&p, "/dev/input/event{d}", .{node}) catch unreachable;
        const rc = std.os.linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) gone = true else {
            _ = std.os.linux.close(@intCast(rc));
            ui.sleepMs(10);
        }
    }
    try testing.expect(gone);
}

test "input: open without uinput the host streams without input, or fails when input is required" {
    const Fail = struct {
        fn open(_: ?*anyopaque, _: input.Kind, _: u8, _: *const ui.Spec) ui.Error!ui.Device {
            return error.AccessDenied;
        }
        fn close(_: ?*anyopaque, _: ui.Device) void {}
    };
    const opener: input.Opener = .{ .openFn = Fail.open, .closeFn = Fail.close };
    std.testing.log_level = .err; // the warning about /dev/uinput is expected here
    defer std.testing.log_level = .warn;
    const h = try host.backend.open(std.testing.allocator, .{ .opener = opener });
    const be = h.backend();
    try std.testing.expect(be.input == null);
    try std.testing.expectEqual(@as(?ui.Error, error.AccessDenied), h.input_error);
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try h.describe(&w);
    try std.testing.expectEqualStrings("capture synthetic, encoder synthetic, audio synthetic, input none (AccessDenied)", w.buffered());
    be.deinit();
    try std.testing.expectError(error.NoInput, host.backend.open(std.testing.allocator, .{ .opener = opener, .require_input = true }));
}
