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
//!   moonsec id | pair host|client | paired | unpair | run pair
//!       Device identity and pairing; see app/pair_cmd.zig. `peer iroh` uses the device key
//!       (--state-dir, else the default state directory): the host admits only paired
//!       clients and the client connects only to paired hosts, on every connection including
//!       reconnects. `--insecure-no-pairing` turns that off; `run iroh` passes it.
//!
//! Options: --fps N, --bitrate BPS, --size WxH, --slices N. `peer sim host` also takes
//! --fixture FILE.h264|FILE.h265: replay that Annex B stream instead of the synthetic codec
//! (platform/synthetic/fixture.zig), for clients with real decoders such as the web client
//! (web/README.md); --size should match the stream. Sim and soak also take
//! --outage-at-ms T --outage-ms D (drop everything host to client for D ms at T), and a
//! scripted path (app/pathsim.zig): --flaps T:D,T:D,... (direct-path outages at T ms for
//! D ms), --drops T:D,... (connection drops), --idle-ms N (path idle timeout, default 300),
//! --repunch-ms N (direct again N ms after an outage, default 500), --relay-delay-ms N,
//! --no-stall-pause (keep sending video while the path is stalled). sim, soak, run and the
//! peers take --displays WxH,WxH,... (the synthetic host's displays) and --switch
//! T:ID,T:ID,... (the client selects display ID T ms into the stream; it reconfigures
//! mid-session).
//! The iroh peers take --path-idle-ms N, --conn-idle-ms N, --bind IP:PORT, --relay-url URL
//! [--relay-ca PEM] and --min-presented PCT (client pass bar, default 80), and redial
//! (client) or accept again (host) when the connection drops.
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
const control_mod = @import("control.zig");
const simrun = @import("simrun.zig");
const iroh = if (options.iroh) @import("iroh") else struct {};
const iroh_pipe = if (options.iroh) @import("iroh_pipe") else struct {};
const pair_cmd = @import("pair_cmd.zig");
const clipboard = @import("clipboard");
/// The Linux client backend (platform/client/linux), in `moonsec-linux` builds.
const client_linux = if (options.linux_client) @import("client_linux") else struct {};
const UinputDevice = if (options.linux_client) client_linux.uinput.Device else void;
/// The Linux host backend (platform/host/linux), in `moonsec-linux` builds.
const host_linux = if (options.linux_host) @import("host_linux") else struct {};
const linux_uinput = if (options.linux_host) host_linux.uinput else struct {};

const Io = std.Io;
const Micros = i64;
const alpn = pair_cmd.alpn;

const ClientKind = enum { synthetic, linux };
const HostKind = enum { synthetic, linux };

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
    fixture: []const u8 = "",
    ticket_file: []const u8 = "",
    relay: bool = false,
    rate_control: bool = false,
    loss_policy: bool = false,
    out: []const u8 = "",
    time_us: u64 = 0,
    frame: u32 = 0,
    outage_at_ms: i64 = 0,
    outage_ms: i64 = 0,
    flaps: [16]simrun.pathsim.Outage = undefined,
    n_flaps: usize = 0,
    drops: [16]simrun.pathsim.Outage = undefined,
    n_drops: usize = 0,
    idle_ms: ?i64 = null,
    repunch_ms: ?i64 = null,
    relay_delay_ms: ?i64 = null,
    no_stall_pause: bool = false,
    /// peer iroh: sync the system clipboard instead of the scripted in-memory one.
    system_clipboard: bool = false,
    path_idle_ms: u32 = 0,
    relay_url: ?[:0]const u8 = null,
    relay_ca: ?[:0]const u8 = null,
    bind: ?[:0]const u8 = null,
    conn_idle_ms: u32 = 0,
    /// Client: share of `seconds × fps` that must be presented for a pass.
    min_presented_pct: u64 = 80,
    displays: [8]api.Size = undefined,
    n_displays: usize = 0,
    switches: [16]simrun.DisplayEvent = undefined,
    n_switches: usize = 0,
    /// The raw --displays and --switch values, passed on to `run`'s peers.
    displays_arg: ?[]const u8 = null,
    switch_arg: ?[]const u8 = null,
    /// Client backend: the synthetic one, or the OS backend (`--client linux`).
    client: ClientKind = .synthetic,
    /// Linux client: type the synthetic host's key script on a uinput keyboard, so the
    /// host's injector check runs through evdev (needs /dev/uinput).
    uinput_script: bool = false,
    /// Linux client: no PipeWire stream. Linux host: no audio source.
    no_audio: bool = false,
    /// Host backend: the synthetic one, or the OS backend (`--host linux`).
    host: HostKind = .synthetic,
    /// Linux host: read the injected keys back from the uinput keyboard's event node and
    /// check them against the synthetic client's key script (needs /dev/uinput).
    verify_input: bool = false,
    /// Host format preferences (platform/format.zig): 4:4:4 and 10-bit when the client has them.
    yuv444: bool = false,
    ten_bit: bool = false,
    p: pair_cmd.Args = .{},
    /// peer iroh: no pairing, anyone who reaches the endpoint gets a session (`run iroh`
    /// and other lab runs only).
    insecure_no_pairing: bool = false,
    /// peer iroh client (lab check): the host gave this device view-only permissions, so
    /// no clipboard arrives.
    expect_view_only: bool = false,
};

/// "T:D,T:D" (ms) into `out`.
fn parseOutages(v: []const u8, out: []simrun.pathsim.Outage) !usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, v, ',');
    while (it.next()) |item| {
        if (n == out.len) return error.Usage;
        const c = std.mem.indexOfScalar(u8, item, ':') orelse return error.Usage;
        out[n] = .{ .at_us = 1000 * try std.fmt.parseInt(i64, item[0..c], 10), .outage_us = 1000 * try std.fmt.parseInt(i64, item[c + 1 ..], 10) };
        n += 1;
    }
    return n;
}

