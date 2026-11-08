//! `moonsec`: the Phase 2 host and client apps with the synthetic backend, and the gate
//! tooling around them.
//!
//!   moonsec sim [--profile lan|wan|clean] [--seconds N] [--seed N] [options]
//!       Host and client in one process over the simulated network, in virtual time.
//!   moonsec soak [--seconds 3600] [--profile lan] [--seed N] [options]
//!       The one-hour soak: `sim` for an hour of simulated time, with progress lines.
//!       Fails on any freeze (no new picture for 200 ms), lost input or bad frame.
//!   moonsec run [sim|iroh|all] [--seconds N] [--seed N] [options]
//!       Two processes, host and client, over the sim hub and/or iroh on loopback,
//!       on the wall clock with the pipeline threads (as the Phase 1 gate runs).
//!   moonsec peer sim host|client --hub PORT [options]
//!   moonsec peer iroh host|client --ticket-file PATH [--relay] [options]
//!       One endpoint, as `run` starts it. With --relay the iroh endpoint uses n0's
//!       relays and binds on all interfaces, so the host and client can be on two machines.
//!   moonsec pattern --out FILE.ppm [--time-us N] [--frame N] [--size WxH]
//!       Write the measurement test pattern as a PPM.
//!
//! Options: --fps N, --bitrate BPS, --size WxH, --slices N; sim and soak also take
//! --outage-at-ms T --outage-ms D (drop everything host to client for D ms at T).
const std = @import("std");
const builtin = @import("builtin");
const options = @import("app_options");
const core = @import("core");
const api = @import("platform");
const synthetic = @import("synthetic");
const simnet = @import("simnet");
const simlink = @import("simlink");
const pipe_mod = @import("pipe");
const apps = @import("apps.zig");
const simrun = @import("simrun.zig");
const iroh = if (options.iroh) @import("iroh") else struct {};
const iroh_pipe = if (options.iroh) @import("iroh_pipe") else struct {};

const Io = std.Io;
const Micros = i64;
const alpn = "moonsec/0";

const Args = struct {
    cmd: []const u8 = "",
    pos: [2][]const u8 = .{ "", "" },
    npos: usize = 0,
    seed: u64 = 1,
    seconds: ?u32 = null,
    profile: simrun.Profile = .lan,
    fps: u32 = 60,
    bitrate: u64 = 10_000_000,
    width: u32 = 640,
    height: u32 = 360,
    sized: bool = false,
    slices: u8 = 4,
    hub_port: u16 = 0,
    ticket_file: []const u8 = "",
    relay: bool = false,
    loss_policy: bool = false,
    out: []const u8 = "",
    time_us: u64 = 0,
    frame: u32 = 0,
    outage_at_ms: i64 = 0,
    outage_ms: i64 = 0,
};

fn usage() error{Usage} {
    std.debug.print(
        \\usage: moonsec sim [--profile lan|wan|longhaul|clean] [--seconds N] [--seed N] [opts]
        \\       moonsec soak [--seconds 3600] [--profile lan] [--seed N] [opts]
        \\       moonsec run [sim|iroh|all] [--seconds N] [--seed N] [opts]
        \\       moonsec peer sim host|client --hub PORT [opts]
        \\       moonsec peer iroh host|client --ticket-file PATH [--relay] [opts]
        \\       moonsec pattern --out FILE.ppm [--time-us N] [--frame N] [--size WxH]
        \\opts:  --fps N --bitrate BPS --size WxH --slices N
        \\       --loss-policy (sim, soak: NACK/FEC/relay chosen per path)
        \\
    , .{});
    return error.Usage;
}

