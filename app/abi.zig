//! The public C ABI (include/moonsec.h; design and rules in spec/c-abi-v1.md).
//!
//! A thin layer over the apps (apps.zig): a `moonsec_session` is a `HostApp` or `ClientApp`
//! with its backend and transport, so the `moonsec` tool and the ABI run one code path.
//!
//!   - Loopback sessions run in virtual time on the caller's thread, inside
//!     `moonsec_loopback_advance` (the in-process sim, as app/simrun.zig drives it).
//!   - iroh sessions run on their own threads: `HostApp/ClientApp.runThreadedWith`, under the
//!     endpoint's mutex, which every ABI call on that host or client also takes.
//!
//! Events are found by comparing each session's state after every network step (`check`),
//! and queued on the session's host or client for `moonsec_*_poll_event`.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("app_options");
const core = @import("core");
const api = @import("platform");
const synthetic = @import("synthetic");
const simnet = @import("simnet");
const pipe_mod = @import("pipe");
const clipboard = @import("clipboard");
const apps = @import("apps.zig");
const simrun = @import("simrun.zig");
const pairing = @import("pairing.zig");
const keystore = @import("keystore.zig");
const pair_cmd = @import("pair_cmd.zig");
const system = @import("system.zig");
const iroh = if (options.iroh) @import("iroh") else struct {};
const iroh_pipe = if (options.iroh) @import("iroh_pipe") else struct {};
pub const c = @import("moonsec_h");

const Io = std.Io;
const Micros = i64;
const pair = core.pair;
const ex = pair.exchange;
const gpa = std.heap.smp_allocator;

const Status = c.moonsec_status;
const ok: Status = c.MOONSEC_OK;

pub const version_string = "1.0.0-draft";

// ---------------------------------------------------------------------------
// Process-wide state: the Io the threads run on, the clock, the last error.

var io_state: Io.Threaded = undefined;
var io_ready: std.atomic.Value(u8) = .init(0);