fn usage() error{Usage} {
    std.debug.print(
        \\usage: moonsec sim [--profile lan|wan|longhaul|clean] [--seconds N] [--seed N] [opts]
        \\       moonsec soak [--seconds 3600] [--profile lan] [--seed N] [opts]
        \\       moonsec run [sim|iroh|all] [--seconds N] [--seed N] [opts]
        \\       moonsec peer sim host|client --hub PORT [--fixture FILE.h264|FILE.h265] [opts]
        \\       moonsec peer iroh host|client --ticket-file PATH [--relay] [opts]
        \\       moonsec pattern --out FILE.ppm [--time-us N] [--frame N] [--size WxH]
        \\       moonsec id [--state-dir D]
        \\       moonsec pair host [--state-dir D] [--name N] [--seconds 120] [--pairings 1] [--relay | --relay-url URL [--relay-ca PEM]]
        \\                         [--pin-only|--qr-only] [--ticket-file F] [--pin-file F] [--qr-svg F]
        \\       moonsec pair client (--ticket T | --ticket-file F) [--pin P] [--state-dir D] [--name N] [--relay]
        \\       moonsec paired [--state-dir D]
        \\       moonsec unpair ID-PREFIX [--state-dir D]
        \\       moonsec allow ID-PREFIX view|full|input,clipboard [--state-dir D]   what a paired client may do
        \\       (pair host --allow PERMS: what devices paired in this window may do; default full)
        \\       moonsec run pair [--seconds N]
        \\       (peer iroh uses the device key in --state-dir or the default state directory: the host
        \\        admits only paired clients, the client connects only to paired hosts, on every
        \\        reconnect too; --insecure-no-pairing turns that off for lab runs)
        \\opts:  --fps N --bitrate BPS --size WxH --slices N --rate-control
        \\       --yuv444 --ten-bit (host: prefer 4:4:4 / 10-bit when the client decodes it)
        \\       --loss-policy (sim, soak: NACK/FEC/relay chosen per path)
        \\sim:   --flaps T:D,.. --drops T:D,.. --idle-ms N --repunch-ms N --relay-delay-ms N --no-stall-pause
        \\client: --client synthetic|linux (moonsec-linux: Wayland/EGL, libavcodec, PipeWire, evdev)
        \\       --uinput-script (type the host's key script on a uinput keyboard) --no-audio
        \\host:  --host synthetic|linux (moonsec-linux: uinput input; synthetic capture and encoder for now)
        \\       --verify-input (read injected keys back from evdev and check them against the key script)
        \\iroh:  --relay-url URL --relay-ca PEM --bind IP:PORT --path-idle-ms N --conn-idle-ms N --min-presented PCT
        \\       --clipboard (sync the system clipboard over the control channel; default: a scripted check)
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
        if (std.mem.eql(u8, s, "--rate-control")) {
            a.rate_control = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--loss-policy")) {
            a.loss_policy = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--clipboard")) {
            a.system_clipboard = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--no-stall-pause")) {
            a.no_stall_pause = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--uinput-script")) {
            a.uinput_script = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--verify-input")) {
            a.verify_input = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--no-audio")) {
            a.no_audio = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--yuv444")) {
            a.yuv444 = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--ten-bit")) {
            a.ten_bit = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--expect-view-only")) {
            a.expect_view_only = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--insecure-no-pairing")) {
            a.insecure_no_pairing = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--pin-only")) {
            a.p.pin_only = true;
            continue;
        }
        if (std.mem.eql(u8, s, "--qr-only")) {
            a.p.qr_only = true;
            continue;
        }
        if (std.mem.startsWith(u8, s, "--")) {
            if (i + 1 >= args.len) return usage();
            i += 1;
            const v = args[i];
            const eq = std.mem.eql;
            if (eq(u8, s, "--seed")) a.seed = try std.fmt.parseInt(u64, v, 10) else if (eq(u8, s, "--seconds")) a.seconds = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--profile")) {
                a.profile = std.meta.stringToEnum(simrun.Profile, v) orelse return usage();
            } else if (eq(u8, s, "--fps")) a.fps = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--bitrate")) a.bitrate = try std.fmt.parseInt(u64, v, 10) else if (eq(u8, s, "--slices")) a.slices = try std.fmt.parseInt(u8, v, 10) else if (eq(u8, s, "--hub")) a.hub_port = try std.fmt.parseInt(u16, v, 10) else if (eq(u8, s, "--fixture")) a.fixture = v else if (eq(u8, s, "--ticket-file")) a.ticket_file = v else if (eq(u8, s, "--out")) a.out = v else if (eq(u8, s, "--time-us")) a.time_us = try std.fmt.parseInt(u64, v, 10) else if (eq(u8, s, "--frame")) a.frame = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--outage-at-ms")) a.outage_at_ms = try std.fmt.parseInt(i64, v, 10) else if (eq(u8, s, "--outage-ms")) a.outage_ms = try std.fmt.parseInt(i64, v, 10) else if (eq(u8, s, "--flaps")) {
                a.n_flaps = try parseOutages(v, &a.flaps);
            } else if (eq(u8, s, "--displays")) {
                a.displays_arg = v;
                var it = std.mem.splitScalar(u8, v, ',');
                while (it.next()) |d| {
                    if (a.n_displays == a.displays.len) return usage();
                    const x = std.mem.indexOfScalar(u8, d, 'x') orelse return usage();
                    a.displays[a.n_displays] = .{ .width = try std.fmt.parseInt(u32, d[0..x], 10), .height = try std.fmt.parseInt(u32, d[x + 1 ..], 10) };
                    a.n_displays += 1;
                }
            } else if (eq(u8, s, "--switch")) {
                a.switch_arg = v;
                var it = std.mem.splitScalar(u8, v, ',');
                while (it.next()) |d| {
                    if (a.n_switches == a.switches.len) return usage();
                    const c = std.mem.indexOfScalar(u8, d, ':') orelse return usage();
                    a.switches[a.n_switches] = .{ .at_us = try std.fmt.parseInt(i64, d[0..c], 10) * 1000, .what = .{ .select = .{ .display = try std.fmt.parseInt(u32, d[c + 1 ..], 10) } } };
                    a.n_switches += 1;
                }
            } else if (eq(u8, s, "--drops")) {
                a.n_drops = try parseOutages(v, &a.drops);
            } else if (eq(u8, s, "--idle-ms")) a.idle_ms = try std.fmt.parseInt(i64, v, 10) else if (eq(u8, s, "--repunch-ms")) a.repunch_ms = try std.fmt.parseInt(i64, v, 10) else if (eq(u8, s, "--relay-delay-ms")) a.relay_delay_ms = try std.fmt.parseInt(i64, v, 10) else if (eq(u8, s, "--path-idle-ms")) a.path_idle_ms = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--relay-url")) a.relay_url = v else if (eq(u8, s, "--relay-ca")) a.relay_ca = v else if (eq(u8, s, "--bind")) a.bind = v else if (eq(u8, s, "--conn-idle-ms")) a.conn_idle_ms = try std.fmt.parseInt(u32, v, 10) else if (eq(u8, s, "--min-presented")) a.min_presented_pct = try std.fmt.parseInt(u64, v, 10) else if (eq(u8, s, "--client")) {
                a.client = std.meta.stringToEnum(ClientKind, v) orelse return usage();
            } else if (eq(u8, s, "--host")) {
                a.host = std.meta.stringToEnum(HostKind, v) orelse return usage();
            } else if (eq(u8, s, "--state-dir")) a.p.state_dir = v else if (eq(u8, s, "--name")) a.p.name = v else if (eq(u8, s, "--ticket")) a.p.ticket = v else if (eq(u8, s, "--pin")) a.p.pin = v else if (eq(u8, s, "--pin-file")) a.p.pin_file = v else if (eq(u8, s, "--qr-svg")) a.p.qr_svg = v else if (eq(u8, s, "--pairings")) a.p.pairings = try std.fmt.parseInt(u8, v, 10) else if (eq(u8, s, "--allow")) {
                a.p.perms = core.pair.allowlist.Perms.parse(v) orelse return usage();
            } else if (eq(u8, s, "--size")) {
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
    environ = init.environ_map;
    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    const eq = std.mem.eql;
    const ok: bool = if (eq(u8, a.cmd, "sim"))
        try cmdSim(gpa, &a, w, a.seconds orelse 10, 0)
    else if (eq(u8, a.cmd, "soak"))
        try cmdSim(gpa, &a, w, a.seconds orelse 3600, 300)
    else if (eq(u8, a.cmd, "run"))
        try cmdRun(gpa, io, a)
    else if (eq(u8, a.cmd, "peer"))
        try cmdPeer(gpa, io, a)
    else if (eq(u8, a.cmd, "pattern"))
        try cmdPattern(gpa, io, a)
    else if (eq(u8, a.cmd, "id"))
        try pair_cmd.cmdId(pctx(gpa, io, a), w)
    else if (eq(u8, a.cmd, "paired"))
        try pair_cmd.cmdPaired(pctx(gpa, io, a), w)
    else if (eq(u8, a.cmd, "unpair"))
        (if (a.npos == 1) try pair_cmd.cmdUnpair(pctx(gpa, io, a), a.pos[0], w) else return usage())
    else if (eq(u8, a.cmd, "allow"))
        (if (a.npos == 2) try pair_cmd.cmdAllow(pctx(gpa, io, a), a.pos[0], a.pos[1], w) else return usage())
    else if (eq(u8, a.cmd, "pair"))
        try cmdPair(gpa, io, a, w)
    else
        return usage();
    try w.flush();
    std.process.exit(if (ok) 0 else 1);
}