fn parseArgs(args: []const [:0]const u8) !Args {
    var a: Args = .{};
    if (args.len < 2) return usage();
    a.cmd = args[1];
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "--relay")) {
            a.relay = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--loss-policy")) {
            a.loss_policy = true;
            continue;
        }
        if (std.mem.startsWith(u8, s, "--")) {
            if (i + 1 >= args.len) return usage();
            i += 1;
            const v = args[i];
            const eq = std.mem.eql;
            if (eq(u8, s, "--seed")) a.seed = try std.fmt.parseInt(u64, v, 10) else if (eq(u8, s, "--seconds")) a.seconds = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--profile")) {
                a.profile = std.meta.stringToEnum(simrun.Profile, v) orelse return usage();
            } else if (eq(u8, s, "--fps")) a.fps = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--bitrate")) a.bitrate = try std.fmt.parseInt(u64, v, 10) else if (eq(u8, s, "--slices")) a.slices = try std.fmt.parseInt(u8, v, 10) else if (eq(u8, s, "--hub")) a.hub_port = try std.fmt.parseInt(u16, v, 10) else if (eq(u8, s, "--ticket-file")) a.ticket_file = v else if (eq(u8, s, "--out")) a.out = v else if (eq(u8, s, "--time-us")) a.time_us = try std.fmt.parseInt(u64, v, 10) else if (eq(u8, s, "--frame")) a.frame = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--outage-at-ms")) a.outage_at_ms = try std.fmt.parseInt(i64, v, 10) else if (eq(u8, s, "--outage-ms")) a.outage_ms = try std.fmt.parseInt(i64, v, 10) else if (eq(u8, s, "--size")) {
                const x = std.mem.indexOfScalar(u8, v, 'x') orelse return usage();
                a.width = try std.fmt.parseInt(u32, v[0..x], 10);
                a.height = try std.fmt.parseInt(u32, v[x + 1 ..], 10);
                a.sized = true;
            } else return usage();
            continue;
        }
        if (a.npos == a.pos.len) return usage();
        a.pos[a.npos] = s;
        a.npos += 1;
    }
    return a;
}

/// Windows sleeps in 15.6 ms ticks by default; ask for 1 ms (see tools/gate).
const winmm = if (builtin.os.tag == .windows) struct {
    extern "winmm" fn timeBeginPeriod(period: u32) callconv(.winapi) u32;
} else struct {};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) _ = winmm.timeBeginPeriod(1);
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const a = try parseArgs(argv);
    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    const eq = std.mem.eql;
    const ok: bool = if (eq(u8, a.cmd, "sim"))
        try cmdSim(gpa, a, w, a.seconds orelse 10, 0)
    else if (eq(u8, a.cmd, "soak"))
        try cmdSim(gpa, a, w, a.seconds orelse 3600, 300)
    else if (eq(u8, a.cmd, "run"))
        try cmdRun(gpa, io, a)
    else if (eq(u8, a.cmd, "peer"))
        try cmdPeer(gpa, io, a)
    else if (eq(u8, a.cmd, "pattern"))
        try cmdPattern(gpa, io, a)
    else
        return usage();
    try w.flush();
    std.process.exit(if (ok) 0 else 1);
}

fn simOptions(a: Args, seconds: u32, progress: u32) simrun.Options {
    return .{
        .seed = a.seed,
        .profile = a.profile,
        .seconds = seconds,
        .fps = a.fps,
        .bitrate_bps = a.bitrate,
        .width = if (a.sized) a.width else 320,
        .height = if (a.sized) a.height else 180,
        .slices = a.slices,
        .progress_every_s = progress,
        .outage_at_us = a.outage_at_ms * 1000,
        .outage_us = a.outage_ms * 1000,
        .loss_policy = a.loss_policy,
    };
}

fn cmdSim(gpa: std.mem.Allocator, a: Args, w: *Io.Writer, seconds: u32, progress: u32) !bool {
    const o = simOptions(a, seconds, progress);
    try w.print("== {d} s of {s} streaming over the {s} sim profile (seed {d}, {d}x{d}@{d}, {d} kbit/s) ==\n", .{ seconds, "synthetic", @tagName(o.profile), o.seed, o.width, o.height, o.fps, o.bitrate_bps / 1000 });
    try w.flush();
    const r = try simrun.run(gpa, o, w);
    try r.print(w);
    const why = r.failure(o);
    try w.print("{s}: {s}\n", .{ if (why == null) "PASS" else "FAIL", why orelse "no freezes, every frame and input checked" });
    return why == null;
}

fn cmdPattern(gpa: std.mem.Allocator, io: Io, a: Args) !bool {
    if (a.out.len == 0) return usage();
    const px = try gpa.alloc(u8, a.width * a.height * 4);
    defer gpa.free(px);
    api.pattern.render(px, a.width, a.height, a.width * 4, .{ .time_us = a.time_us, .frame = a.frame });
    var f = try Io.Dir.cwd().createFile(io, a.out, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = f.writer(io, &buf);
    try api.pattern.writePpm(&fw.interface, px, a.width, a.height, a.width * 4);
    try fw.interface.flush();
    return true;
}

// --- two processes ----------------------------------------------------------

fn spawn(io: Io, argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit });
}