fn io() Io {
    if (io_ready.load(.acquire) != 2) {
        if (io_ready.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            io_state = .init(gpa, .{});
            io_ready.store(2, .release);
        } else while (io_ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
    return io_state.io();
}

fn wallNow() Micros {
    return Io.Clock.awake.now(io()).toMicroseconds();
}

fn wallSleep(_: ?*anyopaque, us: Micros) void {
    if (us > 0) io().sleep(.fromMicroseconds(us), .awake) catch {};
}

threadlocal var err_buf: [512]u8 = undefined;
threadlocal var err_len: usize = 0;

fn fail(status: Status, comptime fmt: []const u8, args: anytype) Status {
    const s = std.fmt.bufPrint(&err_buf, fmt, args) catch err_buf[0..];
    err_len = s.len;
    return status;
}

fn invalid(comptime what: []const u8) Status {
    return fail(c.MOONSEC_ERR_INVALID, what, .{});
}

/// A string out as the header says: `len` is the full length; it must fit with its NUL.
fn outStr(s: []const u8, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    if (len) |l| l.* = s.len;
    const b = buf orelse return fail(c.MOONSEC_ERR_BUFFER_TOO_SMALL, "no buffer", .{});
    if (cap <= s.len) return fail(c.MOONSEC_ERR_BUFFER_TOO_SMALL, "{d} bytes needed", .{s.len + 1});
    @memcpy(b[0..s.len], s);
    b[s.len] = 0;
    return ok;
}

/// A caller's struct, zero-extended from its `struct_size`. Null if it is missing or older
/// than 1.0's layout (every struct is 1.0's now; later fields will be optional).
fn readIn(comptime T: type, p: ?*const T) ?T {
    const src = p orelse return null;
    if (src.struct_size < @sizeOf(T)) return null;
    var v: T = std.mem.zeroes(T);
    const n = @min(src.struct_size, @sizeOf(T));
    @memcpy(std.mem.asBytes(&v)[0..n], std.mem.asBytes(src)[0..n]);
    return v;
}

/// Write `v` into the caller's struct, no further than its `struct_size`.
fn writeOut(comptime T: type, dst: *T, v: T) bool {
    const size = dst.struct_size;
    if (size < 8) return false;
    const n = @min(size, @sizeOf(T));
    var tmp = v;
    tmp.struct_size = size;
    @memcpy(std.mem.asBytes(dst)[0..n], std.mem.asBytes(&tmp)[0..n]);
    return true;
}

fn span(p: [*c]const u8) ?[]const u8 {
    if (p == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn fixedStr(dst: []u8, s: []const u8) void {
    const n = @min(s.len, dst.len - 1);
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
}

// ---------------------------------------------------------------------------
// Version, features, errors

export fn moonsec_version() u32 {
    return c.MOONSEC_ABI_VERSION;
}

export fn moonsec_version_string() [*:0]const u8 {
    return version_string ++ (if (options.iroh) " (iroh)" else " (no iroh)");
}

export fn moonsec_features() u32 {
    var f: u32 = c.MOONSEC_FEATURE_LOOPBACK;
    if (options.iroh) f |= c.MOONSEC_FEATURE_IROH;
    if (system.available) f |= c.MOONSEC_FEATURE_SYSTEM_BACKEND;
    return f;
}

export fn moonsec_status_string(s: Status) [*:0]const u8 {
    return switch (s) {
        c.MOONSEC_OK => "MOONSEC_OK",
        c.MOONSEC_ERR_INVALID => "MOONSEC_ERR_INVALID",
        c.MOONSEC_ERR_UNSUPPORTED => "MOONSEC_ERR_UNSUPPORTED",
        c.MOONSEC_ERR_NO_MEMORY => "MOONSEC_ERR_NO_MEMORY",
        c.MOONSEC_ERR_STATE => "MOONSEC_ERR_STATE",
        c.MOONSEC_ERR_BUFFER_TOO_SMALL => "MOONSEC_ERR_BUFFER_TOO_SMALL",
        c.MOONSEC_ERR_TIMEOUT => "MOONSEC_ERR_TIMEOUT",
        c.MOONSEC_ERR_TRANSPORT => "MOONSEC_ERR_TRANSPORT",
        c.MOONSEC_ERR_REFUSED => "MOONSEC_ERR_REFUSED",
        c.MOONSEC_ERR_BACKEND => "MOONSEC_ERR_BACKEND",
        c.MOONSEC_ERR_IO => "MOONSEC_ERR_IO",
        c.MOONSEC_ERR_INTERNAL => "MOONSEC_ERR_INTERNAL",
        else => "MOONSEC_ERR_UNKNOWN",
    };
}

export fn moonsec_last_error(buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    // As outStr, but without replacing the error it reports.
    const s = err_buf[0..err_len];
    if (len) |l| l.* = s.len;
    const b = buf orelse return c.MOONSEC_ERR_BUFFER_TOO_SMALL;
    if (cap <= s.len) return c.MOONSEC_ERR_BUFFER_TOO_SMALL;
    @memcpy(b[0..s.len], s);
    b[s.len] = 0;
    return ok;
}

// ---------------------------------------------------------------------------
// Hosts and clients

const Role = enum { host, client };
const magic: u32 = 0x6d736563; // "msec"

/// A host or a client: its identity, settings, sessions and event queue. `mu` guards all of
/// it and every session's app (the sessions' threads run under it).
const Endpoint = struct {
    magic: u32 = magic,
    role: Role,
    mu: Io.Mutex = .init,
    events: std.Deque(c.moonsec_event) = .empty,
    sessions: std.ArrayList(*Session) = .empty,

    identity: keystore.Identity,
    state: ?pairing.State = null,
    /// Paired devices: clients allowed in (host) or hosts paired with (client). Saved to
    /// `state` when there is one.
    allow: pair.Allowlist,
    name: []u8,
    /// The state directory's path (null: none, or the key is in memory only).
    state_path: ?[]u8 = null,
    relay_url: ?[:0]u8 = null,
    relay_ca: ?[:0]u8 = null,
    bind_addr: ?[:0]u8 = null,

    hc: c.moonsec_host_config = std.mem.zeroes(c.moonsec_host_config),
    cc: c.moonsec_client_config = std.mem.zeroes(c.moonsec_client_config),
    flags: u32,
    clip_mode: u32,
    relay_mode: u32,

    net: Net = .{},

    fn lock(e: *Endpoint) void {
        e.mu.lockUncancelable(io());
    }
    fn unlock(e: *Endpoint) void {
        e.mu.unlock(io());
    }

    /// Queue an event (with the lock held); wake the app if the queue was empty.
    fn push(e: *Endpoint, ev: c.moonsec_event) void {
        var v = ev;
        v.struct_size = @sizeOf(c.moonsec_event);
        if (v.time_us == 0) v.time_us = wallNow();
        const was_empty = e.events.len == 0;
        e.events.pushBack(gpa, v) catch return;
        if (was_empty) {
            const n = if (e.role == .host) e.hc.notify else e.cc.notify;
            const ctx = if (e.role == .host) e.hc.notify_ctx else e.cc.notify_ctx;
            if (n) |f| f(ctx);
        }
    }

    fn saveAllow(e: *Endpoint) void {
        if (e.state) |*st| st.saveList(if (e.role == .host) .clients else .hosts, &e.allow) catch {};
    }

    fn activeSession(e: *const Endpoint) bool {
        for (e.sessions.items) |s| if (!s.ended()) return true;
        return false;
    }
};

/// iroh state of an endpoint (empty without the shim).
const Net = if (options.iroh) struct {
    ep: ?iroh.Endpoint = null,
    accept: ?Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    window: ?ex.Window = null,
    paired_in_window: u32 = 0,
} else struct {};

fn hostOf(h: ?*c.moonsec_host) ?*Endpoint {
    const e: *Endpoint = @ptrCast(@alignCast(h orelse return null));
    return if (e.magic == magic and e.role == .host) e else null;
}

fn clientOf(h: ?*c.moonsec_client) ?*Endpoint {
    const e: *Endpoint = @ptrCast(@alignCast(h orelse return null));
    return if (e.magic == magic and e.role == .client) e else null;
}

/// The environment variables `pairing.defaultStateDir` reads.
fn envMap() !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(gpa);
    errdefer m.deinit();
    inline for (.{ "MOONSEC_STATE_DIR", "APPDATA", "HOME", "XDG_CONFIG_HOME" }) |k| {
        if (std.c.getenv(k)) |v| try m.put(k, std.mem.span(v));
    }
    return m;
}

fn dupZ(s: [*c]const u8) !?[:0]u8 {
    return if (span(s)) |t| try gpa.dupeZ(u8, t) else null;
}

fn createEndpoint(role: Role, state_dir: [*c]const u8, name: [*c]const u8, relay_url: [*c]const u8, relay_ca: [*c]const u8, bind_addr: [*c]const u8) !*Endpoint {
    var state: ?pairing.State = null;
    errdefer if (state) |*st| st.close();
    var ident: keystore.Identity = undefined;
    const dir = span(state_dir);
    if (dir != null and dir.?.len == 0) {
        var secret: [32]u8 = undefined;
        io().random(&secret);
        ident = .{ .secret = secret, .id = pair.id.publicFromSecret(&secret) };
    } else {
        var env = try envMap();
        defer env.deinit();
        const owned = if (dir == null) try pairing.defaultStateDir(gpa, &env) else null;
        defer if (owned) |o| gpa.free(o);
        state = pairing.State.open(gpa, io(), owned orelse dir.?) catch return error.StateDir;
        ident = state.?.identity() catch return error.StateDir;
    }
    var allow = if (state) |*st| (st.loadList(if (role == .host) .clients else .hosts) catch return error.StateDir) else pair.Allowlist.init(gpa);
    errdefer allow.deinit();
    var hb: [256]u8 = undefined;
    const nm = span(name) orelse hostName(&hb, if (role == .host) "moonsec host" else "moonsec client");
    const e = try gpa.create(Endpoint);
    errdefer gpa.destroy(e);
    e.* = .{
        .role = role,
        .identity = ident,
        .state = state,
        .allow = allow,
        .name = try gpa.dupe(u8, nm),
        .flags = 0,
        .clip_mode = 0,
        .relay_mode = 0,
    };
    if (dir) |d| if (d.len > 0) {
        e.state_path = try gpa.dupe(u8, d);
    };
    e.relay_url = try dupZ(relay_url);
    e.relay_ca = try dupZ(relay_ca);
    e.bind_addr = try dupZ(bind_addr);
    return e;
}

fn hostName(buf: *[256]u8, fallback: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        if (std.c.getenv("COMPUTERNAME")) |n| return std.mem.span(n);
    } else if (builtin.os.tag != .wasi) {
        if (std.posix.gethostname(buf[0..std.posix.HOST_NAME_MAX])) |n| return n else |_| {}
    }
    return fallback;
}

fn createError(e: anyerror) Status {
    return switch (e) {
        error.OutOfMemory => fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{}),
        error.StateDir, error.NoStateDir => fail(c.MOONSEC_ERR_IO, "cannot open the state directory", .{}),
        else => fail(c.MOONSEC_ERR_INTERNAL, "{s}", .{@errorName(e)}),
    };
}

fn checkCommon(backend: u32, clip: u32, relay: u32, relay_url: [*c]const u8) Status {
    if (backend == c.MOONSEC_BACKEND_SYSTEM and !system.available) return fail(c.MOONSEC_ERR_UNSUPPORTED, "this build has no system backend (MOONSEC_FEATURE_SYSTEM_BACKEND)", .{});
    if (backend != c.MOONSEC_BACKEND_SYNTHETIC and backend != c.MOONSEC_BACKEND_SYSTEM) return invalid("unknown backend");
    if (clip > c.MOONSEC_CLIPBOARD_APP) return invalid("unknown clipboard mode");
    if (relay > c.MOONSEC_RELAY_CUSTOM) return invalid("unknown relay mode");
    if (relay == c.MOONSEC_RELAY_CUSTOM and relay_url == null) return invalid("MOONSEC_RELAY_CUSTOM needs relay_url");
    return ok;
}

export fn moonsec_host_create(config: ?*const c.moonsec_host_config, out: ?*?*c.moonsec_host) Status {
    const o = out orelse return invalid("out is NULL");
    o.* = null;
    const cfg = readIn(c.moonsec_host_config, config) orelse return invalid("config is NULL or struct_size is too small");
    const st = checkCommon(cfg.backend, cfg.clipboard, cfg.relay_mode, cfg.relay_url);
    if (st != ok) return st;
    if (cfg.max_clients > 1) return fail(c.MOONSEC_ERR_UNSUPPORTED, "more than one client needs MOONSEC_FEATURE_MULTI_USER", .{});
    if (cfg.codec != 0 and (cfg.codec > 255 or !api.CodecSet.has(.{ .h264 = true, .hevc = true, .av1 = true, .passthrough = true }, @enumFromInt(@as(u8, @intCast(cfg.codec))))))
        return invalid("unknown codec");
    if (cfg.flags & c.MOONSEC_HOST_REQUIRE_PAIRED != 0 and cfg.state_dir != null and cfg.state_dir[0] == 0)
        return invalid("MOONSEC_HOST_REQUIRE_PAIRED needs a state directory");
    const e = createEndpoint(.host, cfg.state_dir, cfg.name, cfg.relay_url, cfg.relay_ca_pem, cfg.bind_addr) catch |err| return createError(err);
    e.hc = cfg;
    // Strings are copied; don't keep the caller's pointers.
    e.hc.state_dir = null;
    e.hc.name = null;
    e.hc.relay_url = null;
    e.hc.relay_ca_pem = null;
    e.hc.bind_addr = null;
    e.flags = cfg.flags;
    e.clip_mode = cfg.clipboard;
    e.relay_mode = cfg.relay_mode;
    o.* = @ptrCast(e);
    return ok;
}

export fn moonsec_client_create(config: ?*const c.moonsec_client_config, out: ?*?*c.moonsec_client) Status {
    const o = out orelse return invalid("out is NULL");
    o.* = null;
    const cfg = readIn(c.moonsec_client_config, config) orelse return invalid("config is NULL or struct_size is too small");
    const st = checkCommon(cfg.backend, cfg.clipboard, cfg.relay_mode, cfg.relay_url);
    if (st != ok) return st;
    if (cfg.flags & c.MOONSEC_CLIENT_REQUIRE_PAIRED != 0 and cfg.state_dir != null and cfg.state_dir[0] == 0)
        return invalid("MOONSEC_CLIENT_REQUIRE_PAIRED needs a state directory");
    const e = createEndpoint(.client, cfg.state_dir, cfg.name, cfg.relay_url, cfg.relay_ca_pem, cfg.bind_addr) catch |err| return createError(err);
    e.cc = cfg;
    e.cc.state_dir = null;
    e.cc.name = null;
    e.cc.relay_url = null;
    e.cc.relay_ca_pem = null;
    e.cc.bind_addr = null;
    e.flags = cfg.flags;
    e.clip_mode = cfg.clipboard;
    e.relay_mode = cfg.relay_mode;
    o.* = @ptrCast(e);
    return ok;
}

fn destroyEndpoint(e: *Endpoint) void {
    // Stop accepting first, so no session starts while the others close.
    if (options.iroh) {
        e.net.stopping.store(true, .release);
        if (e.net.accept) |*f| f.await(io());
    }
    // Each session is closed (a bye to the peer) and its threads joined.
    while (true) {
        e.lock();
        const last: ?*Session = if (e.sessions.items.len > 0) e.sessions.items[e.sessions.items.len - 1] else null;
        e.unlock();
        releaseSession(last orelse break);
    }
    if (options.iroh) if (e.net.ep) |ep| ep.deinit();
    e.sessions.deinit(gpa);
    e.events.deinit(gpa);
    e.allow.deinit();
    if (e.state) |*st| st.close();
    gpa.free(e.name);
    if (e.state_path) |sp| gpa.free(sp);
    inline for (.{ "relay_url", "relay_ca", "bind_addr" }) |f| if (@field(e, f)) |s| gpa.free(s);
    e.magic = 0;
    gpa.destroy(e);
}

export fn moonsec_host_destroy(h: ?*c.moonsec_host) void {
    if (hostOf(h)) |e| destroyEndpoint(e);
}

export fn moonsec_client_destroy(h: ?*c.moonsec_client) void {
    if (clientOf(h)) |e| destroyEndpoint(e);
}

fn idOut(e: *Endpoint, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    const hex = pair.id.toHex(&e.identity.id);
    return outStr(&hex, buf, cap, len);
}

export fn moonsec_host_id(h: ?*c.moonsec_host, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    return idOut(hostOf(h) orelse return invalid("not a host"), buf, cap, len);
}

export fn moonsec_client_id(h: ?*c.moonsec_client, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    return idOut(clientOf(h) orelse return invalid("not a client"), buf, cap, len);
}

fn pollEvent(e: *Endpoint, ev: ?*c.moonsec_event, timeout_ms: u32) i32 {
    const out = ev orelse return invalid("event is NULL");
    if (out.struct_size < 8) return invalid("event.struct_size is too small");
    const deadline = wallNow() + @as(Micros, timeout_ms) * 1000;
    while (true) {
        e.lock();
        const got = e.events.popFront();
        e.unlock();
        if (got) |g| {
            _ = writeOut(c.moonsec_event, out, g);
            return 1;
        }
        if (wallNow() >= deadline) return 0;
        io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

export fn moonsec_host_poll_event(h: ?*c.moonsec_host, ev: ?*c.moonsec_event, timeout_ms: u32) i32 {
    return pollEvent(hostOf(h) orelse return invalid("not a host"), ev, timeout_ms);
}

export fn moonsec_client_poll_event(h: ?*c.moonsec_client, ev: ?*c.moonsec_event, timeout_ms: u32) i32 {
    return pollEvent(clientOf(h) orelse return invalid("not a client"), ev, timeout_ms);
}

export fn moonsec_host_give_input(h: ?*c.moonsec_host, s: ?*c.moonsec_session) Status {
    _ = hostOf(h) orelse return invalid("not a host");
    _ = s;
    return fail(c.MOONSEC_ERR_UNSUPPORTED, "multi-user sessions are not in this build (MOONSEC_FEATURE_MULTI_USER)", .{});
}

export fn moonsec_host_displays(h: ?*c.moonsec_host, out: ?[*]c.moonsec_display_info, cap: usize, count: ?*usize) Status {
    _ = hostOf(h) orelse return invalid("not a host");
    _ = out;
    _ = cap;
    if (count) |n| n.* = 0;
    return fail(c.MOONSEC_ERR_UNSUPPORTED, "display listing is not in this build (MOONSEC_FEATURE_DISPLAYS)", .{});
}

// ---------------------------------------------------------------------------
// Sessions

const SideClock = struct {
    net: *simnet.Net,
    side: simnet.Side,

    fn now(p: ?*anyopaque) Micros {
        const sc: *SideClock = @ptrCast(@alignCast(p.?));
        return sc.net.localTime(sc.side);
    }

    fn clock(sc: *SideClock) api.Clock {
        return .{ .ptr = sc, .nowFn = now };
    }
};

/// Client input to the host app's event queue (MOONSEC_HOST_APP_INPUT), in place of the
/// backend's injector.
const AppInjector = struct {
    s: *Session,

    pub fn inject(self: *AppInjector, a: core.input.Action) api.Error!void {
        var in = std.mem.zeroes(c.moonsec_input);
        const now = self.s.clock.now();
        in.time_us = now;
        switch (a) {
            .key => |k| {
                in.kind = c.MOONSEC_INPUT_KEY;
                in.code = k.code;
                in.down = @intFromBool(k.down);
                in.time_us = k.time;
            },
            .button => |b| {
                in.kind = c.MOONSEC_INPUT_BUTTON;
                in.code = b.code;
                in.down = @intFromBool(b.down);
                in.time_us = b.time;
            },
            .scroll => |sc| {
                in.kind = c.MOONSEC_INPUT_SCROLL;
                in.x = sc.dx;
                in.y = sc.dy;
                in.time_us = sc.time;
            },
            .motion => |m| {
                in.kind = c.MOONSEC_INPUT_MOVE_REL;
                in.x = m.dx;
                in.y = m.dy;
            },
            .abs => |m| {
                in.kind = c.MOONSEC_INPUT_MOVE_ABS;
                in.x = m.x;
                in.y = m.y;
            },
            .pad => |p| {
                in.kind = c.MOONSEC_INPUT_GAMEPAD;
                in.code = p.index;
                in.down = @intFromBool(p.connected);
                in.pad_buttons = p.state.buttons;
                in.pad_lx = p.state.lx;
                in.pad_ly = p.state.ly;
                in.pad_rx = p.state.rx;
                in.pad_ry = p.state.ry;
                in.pad_lt = p.state.lt;
                in.pad_rt = p.state.rt;
            },
        }
        var ev = std.mem.zeroes(c.moonsec_event);
        ev.type = c.MOONSEC_EVENT_INPUT;
        ev.session = @ptrCast(self.s);
        ev.time_us = now;
        ev.input = in;
        self.s.ep.push(ev);
    }
};

/// The backend's presenter, then the app's frame callback.
const FramePresenter = struct {
    inner: api.Presenter,
    cb: *const fn (?*anyopaque, [*c]const c.moonsec_frame) callconv(.c) void,
    ctx: ?*anyopaque,
    format: c.moonsec_video_format = std.mem.zeroes(c.moonsec_video_format),

    pub fn configure(self: *FramePresenter, cfg: api.PresenterConfig) api.Error!void {
        self.format.chroma = @intFromEnum(cfg.format.chroma);
        self.format.bit_depth = cfg.format.bit_depth;
        self.format.color = @intFromEnum(cfg.format.color);
        return self.inner.configure(cfg);
    }

    pub fn present(self: *FramePresenter, f: *const api.DecodedFrame, o: ?*const api.Overlay) api.Error!api.Presented {
        const r = try self.inner.present(f, o);
        var fr = std.mem.zeroes(c.moonsec_frame);
        fr.struct_size = @sizeOf(c.moonsec_frame);
        fr.frame_id = f.frame_id;
        fr.width = f.image.width;
        fr.height = f.image.height;
        fr.format = self.format;
        if (f.image.cpu) |cpu| if (f.image.format == .bgra8) {
            fr.pixels = cpu.data.ptr;
            fr.stride = cpu.stride;
        };
        fr.gpu_texture = f.image.gpu;
        fr.presented_us = r.presented_us;
        self.cb(self.ctx, &fr);
        return r;
    }

    pub fn deinit(self: *FramePresenter) void {
        self.inner.deinit();
    }
};

const Transport = union(enum) {
    loopback: *Loopback,
    iroh: if (options.iroh) *iroh_pipe.IrohPipe else void,
};

const Session = struct {
    magic: u32 = magic,
    ep: *Endpoint,
    app: union(Role) { host: apps.HostApp, client: apps.ClientApp },
    transport: Transport,
    clock: api.Clock,
    side_clock: SideClock = undefined,
    syn_host: ?*synthetic.Host = null,
    syn_client: ?*synthetic.Client = null,
    injector: AppInjector = undefined,
    presenter: FramePresenter = undefined,
    clip: clipboard.Memory,
    clip_seen: u64 = 0,
    sys_clip: ?clipboard.System = null,
    runner: ?Io.Future(void) = null,

    // What `check` last reported.
    started: bool = false,
    ended_sent: bool = false,
    last_format: c.moonsec_video_format = std.mem.zeroes(c.moonsec_video_format),
    last_size: [2]u32 = .{ 0, 0 },
    relayed: bool = false,

    fn ended(s: *const Session) bool {
        return switch (s.app) {
            .host => |*a| a.done(),
            .client => |*a| a.done(),
        };
    }

    fn close(s: *Session) void {
        const now = s.clock.now();
        switch (s.app) {
            .host => |*a| a.s.close(now),
            .client => |*a| a.s.close(now),
        }
    }

    /// Close and send the first bye now, for a session about to be freed.
    fn closeNow(s: *Session) void {
        s.close();
        const now = s.clock.now();
        switch (s.app) {
            .host => |*a| a.s.step(now),
            .client => |*a| a.s.step(now),
        }
    }

    fn state(s: *const Session) i32 {
        return switch (s.app) {
            .host => |*a| switch (a.s.state) {
                .waiting => c.MOONSEC_STATE_CONNECTING,
                .streaming => c.MOONSEC_STATE_STREAMING,
                .ended => c.MOONSEC_STATE_ENDED,
            },
            .client => |*a| switch (a.s.state) {
                .connecting => c.MOONSEC_STATE_CONNECTING,
                .streaming => c.MOONSEC_STATE_STREAMING,
                .ended => c.MOONSEC_STATE_ENDED,
            },
        };
    }

    fn endReason(s: *const Session) i32 {
        return switch (s.app) {
            .host => |*a| switch (a.s.end) {
                .none => c.MOONSEC_END_NONE,
                .closed => c.MOONSEC_END_CLOSED,
                .client_bye => c.MOONSEC_END_PEER_CLOSED,
                .peer_timeout => c.MOONSEC_END_TIMEOUT,
                .pipe_closed => c.MOONSEC_END_TRANSPORT,
                .failed => c.MOONSEC_END_FAILED,
            },
            .client => |*a| switch (a.s.end) {
                .none => c.MOONSEC_END_NONE,
                .closed => c.MOONSEC_END_CLOSED,
                .host_bye => c.MOONSEC_END_PEER_CLOSED,
                .peer_timeout, .connect_timeout => c.MOONSEC_END_TIMEOUT,
                .pipe_closed => c.MOONSEC_END_TRANSPORT,
                .failed => c.MOONSEC_END_FAILED,
            },
        };
    }

    /// The stream's format and size (zeros before there is one).
    fn format(s: *const Session) struct { f: c.moonsec_video_format, w: u32, h: u32, fps: u32, bitrate: u64 } {
        switch (s.app) {
            .host => |*a| return .{ .f = vf(a.s.codec, a.s.format), .w = a.size.width, .h = a.size.height, .fps = a.opts.fps, .bitrate = a.s.bitrate_bps },
            .client => |*a| {
                const cf = a.s.config orelse return .{ .f = std.mem.zeroes(c.moonsec_video_format), .w = 0, .h = 0, .fps = 0, .bitrate = 0 };
                return .{ .f = vf(cf.codec, cf.format), .w = cf.width, .h = cf.height, .fps = cf.fps, .bitrate = cf.bitrate_bps };
            },
        }
    }

    fn pathStats(s: *const Session) pipe_mod.PathStats {
        return switch (s.app) {
            .host => |*a| a.s.path,
            .client => |*a| a.s.path,
        };
    }

    fn tick(s: *Session) void {
        switch (s.app) {
            .host => |*a| a.tick(),
            .client => |*a| a.tick(),
        }
    }

    fn deinit(s: *Session) void {
        switch (s.app) {
            .host => |*a| {
                const be = a.be;
                a.deinit();
                be.deinit();
            },
            .client => |*a| {
                const be = a.be;
                a.deinit();
                be.deinit();
            },
        }
        if (options.iroh) switch (s.transport) {
            .iroh => |p| {
                p.ctl.drop();
                p.conn.deinit(0);
                gpa.destroy(p);
            },
            else => {},
        };
        s.clip.deinit();
        if (s.sys_clip) |*y| y.close();
        s.magic = 0;
        gpa.destroy(s);
    }
};

fn vf(codec: api.Codec, f: api.VideoFormat) c.moonsec_video_format {
    return .{ .codec = @intFromEnum(codec), .chroma = @intFromEnum(f.chroma), .bit_depth = f.bit_depth, .color = @intFromEnum(f.color) };
}

fn sessionOf(p: ?*c.moonsec_session) ?*Session {
    const s: *Session = @ptrCast(@alignCast(p orelse return null));
    return if (s.magic == magic) s else null;
}

/// Compare the session with what was last reported and queue events (lock held).
fn check(s: *Session) void {
    const e = s.ep;
    const st = s.state();
    const fmt = s.format();
    var ev = std.mem.zeroes(c.moonsec_event);
    ev.session = @ptrCast(s);
    ev.time_us = s.clock.now();
    ev.format = fmt.f;
    ev.width = fmt.w;
    ev.height = fmt.h;
    if (!s.started and st == c.MOONSEC_STATE_STREAMING) {
        s.started = true;
        s.last_format = fmt.f;
        s.last_size = .{ fmt.w, fmt.h };
        ev.type = c.MOONSEC_EVENT_SESSION_STARTED;
        e.push(ev);
    } else if (s.started and !s.ended_sent and (!std.meta.eql(s.last_format, fmt.f) or s.last_size[0] != fmt.w or s.last_size[1] != fmt.h)) {
        s.last_format = fmt.f;
        s.last_size = .{ fmt.w, fmt.h };
        ev.type = c.MOONSEC_EVENT_FORMAT_CHANGED;
        e.push(ev);
    }
    const relayed = s.pathStats().relayed;
    if (relayed != s.relayed) {
        s.relayed = relayed;
        var pe = ev;
        pe.type = c.MOONSEC_EVENT_PATH_CHANGED;
        pe.code = @intFromBool(relayed);
        e.push(pe);
    }
    if (e.clip_mode == c.MOONSEC_CLIPBOARD_APP and s.clip.writes != s.clip_seen) {
        s.clip_seen = s.clip.writes;
        var ce = ev;
        ce.type = c.MOONSEC_EVENT_CLIPBOARD;
        e.push(ce);
    }
    if (!s.ended_sent and st == c.MOONSEC_STATE_ENDED) {
        s.ended_sent = true;
        var ee = ev;
        ee.type = c.MOONSEC_EVENT_SESSION_ENDED;
        ee.code = s.endReason();
        e.push(ee);
    }
}

fn hookCheck(p: *anyopaque) void {
    check(@ptrCast(@alignCast(p)));
}

fn pickCodec(caps: api.EncoderCaps, want: u32) ?api.Codec {
    if (want != 0) {
        const cd: api.Codec = @enumFromInt(@as(u8, @truncate(want)));
        return if (caps.codecs.has(cd)) cd else null;
    }
    for ([_]api.Codec{ .hevc, .h264, .av1, .passthrough }) |cd| if (caps.codecs.has(cd)) return cd;
    return null;
}

const SessionError = error{ Unsupported, Backend, OutOfMemory };

/// The clipboard the session syncs: the app's (in memory), the system's, or none.
fn sessionClipboard(s: *Session) SessionError!?clipboard.Clipboard {
    return switch (s.ep.clip_mode) {
        c.MOONSEC_CLIPBOARD_APP => s.clip.clipboard(),
        c.MOONSEC_CLIPBOARD_SYSTEM => blk: {
            s.sys_clip = clipboard.System.open() orelse return error.Unsupported;
            break :blk s.sys_clip.?.clipboard();
        },
        else => null,
    };
}

/// A host session over `p`. `virtual`: the clock is the loopback's, nothing may block.
fn newHostSession(e: *Endpoint, p: pipe_mod.PacketPipe, ctl: ?pipe_mod.ByteStream, transport: Transport, virtual: ?*Loopback) SessionError!*Session {
    const s = try gpa.create(Session);
    errdefer gpa.destroy(s);
    s.* = .{ .ep = e, .app = undefined, .transport = transport, .clock = undefined, .clip = .init(gpa) };
    errdefer s.clip.deinit();
    if (virtual) |lb| {
        s.side_clock = .{ .net = lb.net, .side = .a };
        s.clock = s.side_clock.clock();
    } else s.clock = api.clockFn(wallNow);
    const cfg = e.hc;
    var be: api.HostBackend = undefined;
    if (cfg.backend == c.MOONSEC_BACKEND_SYSTEM) {
        // The OS's capture, encoder, audio and input (app/system.zig), on its clock.
        std.debug.assert(virtual == null);
        be = try system.openHost(gpa, .{
            .audio = cfg.flags & c.MOONSEC_HOST_NO_AUDIO == 0,
            .state_dir = e.state_path,
        });
        s.clock = be.clock;
    } else {
        const sh = synthetic.openHost(gpa, .{
            .clock = s.clock,
            .sleeper = if (virtual == null) wallSleep else null,
            .width = if (cfg.width != 0) cfg.width else 640,
            .height = if (cfg.height != 0) cfg.height else 360,
            .audio = cfg.flags & c.MOONSEC_HOST_NO_AUDIO == 0,
        }) catch return error.OutOfMemory;
        be = sh.backend();
        s.syn_host = sh;
    }
    errdefer be.deinit();
    if (cfg.flags & c.MOONSEC_HOST_APP_INPUT != 0) {
        s.injector = .{ .s = s };
        be.input = api.bind(api.InputInjector, AppInjector, &s.injector);
    }
    const codec = pickCodec(be.encoder.caps(), cfg.codec) orelse return error.Unsupported;
    const clip = try sessionClipboard(s);
    s.app = .{ .host = apps.HostApp.init(gpa, be, .{
        .fps = if (cfg.fps != 0) cfg.fps else 60,
        .bitrate_bps = if (cfg.bitrate_bps != 0) cfg.bitrate_bps else 10_000_000,
        .codec = codec,
        .yuv444 = cfg.flags & c.MOONSEC_HOST_YUV444 != 0,
        .ten_bit = cfg.flags & c.MOONSEC_HOST_TEN_BIT != 0,
        .hdr = cfg.flags & c.MOONSEC_HOST_NO_HDR == 0,
        .display = cfg.display,
        .width = cfg.width,
        .height = cfg.height,
        .audio = cfg.flags & c.MOONSEC_HOST_NO_AUDIO == 0,
        .session = .{
            .rate_control = cfg.flags & c.MOONSEC_HOST_RATE_CONTROL != 0,
            .loss_policy = cfg.flags & c.MOONSEC_HOST_LOSS_POLICY != 0,
        },
        .control_stream = ctl,
        .clipboard = clip,
        .clipboard_poll_us = 50_000,
    }, p) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.Backend,
    } };
    return s;
}

fn newClientSession(e: *Endpoint, p: pipe_mod.PacketPipe, ctl: ?pipe_mod.ByteStream, transport: Transport, virtual: ?*Loopback) SessionError!*Session {
    const s = try gpa.create(Session);
    errdefer gpa.destroy(s);
    s.* = .{ .ep = e, .app = undefined, .transport = transport, .clock = undefined, .clip = .init(gpa) };
    errdefer s.clip.deinit();
    if (virtual) |lb| {
        s.side_clock = .{ .net = lb.net, .side = .b };
        s.clock = s.side_clock.clock();
    } else s.clock = api.clockFn(wallNow);
    const cfg = e.cc;
    var be: api.ClientBackend = undefined;
    if (cfg.backend == c.MOONSEC_BACKEND_SYSTEM) {
        // The OS's decoder, window, audio and input (app/system.zig), on its clock.
        std.debug.assert(virtual == null);
        be = try system.openClient(gpa, .{
            .title = "moonsec",
            .audio = cfg.flags & c.MOONSEC_CLIENT_NO_AUDIO == 0,
            .input = cfg.flags & c.MOONSEC_CLIENT_NO_OS_INPUT == 0,
        });
        s.clock = be.clock;
    } else {
        const sc = synthetic.openClient(gpa, .{
            .clock = s.clock,
            // No scripted input: the app sends its own with moonsec_session_send_input.
            .input_interval_us = 0,
            .audio = cfg.flags & c.MOONSEC_CLIENT_NO_AUDIO == 0,
        }) catch return error.OutOfMemory;
        be = sc.backend();
        s.syn_client = sc;
    }
    errdefer be.deinit();
    if (cfg.flags & c.MOONSEC_CLIENT_NO_OS_INPUT != 0) be.input = null;
    if (cfg.on_frame) |cb| {
        s.presenter = .{ .inner = be.presenter, .cb = cb, .ctx = cfg.frame_ctx };
        be.presenter = api.bind(api.Presenter, FramePresenter, &s.presenter);
    }
    const clip = try sessionClipboard(s);
    var nonce: [4]u8 = undefined;
    io().random(&nonce);
    s.app = .{ .client = apps.ClientApp.init(gpa, be, .{
        .windowed = cfg.flags & c.MOONSEC_CLIENT_FULLSCREEN == 0,
        .audio = cfg.flags & c.MOONSEC_CLIENT_NO_AUDIO == 0,
        .session = .{
            .max_width = cfg.max_width,
            .max_height = cfg.max_height,
            .nonce = std.mem.readInt(u32, &nonce, .little) | 1,
        },
        .control_stream = ctl,
        .clipboard = clip,
        .clipboard_poll_us = 50_000,
    }, p) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Backend,
    } };
    // Offer only the codecs the app allows.
    if (cfg.codecs != 0) {
        const mask: u8 = @truncate(cfg.codecs);
        const have: u8 = @bitCast(s.app.client.s.cfg.codecs);
        s.app.client.s.cfg.codecs = @bitCast(have & mask & 0x0f);
    }
    return s;
}

fn sessionError(err: SessionError) Status {
    return switch (err) {
        error.OutOfMemory => fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{}),
        error.Unsupported => fail(c.MOONSEC_ERR_UNSUPPORTED, "the backend is not available here, has no such codec, or there is no system clipboard", .{}),
        error.Backend => fail(c.MOONSEC_ERR_BACKEND, "the backend failed to start", .{}),
    };
}