var environ: *std.process.Environ.Map = undefined;

fn pctx(gpa: std.mem.Allocator, io: Io, a: Args) pair_cmd.Ctx {
    return .{ .gpa = gpa, .io = io, .env = environ, .p = a.p, .ticket_file = a.ticket_file, .relay = a.relay, .relay_url = a.relay_url, .relay_ca = a.relay_ca, .seconds = a.seconds };
}

fn cmdPair(gpa: std.mem.Allocator, io: Io, a: Args, w: *Io.Writer) !bool {
    if (a.npos != 1) return usage();
    if (!options.iroh) {
        std.debug.print("moonsec: built without the iroh shim; use `zig build moonsec`\n", .{});
        return false;
    }
    const role = std.meta.stringToEnum(Role, a.pos[0]) orelse return usage();
    if (role == .client and a.p.ticket.len == 0 and a.ticket_file.len == 0) return usage();
    return switch (role) {
        .host => pair_cmd.cmdPairHost(pctx(gpa, io, a), w),
        .client => pair_cmd.cmdPairClient(pctx(gpa, io, a), w),
    };
}

fn simOptions(a: *const Args, seconds: u32, progress: u32) simrun.Options {
    const scripted = a.n_flaps + a.n_drops > 0;
    var path: simrun.pathsim.Config = .{ .flaps = a.flaps[0..a.n_flaps], .drops = a.drops[0..a.n_drops] };
    if (a.idle_ms) |v| path.idle_us = v * 1000;
    if (a.repunch_ms) |v| path.repunch_us = v * 1000;
    if (a.relay_delay_ms) |v| path.relay_delay_us = v * 1000;
    return .{
        .path = if (scripted) path else null,
        .pause_on_stall = !a.no_stall_pause,
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
        .rate_control = a.rate_control,
        .loss_policy = a.loss_policy,
        .displays = a.displays[0..a.n_displays],
        .display_events = a.switches[0..a.n_switches],
        .yuv444 = a.yuv444,
        .ten_bit = a.ten_bit,
    };
}

fn cmdSim(gpa: std.mem.Allocator, a: *const Args, w: *Io.Writer, seconds: u32, progress: u32) !bool {
    const o = simOptions(a, seconds, progress);
    try w.print("== {d} s of {s} streaming over the {s} sim profile (seed {d}, {d}x{d}@{d}, {d} kbit/s) ==\n", .{ seconds, "synthetic", @tagName(o.profile), o.seed, o.width, o.height, o.fps, o.bitrate_bps / 1000 });
    try w.flush();
    const r = try simrun.run(gpa, o, w);
    try r.print(w);
    const why = r.failure(o);
    const pass_why = if (o.path != null) "clean end, every presented frame checked" else "no freezes, every frame and input checked";
    try w.print("{s}: {s}\n", .{ if (why == null) "PASS" else "FAIL", why orelse pass_why });
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
    list: [32][]const u8 = undefined,
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
        inline for (.{ .{ "--displays", "displays_arg" }, .{ "--switch", "switch_arg" } }) |f| if (@field(a, f[1])) |v| {
            p.list[p.n] = f[0];
            p.list[p.n + 1] = v;
            p.n += 2;
        };
        if (a.client != .synthetic) {
            p.list[p.n] = "--client";
            p.list[p.n + 1] = @tagName(a.client);
            p.n += 2;
        }
        if (a.host != .synthetic) {
            p.list[p.n] = "--host";
            p.list[p.n + 1] = @tagName(a.host);
            p.n += 2;
        }
        if (a.uinput_script) {
            p.list[p.n] = "--uinput-script";
            p.n += 1;
        }
        if (a.verify_input) {
            p.list[p.n] = "--verify-input";
            p.n += 1;
        }
        if (a.no_audio) {
            p.list[p.n] = "--no-audio";
            p.n += 1;
        }
        if (a.yuv444) {
            p.list[p.n] = "--yuv444";
            p.n += 1;
        }
        if (a.ten_bit) {
            p.list[p.n] = "--ten-bit";
            p.n += 1;
        }
    }
};

