//! The Phase 1 gate (docs/design.md): two processes exchange stream-tagged
//! datagrams through the core, over real iroh and over the simulated network.
//!
//!   gate run [sim|iroh|all] [--seed N] [--frames N]
//!       Runs the gate: spawns a host process and a client process (this same
//!       binary in `peer` mode) for each transport and exits 0 only if both pass.
//!       For the sim, this process is the hub that owns the simulated network.
//!   gate peer sim  host|client --hub PORT [--seed N] [--frames N]
//!   gate peer iroh host --ticket-file PATH [--seed N] [--frames N]
//!   gate peer iroh client --ticket-file PATH [--seed N] [--frames N]
//!       One endpoint, as `run` starts it. The iroh host binds on loopback with
//!       relays off, writes its ticket to PATH and accepts one connection; the
//!       client reads the ticket and dials.
//!
//! What each side sends and checks: tools/gate/session.zig. `gate-sim` is this
//! program built without the iroh shim (sim only), for builds without Rust.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("gate_options");
const session = @import("session.zig");
const scenario = @import("scenario.zig");
const simnet = @import("simnet");
const simlink = @import("simlink");
const pipe = @import("pipe");
const iroh = if (options.iroh) @import("iroh") else struct {};
const iroh_pipe = if (options.iroh) @import("iroh_pipe") else struct {};

const Io = std.Io;
const alpn = "moonsec/gate/0";

const Transport = enum { sim, iroh };

const Args = struct {
    cmd: []const u8 = "",
    which: []const u8 = "all",
    role: session.Role = .host,
    hub_port: u16 = 0,
    ticket_file: []const u8 = "",
    seed: u64 = 1,
    frames: u32 = 300,
};

fn usage() error{Usage} {
    std.debug.print(
        \\usage: gate run [sim|iroh|all] [--seed N] [--frames N]
        \\       gate peer sim host|client --hub PORT [--seed N] [--frames N]
        \\       gate peer iroh host|client --ticket-file PATH [--seed N] [--frames N]
        \\
    , .{});
    return error.Usage;
}

fn parseArgs(args: []const [:0]const u8) !Args {
    var a: Args = .{};
    if (args.len < 2) return usage();
    a.cmd = args[1];
    var pos: usize = 0;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.startsWith(u8, s, "--")) {
            if (i + 1 >= args.len) return usage();
            i += 1;
            const v = args[i];
            if (std.mem.eql(u8, s, "--seed")) {
                a.seed = try std.fmt.parseInt(u64, v, 10);
            } else if (std.mem.eql(u8, s, "--frames")) {
                a.frames = try std.fmt.parseInt(u32, v, 10);
            } else if (std.mem.eql(u8, s, "--hub")) {
                a.hub_port = try std.fmt.parseInt(u16, v, 10);
            } else if (std.mem.eql(u8, s, "--ticket-file")) {
                a.ticket_file = v;
            } else return usage();
            continue;
        }
        switch (pos) {
            0 => a.which = s,
            1 => a.role = std.meta.stringToEnum(session.Role, s) orelse return usage(),
            else => return usage(),
        }
        pos += 1;
    }
    return a;
}

fn sessionConfig(a: Args) session.Config {
    return .{ .seed = a.seed, .frames = a.frames };
}