/// Run an iroh session on its own threads until it ends.
fn runSession(s: *Session) void {
    const lock: apps.Lock = .{ .mu = &s.ep.mu, .io = io() };
    const hook: apps.Hook = .{ .ctx = s, .f = hookCheck };
    switch (s.app) {
        .host => |*a| a.runThreadedWith(io(), lock, hook) catch {},
        .client => |*a| a.runThreadedWith(io(), lock, hook) catch {},
    }
    s.ep.lock();
    check(s);
    s.ep.unlock();
}

fn releaseSession(s: *Session) void {
    const e = s.ep;
    switch (s.transport) {
        .loopback => |lb| {
            lb.lock();
            defer lb.unlock();
            e.lock();
            defer e.unlock();
            if (lb.host == s) lb.host = null;
            if (lb.client == s) lb.client = null;
            if (!s.ended()) s.closeNow();
            removeSession(e, s);
            s.deinit();
        },
        .iroh => {
            e.lock();
            if (!s.ended()) s.close();
            e.unlock();
            if (s.runner) |*r| r.await(io());
            e.lock();
            defer e.unlock();
            removeSession(e, s);
            s.deinit();
        },
    }
}

fn removeSession(e: *Endpoint, s: *Session) void {
    for (e.sessions.items, 0..) |x, i| if (x == s) {
        _ = e.sessions.swapRemove(i);
        break;
    };
    // Events about it would name a freed handle.
    var i: usize = 0;
    while (i < e.events.len) {
        const ev = e.events.at(i);
        if (ev.session == @as(?*c.moonsec_session, @ptrCast(s))) {
            removeEventAt(&e.events, i);
        } else i += 1;
    }
}