fn cmdRun(gpa: std.mem.Allocator, io: Io, a: Args) !bool {
    const which = if (a.npos > 0) a.pos[0] else "all";
    const want_sim = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "sim");
    const want_iroh = std.mem.eql(u8, which, "all") or std.mem.eql(u8, which, "iroh");
    const want_pair = std.mem.eql(u8, which, "pair");
    if (!want_sim and !want_iroh and !want_pair) return usage();
    if (want_pair) {
        if (!options.iroh) {
            std.debug.print("moonsec: built without the iroh shim; use `zig build moonsec`\n", .{});
            return false;
        }
        const exe = try std.process.executablePathAlloc(io, gpa);
        defer gpa.free(exe);
        return pair_cmd.runPairE2E(pctx(gpa, io, a), exe);
    }
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
        .longhaul => &warmLonghaul,
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
    var argv: [36][]const u8 = undefined;
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

fn warmLonghaul(net: *simnet.Net) void {
    for (&net.links) |*l| l.cfg.loss = simrun.Profile.longhaul.link().loss;
}

fn runIroh(io: Io, self_exe: []const u8, a: Args) !bool {
    std.debug.print("== two processes over iroh, loopback, relays off (seed {d}) ==\n", .{a.seed});
    var name_buf: [64]u8 = undefined;
    const ticket_file = try std.fmt.bufPrint(&name_buf, ".moonsec-ticket-{d}", .{Io.Clock.awake.now(io).toNanoseconds()});
    Io.Dir.cwd().deleteFile(io, ticket_file) catch {};
    defer Io.Dir.cwd().deleteFile(io, ticket_file) catch {};
    var pa: PeerArgs = .{};
    pa.fill(a);
    var argv: [36][]const u8 = undefined;
    // A lab run between two throwaway endpoints: no pairing (`run pair` covers it).
    const base = [_][]const u8{ self_exe, "peer", "iroh", "host", "--ticket-file", ticket_file, "--insecure-no-pairing" };
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
        return peer(gpa, io, a, role, link.packetPipe(), null, null);
    }
    if (std.mem.eql(u8, a.pos[0], "iroh")) {
        if (!options.iroh) return usage();
        return peerIroh(gpa, io, a, role);
    }
    return usage();
}

/// A clipboard for wall-clock peer runs: in memory, with one scripted copy `copy_after_us`
/// after the first poll (made on the network thread, which polls it). Checks that the
/// control channel carries a copy each way over the real transport.
const ScriptedClipboard = struct {
    mem: clipboard.Memory,
    text: []const u8,
    copy_after_us: Micros,
    start: ?Micros = null,
    copied: bool = false,

    fn clip(s: *ScriptedClipboard) clipboard.Clipboard {
        return .{ .ptr = s, .vtable = &vt };
    }
    fn changeCount(p: *anyopaque) u64 {
        const s: *ScriptedClipboard = @ptrCast(@alignCast(p));
        const now = wallNow();
        const t0 = s.start orelse blk: {
            s.start = now;
            break :blk now;
        };
        if (!s.copied and now - t0 >= s.copy_after_us) {
            s.mem.set(s.text) catch {};
            s.copied = true;
        }
        return s.mem.count;
    }
    fn readText(p: *anyopaque, gpa: std.mem.Allocator) clipboard.Error!?[]u8 {
        const s: *ScriptedClipboard = @ptrCast(@alignCast(p));
        return s.mem.clipboard().readText(gpa);
    }
    fn writeText(p: *anyopaque, text: []const u8) clipboard.Error!void {
        const s: *ScriptedClipboard = @ptrCast(@alignCast(p));
        return s.mem.clipboard().writeText(text);
    }
    const vt = clipboard.Clipboard.VTable{ .changeCount = changeCount, .readText = readText, .writeText = writeText };

    /// The peer's copy arrived (and nothing newer replaced it).
    fn got(s: *const ScriptedClipboard, want: []const u8) bool {
        return s.mem.writes > 0 and std.mem.eql(u8, s.mem.get() orelse "", want);
    }
};

const host_copy = "copied on the host";
const client_copy = "copied on the client";