/// Windows sleeps in 15.6 ms ticks by default, which turns the hub's and the peers'
/// sub-millisecond waits into 16 ms bursts (frames and deliveries batch up, and the
/// rate controller reads the batching as queueing). Ask for 1 ms ticks.
const winmm = if (builtin.os.tag == .windows) struct {
    extern "winmm" fn timeBeginPeriod(period: u32) callconv(.winapi) u32;
} else struct {};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) _ = winmm.timeBeginPeriod(1);
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const a = try parseArgs(args);
    if (std.mem.eql(u8, a.cmd, "run")) {
        const self_exe = try std.process.executablePathAlloc(io, init.arena.allocator());
        var ok = true;
        const want_sim = std.mem.eql(u8, a.which, "all") or std.mem.eql(u8, a.which, "sim");
        const want_iroh = std.mem.eql(u8, a.which, "all") or std.mem.eql(u8, a.which, "iroh");
        if (!want_sim and !want_iroh) return usage();
        if (want_sim) ok = (try runSim(gpa, io, self_exe, a)) and ok;
        if (want_iroh) {
            if (!options.iroh) {
                std.debug.print("gate: built without the iroh shim (gate-sim); use `zig build gate`\n", .{});
                std.process.exit(2);
            }
            ok = (try runIroh(gpa, io, self_exe, a)) and ok;
        }
        std.debug.print("\nPhase 1 gate: {s}\n", .{if (ok) "PASS" else "FAIL"});
        std.process.exit(if (ok) 0 else 1);
    } else if (std.mem.eql(u8, a.cmd, "peer")) {
        const t = std.meta.stringToEnum(Transport, a.which) orelse return usage();
        const passed = switch (t) {
            .sim => try peerSim(gpa, io, a),
            .iroh => if (options.iroh) try peerIroh(gpa, io, a) else return usage(),
        };
        std.process.exit(if (passed) 0 else 1);
    } else return usage();
}

// --- orchestration ------------------------------------------------------------

fn spawnPeer(io: Io, argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit });
}

fn exitedOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn runSim(gpa: std.mem.Allocator, io: Io, self_exe: []const u8, a: Args) !bool {
    std.debug.print("== gate over the simulated network (seed {d}, {d} frames) ==\n", .{ a.seed, a.frames });
    const hub = try gpa.create(simlink.Hub);
    defer gpa.destroy(hub);
    try hub.init(gpa, io, scenario.config(a.seed));
    defer hub.deinit();
    hub.on_warm = scenario.startLoss;
    hub.warmup_us = scenario.warmup_us;

    var stop: std.atomic.Value(bool) = .init(false);
    var hub_task = try io.concurrent(simlink.Hub.run, .{ hub, &stop });
    var hub_done = false;
    defer if (!hub_done) {
        stop.store(true, .release);
        hub_task.await(io) catch {};
    };

    var port_buf: [8]u8 = undefined;
    const port = try std.fmt.bufPrint(&port_buf, "{d}", .{hub.port()});
    var seed_buf: [24]u8 = undefined;
    const seed = try std.fmt.bufPrint(&seed_buf, "{d}", .{a.seed});
    var frames_buf: [12]u8 = undefined;
    const frames = try std.fmt.bufPrint(&frames_buf, "{d}", .{a.frames});

    var host = try spawnPeer(io, &.{ self_exe, "peer", "sim", "host", "--hub", port, "--seed", seed, "--frames", frames });
    var client = spawnPeer(io, &.{ self_exe, "peer", "sim", "client", "--hub", port, "--seed", seed, "--frames", frames }) catch |e| {
        host.kill(io);
        return e;
    };
    const host_ok = exitedOk(try host.wait(io));
    const client_ok = exitedOk(try client.wait(io));
    stop.store(true, .release);
    hub_done = true;
    try hub_task.await(io);

    for ([_]simnet.Side{ .a, .b }) |s| {
        const st = hub.net.linkStats(s);
        std.debug.print("sim {s}: sent {d}, delivered {d}, random losses {d}, reordered {d}, queue drops {d}\n", .{
            if (s == .a) "host->client" else "client->host", st.sent, st.delivered, st.random_losses, st.reordered, st.queue_drops,
        });
    }
    const lost = hub.net.linkStats(.a).random_losses + hub.net.linkStats(.b).random_losses;
    if (lost == 0) std.debug.print("sim: expected some random loss after warmup, saw none\n", .{});
    const ok = host_ok and client_ok and lost > 0;
    std.debug.print("gate over sim: {s}\n\n", .{if (ok) "pass" else "FAIL"});
    return ok;
}