fn removeEventAt(q: *std.Deque(c.moonsec_event), idx: usize) void {
    var tmp: std.Deque(c.moonsec_event) = .empty;
    var i: usize = 0;
    while (q.popFront()) |ev| : (i += 1) {
        if (i != idx) tmp.pushBack(gpa, ev) catch {};
    }
    q.deinit(gpa);
    q.* = tmp;
}

export fn moonsec_session_state(p: ?*c.moonsec_session) i32 {
    const s = sessionOf(p) orelse return invalid("not a session");
    s.ep.lock();
    defer s.ep.unlock();
    return s.state();
}

export fn moonsec_session_close(p: ?*c.moonsec_session) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    s.ep.lock();
    defer s.ep.unlock();
    s.close();
    return ok;
}

export fn moonsec_session_release(p: ?*c.moonsec_session) void {
    if (sessionOf(p)) |s| releaseSession(s);
}

export fn moonsec_session_send_input(p: ?*c.moonsec_session, in: ?*const c.moonsec_input) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    const i = in orelse return invalid("input is NULL");
    s.ep.lock();
    defer s.ep.unlock();
    const a = switch (s.app) {
        .client => |*a| a,
        .host => return fail(c.MOONSEC_ERR_STATE, "input is sent from the client's session", .{}),
    };
    if (a.s.state != .streaming) return fail(c.MOONSEC_ERR_STATE, "the session is not streaming", .{});
    const t = if (i.time_us != 0) i.time_us else s.clock.now();
    const what: api.InputEvent.What = switch (i.kind) {
        c.MOONSEC_INPUT_KEY => .{ .key = .{ .code = @truncate(i.code), .down = i.down != 0 } },
        c.MOONSEC_INPUT_BUTTON => .{ .button = .{ .code = @truncate(i.code), .down = i.down != 0 } },
        c.MOONSEC_INPUT_SCROLL => .{ .scroll = .{ .dx = i.x, .dy = i.y } },
        c.MOONSEC_INPUT_MOVE_REL => .{ .move_rel = .{ .dx = i.x, .dy = i.y } },
        c.MOONSEC_INPUT_MOVE_ABS => .{ .move_abs = .{ .x = @intCast(std.math.clamp(i.x, 0, 65535)), .y = @intCast(std.math.clamp(i.y, 0, 65535)) } },
        c.MOONSEC_INPUT_GAMEPAD => blk: {
            if (i.code > 3) return invalid("gamepad index must be 0..3");
            break :blk .{ .pad = .{ .index = @intCast(i.code), .state = if (i.down != 0) .{
                .buttons = i.pad_buttons,
                .lx = i.pad_lx,
                .ly = i.pad_ly,
                .rx = i.pad_rx,
                .ry = i.pad_ry,
                .lt = i.pad_lt,
                .rt = i.pad_rt,
            } else null } };
        },
        else => return invalid("unknown input kind"),
    };
    a.s.onInput(.{ .time_us = t, .what = what });
    return ok;
}