/// `perms` (host): what the connected device may do; null for everything.
fn peer(gpa: std.mem.Allocator, io: Io, a: Args, role: Role, p: pipe_mod.PacketPipe, ctl_stream: ?pipe_mod.ByteStream, perms: ?control_mod.PermsSource) !bool {
    const clock = api.clockFn(wallNow);
    // With a control stream: the host copies after 1 s, the client after 2 s, so each side
    // ends up holding the client's copy and the host also got it from the client.
    var clip: ScriptedClipboard = .{
        .mem = .init(gpa),
        .text = if (role == .host) host_copy else client_copy,
        .copy_after_us = if (role == .host) 1_000_000 else 2_000_000,
    };
    defer clip.mem.deinit();
    var sys: ?clipboard.System = null;
    if (a.system_clipboard and ctl_stream != null) {
        sys = clipboard.System.open() orelse {
            std.debug.print("{s}: no system clipboard here (Linux: build with -Dlinux-clipboard, and run under Wayland or X11)\n", .{@tagName(role)});
            return false;
        };
        std.debug.print("{s}: syncing the system clipboard ({s}); copy on either machine and paste on the other\n", .{ @tagName(role), sys.?.name() });
    }
    defer if (sys) |*sy| sy.close();
    const scripted = ctl_stream != null and sys == null;
    const clip_opt: ?clipboard.Clipboard = if (sys) |*sy| sy.clipboard() else if (scripted) clip.clip() else null;
    const seconds = a.seconds orelse 10;
    var buf: [16384]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var ok = false;
    switch (role) {
        .host => if (a.host == .linux) {
            if (!options.linux_host) {
                std.debug.print("moonsec: built without the Linux host; use `zig build moonsec-linux`\n", .{});
                return false;
            }
            ok = try peerLinuxHost(gpa, io, a, p, &w, perms);
        } else {
            const sh = try synthetic.openHost(gpa, .{ .clock = clock, .sleeper = wallSleep, .width = a.width, .height = a.height, .displays = a.displays[0..a.n_displays] });
            var hb = sh.backend();
            defer hb.deinit();
            // --fixture: a recorded H.264/HEVC stream stands in for the encoder.
            var codec: api.Codec = .passthrough;
            var fx: synthetic.fixture.Encoder = undefined;
            var units: []synthetic.fixture.AccessUnit = &.{};
            defer gpa.free(units);
            var fixture_data: []u8 = &.{};
            defer gpa.free(fixture_data);
            if (a.fixture.len > 0) {
                codec = if (std.mem.endsWith(u8, a.fixture, ".h265") or std.mem.endsWith(u8, a.fixture, ".hevc")) .hevc else .h264;
                fixture_data = try Io.Dir.cwd().readFileAlloc(io, a.fixture, gpa, .limited(64 << 20));
                units = try gpa.alloc(synthetic.fixture.AccessUnit, 1 << 16);
                const split = try synthetic.fixture.split(codec, fixture_data, units);
                fx = .init(clock, codec, fixture_data, split);
                hb.encoder = api.bind(api.Encoder, synthetic.fixture.Encoder, &fx);
            }
            var app = try apps.HostApp.init(gpa, hb, .{ .fps = a.fps, .bitrate_bps = a.bitrate, .slices = a.slices, .codec = codec, .pause_on_stall = !a.no_stall_pause, .yuv444 = a.yuv444, .ten_bit = a.ten_bit, .session = .{ .rate_control = a.rate_control }, .control_stream = ctl_stream, .clipboard = clip_opt, .perms = perms }, p);
            defer app.deinit();
            try app.runThreaded(io);
            try app.s.report(&w);
            const pm: core.pair.allowlist.Perms = if (perms) |src| src.read() else .full;
            if (!pm.eql(.full)) try w.print("  device permissions: {f}\n", .{pm});
            const lost_input = app.s.input_rx.stats.lost_events;
            try w.print("  injected keys {d} (out of order {d}, lost {d}), capture timeouts {d}, encode errors {d}\n", .{ sh.injector.keys, sh.injector.wrong, lost_input, app.stats.capture_timeouts, app.stats.encode_errors });
            if (app.audio) |au| try w.print("  audio: {d} frames encoded, {d} datagrams, {d} errors; source skipped {d} frames\n", .{ au.stats.frames, au.stats.datagrams, au.stats.errors, sh.audio.stats.skipped });
            // Keys older than the sender's 500 ms window are dropped by design (an outage);
            // the injector's script check then reads the rest as out of order.
            if (a.fixture.len > 0) {
                try w.print("  fixture: {d} frames ({d} keyframes, {d} skipped for recovery), {d} bytes\n", .{ fx.stats.frames, fx.stats.keyframes, fx.stats.skipped, fx.stats.bytes });
                // A real client's input is whatever its user typed, not the scripted keys.
                ok = app.s.end == .client_bye and app.s.stats.frames > 0;
            } else {
                // A device without the input permission: nothing injected, its input refused.
                const input_ok = if (pm.input) (sh.injector.wrong == 0 or lost_input > 0) and sh.injector.keys > 0 else sh.injector.keys == 0 and app.s.stats.inputs_denied > 0;
                ok = app.s.end == .client_bye and input_ok and app.s.stats.frames > 0;
            }
            if (ctl_stream != null) {
                const cs = app.s.control.stats;
                // Without the clipboard permission, the client's copy must not arrive.
                const clip_ok = !scripted or if (pm.clipboard) clip.got(client_copy) else !clip.got(client_copy) and app.s.control.clip.stats.applied == 0;
                try w.print("  control: {d} channels, {d} up, {d} resets, {d} errors; clipboard {s} (sent {d}, applied {d}, echoes {d})\n", .{ cs.channels, cs.ups, cs.resets, cs.errors, if (clip_ok) "ok" else "MISSING the client's copy", app.s.control.clip.stats.sent, app.s.control.clip.stats.applied, app.s.control.clip.stats.echoes });
                ok = ok and clip_ok;
            }
        },
        .client => if (a.client == .linux) {
            if (!options.linux_client) {
                std.debug.print("moonsec: built without the Linux client; use `zig build moonsec-linux`\n", .{});
                return false;
            }
            ok = try peerLinuxClient(gpa, io, a, p, &w);
        } else {
            const sc = try synthetic.openClient(gpa, .{ .clock = clock, .input_interval_us = 25_000 });
            const cb = sc.backend();
            defer cb.deinit();
            var switches: [16]apps.Switch = undefined;
            for (a.switches[0..a.n_switches], switches[0..a.n_switches]) |e, *sw| sw.* = .{ .after_us = e.at_us, .display = e.what.select.display };
            var app = try apps.ClientApp.init(gpa, cb, .{ .content_ctx = sc, .contentFn = patternContent, .control_stream = ctl_stream, .clipboard = clip_opt, .switches = switches[0..a.n_switches] }, p);
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
                audio_ok = (bs.decoded + bs.fec) * 100 >= @as(u64, seconds) * 100 * a.min_presented_pct and ss.loud * 2 >= ss.written;
            }
            const want = @as(u64, seconds) * a.fps;
            // Wall-clock runs on shared CI machines get scheduling stalls the sim never
            // has; hold them to most frames and no corruption, and report freezes.
            ok = app.s.end == .closed and app.s.stats.frames_presented * 100 >= want * a.min_presented_pct and
                sc.presenter.stats.unreadable == 0 and sc.decoder.stats.corrupt == 0 and audio_ok;
            if (ctl_stream != null) {
                const cs = app.s.control.stats;
                // The host's copy arrived before ours replaced it.
                // --expect-view-only: the host gave this device no clipboard, so nothing came.
                const clip_ok = !scripted or if (a.expect_view_only) app.s.control.clip.stats.applied == 0 else (clip.mem.writes >= 1 and app.s.control.clip.stats.applied >= 1 and std.mem.eql(u8, clip.mem.get() orelse "", client_copy));
                try w.print("  control: {d} channels, {d} up, {d} resets, {d} errors; clipboard {s} (sent {d}, applied {d}, echoes {d})\n", .{ cs.channels, cs.ups, cs.resets, cs.errors, if (clip_ok) "ok" else "MISSING the host's copy", app.s.control.clip.stats.sent, app.s.control.clip.stats.applied, app.s.control.clip.stats.echoes });
                ok = ok and clip_ok;
            }
        },
    }
    std.debug.print("{s}", .{w.buffered()});
    return ok;
}