fn exitedOk(t: std.process.Child.Term) bool {
    return switch (t) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// The argv tail every peer gets.
const PeerArgs = struct {
    buf: [6][24]u8 = undefined,
    list: [12][]const u8 = undefined,
    n: usize = 0,

    fn add(p: *PeerArgs, k: []const u8, comptime fmt: []const u8, v: anytype) void {
        p.list[p.n] = k;
        p.list[p.n + 1] = std.fmt.bufPrint(&p.buf[p.n / 2], fmt, .{v}) catch unreachable;
        p.n += 2;
    }

    /// Fill in place: `list` points into `buf`.
    fn fill(p: *PeerArgs, a: Args) void {
        p.add("--seed", "{d}", a.seed);
        p.add("--seconds", "{d}", a.seconds orelse 10);
        p.add("--fps", "{d}", a.fps);
        p.add("--bitrate", "{d}", a.bitrate);
        p.add("--slices", "{d}", a.slices);
        p.list[p.n] = "--size";
        p.list[p.n + 1] = std.fmt.bufPrint(&p.buf[5], "{d}x{d}", .{ a.width, a.height }) catch unreachable;
        p.n += 2;
    }
};

fn cmdRun(gpa: std.mem.Allocator, io: Io, a: Args) !bool {
    const which = if (a.npos > 0) a.pos[0] else "all";
    const want_sim = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "sim");
    const want_iroh = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "iroh");
    if (!want_sim and !want_iroh) return usage();
    const self_exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self_exe);
    var ok = true;
    if (want_sim) ok = (try runSim(gpa, io, self_exe, a)) and ok;
    if (want_iroh) {
        if (!options.iroh) {
            std.debug.print("moonsec: built without the iroh shim; use `zig build moonsec`\n", .{});
            return false;
        }
        ok = (try runIroh(io, self_exe, a)) and ok;
    }
    std.debug.print("\nPhase 2 session spine: {s}\n", .{if (ok) "PASS" else "FAIL"});
    return ok;
}

fn runSim(gpa: std.mem.Allocator, io: Io, self_exe: []const u8, a: Args) !bool {
    std.debug.print("== two processes over the simulated network ({s} profile, seed {d}) ==\n", .{ @tagName(a.profile), a.seed });
    const hub = try gpa.create(simlink.Hub);
    defer gpa.destroy(hub);
    var cfg: simnet.Config = .{ .seed = a.seed, .a_to_b = a.profile.link(), .b_to_a = a.profile.link() };
    const loss = cfg.a_to_b.loss;
    cfg.a_to_b.loss = 0;
    cfg.b_to_a.loss = 0;
    try hub.init(gpa, io, cfg);
    defer hub.deinit();
    hub.warmup_us = 300 * simnet.MS;
    hub.on_warm = if (loss > 0) switch (a.profile) {
        .lan => &warmLan,
        .wan => &warmWan,
        .clean => null,
    } else null;
    var stop: std.atomic.Value(bool) = .init(false);
    var hub_task = try io.concurrent(simlink.Hub.run, .{ hub, &stop });
    var hub_done = false;
    defer if (!hub_done) {
        stop.store(true, .release);
        hub_task.await(io) catch {};
    };
    var port_buf: [8]u8 = undefined;
    const port = try std.fmt.bufPrint(&port_buf, "{d}", .{hub.port()});
    var pa: PeerArgs = .{};
    pa.fill(a);
    var argv: [20][]const u8 = undefined;
    const base = [_][]const u8{ self_exe, "peer", "sim", "host", "--hub", port };
    @memcpy(argv[0..base.len], &base);
    @memcpy(argv[base.len..][0..pa.n], pa.list[0..pa.n]);
    var host = try spawn(io, argv[0 .. base.len + pa.n]);
    argv[3] = "client";
    var client = spawn(io, argv[0 .. base.len + pa.n]) catch |e| {
        host.kill(io);
        return e;
    };
    const client_ok = exitedOk(try client.wait(io));
    const host_ok = exitedOk(try host.wait(io));
    stop.store(true, .release);
    hub_done = true;
    try hub_task.await(io);
    const lost = hub.net.linkStats(.a).random_losses + hub.net.linkStats(.b).random_losses;
    std.debug.print("sim: random losses {d}\n", .{lost});
    const ok = host_ok and client_ok and (loss == 0 or lost > 0);
    std.debug.print("over sim: {s}\n\n", .{if (ok) "pass" else "FAIL"});
    return ok;
}

fn warmLan(net: *simnet.Net) void {
    for (&net.links) |*l| l.cfg.loss = simrun.Profile.lan.link().loss;
}
fn warmWan(net: *simnet.Net) void {
    for (&net.links) |*l| l.cfg.loss = simrun.Profile.wan.link().loss;
}