export fn moonsec_session_request_input(p: ?*c.moonsec_session) Status {
    _ = sessionOf(p) orelse return invalid("not a session");
    return fail(c.MOONSEC_ERR_UNSUPPORTED, "multi-user sessions are not in this build (MOONSEC_FEATURE_MULTI_USER)", .{});
}

export fn moonsec_session_clipboard_set(p: ?*c.moonsec_session, text: ?[*]const u8, len: usize) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    if (text == null and len > 0) return invalid("text is NULL");
    s.ep.lock();
    defer s.ep.unlock();
    if (s.ep.clip_mode != c.MOONSEC_CLIPBOARD_APP) return fail(c.MOONSEC_ERR_STATE, "the clipboard mode is not MOONSEC_CLIPBOARD_APP", .{});
    if (!std.unicode.utf8ValidateSlice(if (len > 0) text.?[0..len] else "")) return invalid("text is not UTF-8");
    s.clip.set(if (len > 0) text.?[0..len] else "") catch return fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{});
    // Our own copy is not news for the app.
    s.clip_seen = s.clip.writes;
    return ok;
}

export fn moonsec_session_clipboard_get(p: ?*c.moonsec_session, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    s.ep.lock();
    defer s.ep.unlock();
    if (s.ep.clip_mode != c.MOONSEC_CLIPBOARD_APP) return fail(c.MOONSEC_ERR_STATE, "the clipboard mode is not MOONSEC_CLIPBOARD_APP", .{});
    return outStr(s.clip.get() orelse "", buf, cap, len);
}