/// The Linux host backend against any client: uinput injection, and (until the capture and
/// encoders are wired in) the synthetic capture, encoder and audio. With --verify-input the injected keys
/// are read back from the uinput keyboard's event node, as the compositor reads them, and
/// checked against the synthetic client's key script.
fn peerLinuxHost(gpa: std.mem.Allocator, io: Io, a: Args, p: pipe_mod.PacketPipe, w: *Io.Writer, perms: ?control_mod.PermsSource) !bool {
    if (!options.linux_host) unreachable;
    const h = host_linux.backend.open(gpa, .{ .width = a.width, .height = a.height, .audio = !a.no_audio, .sleeper = wallSleep, .require_input = a.verify_input }) catch |e| {
        std.debug.print("linux host: {s}\n", .{@errorName(e)});
        return false;
    };
    const hb = h.backend();
    defer hb.deinit();
    try w.writeAll("  linux host: ");
    try h.describe(w);
    try w.writeAll("\n");
    if (h.injector != null and !a.verify_input)
        std.debug.print("linux host: injecting the client's input into this session's desktop\n", .{});
    var check: KeyCheck = .{};
    if (a.verify_input) {
        const node = h.injector.?.keyboard.node orelse {
            std.debug.print("linux host: the uinput keyboard has no event node\n", .{});
            return false;
        };
        check.reader = linux_uinput.Reader.open(node, 3000) orelse {
            std.debug.print("linux host: cannot read /dev/input/event{d} (needs read access to input devices)\n", .{node});
            return false;
        };
    }
    defer if (check.reader) |r| r.close();
    var app = try apps.HostApp.init(gpa, hb, .{ .fps = a.fps, .bitrate_bps = a.bitrate, .slices = a.slices, .pause_on_stall = !a.no_stall_pause, .session = .{ .rate_control = a.rate_control }, .perms = perms }, p);
    defer app.deinit();
    var reading: ?Io.Future(Io.Cancelable!void) = if (check.reader != null) try io.concurrent(KeyCheck.run, .{ &check, io }) else null;
    defer if (reading) |*f| f.cancel(io) catch {};
    try app.runThreaded(io);
    if (reading) |*f| {
        // Let the last reports through, then stop reading.
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        f.cancel(io) catch {};
        reading = null;
    }
    try app.s.report(w);
    const lost_input = app.s.input_rx.stats.lost_events;
    if (h.injector) |j| {
        const st = j.stats;
        try w.print("  uinput: keys {d}, buttons {d}, motions {d}, scrolls {d}, absolute {d}, pad reports {d} ({d} pads); unmapped {d}, write errors {d}, device errors {d}; inject errors {d}\n", .{ st.keys, st.buttons, st.motions, st.scrolls, st.abs, st.pad_reports, st.pads_connected, st.unmapped, st.write_errors, st.device_errors, app.stats.inject_errors });
    }
    if (check.reader != null) try w.print("  evdev read back: {d} keys ({d} out of script order)\n", .{ check.keys, check.wrong });
    if (app.audio) |au| try w.print("  audio: {d} frames encoded, {d} datagrams, {d} errors\n", .{ au.stats.frames, au.stats.datagrams, au.stats.errors });
    var ok = app.s.end == .client_bye and app.s.stats.frames > 0;
    if (h.injector) |j| ok = ok and j.stats.write_errors == 0 and (a.client != .synthetic or j.stats.keys > 0);
    // As for the synthetic host: keys past the sender's 500 ms window are dropped by
    // design (an outage), and the script check then reads the rest as out of order.
    if (check.reader != null) ok = ok and check.keys > 0 and (check.wrong == 0 or lost_input > 0);
    return ok;
}

/// Reads a uinput keyboard's event node and checks the keys against
/// `synthetic.scriptKey(0, 1, ...)`, as the synthetic host's injector does.
const KeyCheck = struct {
    reader: if (options.linux_host) ?linux_uinput.Reader else ?void = null,
    keys: u64 = 0,
    wrong: u64 = 0,

    fn run(c: *KeyCheck, io: Io) Io.Cancelable!void {
        if (!options.linux_host) unreachable;
        var buf: [64]linux_uinput.Event = undefined;
        while (true) {
            const got = c.reader.?.read(&buf);
            for (got) |e| {
                if (e.type != linux_uinput.EV_KEY) continue;
                const want = synthetic.scriptKey(c.keys);
                if (linux_uinput.hidUsage(e.code) != want.code or (e.value != 0) != want.down) c.wrong += 1;
                c.keys += 1;
            }
            if (got.len == 0) try io.sleep(.fromMilliseconds(2), .awake);
        }
    }
};