fn runIroh(io: Io, self_exe: []const u8, a: Args) !bool {
    std.debug.print("== two processes over iroh, loopback, relays off (seed {d}) ==\n", .{a.seed});
    var name_buf: [64]u8 = undefined;
    const ticket_file = try std.fmt.bufPrint(&name_buf, ".moonsec-ticket-{d}", .{Io.Clock.awake.now(io).toNanoseconds()});
    Io.Dir.cwd().deleteFile(io, ticket_file) catch {};
    defer Io.Dir.cwd().deleteFile(io, ticket_file) catch {};
    var pa: PeerArgs = .{};
    pa.fill(a);
    var argv: [20][]const u8 = undefined;
    const base = [_][]const u8{ self_exe, "peer", "iroh", "host", "--ticket-file", ticket_file };
    @memcpy(argv[0..base.len], &base);
    @memcpy(argv[base.len..][0..pa.n], pa.list[0..pa.n]);
    var host = try spawn(io, argv[0 .. base.len + pa.n]);
    argv[3] = "client";
    var client = spawn(io, argv[0 .. base.len + pa.n]) catch |e| {
        host.kill(io);
        return e;
    };
    const client_ok = exitedOk(try client.wait(io));
    const host_ok = exitedOk(try host.wait(io));
    const ok = host_ok and client_ok;
    std.debug.print("over iroh: {s}\n\n", .{if (ok) "pass" else "FAIL"});
    return ok;
}

// --- one peer on the wall clock -------------------------------------------------

var wall_io: Io = undefined;

fn wallNow() Micros {
    return Io.Clock.awake.now(wall_io).toMicroseconds();
}

fn wallSleep(_: ?*anyopaque, us: Micros) void {
    if (us > 0) wall_io.sleep(.fromMicroseconds(us), .awake) catch {};
}

fn patternContent(ctx: ?*anyopaque, _: *const api.DecodedFrame) u64 {
    const c: *synthetic.Client = @ptrCast(@alignCast(ctx.?));
    return if (c.presenter.last_stamp) |s| s.frame else 0;
}

const Role = enum { host, client };

fn cmdPeer(gpa: std.mem.Allocator, io: Io, a: Args) !bool {
    if (a.npos != 2) return usage();
    const role = std.meta.stringToEnum(Role, a.pos[1]) orelse return usage();
    wall_io = io;
    if (std.mem.eql(u8, a.pos[0], "sim")) {
        if (a.hub_port == 0) return usage();
        const link = try gpa.create(simlink.Link);
        defer gpa.destroy(link);
        try link.init(gpa, io, a.hub_port, if (role == .host) .a else .b);
        defer link.deinit();
        return peer(gpa, io, a, role, link.packetPipe());
    }
    if (std.mem.eql(u8, a.pos[0], "iroh")) {
        if (!options.iroh) return usage();
        return peerIroh(gpa, io, a, role);
    }
    return usage();
}