export fn moonsec_session_format(p: ?*c.moonsec_session, f: ?*c.moonsec_video_format, w: ?*u32, h: ?*u32) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    s.ep.lock();
    defer s.ep.unlock();
    if (!s.started) return fail(c.MOONSEC_ERR_STATE, "the session has not started streaming", .{});
    const fmt = s.format();
    if (f) |x| x.* = fmt.f;
    if (w) |x| x.* = fmt.w;
    if (h) |x| x.* = fmt.h;
    return ok;
}

fn stageOut(st: core.telemetry.StageStats) c.moonsec_stage_stats {
    return .{ .count = st.count, .reserved = 0, .min_us = st.min, .mean_us = st.mean, .p50_us = st.p50, .p95_us = st.p95, .p99_us = st.p99, .max_us = st.max };
}

export fn moonsec_session_telemetry(p: ?*c.moonsec_session, out: ?*c.moonsec_telemetry) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    const o = out orelse return invalid("out is NULL");
    var t = std.mem.zeroes(c.moonsec_telemetry);
    s.ep.lock();
    defer s.ep.unlock();
    t.state = s.state();
    t.end_reason = s.endReason();
    const fmt = s.format();
    t.format = fmt.f;
    t.width = fmt.w;
    t.height = fmt.h;
    t.fps = fmt.fps;
    t.bitrate_bps = fmt.bitrate;
    const path = s.pathStats();
    t.pacing_bps = path.pacing_bps;
    if (path.relayed) t.flags |= c.MOONSEC_TELEMETRY_RELAYED;
    if (path.stalled) t.flags |= c.MOONSEC_TELEMETRY_STALLED;
    t.stage_count = core.telemetry.Stage.count;
    const now = s.clock.now();
    var snap: core.telemetry.Snapshot = undefined;
    switch (s.app) {
        .host => |*a| {
            const st = a.s.stats;
            t.rtt_us = path.rtt_us;
            t.frames = st.frames;
            t.keyframes = st.keyframes;
            t.refreshes = st.refreshes;
            t.retransmits = st.retransmits;
            t.parity_shards = st.parity_shards;
            t.input_events = st.inputs_applied;
            t.path_changes = st.path_changes;
            t.reconnects = st.reconnects;
            if (a.s.offset != null) t.flags |= c.MOONSEC_TELEMETRY_CLOCK_SYNCED;
            snap = a.s.tele.snapshot();
        },
        .client => |*a| {
            const st = a.s.stats;
            const ov = a.s.overlay(now);
            t.rtt_us = ov.rtt_us;
            t.frames = st.frames_presented;
            t.frames_lost = st.frames_lost;
            t.freezes = a.s.freeze.stats.freezes;
            t.longest_gap_us = a.s.freeze.stats.longest_gap_us;
            t.input_events = st.input_events;
            t.path_changes = st.path_changes;
            t.reconnects = st.reconnects;
            if (ov.clock_synced) t.flags |= c.MOONSEC_TELEMETRY_CLOCK_SYNCED;
            snap = ov.telemetry;
        },
    }
    for (snap.stages, 0..) |st, i| t.stages[i] = stageOut(st);
    if (!writeOut(c.moonsec_telemetry, o, t)) return invalid("out.struct_size is too small");
    return ok;
}

// ---------------------------------------------------------------------------
// Loopback

const Loopback = struct {
    magic: u32 = magic,
    mu: Io.Mutex = .init,
    net: *simnet.Net,
    t: Micros = 0,
    host: ?*Session = null,
    client: ?*Session = null,

    fn lock(l: *Loopback) void {
        l.mu.lockUncancelable(io());
    }
    fn unlock(l: *Loopback) void {
        l.mu.unlock(io());
    }
};

fn loopbackOf(p: ?*c.moonsec_loopback) ?*Loopback {
    const l: *Loopback = @ptrCast(@alignCast(p orelse return null));
    return if (l.magic == magic) l else null;
}

export fn moonsec_loopback_create(config: ?*const c.moonsec_loopback_config, out: ?*?*c.moonsec_loopback) Status {
    const o = out orelse return invalid("out is NULL");
    o.* = null;
    const cfg = readIn(c.moonsec_loopback_config, config) orelse return invalid("config is NULL or struct_size is too small");
    const profile: simrun.Profile = switch (cfg.profile) {
        c.MOONSEC_PROFILE_CLEAN => .clean,
        c.MOONSEC_PROFILE_LAN => .lan,
        c.MOONSEC_PROFILE_WAN => .wan,
        else => return invalid("unknown profile"),
    };
    const net = gpa.create(simnet.Net) catch return fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{});
    net.init(gpa, .{ .seed = if (cfg.seed != 0) cfg.seed else 1, .a_to_b = profile.link(), .b_to_a = profile.link() }) catch {
        gpa.destroy(net);
        return fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{});
    };
    const l = gpa.create(Loopback) catch {
        net.deinit();
        gpa.destroy(net);
        return fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{});
    };
    l.* = .{ .net = net };
    o.* = @ptrCast(l);
    return ok;
}

export fn moonsec_loopback_destroy(p: ?*c.moonsec_loopback) void {
    const l = loopbackOf(p) orelse return;
    // Sessions still on it are the caller's bug; free them with their endpoints' locks.
    if (l.host) |s| releaseSession(s);
    if (l.client) |s| releaseSession(s);
    l.net.deinit();
    gpa.destroy(l.net);
    l.magic = 0;
    gpa.destroy(l);
}

export fn moonsec_loopback_now(p: ?*c.moonsec_loopback) i64 {
    const l = loopbackOf(p) orelse return invalid("not a loopback");
    l.lock();
    defer l.unlock();
    return l.t;
}

const loop_step_us: Micros = 250;

export fn moonsec_loopback_advance(p: ?*c.moonsec_loopback, us: i64) Status {
    const l = loopbackOf(p) orelse return invalid("not a loopback");
    if (us < 0) return invalid("us is negative");
    l.lock();
    defer l.unlock();
    const end = l.t + us;
    while (l.t < end) {
        l.t = @min(l.t + loop_step_us, end);
        l.net.runUntil(l.t) catch return fail(c.MOONSEC_ERR_INTERNAL, "the simulated network failed", .{});
        for ([_]?*Session{ l.host, l.client }) |maybe| if (maybe) |s| {
            s.ep.lock();
            defer s.ep.unlock();
            if (!s.ended_sent) {
                s.tick();
                check(s);
            }
        };
    }
    return ok;
}

export fn moonsec_host_listen_loopback(h: ?*c.moonsec_host, lp: ?*c.moonsec_loopback, out: ?*?*c.moonsec_session) Status {
    const e = hostOf(h) orelse return invalid("not a host");
    const l = loopbackOf(lp) orelse return invalid("not a loopback");
    if (out) |o| o.* = null;
    l.lock();
    defer l.unlock();
    e.lock();
    defer e.unlock();
    if (l.host != null) return fail(c.MOONSEC_ERR_STATE, "a host is already on this loopback", .{});
    if (e.hc.backend == c.MOONSEC_BACKEND_SYSTEM) return fail(c.MOONSEC_ERR_UNSUPPORTED, "the loopback runs in virtual time: system backends need iroh", .{});
    if (e.activeSession()) return fail(c.MOONSEC_ERR_STATE, "the host already has a session", .{});
    const s = newHostSession(e, l.net.pipeFor(.a), l.net.streamFor(.a), .{ .loopback = l }, l) catch |err| return sessionError(err);
    e.sessions.append(gpa, s) catch {
        s.deinit();
        return fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{});
    };
    l.host = s;
    if (out) |o| o.* = @ptrCast(s);
    return ok;
}

export fn moonsec_client_connect_loopback(h: ?*c.moonsec_client, lp: ?*c.moonsec_loopback, out: ?*?*c.moonsec_session) Status {
    const e = clientOf(h) orelse return invalid("not a client");
    const l = loopbackOf(lp) orelse return invalid("not a loopback");
    if (out) |o| o.* = null;
    l.lock();
    defer l.unlock();
    e.lock();
    defer e.unlock();
    if (l.client != null) return fail(c.MOONSEC_ERR_STATE, "a client is already on this loopback", .{});
    if (e.cc.backend == c.MOONSEC_BACKEND_SYSTEM) return fail(c.MOONSEC_ERR_UNSUPPORTED, "the loopback runs in virtual time: system backends need iroh", .{});
    if (e.activeSession()) return fail(c.MOONSEC_ERR_STATE, "the client already has a session", .{});
    const s = newClientSession(e, l.net.pipeFor(.b), l.net.streamFor(.b), .{ .loopback = l }, l) catch |err| return sessionError(err);
    e.sessions.append(gpa, s) catch {
        s.deinit();
        return fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{});
    };
    l.client = s;
    if (out) |o| o.* = @ptrCast(s);
    return ok;
}