/// The client on the Linux backend against the synthetic host: every presented picture
/// is read back from the GL back buffer and its pattern stamp decoded (so a freeze or a
/// wrong picture is caught after the real presenter), audio plays into PipeWire, and with
/// --uinput-script the host's key script is typed on a uinput keyboard and read back
/// through evdev.
fn peerLinuxClient(gpa: std.mem.Allocator, io: Io, a: Args, p: pipe_mod.PacketPipe, w: *Io.Writer) !bool {
    if (!options.linux_client) unreachable;
    const seconds = a.seconds orelse 10;
    // The typist's device exists before the backend scans, so evdev opens it at once.
    const typist: ?client_linux.uinput.Device = if (a.uinput_script) client_linux.uinput.Device.create("moonsec uinput script") catch |e| {
        std.debug.print("uinput: {s}\n", .{@errorName(e)});
        return false;
    } else null;
    defer if (typist) |t| t.destroy();
    const cl = try client_linux.open(gpa, .{ .width = a.width, .height = a.height, .title = "moonsec", .verify_pattern = true });
    var be = cl.backend();
    defer be.deinit();
    var audio = !a.no_audio;
    if (audio) {
        if (cl.audio.start(.{})) |_| cl.audio.stop() else |e| {
            std.debug.print("  no PipeWire ({s}): video and input only\n", .{@errorName(e)});
            audio = false;
        }
    }
    if (!audio) be.audio = null;
    var app = try apps.ClientApp.init(gpa, be, .{ .content_ctx = cl, .contentFn = linuxPatternContent }, p);
    defer app.deinit();
    var timer = try io.concurrent(quitAfter, .{ &app, io, seconds });
    defer timer.cancel(io) catch {};
    var typing: ?Io.Future(Io.Cancelable!u64) = if (typist) |t| try io.concurrent(typeScript, .{ &app, io, t }) else null;
    defer if (typing) |*f| {
        _ = f.cancel(io) catch {};
    };
    try app.runThreaded(io);
    const typed: u64 = if (typing) |*f| f.cancel(io) catch 0 else 0;
    typing = null;
    app.s.freeze.finish(app.s.freeze.last_new_us orelse 0);
    try app.s.report(w);
    const ps = cl.presenter.stats;
    try w.print("  presenter (EGL, {s}): {d} presents, {d} patterns verified from the back buffer, {d} unreadable, {d} not 1:1; decoder corrupt {d}\n", .{ std.mem.span(client_linux.c.mlc_window_renderer(cl.window)), ps.presents, ps.verified, ps.unreadable, ps.unscaled_skipped, cl.decoder.pass.stats.corrupt });
    try w.print("  evdev: {d} devices, {d} events ({d} dropped unfocused); uinput typed {d} keys\n", .{ if (cl.input.devices) |d| d.n else 0, cl.input.stats.events, cl.input.stats.dropped_unfocused, typed });
    var audio_ok = true;
    if (app.audio) |au| {
        const bs = au.bufferStats();
        const info = cl.audio.info();
        try w.print("  audio (PipeWire): played {d} (FEC {d}, RS rebuilt {d}), concealed {d}, late {d}, silence {d}; stream {s}, quantum {d}, ring underruns {d}\n", .{ bs.decoded + bs.fec, bs.fec, bs.rs_recovered, bs.concealed, bs.late, bs.silence, if (info != null and info.?.streaming) "streaming" else "not linked", if (info) |i| i.quantum else 0, if (info) |i| i.underruns else 0 });
        audio_ok = (bs.decoded + bs.fec) * 100 >= @as(u64, seconds) * 100 * a.min_presented_pct;
    }
    const want = @as(u64, seconds) * a.fps;
    return app.s.end == .closed and app.s.stats.frames_presented * 100 >= want * a.min_presented_pct and
        ps.unreadable == 0 and ps.verified * 100 >= want * a.min_presented_pct and cl.decoder.pass.stats.corrupt == 0 and audio_ok and
        (typist == null or cl.input.stats.events > 0);
}

fn linuxPatternContent(ctx: ?*anyopaque, _: *const api.DecodedFrame) u64 {
    if (!options.linux_client) unreachable;
    const cl: *client_linux.Client = @ptrCast(@alignCast(ctx.?));
    return if (cl.presenter.last_stamp) |s| s.frame else 0;
}

/// Types `synthetic.scriptKey(0, 1, ...)` on the uinput keyboard every 25 ms while the
/// session streams, with a little motion, as the synthetic input source does.
fn typeScript(app: *apps.ClientApp, io: Io, t: UinputDevice) Io.Cancelable!u64 {
    if (!options.linux_client) unreachable;
    while (app.s.config == null) try io.sleep(.fromMilliseconds(5), .awake);
    // The client polls input once streaming; give it a moment to start.
    try io.sleep(.fromMilliseconds(100), .awake);
    var i: u64 = 0;
    while (true) : (i += 1) {
        const k = synthetic.scriptKey(i);
        t.key(client_linux.uinput.keyCode(k.code), k.down);
        t.move(3, -2);
        io.sleep(.fromMilliseconds(25), .awake) catch return i + 1;
    }
}

fn quitAfter(app: *apps.ClientApp, io: Io, seconds: u32) Io.Cancelable!void {
    // Count from the first config, not from process start.
    while (app.s.config == null) try io.sleep(.fromMilliseconds(5), .awake);
    try io.sleep(.fromSeconds(seconds), .awake);
    app.quit = true;
}