fn runIroh(gpa: std.mem.Allocator, io: Io, self_exe: []const u8, a: Args) !bool {
    _ = gpa;
    std.debug.print("== gate over iroh, loopback, relays off (seed {d}, {d} frames) ==\n", .{ a.seed, a.frames });
    var name_buf: [64]u8 = undefined;
    const ticket_file = try std.fmt.bufPrint(&name_buf, ".gate-ticket-{d}", .{Io.Clock.awake.now(io).toNanoseconds()});
    Io.Dir.cwd().deleteFile(io, ticket_file) catch {};
    defer Io.Dir.cwd().deleteFile(io, ticket_file) catch {};

    var seed_buf: [24]u8 = undefined;
    const seed = try std.fmt.bufPrint(&seed_buf, "{d}", .{a.seed});
    var frames_buf: [12]u8 = undefined;
    const frames = try std.fmt.bufPrint(&frames_buf, "{d}", .{a.frames});
    var host = try spawnPeer(io, &.{ self_exe, "peer", "iroh", "host", "--ticket-file", ticket_file, "--seed", seed, "--frames", frames });
    var client = spawnPeer(io, &.{ self_exe, "peer", "iroh", "client", "--ticket-file", ticket_file, "--seed", seed, "--frames", frames }) catch |e| {
        host.kill(io);
        return e;
    };
    const client_ok = exitedOk(try client.wait(io));
    const host_ok = exitedOk(try host.wait(io));
    const ok = host_ok and client_ok;
    std.debug.print("gate over iroh: {s}\n\n", .{if (ok) "pass" else "FAIL"});
    return ok;
}

// --- peers ------------------------------------------------------------------

fn nowUs(io: Io) i64 {
    return Io.Clock.awake.now(io).toMicroseconds();
}

/// Drives a session on the wall clock until it ends, then prints its report.
fn drive(io: Io, s: *session.Session, clock: *const fn (Io) i64) bool {
    while (!s.done()) {
        const now = clock(io);
        s.step(now);
        const wait = s.nextWake(clock(io)) - clock(io);
        if (wait > 0) io.sleep(.fromMicroseconds(@min(wait, 1000)), .awake) catch {};
    }
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    s.report(&w) catch {};
    std.debug.print("{s}", .{w.buffered()});
    return s.outcome == .passed;
}

fn peerSim(gpa: std.mem.Allocator, io: Io, a: Args) !bool {
    if (a.hub_port == 0) return usage();
    const link = try gpa.create(simlink.Link);
    defer gpa.destroy(link);
    try link.init(gpa, io, a.hub_port, if (a.role == .host) .a else .b);
    defer link.deinit();
    var s = try session.Session.init(gpa, a.role, sessionConfig(a), link.packetPipe());
    defer s.deinit();
    return drive(io, &s, nowUs);
}

fn irohNowUs(_: Io) i64 {
    return @intCast(iroh.nowUs());
}

fn peerIroh(gpa: std.mem.Allocator, io: Io, a: Args) !bool {
    if (a.ticket_file.len == 0) return usage();
    iroh.init(null, null) catch |e| {
        std.debug.print("iroh init: {s}\n", .{iroh.lastError()});
        return e;
    };
    const ep = iroh.Endpoint.bind(.{
        .alpn = if (a.role == .host) alpn else "",
        .relay_mode = .disabled,
        .bind_addr = "127.0.0.1:0",
    }) catch |e| {
        std.debug.print("bind: {s}\n", .{iroh.lastError()});
        return e;
    };
    defer ep.deinit();

    const conn = switch (a.role) {
        .host => blk: {
            var tbuf: [4096]u8 = undefined;
            const t = try ep.ticket(&tbuf);
            // Write then rename, so the client never reads half a ticket.
            var tmp_buf: [256]u8 = undefined;
            const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{a.ticket_file});
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = t });
            try Io.Dir.rename(.cwd(), tmp, .cwd(), a.ticket_file, io);
            break :blk ep.accept(30_000) catch |e| {
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
            const tz = try gpa.dupeZ(u8, t);
            defer gpa.free(tz);
            break :blk ep.connect(tz, alpn, 30_000) catch |e| {
                std.debug.print("connect: {s}\n", .{iroh.lastError()});
                return e;
            };
        },
    };
    defer conn.deinit(0);
    var ip = iroh_pipe.IrohPipe.init(conn);
    var s = try session.Session.init(gpa, a.role, sessionConfig(a), ip.packetPipe());
    defer s.deinit();
    const ok = drive(io, &s, irohNowUs);
    // Let the last datagrams (the bye ack) leave before the connection closes.
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    return ok;
}