// ---------------------------------------------------------------------------
// iroh: listen, connect, pairing

fn noIroh() Status {
    return fail(c.MOONSEC_ERR_UNSUPPORTED, "this build has no iroh transport (MOONSEC_FEATURE_IROH)", .{});
}

fn irohErr(comptime what: []const u8) Status {
    if (!options.iroh) return noIroh();
    return fail(c.MOONSEC_ERR_TRANSPORT, what ++ ": {s}", .{iroh.lastError()});
}

/// Bind the endpoint's iroh endpoint once (lock held).
fn bindIroh(e: *Endpoint) Status {
    if (!options.iroh) return noIroh();
    if (e.net.ep != null) return ok;
    pair_cmd.initIroh() catch return irohErr("iroh init");
    const any_relay = e.relay_mode != c.MOONSEC_RELAY_DISABLED;
    const ep = iroh.Endpoint.bind(.{
        .secret_key = &e.identity.secret,
        .alpn = if (e.role == .host) pair_cmd.alpn else "",
        .relay_mode = switch (e.relay_mode) {
            c.MOONSEC_RELAY_DEFAULT => .default,
            c.MOONSEC_RELAY_CUSTOM => .custom_only,
            else => .disabled,
        },
        .relay_urls = if (e.relay_url) |u| u.ptr else null,
        .relay_ca_pem = if (e.relay_ca) |t| t.ptr else null,
        .bind_addr = if (e.bind_addr) |b| b.ptr else if (any_relay) "0.0.0.0:0" else "127.0.0.1:0",
    }) catch return irohErr("bind");
    if (any_relay) ep.online(15_000) catch {};
    e.net.ep = ep;
    return ok;
}

export fn moonsec_host_listen(h: ?*c.moonsec_host) Status {
    const e = hostOf(h) orelse return invalid("not a host");
    if (!options.iroh) return noIroh();
    e.lock();
    defer e.unlock();
    if (e.net.accept != null) return fail(c.MOONSEC_ERR_STATE, "already listening", .{});
    const st = bindIroh(e);
    if (st != ok) return st;
    e.net.accept = io().concurrent(acceptLoop, .{e}) catch return fail(c.MOONSEC_ERR_INTERNAL, "cannot start the accept thread", .{});
    return ok;
}

fn addrTicket(e: *Endpoint, buf: []u8) ![]u8 {
    var abuf: [4096]u8 = undefined;
    const addr = try e.net.ep.?.ticket(&abuf);
    return (pair.Ticket{ .host_id = e.identity.id, .addr = addr }).encode(buf);
}

export fn moonsec_host_ticket(h: ?*c.moonsec_host, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    const e = hostOf(h) orelse return invalid("not a host");
    if (!options.iroh) return noIroh();
    e.lock();
    defer e.unlock();
    if (e.net.ep == null) return fail(c.MOONSEC_ERR_STATE, "call moonsec_host_listen first", .{});
    var tb: [pair.ticket.max_text]u8 = undefined;
    const t = addrTicket(e, &tb) catch return irohErr("ticket");
    return outStr(t, buf, cap, len);
}

fn peerEvent(ty: u32, id: *const pair.Id, name: []const u8, code: i32) c.moonsec_event {
    var ev = std.mem.zeroes(c.moonsec_event);
    ev.type = ty;
    ev.code = code;
    fixedStr(&ev.peer_id, &pair.id.toHex(id));
    fixedStr(&ev.peer_name, name);
    return ev;
}

/// The host's accept thread: pairing requests while a window is open, and session
/// admission. One session at a time.
fn acceptLoop(e: *Endpoint) void {
    if (!options.iroh) return;
    while (!e.net.stopping.load(.acquire)) {
        closeWindowIfDone(e);
        const conn = e.net.ep.?.accept(200) catch |err| switch (err) {
            error.Closed => return,
            else => continue,
        };
        handleConn(e, conn) catch {
            conn.deinit(0);
        };
    }
}

fn closeWindowIfDone(e: *Endpoint) void {
    if (!options.iroh) return;
    e.lock();
    defer e.unlock();
    if (e.net.window) |*w| if (!w.isOpen(wallNow())) {
        var ev = std.mem.zeroes(c.moonsec_event);
        ev.type = c.MOONSEC_EVENT_PAIR_CLOSED;
        ev.code = @intCast(e.net.paired_in_window);
        e.push(ev);
        e.net.window = null;
    };
}

fn handleConn(e: *Endpoint, conn: iroh.Conn) !void {
    const peer_id = try pair_cmd.remoteId(conn);
    var s: pair_cmd.IrohStream = .{ .s = try conn.acceptBi(5_000) };
    var f: ex.Framer = .{};
    var mb: [ex.max_message]u8 = undefined;
    const first = (pair_cmd.readFirst(s.stream(), &f, &mb) catch null) orelse {
        s.close();
        return error.Protocol;
    };
    switch (ex.classify(first)) {
        .pair => {
            defer s.close();
            defer conn.deinit(0);
            e.lock();
            // No window open: a closed one, so the client hears "not pairing right now".
            var window = e.net.window orelse ex.Window{ .deadline_us = 0 };
            e.unlock();
            var nonce: ex.Nonce = undefined;
            io().random(&nonce);
            var hs = ex.Host.init(&window, e.identity.id, peer_id, nonce, e.name);
            const out = pairing.serveHost(s.stream(), &f, &hs, first, &wallNow) catch return;
            e.lock();
            defer e.unlock();
            // The window's counters moved; keep them unless pair_end closed it meanwhile.
            if (e.net.window != null) e.net.window = window;
            switch (out) {
                .paired => |pd| {
                    e.allow.put(.{ .id = pd.peer_id, .paired_unix_s = pair_cmd.unixNow(io()), .name = pd.name() }) catch {};
                    e.saveAllow();
                    e.net.paired_in_window += 1;
                    e.push(peerEvent(c.MOONSEC_EVENT_PAIRED, &pd.peer_id, pd.name(), 0));
                },
                .failed => |why| e.push(peerEvent(c.MOONSEC_EVENT_PAIR_FAILED, &peer_id, "", switch (why) {
                    .bad_proof, .locked => c.MOONSEC_PAIR_FAIL_BAD_PROOF,
                    .expired, .no_window => c.MOONSEC_PAIR_FAIL_EXPIRED,
                    else => c.MOONSEC_PAIR_FAIL_OTHER,
                })),
            }
        },
        .admit => {
            e.lock();
            const paired = e.allow.contains(&peer_id);
            const need = e.flags & c.MOONSEC_HOST_REQUIRE_PAIRED != 0;
            const busy = e.activeSession();
            e.unlock();
            const allowed = (paired or !need) and !busy;
            var o: ex.Out = .{};
            s.stream().write(ex.admitReply(&o, allowed)) catch {};
            s.close();
            if (!allowed) {
                conn.deinit(pair_cmd.close_not_paired);
                e.lock();
                defer e.unlock();
                e.push(peerEvent(c.MOONSEC_EVENT_REFUSED, &peer_id, "", if (busy) 1 else 0));
                return;
            }
            // It owns `conn` from here, also when it fails (the backend did not
            // open): the client's session then ends with the connection.
            startIrohSession(e, conn) catch {};
        },
        .invalid => {
            s.close();
            return error.Protocol;
        },
    }
}

/// A session over `conn` on its own threads. Owns `conn` from here (also on failure).
fn startIrohSession(e: *Endpoint, conn: iroh.Conn) !void {
    if (!options.iroh) unreachable;
    const ip = gpa.create(iroh_pipe.IrohPipe) catch |err| {
        conn.deinit(0);
        return err;
    };
    ip.* = .init(conn);
    e.lock();
    defer e.unlock();
    const s = (if (e.role == .host)
        newHostSession(e, ip.packetPipe(), ip.controlStream(false), .{ .iroh = ip }, null)
    else
        newClientSession(e, ip.packetPipe(), ip.controlStream(true), .{ .iroh = ip }, null)) catch |err| {
        ip.ctl.drop();
        conn.deinit(0);
        gpa.destroy(ip);
        return err;
    };
    e.sessions.append(gpa, s) catch |err| {
        s.deinit();
        return err;
    };
    s.runner = io().concurrent(runSession, .{s}) catch |err| {
        _ = e.sessions.pop();
        s.deinit();
        return err;
    };
    last_started = s;
}

/// The session `startIrohSession` made last (the client's connect returns it).
threadlocal var last_started: ?*Session = null;