fn peer(gpa: std.mem.Allocator, io: Io, a: Args, role: Role, p: pipe_mod.PacketPipe) !bool {
    const clock = api.clockFn(wallNow);
    const seconds = a.seconds orelse 10;
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var ok = false;
    switch (role) {
        .host => {
            const sh = try synthetic.openHost(gpa, .{ .clock = clock, .sleeper = wallSleep, .width = a.width, .height = a.height });
            const hb = sh.backend();
            defer hb.deinit();
            var app = try apps.HostApp.init(gpa, hb, .{ .fps = a.fps, .bitrate_bps = a.bitrate, .slices = a.slices }, p);
            defer app.deinit();
            try app.runThreaded(io);
            try app.s.report(&w);
            try w.print("  injected keys {d} (out of order {d}), capture timeouts {d}, encode errors {d}\n", .{ sh.injector.keys, sh.injector.wrong, app.stats.capture_timeouts, app.stats.encode_errors });
            if (app.audio) |au| try w.print("  audio: {d} frames encoded, {d} datagrams, {d} errors; source skipped {d} frames\n", .{ au.stats.frames, au.stats.datagrams, au.stats.errors, sh.audio.stats.skipped });
            ok = app.s.end == .client_bye and sh.injector.wrong == 0 and sh.injector.keys > 0 and app.s.stats.frames > 0;
        },
        .client => {
            const sc = try synthetic.openClient(gpa, .{ .clock = clock, .input_interval_us = 25_000 });
            const cb = sc.backend();
            defer cb.deinit();
            var app = try apps.ClientApp.init(gpa, cb, .{ .content_ctx = sc, .contentFn = patternContent }, p);
            defer app.deinit();
            // Stop after `seconds` of streaming: the input source asks to quit.
            var timer = try io.concurrent(quitAfter, .{ &app, io, seconds });
            defer timer.cancel(io) catch {};
            try app.runThreaded(io);
            app.s.freeze.finish(app.s.freeze.last_new_us orelse 0);
            try app.s.report(&w);
            try w.print("  presenter: {d} presents, {d} unreadable patterns; decoder corrupt {d}\n", .{ sc.presenter.stats.presents, sc.presenter.stats.unreadable, sc.decoder.stats.corrupt });
            var audio_ok = true;
            if (app.audio) |au| {
                const bs = au.bufferStats();
                const ss = sc.audio.stats;
                try w.print("  audio: played {d} (FEC {d}, RS rebuilt {d}), concealed {d}, late {d}, silence {d}; sink underruns {d} ({d} frames), buffer delay {d:.1} ms\n", .{ bs.decoded + bs.fec, bs.fec, bs.rs_recovered, bs.concealed, bs.late, bs.silence, ss.underruns, ss.underrun_frames, @as(f64, @floatFromInt(bs.delay_us)) / 1000 });
                audio_ok = (bs.decoded + bs.fec) * 100 >= @as(u64, seconds) * 100 * 80 and ss.loud * 2 >= ss.written;
            }
            const want = @as(u64, seconds) * a.fps;
            // Wall-clock runs on shared CI machines get scheduling stalls the sim never
            // has; hold them to most frames and no corruption, and report freezes.
            ok = app.s.end == .closed and app.s.stats.frames_presented * 100 >= want * 80 and
                sc.presenter.stats.unreadable == 0 and sc.decoder.stats.corrupt == 0 and audio_ok;
        },
    }
    std.debug.print("{s}", .{w.buffered()});
    return ok;
}

fn quitAfter(app: *apps.ClientApp, io: Io, seconds: u32) Io.Cancelable!void {
    // Count from the first config, not from process start.
    while (app.s.config == null) try io.sleep(.fromMilliseconds(5), .awake);
    try io.sleep(.fromSeconds(seconds), .awake);
    app.quit = true;
}

fn peerIroh(gpa: std.mem.Allocator, io: Io, a: Args, role: Role) !bool {
    if (a.ticket_file.len == 0) return usage();
    iroh.init(null, null) catch |e| {
        std.debug.print("iroh init: {s}\n", .{iroh.lastError()});
        return e;
    };
    const ep = iroh.Endpoint.bind(.{
        .alpn = if (role == .host) alpn else "",
        .relay_mode = if (a.relay) .default else .disabled,
        .bind_addr = if (a.relay) "0.0.0.0:0" else "127.0.0.1:0",
    }) catch |e| {
        std.debug.print("bind: {s}\n", .{iroh.lastError()});
        return e;
    };
    defer ep.deinit();
    const conn = switch (role) {
        .host => blk: {
            var tbuf: [4096]u8 = undefined;
            const t = try ep.ticket(&tbuf);
            var tmp_buf: [256]u8 = undefined;
            const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{a.ticket_file});
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = t });
            try Io.Dir.rename(.cwd(), tmp, .cwd(), a.ticket_file, io);
            break :blk ep.accept(if (a.relay) 600_000 else 30_000) catch |e| {
                std.debug.print("accept: {s}\n", .{iroh.lastError()});
                return e;
            };
        },
        .client => blk: {
            var ticket: ?[]u8 = null;
            defer if (ticket) |t| gpa.free(t);
            for (0..1200) |_| {
                ticket = Io.Dir.cwd().readFileAlloc(io, a.ticket_file, gpa, .limited(8192)) catch null;
                if (ticket != null and ticket.?.len > 0) break;
                io.sleep(.fromMilliseconds(25), .awake) catch {};
            }
            const t = ticket orelse return error.NoTicket;
            const tz = try gpa.dupeZ(u8, std.mem.trim(u8, t, " \r\n"));
            defer gpa.free(tz);
            break :blk ep.connect(tz, alpn, 30_000) catch |e| {
                std.debug.print("connect: {s}\n", .{iroh.lastError()});
                return e;
            };
        },
    };
    defer conn.deinit(0);
    var ip = iroh_pipe.IrohPipe.init(conn);
    const ok = try peer(gpa, io, a, role, ip.packetPipe());
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    return ok;
}
