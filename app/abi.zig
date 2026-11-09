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
const multi_host = @import("multi_host.zig");
const clipsync = @import("clipsync.zig");
const HostSession = @import("host_session.zig").HostSession;
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
    if (options.iroh) f |= c.MOONSEC_FEATURE_IROH | c.MOONSEC_FEATURE_MULTI_USER;
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
        return e.activeSessions() > 0;
    }

    fn activeSessions(e: *const Endpoint) u32 {
        var n: u32 = 0;
        for (e.sessions.items) |s| if (!s.ended()) {
            n += 1;
        };
        return n;
    }

    /// A host that takes more than one client at once.
    fn multiUser(e: *const Endpoint) bool {
        return e.role == .host and e.hc.max_clients > 1;
    }

    /// The host can't take another client now.
    fn full(e: *const Endpoint) bool {
        const admitting = if (options.iroh) e.net.admitting else 0;
        return e.activeSessions() + admitting >= @max(e.hc.max_clients, 1);
    }
};

/// iroh state of an endpoint (empty without the shim).
const Net = if (options.iroh) struct {
    ep: ?iroh.Endpoint = null,
    accept: ?Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    window: ?ex.Window = null,
    /// Changes whenever a window opens or closes, so an exchange that started on one window
    /// never touches the next.
    window_gen: u64 = 0,
    paired_in_window: u32 = 0,
    /// A multi-user host's current stream (max_clients > 1).
    run: ?*MultiRun = null,
    /// Connections being paired or admitted, each on its own task.
    tasks: ?*pair_cmd.ConnTasks = null,
    /// Admitted connections whose session is being set up (they count toward `max_clients`).
    admitting: u32 = 0,
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
    if (cfg.max_clients > core.multi.max_members) return invalid("max_clients is more than 32");
    if (cfg.max_clients > 1 and !options.iroh) return fail(c.MOONSEC_ERR_UNSUPPORTED, "multi-user hosts need iroh (MOONSEC_FEATURE_MULTI_USER)", .{});
    if (cfg.codec != 0 and (cfg.codec > 255 or !api.CodecSet.has(.{ .h264 = true, .hevc = true, .av1 = true, .passthrough = true }, @enumFromInt(@as(u8, @intCast(cfg.codec))))))
        return invalid("unknown codec");
    if (cfg.flags & c.MOONSEC_HOST_REQUIRE_PAIRED != 0 and cfg.flags & c.MOONSEC_HOST_INSECURE_NO_PAIRING != 0)
        return invalid("MOONSEC_HOST_REQUIRE_PAIRED and MOONSEC_HOST_INSECURE_NO_PAIRING contradict each other");
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
    if (cfg.flags & c.MOONSEC_CLIENT_REQUIRE_PAIRED != 0 and cfg.flags & c.MOONSEC_CLIENT_INSECURE_NO_PAIRING != 0)
        return invalid("MOONSEC_CLIENT_REQUIRE_PAIRED and MOONSEC_CLIENT_INSECURE_NO_PAIRING contradict each other");
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
        if (e.net.tasks) |t| {
            t.wait();
            gpa.destroy(t);
            e.net.tasks = null;
        }
    }
    // Each session is closed (a bye to the peer) and its threads joined.
    while (true) {
        e.lock();
        const last: ?*Session = if (e.sessions.items.len > 0) e.sessions.items[e.sessions.items.len - 1] else null;
        e.unlock();
        const l = last orelse break;
        if (l.run != null) releaseMember(l) else releaseSession(l);
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

export fn moonsec_host_give_input(h: ?*c.moonsec_host, p: ?*c.moonsec_session) Status {
    const e = hostOf(h) orelse return invalid("not a host");
    if (!options.iroh) return fail(c.MOONSEC_ERR_UNSUPPORTED, "multi-user sessions need iroh (MOONSEC_FEATURE_MULTI_USER)", .{});
    e.lock();
    defer e.unlock();
    const r = e.net.run orelse return fail(c.MOONSEC_ERR_STATE, "no multi-user session is streaming (max_clients > 1)", .{});
    var to: u16 = core.multi.host_id;
    if (p != null) {
        const s = sessionOf(p) orelse return invalid("not a session");
        if (s.run != r or s.released) return invalid("not a member of this host's current session");
        to = s.app.member.id;
    }
    return switch (r.app.m.hostGive(to)) {
        .ok => ok,
        .wrong_policy => fail(c.MOONSEC_ERR_STATE, "the input policy has no owner", .{}),
        else => fail(c.MOONSEC_ERR_STATE, "that member may not take input, or has left", .{}),
    };
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
    /// A single client's session, or (null) the member of `run` whose action it is.
    s: ?*Session = null,
    run: ?*MultiRun = null,
    clock: api.Clock,
    ep: *Endpoint,

    pub fn inject(self: *AppInjector, a: core.input.Action) api.Error!void {
        // A member's input names the member's session; releases after a handoff come
        // from the host's user (no session).
        const target: ?*Session = self.s orelse if (self.run) |r| r.memberById(r.app.injecting_from) else null;
        var in = std.mem.zeroes(c.moonsec_input);
        const now = self.clock.now();
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
        ev.session = @ptrCast(target);
        ev.time_us = now;
        ev.input = in;
        self.ep.push(ev);
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
    iroh: if (options.iroh) *NetLink else void,
};

/// An iroh session's connection: an `IrohLink` that outlives a dropped connection. The
/// client redials (admission again on each new connection, the link's gate); the host's
/// accept loop admits the client's new connection and hands it to the session's link
/// (`offered`), found by the client's endpoint id.
const NetLink = if (options.iroh) struct {
    link: iroh_pipe.IrohLink = undefined,
    ep: *Endpoint,
    /// The far end's endpoint id: the client on a host, the host on a client.
    peer: pair.Id,
    /// client: the address it dials again.
    addr: ?[:0]u8 = null,

    /// Starts on `conn` (admitted already); owns it from here, also on failure.
    fn create(e: *Endpoint, conn: iroh.Conn, peer: pair.Id, addr: ?[]const u8) !*NetLink {
        const n = gpa.create(NetLink) catch |err| {
            conn.deinit(0);
            return err;
        };
        n.* = .{ .ep = e, .peer = peer };
        if (addr) |a| n.addr = gpa.dupeZ(u8, a) catch |err| {
            gpa.destroy(n);
            conn.deinit(0);
            return err;
        };
        const dial = e.role == .client;
        n.link.startWith(io(), e.net.ep.?, .{
            .role = if (dial) .dial else .offered,
            .ticket = n.addr orelse "",
            .alpn = pair_cmd.alpn,
            .gate = if (dial) .{ .ctx = n, .check = clientGate } else null,
            .refuse_code = pair_cmd.close_not_paired,
        }, conn) catch |err| {
            if (n.addr) |a| gpa.free(a);
            gpa.destroy(n);
            return err;
        };
        return n;
    }

    fn destroy(n: *NetLink) void {
        n.link.deinit();
        if (n.addr) |a| gpa.free(a);
        gpa.destroy(n);
    }

    /// client: each new connection goes to the same host and through admission, as
    /// `moonsec_client_connect`'s first one did.
    fn clientGate(ctx: *anyopaque, conn: iroh.Conn) iroh_pipe.IrohLink.Verdict {
        const n: *NetLink = @ptrCast(@alignCast(ctx));
        const rid = pair_cmd.remoteId(conn) catch return .retry;
        if (!std.mem.eql(u8, &rid, &n.peer)) return .refuse;
        var s: pair_cmd.IrohStream = .{ .s = conn.openBi(5_000) catch return .retry };
        defer s.close();
        const refused = pairing.requestAdmission(s.stream()) catch return .retry;
        return if (refused == null) .admit else .refuse;
    }
} else struct {};

const Session = struct {
    magic: u32 = magic,
    ep: *Endpoint,
    /// A host's one client (`HostApp`), a client, or one member of a multi-user host
    /// (its peer in `run`, which owns it).
    app: union(enum) { host: apps.HostApp, client: apps.ClientApp, member: *multi_host.Peer },
    run: ?*MultiRun = null,
    /// The app let go of a member's handle; it is freed with its run.
    released: bool = false,
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
    /// A member's clipboard sync (a single session's is inside its app).
    clip_sync: ?clipsync.Sync = null,
    runner: ?Io.Future(void) = null,
    /// A multi-user client's view of the host's roster.
    view: core.multi.View = .{},

    // What `check` last reported.
    started: bool = false,
    ended_sent: bool = false,
    last_format: c.moonsec_video_format = std.mem.zeroes(c.moonsec_video_format),
    last_size: [2]u32 = .{ 0, 0 },
    relayed: bool = false,
    /// Who held input when last reported (a member id; `core.multi.host_id`: the host's user).
    last_owner: ?u16 = null,

    /// The host side's session: a single client's or a member's.
    fn hostSession(s: *const Session) ?*HostSession {
        return switch (s.app) {
            .host => |*a| @constCast(&a.s),
            .member => |p| &p.s,
            .client => null,
        };
    }

    fn ended(s: *const Session) bool {
        return switch (s.app) {
            .host => |*a| a.done(),
            .client => |*a| a.done(),
            .member => |p| p.left or p.s.ended(),
        };
    }

    fn close(s: *Session) void {
        const now = s.clock.now();
        switch (s.app) {
            .client => |*a| a.s.close(now),
            else => s.hostSession().?.close(now),
        }
    }

    /// Close and send the first bye now, for a session about to be freed.
    fn closeNow(s: *Session) void {
        s.close();
        const now = s.clock.now();
        switch (s.app) {
            .client => |*a| a.s.step(now),
            else => s.hostSession().?.step(now),
        }
    }

    fn state(s: *const Session) i32 {
        return switch (s.app) {
            .client => |*a| switch (a.s.state) {
                .connecting => c.MOONSEC_STATE_CONNECTING,
                .streaming => c.MOONSEC_STATE_STREAMING,
                .ended => c.MOONSEC_STATE_ENDED,
            },
            else => switch (s.hostSession().?.state) {
                .waiting => c.MOONSEC_STATE_CONNECTING,
                .streaming => c.MOONSEC_STATE_STREAMING,
                .ended => c.MOONSEC_STATE_ENDED,
            },
        };
    }

    fn endReason(s: *const Session) i32 {
        return switch (s.app) {
            .client => |*a| switch (a.s.end) {
                .none => c.MOONSEC_END_NONE,
                .closed => c.MOONSEC_END_CLOSED,
                .host_bye => c.MOONSEC_END_PEER_CLOSED,
                .peer_timeout, .connect_timeout => c.MOONSEC_END_TIMEOUT,
                .pipe_closed => c.MOONSEC_END_TRANSPORT,
                .failed => c.MOONSEC_END_FAILED,
            },
            else => switch (s.hostSession().?.end) {
                .none => c.MOONSEC_END_NONE,
                .closed => c.MOONSEC_END_CLOSED,
                .client_bye => c.MOONSEC_END_PEER_CLOSED,
                .peer_timeout => c.MOONSEC_END_TIMEOUT,
                .pipe_closed => c.MOONSEC_END_TRANSPORT,
                .failed => c.MOONSEC_END_FAILED,
            },
        };
    }

    /// The stream's format and size (zeros before there is one).
    fn format(s: *const Session) struct { f: c.moonsec_video_format, w: u32, h: u32, fps: u32, bitrate: u64 } {
        switch (s.app) {
            .host => |*a| return .{ .f = vf(a.s.codec, a.s.format), .w = a.size.width, .h = a.size.height, .fps = a.opts.fps, .bitrate = a.s.bitrate_bps },
            .member => |p| {
                const r = &s.run.?.app;
                return .{ .f = vf(p.s.codec, p.s.format), .w = r.size.width, .h = r.size.height, .fps = r.opts.fps, .bitrate = p.s.bitrate_bps };
            },
            .client => |*a| {
                const cf = a.s.config orelse return .{ .f = std.mem.zeroes(c.moonsec_video_format), .w = 0, .h = 0, .fps = 0, .bitrate = 0 };
                return .{ .f = vf(cf.codec, cf.format), .w = cf.width, .h = cf.height, .fps = cf.fps, .bitrate = cf.bitrate_bps };
            },
        }
    }

    fn pathStats(s: *const Session) pipe_mod.PathStats {
        return switch (s.app) {
            .client => |*a| a.s.path,
            else => s.hostSession().?.path,
        };
    }

    fn tick(s: *Session) void {
        switch (s.app) {
            .host => |*a| a.tick(),
            .client => |*a| a.tick(),
            .member => unreachable, // members run on their run's threads
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
            // The run freed the peer (`MultiRun.deinit`).
            .member => {},
        }
        if (options.iroh) switch (s.transport) {
            .iroh => |n| n.destroy(),
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
    if (s.app == .client) {
        // A multi-user host's roster: who holds input.
        const ctl = &s.app.client.s.control;
        while (ctl.takeMessage()) |m| {
            defer ctl.gpa.free(m.body);
            if (m.type == core.multi.msg.roster) s.view.onRoster(m.body);
        }
        if (s.view.have and (s.last_owner == null or s.last_owner.? != s.view.owner)) {
            s.last_owner = s.view.owner;
            var oe = ev;
            oe.type = c.MOONSEC_EVENT_INPUT_OWNER;
            // This client's session when it holds input, else NULL.
            oe.session = if (s.view.owner == s.view.you) @ptrCast(s) else null;
            oe.code = s.view.owner;
            e.push(oe);
        }
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
        s.injector = .{ .s = s, .clock = s.clock, .ep = e };
        be.input = api.bind(api.InputInjector, AppInjector, &s.injector);
    }
    const codec = pickCodec(be.encoder.caps(), cfg.codec) orelse return error.Unsupported;
    const clip = try sessionClipboard(s);
    s.app = .{ .host = apps.HostApp.init(gpa, be, hostOptions(cfg, codec, ctl, clip), p) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.Backend,
    } };
    return s;
}

/// The host config as the apps' options.
fn hostOptions(cfg: c.moonsec_host_config, codec: api.Codec, ctl: ?pipe_mod.ByteStream, clip: ?clipboard.Clipboard) apps.HostOptions {
    return .{
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
    };
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
    s.app = .{
        .client = apps.ClientApp.init(gpa, be, .{
            .windowed = cfg.flags & c.MOONSEC_CLIENT_FULLSCREEN == 0,
            .audio = cfg.flags & c.MOONSEC_CLIENT_NO_AUDIO == 0,
            .session = .{
                .max_width = cfg.max_width,
                .max_height = cfg.max_height,
                .nonce = std.mem.readInt(u32, &nonce, .little) | 1,
                // Rosters from a multi-user host (spec/multi-user-v0.md).
                .control = .{ .features = core.multi.feature_bit, .known = &core.multi.known },
            },
            .control_stream = ctl,
            .clipboard = clip,
            .clipboard_poll_us = 50_000,
        }, p) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Backend,
        },
    };
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
        .member => unreachable, // on its run's threads (runMulti)
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

/// Not part of the ABI (not in moonsec.h): tests drop a session's iroh connection as a
/// network failure would, to exercise reconnecting.
export fn moonsec__test_drop_connection(p: ?*c.moonsec_session) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    if (!options.iroh) return noIroh();
    s.ep.lock();
    defer s.ep.unlock();
    switch (s.transport) {
        .iroh => |n| n.link.dropForTest(),
        else => return fail(c.MOONSEC_ERR_UNSUPPORTED, "not an iroh session", .{}),
    }
    return ok;
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
    if (sessionOf(p)) |s| if (s.run != null) releaseMember(s) else releaseSession(s);
}

export fn moonsec_session_send_input(p: ?*c.moonsec_session, in: ?*const c.moonsec_input) Status {
    const s = sessionOf(p) orelse return invalid("not a session");
    const i = in orelse return invalid("input is NULL");
    s.ep.lock();
    defer s.ep.unlock();
    const a = switch (s.app) {
        .client => |*a| a,
        .host, .member => return fail(c.MOONSEC_ERR_STATE, "input is sent from the client's session", .{}),
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
    const s = sessionOf(p) orelse return invalid("not a session");
    s.ep.lock();
    defer s.ep.unlock();
    const a = switch (s.app) {
        .client => |*a| a,
        else => return fail(c.MOONSEC_ERR_STATE, "input is requested from the client's session", .{}),
    };
    if (!s.view.have) return fail(c.MOONSEC_ERR_STATE, "the host is not a multi-user host, or its roster has not come yet", .{});
    a.s.control.send(.{ .type = core.multi.msg.input_request, .body = &core.multi.msg.encodeRequest(true) }, core.multi.feature_bit) catch
        return fail(c.MOONSEC_ERR_STATE, "the control channel is not up", .{});
    return ok;
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
        .host, .member => {
            const hs = s.hostSession().?;
            const st = hs.stats;
            t.rtt_us = path.rtt_us;
            t.frames = st.frames;
            t.keyframes = st.keyframes;
            t.refreshes = st.refreshes;
            t.retransmits = st.retransmits;
            t.parity_shards = st.parity_shards;
            t.input_events = st.inputs_applied;
            t.path_changes = st.path_changes;
            t.reconnects = st.reconnects;
            if (hs.offset != null) t.flags |= c.MOONSEC_TELEMETRY_CLOCK_SYNCED;
            snap = hs.tele.snapshot();
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
/// admission, each connection on its own task with a total budget (`pair_cmd.ConnTasks`),
/// so one peer that connects and stalls holds up no one else. One session at a time.
fn acceptLoop(e: *Endpoint) void {
    if (!options.iroh) return;
    const tasks = gpa.create(pair_cmd.ConnTasks) catch return;
    tasks.* = .{ .io = io() };
    e.net.tasks = tasks;
    while (!e.net.stopping.load(.acquire)) {
        closeWindowIfDone(e);
        const conn = e.net.ep.?.accept(200) catch |err| switch (err) {
            error.Closed => return,
            else => continue,
        };
        if (!tasks.spawn(connTask, .{ e, conn })) conn.deinit(pair_cmd.close_busy);
    }
}

fn connTask(e: *Endpoint, conn: iroh.Conn) void {
    defer e.net.tasks.?.done();
    handleConn(e, conn) catch {
        conn.deinit(0);
    };
}

fn closeWindowIfDone(e: *Endpoint) void {
    if (!options.iroh) return;
    e.lock();
    defer e.unlock();
    if (e.net.window) |*w| {
        const now = wallNow();
        if (w.isOpen(now)) return;
        // Full only because a pairing awaits its confirm: keep it until that settles.
        if (w.pending > 0 and now < w.deadline_us and w.attempts_left > 0) return;
        var ev = std.mem.zeroes(c.moonsec_event);
        ev.type = c.MOONSEC_EVENT_PAIR_CLOSED;
        ev.code = @intCast(e.net.paired_in_window);
        e.push(ev);
        e.net.window = null;
        e.net.window_gen +%= 1;
    }
}

/// `pairing.Guard` over the endpoint's lock and the window an exchange started on.
const WindowGuard = struct {
    e: *Endpoint,
    gen: u64,

    fn guard(g: *WindowGuard) pairing.Guard {
        return .{ .ctx = g, .enter = enter, .leave = leave };
    }
    fn enter(ctx: *anyopaque) bool {
        const g: *WindowGuard = @ptrCast(@alignCast(ctx));
        g.e.lock();
        return g.e.net.window != null and g.e.net.window_gen == g.gen;
    }
    fn leave(ctx: *anyopaque) void {
        const g: *WindowGuard = @ptrCast(@alignCast(ctx));
        g.e.unlock();
    }
};

fn handleConn(e: *Endpoint, conn: iroh.Conn) !void {
    const peer_id = try pair_cmd.remoteId(conn);
    const budget = pair_cmd.IrohStream.pair_budget_ms;
    var s: pair_cmd.IrohStream = .withBudget(try conn.acceptBi(budget), budget);
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
            var nonce: ex.Nonce = undefined;
            io().random(&nonce);
            var seed: ex.Seed = undefined;
            io().random(&seed);
            // No window open: a closed one, so the client hears "not pairing right now".
            var closed: ex.Window = .{ .deadline_us = 0 };
            e.lock();
            var wg: WindowGuard = .{ .e = e, .gen = e.net.window_gen };
            const window: *ex.Window = if (e.net.window) |*w| w else &closed;
            const shared = e.net.window != null;
            e.unlock();
            var hs = ex.Host.init(window, e.identity.id, peer_id, nonce, seed, e.name);
            const out = pairing.serveHost(s.stream(), &f, &hs, first, &wallNow, if (shared) wg.guard() else null) catch return;
            e.lock();
            defer e.unlock();
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
            const need = e.flags & c.MOONSEC_HOST_INSECURE_NO_PAIRING == 0;
            // A client of a live session coming back on a new connection (it dropped):
            // it keeps its session, so it does not count against max_clients.
            const back = liveLink(e, &peer_id) != null;
            const busy = !back and e.full();
            const name = if (e.allow.get(&peer_id)) |d| d.name else "";
            var name_buf: [64]u8 = undefined;
            const nm = name_buf[0..@min(name.len, name_buf.len)];
            @memcpy(nm, name[0..nm.len]);
            const allowed = (paired or !need) and !busy;
            if (allowed and !back) e.net.admitting += 1;
            e.unlock();
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
            if (back) {
                e.lock();
                defer e.unlock();
                // Its session may have ended meanwhile: then the connection goes unused.
                if (liveLink(e, &peer_id)) |n| n.link.offer(conn) else conn.deinit(0);
                return;
            }
            defer {
                e.lock();
                e.net.admitting -= 1;
                e.unlock();
            }
            // It owns `conn` from here, also when it fails (the backend did not
            // open): the client's session then ends with the connection.
            startIrohSession(e, conn, if (nm.len > 0) nm else "client", peer_id, null) catch {};
        },
        .invalid => {
            s.close();
            return error.Protocol;
        },
    }
}

/// A session over `conn` on its own threads. Owns `conn` from here (also on failure).
/// The link of a session with `peer` that has not ended, if any. Under the endpoint lock.
fn liveLink(e: *Endpoint, peer: *const pair.Id) ?*NetLink {
    for (e.sessions.items) |x| switch (x.transport) {
        .iroh => |n| if (std.mem.eql(u8, &n.peer, peer) and !x.ended()) return n,
        else => {},
    };
    return null;
}

/// `peer` is the far end's endpoint id; `addr` (client) is where it dials again after a drop.
fn startIrohSession(e: *Endpoint, conn: iroh.Conn, peer_name: []const u8, peer: pair.Id, addr: ?[]const u8) !void {
    if (!options.iroh) unreachable;
    const n = try NetLink.create(e, conn, peer, addr);
    e.lock();
    defer e.unlock();
    if (e.role == .host and e.multiUser()) {
        last_started = joinMulti(e, n, peer_name) catch |err| {
            n.destroy();
            return err;
        };
        return;
    }
    const s = (if (e.role == .host)
        newHostSession(e, n.link.packetPipe(), n.link.controlStream(), .{ .iroh = n }, null)
    else
        newClientSession(e, n.link.packetPipe(), n.link.controlStream(), .{ .iroh = n }, null)) catch |err| {
        n.destroy();
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

// ---------------------------------------------------------------------------
// Multi-user hosts (max_clients > 1): one capture and encode for every member
// (app/multi_host.zig, spec/multi-user-v0.md)

/// A multi-user stream: the backend, the `MultiHostApp` and its threads, and the member
/// sessions. Starts with its first member; when every member has left the threads stop,
/// and the next client starts a new one. Freed once the app released every member.
const MultiRun = struct {
    ep: *Endpoint,
    app: multi_host.MultiHostApp,
    injector: AppInjector = undefined,
    members: std.ArrayList(*Session) = .empty,
    runner: ?Io.Future(void) = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// The threads returned (every member left, or `stop`).
    finished: bool = false,
    /// Who held input when last reported.
    last_owner: ?u16 = null,

    fn memberById(r: *MultiRun, id: u16) ?*Session {
        for (r.members.items) |s| if (s.app.member.id == id and !s.released) return s;
        return null;
    }

    fn deinit(r: *MultiRun) void {
        const be = r.app.be;
        r.app.deinit();
        be.deinit();
        for (r.members.items) |s| s.deinit();
        r.members.deinit(gpa);
        gpa.destroy(r);
    }
};

/// Admit a client into the endpoint's current run, starting one if there is none (lock held).
fn joinMulti(e: *Endpoint, n: *NetLink, name: []const u8) !*Session {
    if (!options.iroh) unreachable;
    var fresh = false;
    const run = if (e.net.run) |r| r else blk: {
        const r = try newRun(e);
        fresh = true;
        break :blk r;
    };
    errdefer if (fresh) run.deinit();
    // Room first, so nothing fails once the peer is in.
    try run.members.ensureUnusedCapacity(gpa, 1);
    try e.sessions.ensureUnusedCapacity(gpa, 1);
    const s = try gpa.create(Session);
    errdefer gpa.destroy(s);
    s.* = .{ .ep = e, .app = undefined, .run = run, .transport = .{ .iroh = n }, .clock = run.app.be.clock, .clip = .init(gpa) };
    errdefer s.clip.deinit();
    if (try sessionClipboard(s)) |cb| s.clip_sync = .{ .cb = cb, .interval_us = 50_000 };
    errdefer if (s.sys_clip) |*y| y.close();
    // v0: every member may control (a per-device permission is a follow-up).
    const peer = run.app.m.addPeer(n.link.packetPipe(), n.link.controlStream(), name, true) catch |err| return switch (err) {
        error.Full => error.Busy,
        else => err,
    };
    s.app = .{ .member = peer };
    run.members.appendAssumeCapacity(s);
    e.sessions.appendAssumeCapacity(s);
    if (fresh) {
        run.runner = io().concurrent(runMulti, .{run}) catch |err| {
            _ = e.sessions.pop();
            _ = run.members.pop();
            return err;
        };
        e.net.run = run;
    }
    return s;
}

fn newRun(e: *Endpoint) !*MultiRun {
    const cfg = e.hc;
    var be: api.HostBackend = undefined;
    if (cfg.backend == c.MOONSEC_BACKEND_SYSTEM) {
        be = try system.openHost(gpa, .{ .audio = cfg.flags & c.MOONSEC_HOST_NO_AUDIO == 0, .state_dir = e.state_path });
    } else {
        const sh = synthetic.openHost(gpa, .{
            .clock = api.clockFn(wallNow),
            .sleeper = wallSleep,
            .width = if (cfg.width != 0) cfg.width else 640,
            .height = if (cfg.height != 0) cfg.height else 360,
            .audio = cfg.flags & c.MOONSEC_HOST_NO_AUDIO == 0,
        }) catch return error.OutOfMemory;
        be = sh.backend();
    }
    errdefer be.deinit();
    const r = try gpa.create(MultiRun);
    errdefer gpa.destroy(r);
    r.* = .{ .ep = e, .app = undefined };
    if (cfg.flags & c.MOONSEC_HOST_APP_INPUT != 0) {
        r.injector = .{ .run = r, .clock = be.clock, .ep = e };
        be.input = api.bind(api.InputInjector, AppInjector, &r.injector);
    }
    const codec = pickCodec(be.encoder.caps(), cfg.codec) orelse return error.Unsupported;
    r.app = multi_host.MultiHostApp.init(gpa, be, hostOptions(cfg, codec, null, null), .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.Backend,
    };
    return r;
}

/// A run's threads: network here, capture+encode on their own, until every member left.
fn runMulti(r: *MultiRun) void {
    const e = r.ep;
    const lock: apps.Lock = .{ .mu = &e.mu, .io = io() };
    r.app.runThreadedWith(io(), lock, .{ .ctx = r, .f = multiHook }, &r.stop) catch {};
    e.lock();
    defer e.unlock();
    multiHook(r);
    r.finished = true;
    if (options.iroh) if (e.net.run == r) {
        e.net.run = null;
    };
}

/// After every network step (lock held): members' clipboards, events, the input owner.
fn multiHook(p: *anyopaque) void {
    const r: *MultiRun = @ptrCast(@alignCast(p));
    const now = r.app.be.clock.now();
    for (r.members.items) |s| {
        const peer = s.app.member;
        if (s.clip_sync) |*y| if (!peer.left) y.pump(gpa, &peer.s.control, now);
        if (!s.released) check(s);
    }
    const owner = r.app.m.roster.owner;
    if (r.last_owner == null or r.last_owner.? != owner) {
        r.last_owner = owner;
        var ev = std.mem.zeroes(c.moonsec_event);
        ev.type = c.MOONSEC_EVENT_INPUT_OWNER;
        ev.session = @ptrCast(r.memberById(owner));
        ev.code = owner;
        ev.time_us = now;
        // Only changes after the first member's arrival are news.
        if (r.members.items.len > 0 and r.app.m.stats.joins > 0) r.ep.push(ev);
    }
}

fn releaseMember(s: *Session) void {
    const e = s.ep;
    const r = s.run.?;
    e.lock();
    if (!s.ended()) s.closeNow();
    s.released = true;
    removeSession(e, s);
    var all = true;
    for (r.members.items) |m| if (!m.released) {
        all = false;
    };
    e.unlock();
    if (!all) return;
    // The last handle: stop the threads (if they still run) and free the run.
    r.stop.store(true, .release);
    if (r.runner) |*f| f.await(io());
    e.lock();
    if (options.iroh) if (e.net.run == r) {
        e.net.run = null;
    };
    e.unlock();
    r.deinit();
}

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
    e.net.window_gen +%= 1;
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
    e.net.window_gen +%= 1;
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
        if (e.flags & c.MOONSEC_CLIENT_INSECURE_NO_PAIRING == 0 and !paired) {
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
    startIrohSession(e, conn, "", rid, tg.addr) catch |err| return sessionError(switch (err) {
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
    var seed: ex.Seed = undefined;
    io().random(&seed);
    var cl = ex.Client.init(host_id, e.identity.id, nonce, seed, cred, e.name);
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