export fn moonsec_host_pair_begin(h: ?*c.moonsec_host, config: ?*const c.moonsec_pair_config, info: ?*c.moonsec_pair_info) Status {
    const e = hostOf(h) orelse return invalid("not a host");
    if (!options.iroh) return noIroh();
    const cfg = readIn(c.moonsec_pair_config, config) orelse return invalid("config is NULL or struct_size is too small");
    const out = info orelse return invalid("info is NULL");
    if (out.struct_size < @sizeOf(c.moonsec_pair_info)) return invalid("info.struct_size is too small");
    if (cfg.method > c.MOONSEC_PAIR_PIN_ONLY) return invalid("unknown pairing method");
    e.lock();
    defer e.unlock();
    if (e.net.ep == null or e.net.accept == null) return fail(c.MOONSEC_ERR_STATE, "call moonsec_host_listen first", .{});
    var rnd: [32]u8 = undefined;
    io().random(&rnd);
    const pin = while (true) {
        if (pair.pin.fromRandom(rnd[16..32])) |p| break p;
        io().random(rnd[16..32]);
    };
    const seconds: u32 = if (cfg.seconds != 0) cfg.seconds else 120;
    const window: ex.Window = .{
        .secret = if (cfg.method == c.MOONSEC_PAIR_PIN_ONLY) null else rnd[0..16].*,
        .pin = if (cfg.method == c.MOONSEC_PAIR_QR_ONLY) null else pin,
        .deadline_us = wallNow() + @as(Micros, seconds) * std.time.us_per_s,
        .pairings_left = @intCast(@min(@max(cfg.pairings, 1), 255)),
    };
    var abuf: [4096]u8 = undefined;
    const addr = e.net.ep.?.ticket(&abuf) catch return irohErr("ticket");
    var r = std.mem.zeroes(c.moonsec_pair_info);
    r.seconds = seconds;
    var tb: [pair.ticket.max_text]u8 = undefined;
    const at = (pair.Ticket{ .host_id = e.identity.id, .addr = addr }).encode(&tb) catch return fail(c.MOONSEC_ERR_INTERNAL, "ticket too long", .{});
    if (at.len >= r.addr_ticket.len) return fail(c.MOONSEC_ERR_INTERNAL, "ticket too long", .{});
    fixedStr(&r.addr_ticket, at);
    if (window.secret) |sec| {
        const expires = pair_cmd.unixNow(io()) + seconds;
        const qt = (pair.Ticket{ .host_id = e.identity.id, .secret = sec, .expires_unix_s = expires, .addr = addr }).encode(&tb) catch return fail(c.MOONSEC_ERR_INTERNAL, "ticket too long", .{});
        if (qt.len >= r.qr_ticket.len) return fail(c.MOONSEC_ERR_INTERNAL, "ticket too long", .{});
        fixedStr(&r.qr_ticket, qt);
    }
    if (window.pin) |p| fixedStr(&r.pin, &p);
    e.net.window = window;
    e.net.paired_in_window = 0;
    _ = writeOut(c.moonsec_pair_info, out, r);
    return ok;
}

export fn moonsec_host_pair_end(h: ?*c.moonsec_host) Status {
    const e = hostOf(h) orelse return invalid("not a host");
    if (!options.iroh) return noIroh();
    e.lock();
    defer e.unlock();
    if (e.net.window == null) return ok;
    e.net.window = null;
    var ev = std.mem.zeroes(c.moonsec_event);
    ev.type = c.MOONSEC_EVENT_PAIR_CLOSED;
    ev.code = @intCast(e.net.paired_in_window);
    e.push(ev);
    return ok;
}

/// Decode a ticket: a moonsec ticket ("MOONSEC1:...") gives the host's ID and iroh address,
/// anything else is taken as a bare iroh address.
const Target = struct { host_id: ?pair.Id, addr: [:0]u8, secret: ?[pair.ticket.secret_len]u8, expired: bool };

fn decodeTicket(text: []const u8) !Target {
    const t = std.mem.trim(u8, text, " \r\n\t");
    if (std.mem.startsWith(u8, t, "MOONSEC")) {
        var scratch: [pair.ticket.max_binary]u8 = undefined;
        const tk = try pair.Ticket.decode(t, &scratch);
        return .{ .host_id = tk.host_id, .addr = try gpa.dupeZ(u8, tk.addr), .secret = tk.secret, .expired = tk.expired(pair_cmd.unixNow(io())) };
    }
    return .{ .host_id = null, .addr = try gpa.dupeZ(u8, t), .secret = null, .expired = false };
}

export fn moonsec_client_connect(h: ?*c.moonsec_client, ticket: ?[*:0]const u8, timeout_ms: u32, out: ?*?*c.moonsec_session) Status {
    const e = clientOf(h) orelse return invalid("not a client");
    if (out) |o| o.* = null;
    const text = span(ticket) orelse return invalid("ticket is NULL");
    if (!options.iroh) return noIroh();
    {
        e.lock();
        defer e.unlock();
        if (e.activeSession()) return fail(c.MOONSEC_ERR_STATE, "the client already has a session", .{});
        const st = bindIroh(e);
        if (st != ok) return st;
    }
    const tg = decodeTicket(text) catch return invalid("not a moonsec or iroh ticket");
    defer gpa.free(tg.addr);
    const conn = e.net.ep.?.connect(tg.addr, pair_cmd.alpn, if (timeout_ms != 0) timeout_ms else 30_000) catch |err| return switch (err) {
        error.Timeout => fail(c.MOONSEC_ERR_TIMEOUT, "connect: {s}", .{iroh.lastError()}),
        else => irohErr("connect"),
    };
    const rid = pair_cmd.remoteId(conn) catch {
        conn.deinit(0);
        return irohErr("remote id");
    };
    if (tg.host_id) |want| if (!std.mem.eql(u8, &want, &rid)) {
        conn.deinit(0);
        return fail(c.MOONSEC_ERR_REFUSED, "the host at that address is not the one in the ticket", .{});
    };
    {
        e.lock();
        const paired = e.allow.contains(&rid);
        e.unlock();
        if (e.flags & c.MOONSEC_CLIENT_REQUIRE_PAIRED != 0 and !paired) {
            conn.deinit(0);
            return fail(c.MOONSEC_ERR_REFUSED, "host {s} is not paired with this device", .{&pair.id.short(&rid)});
        }
    }
    // Admission (spec/pairing-v0.md): the host says whether this client may have a session.
    var s: pair_cmd.IrohStream = .{ .s = conn.openBi(5_000) catch {
        conn.deinit(0);
        return irohErr("open stream");
    } };
    const refused = pairing.requestAdmission(s.stream()) catch {
        s.close();
        conn.deinit(0);
        return irohErr("admission");
    };
    s.close();
    if (refused) |why| {
        conn.deinit(0);
        return fail(c.MOONSEC_ERR_REFUSED, "the host refused the session: {s}", .{pairing.reasonText(why)});
    }
    last_started = null;
    startIrohSession(e, conn) catch |err| return sessionError(switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.Backend,
    });
    if (out) |o| o.* = @ptrCast(last_started);
    return ok;
}

export fn moonsec_client_pair(h: ?*c.moonsec_client, ticket: ?[*:0]const u8, pin_text: ?[*:0]const u8) Status {
    const e = clientOf(h) orelse return invalid("not a client");
    const text = span(ticket) orelse return invalid("ticket is NULL");
    if (!options.iroh) return noIroh();
    const tg = decodeTicket(text) catch return invalid("not a moonsec pairing ticket");
    defer gpa.free(tg.addr);
    const host_id = tg.host_id orelse return invalid("not a moonsec pairing ticket");
    if (tg.expired) return fail(c.MOONSEC_ERR_REFUSED, "the ticket has expired; start pairing on the host again", .{});
    const cred: ex.Credential = if (tg.secret) |sec| .{ .ticket_secret = sec } else blk: {
        const p = pair.pin.parse(span(pin_text) orelse "") orelse return invalid("this ticket has no secret: give the host's PIN");
        break :blk .{ .pin = p };
    };
    {
        e.lock();
        defer e.unlock();
        const st = bindIroh(e);
        if (st != ok) return st;
    }
    const conn = e.net.ep.?.connect(tg.addr, pair_cmd.alpn, 30_000) catch |err| return switch (err) {
        error.Timeout => fail(c.MOONSEC_ERR_TIMEOUT, "connect: {s}", .{iroh.lastError()}),
        else => irohErr("connect"),
    };
    defer conn.deinit(0);
    const rid = pair_cmd.remoteId(conn) catch return irohErr("remote id");
    if (!std.mem.eql(u8, &rid, &host_id)) return fail(c.MOONSEC_ERR_REFUSED, "the host at that address is not the one in the ticket", .{});
    var s: pair_cmd.IrohStream = .{ .s = conn.openBi(10_000) catch return irohErr("open stream") };
    defer s.close();
    var nonce: ex.Nonce = undefined;
    io().random(&nonce);
    var cl = ex.Client.init(host_id, e.identity.id, nonce, cred, e.name);
    const result = pairing.runClient(s.stream(), &cl) catch return irohErr("pairing");
    switch (result) {
        .paired => |pd| {
            e.lock();
            defer e.unlock();
            e.allow.put(.{ .id = host_id, .paired_unix_s = pair_cmd.unixNow(io()), .name = pd.name(), .addr = tg.addr }) catch return fail(c.MOONSEC_ERR_NO_MEMORY, "out of memory", .{});
            e.saveAllow();
            return ok;
        },
        .failed => |why| return fail(c.MOONSEC_ERR_REFUSED, "pairing failed: {s}", .{pairing.reasonText(why)}),
    }
}

test {
    _ = std.testing.refAllDecls(@This());
}