fn peerIroh(gpa: std.mem.Allocator, io: Io, a: Args, role: Role) !bool {
    if (a.ticket_file.len == 0) return usage();
    // Pairing is enforced unless a lab run turns it off: the device key from the state
    // directory (--state-dir, else the default one), the host admits only paired clients and
    // the client connects only to paired hosts, on every connection including reconnects.
    var state: ?@import("pairing.zig").State = if (!a.insecure_no_pairing) try pair_cmd.openStateFor(pctx(gpa, io, a)) else if (a.p.state_dir.len > 0) try pair_cmd.openStateFor(pctx(gpa, io, a)) else null;
    defer if (state) |*st| st.close();
    if (a.insecure_no_pairing and role == .host) std.debug.print("moonsec: --insecure-no-pairing: any peer that reaches this endpoint gets a session (lab use only)\n", .{});
    var secret: ?[32]u8 = null;
    if (state) |*st| secret = (try st.identity()).secret;
    iroh.init(null, null) catch |e| {
        std.debug.print("iroh init: {s}\n", .{iroh.lastError()});
        return e;
    };
    const any_relay = a.relay or a.relay_url != null;
    // --relay-ca names a PEM file; the shim takes the PEM text.
    const ca_pem: ?[:0]u8 = if (a.relay_ca) |path| blk: {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(text);
        break :blk try gpa.dupeZ(u8, text);
    } else null;
    defer if (ca_pem) |t| gpa.free(t);
    const ep = iroh.Endpoint.bind(.{
        .secret_key = if (secret) |*k| k else null,
        .alpn = if (role == .host) alpn else "",
        .relay_mode = if (a.relay_url != null) .custom_only else if (a.relay) .default else .disabled,
        .relay_urls = if (a.relay_url) |u| u.ptr else null,
        .relay_ca_pem = if (ca_pem) |t| t.ptr else null,
        .bind_addr = a.bind orelse if (any_relay) "0.0.0.0:0" else "127.0.0.1:0",
        .conn_idle_timeout_ms = a.conn_idle_ms,
        .path_idle_timeout_ms = a.path_idle_ms,
        // Keep-alive at a third of the idle timeout (the shim's 100 ms suits its 300 ms).
        .path_keepalive_ms = if (a.path_idle_ms > 0) @max(a.path_idle_ms / 3, 50) else 0,
    }) catch |e| {
        std.debug.print("bind: {s}\n", .{iroh.lastError()});
        return e;
    };
    defer ep.deinit();
    if (a.relay_url != null) ep.online(15_000) catch |e| {
        std.debug.print("relay: {s}\n", .{iroh.lastError()});
        return e;
    };
    var ticket_z: ?[:0]u8 = null;
    defer if (ticket_z) |t| gpa.free(t);
    switch (role) {
        .host => {
            var tbuf: [4096]u8 = undefined;
            const t = try ep.ticket(&tbuf);
            var tmp_buf: [256]u8 = undefined;
            const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{a.ticket_file});
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = t });
            try Io.Dir.rename(.cwd(), tmp, .cwd(), a.ticket_file, io);
        },
        .client => {
            var ticket: ?[]u8 = null;
            defer if (ticket) |t| gpa.free(t);
            for (0..1200) |_| {
                ticket = Io.Dir.cwd().readFileAlloc(io, a.ticket_file, gpa, .limited(8192)) catch null;
                if (ticket != null and ticket.?.len > 0) break;
                io.sleep(.fromMilliseconds(25), .awake) catch {};
            }
            const t = ticket orelse return error.NoTicket;
            ticket_z = try gpa.dupeZ(u8, std.mem.trim(u8, t, " \r\n"));
        },
    }
    const wait_ms: u32 = if (role == .host and a.relay) 600_000 else 30_000;
    // The allowlist (host) or paired-host list (client) the gate checks every connection
    // against. The host's gate reads it again on every connection, so `moonsec unpair` and
    // `moonsec allow` apply from a device's next connection.
    var list: ?core.pair.Allowlist = if (!a.insecure_no_pairing) try state.?.loadList(if (role == .host) .clients else .hosts) else null;
    defer if (list) |*l| l.deinit();
    var gate: pair_cmd.LinkGate = undefined;
    if (list) |*l| gate = .{ .list = l, .role = if (role == .host) .host else .client, .state = if (role == .host) &state.? else null };
    // The link accepts (host) or dials (client) in the background, and again after a drop.
    const link = try gpa.create(iroh_pipe.IrohLink);
    defer gpa.destroy(link);
    try link.start(io, ep, .{
        .role = if (role == .host) .accept else .dial,
        .ticket = ticket_z orelse "",
        .alpn = alpn,
        .gate = if (list != null) gate.gate() else null,
        .refuse_code = pair_cmd.close_not_paired,
    });
    defer link.deinit();
    const p = link.packetPipe();
    // The first connection, within the old accept/connect timeouts.
    var waited: u64 = 0;
    while (!p.stats().connected) : (waited += 10) {
        if (link.refused()) return false; // requestSession said why
        if (waited >= wait_ms) {
            std.debug.print("{s}: no connection after {d} s ({d} dials, {d} failed, {d} refused): {s}\n", .{ @tagName(role), wait_ms / 1000, link.linkStats().dials, link.linkStats().dial_failures, link.linkStats().refused, iroh.lastError() });
            return error.Timeout;
        }
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    // Host: the installed connection's device decides what the session applies.
    const perms_src: ?control_mod.PermsSource = if (role == .host and list != null) .{ .ctx = link, .get = linkPerms } else null;
    const ok = try peer(gpa, io, a, role, p, link.controlStream(), perms_src);
    const ls = link.linkStats();
    std.debug.print("  {s} link: {d} dials ({d} failed), {d} accepts, {d} refused, {d} reconnects, {d} discarded, {d} datagrams dropped offline\n", .{ @tagName(role), ls.dials, ls.dial_failures, ls.accepts, ls.refused, ls.switches, ls.discarded, ls.offline_drops });
    if (link.conn()) |conn| printQuic(conn, role);
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    return ok;
}

fn linkPerms(ctx: *anyopaque) core.pair.allowlist.Perms {
    const link: *iroh_pipe.IrohLink = @ptrCast(@alignCast(ctx));
    return pair_cmd.tagPerms(link.curTag());
}

/// The current connection's shim counters and paths, so a lab run shows where datagrams went.
fn printQuic(conn: iroh.Conn, role: anytype) void {
    if (conn.stats()) |c| {
        std.debug.print("  {s} quic: datagrams sent {d}, on the wire {d}, evicted {d}, queued {d}; received {d}, read {d}, dropped {d}+{d}; packets {d} (lost {d}); target {d} kbit/s\n", .{ @tagName(role), c.dgram_sent, c.dgram_tx_wire, c.dgram_send_drops, c.dgram_send_queued, c.dgram_rx_wire, c.dgram_read, c.dgram_recv_drops_quic, c.dgram_recv_drops_shim, c.sent_packets, c.lost_packets, c.target_bps / 1000 });
    } else |_| {}
    var pbuf: [8]iroh.PathStats = undefined;
    const paths = conn.pathStats(&pbuf) catch return;
    for (paths) |*p| {
        std.debug.print("    path {d} {s} relay={d} selected={d} pacing={d} kbit/s cwnd={d} mtu={d} rtt={d} us sent {d} pkts {d} B, lost {d}\n", .{ p.path_id, iroh.pathRemoteAddr(p), p.is_relay, p.is_selected, p.pacing_bps / 1000, p.cwnd, p.mtu, p.rtt_us, p.sent_packets, p.sent_bytes, p.lost_packets });
    }
}
