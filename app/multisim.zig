//! A multi-user session over the in-process sim, in virtual time: one host (`MultiHostApp`
//! on the synthetic backend) and N synthetic clients, each on its own simulated path with
//! its own profile. Clients can join late and leave early, and scripted control-channel
//! events (input requests and handoffs) run between the host's and the clients' control
//! channels, which this harness connects back to back (reliable and in order, like the
//! QUIC stream they stand in for).
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const simnet = @import("simnet");
const synthetic = @import("synthetic");
const pipe_mod = @import("pipe");
const apps = @import("apps.zig");
const simrun = @import("simrun.zig");
const multi_host = @import("multi_host.zig");

const multi = core.multi;
const control = core.control;
const Micros = i64;

pub const ClientSpec = struct {
    name: []const u8 = "client",
    profile: simrun.Profile = .lan,
    /// Random loss in each direction instead of the profile's.
    loss: ?f64 = null,
    /// Bottleneck capacity instead of the profile's.
    bps: ?f64 = null,
    /// The path goes through a relay: 25 ms each way and `relayed` in the path stats.
    relayed: bool = false,
    may_control: bool = true,
    /// Advertise the multi-user feature on the control channel (an older client does not).
    multi_user: bool = true,
    join_at_us: Micros = 0,
    leave_at_us: ?Micros = null,
};

pub const Event = union(enum) {
    /// Client `client` asks for input.
    request: struct { at_us: Micros, client: usize },
    /// Client `from` (the owner) hands input to client `to`.
    give: struct { at_us: Micros, from: usize, to: usize },
    /// The host's user takes input back.
    host_take: struct { at_us: Micros },

    fn at(e: Event) Micros {
        return switch (e) {
            inline else => |x| x.at_us,
        };
    }
};

pub const Options = struct {
    seed: u64 = 1,
    seconds: u32 = 4,
    fps: u32 = 60,
    bitrate_bps: u64 = 10_000_000,
    width: u32 = 320,
    height: u32 = 180,
    slices: u8 = 4,
    step_us: Micros = 250,
    warmup_us: Micros = 300_000,
    input_interval_us: Micros = 25_000,
    audio: bool = false,
    rate_control: bool = false,
    loss_policy: bool = false,
    clients: []const ClientSpec,
    events: []const Event = &.{},
    roster: multi.roster.Config = .{},
    rate: multi.rate.Config = .{},
    intersect_acks: bool = true,
};

pub const ClientResult = struct {
    joined: bool = false,
    presented: u64 = 0,
    lost: u64 = 0,
    freezes: u64 = 0,
    longest_gap_us: Micros = 0,
    corrupt: u64 = 0,
    missing_ref: u64 = 0,
    unreadable: u64 = 0,
    input_sent: u64 = 0,
    retransmits: u64 = 0,
    parity_shards: u64 = 0,
    end: []const u8 = "",
    /// From the client's roster view at the end of the run, before anyone left; the most
    /// members any roster listed.
    have_input: bool = false,
    members_seen: u8 = 0,
    rosters: u64 = 0,
    presence: [80]u8 = undefined,
    presence_len: u8 = 0,

    pub fn presenceText(c: *const ClientResult) []const u8 {
        return c.presence[0..c.presence_len];
    }
};

pub const Result = struct {
    seconds: u32,
    host: struct {
        frames: u64,
        keyframes: u64,
        refreshes: u64,
        keys: u64,
        keys_wrong: u64,
        inputs_applied: u64,
        inputs_dropped: u64,
        releases: u64,
        acks_held: u64,
        acks_released: u64,
        joins: u64,
        leaves: u64,
        bitrate_bps: u64,
    },
    clients: [multi.max_members]ClientResult,
    n: usize,

    pub fn client(r: *const Result, i: usize) *const ClientResult {
        return &r.clients[i];
    }

    pub fn print(r: *const Result, w: *std.Io.Writer) !void {
        const h = r.host;
        try w.print("{d} s, {d} clients: host sent {d} frames (keyframes {d}, refreshes {d}), bitrate {d} kbit/s; acks held {d}, released {d}; input applied {d}, dropped {d}, releases {d}; keys {d} (wrong {d}); joins {d}, leaves {d}\n", .{ r.seconds, r.n, h.frames, h.keyframes, h.refreshes, h.bitrate_bps / 1000, h.acks_held, h.acks_released, h.inputs_applied, h.inputs_dropped, h.releases, h.keys, h.keys_wrong, h.joins, h.leaves });
        for (r.clients[0..r.n], 0..) |c, i| try w.print("  client {d}: presented {d}, lost {d}, freezes {d}, longest gap {d:.1} ms, corrupt {d} (missing ref {d}), unreadable {d}, retransmits {d}, parity {d}; {s}; \"{s}\"\n", .{ i, c.presented, c.lost, c.freezes, @as(f64, @floatFromInt(c.longest_gap_us)) / 1000, c.corrupt, c.missing_ref, c.unreadable, c.retransmits, c.parity_shards, c.end, c.presence[0..c.presence_len] });
    }
};

/// Reports a relayed path on top of a sim pipe.
const RelayedPipe = struct {
    inner: pipe_mod.PacketPipe,

    fn send(p: *anyopaque, d: []const u8) pipe_mod.SendError!void {
        return self(p).inner.send(d);
    }
    fn recv(p: *anyopaque, b: []u8) pipe_mod.RecvError!?pipe_mod.Received {
        return self(p).inner.recv(b);
    }
    fn setPacingRate(p: *anyopaque, bps: u64) void {
        self(p).inner.setPacingRate(bps);
    }
    fn stats(p: *anyopaque) pipe_mod.PathStats {
        var s = self(p).inner.stats();
        s.relayed = true;
        return s;
    }
    fn maxDatagramSize(p: *anyopaque) usize {
        return self(p).inner.maxDatagramSize();
    }
    fn self(p: *anyopaque) *RelayedPipe {
        return @ptrCast(@alignCast(p));
    }
    const vtable = pipe_mod.PacketPipe.VTable{ .send = send, .recv = recv, .setPacingRate = setPacingRate, .stats = stats, .maxDatagramSize = maxDatagramSize };

    fn pipe(r: *RelayedPipe) pipe_mod.PacketPipe {
        return .{ .ptr = r, .vtable = &vtable };
    }
};

const SideClock = struct {
    net: *simnet.Net,
    side: simnet.Side,

    fn now(p: ?*anyopaque) Micros {
        const c: *SideClock = @ptrCast(@alignCast(p.?));
        return c.net.localTime(c.side);
    }

    fn clock(c: *SideClock) api.Clock {
        return .{ .ptr = c, .nowFn = now };
    }
};

fn patternContent(ctx: ?*anyopaque, _: *const api.DecodedFrame) u64 {
    const c: *synthetic.Client = @ptrCast(@alignCast(ctx.?));
    return if (c.presenter.last_stamp) |s| s.frame else 0;
}

/// One client: its network, backend, app, control channel and roster view.
const Slot = struct {
    spec: ClientSpec,
    net: simnet.Net,
    hclock: SideClock,
    cclock: SideClock,
    relay: [2]RelayedPipe,
    loss: f64,
    steps: [1]simnet.Step = undefined,
    sc: ?*synthetic.Client = null,
    app: ?apps.ClientApp = null,
    peer: ?*multi_host.Peer = null,
    ctl: ?control.Channel = null,
    view: multi.View = .{},
    closing: bool = false,
    /// The roster view just before the run's end (before anyone leaves), and the most
    /// members it ever listed.
    snap: ?multi.View = null,
    most_members: u8 = 0,

    fn pipeFor(s: *Slot, side: simnet.Side) pipe_mod.PacketPipe {
        if (!s.spec.relayed) return s.net.pipeFor(side);
        return s.relay[@intFromEnum(side)].pipe();
    }

    fn done(s: *const Slot) bool {
        const a = s.app orelse return true;
        return a.done();
    }
};

pub fn run(gpa: std.mem.Allocator, o: Options, log: ?*std.Io.Writer) !Result {
    std.debug.assert(o.clients.len >= 1 and o.clients.len <= multi.max_members);
    const slots = try gpa.alloc(Slot, o.clients.len);
    defer gpa.free(slots);
    var inited: usize = 0;
    defer for (slots[0..inited]) |*s| s.net.deinit();
    for (slots, o.clients, 0..) |*s, spec, i| {
        s.* = .{ .spec = spec, .net = undefined, .hclock = undefined, .cclock = undefined, .relay = undefined, .loss = 0 };
        var l = spec.profile.link();
        if (spec.bps) |b| {
            s.steps = .{.{ .t_us = 0, .bps = b }};
            l.steps = &s.steps;
        }
        if (spec.relayed) l.delay_us = 25 * simnet.MS;
        var cfg: simnet.Config = .{ .seed = o.seed *% 1000 +% i, .a_to_b = l, .b_to_a = l };
        cfg.b.clock_offset_us = 3_217_000_000 + @as(Micros, @intCast(i)) * 11_000_000;
        s.loss = spec.loss orelse l.loss;
        cfg.a_to_b.loss = 0;
        cfg.b_to_a.loss = 0;
        try s.net.init(gpa, cfg);
        inited += 1;
        s.hclock = .{ .net = &s.net, .side = .a };
        s.cclock = .{ .net = &s.net, .side = .b };
        s.relay = .{ .{ .inner = s.net.pipeFor(.a) }, .{ .inner = s.net.pipeFor(.b) } };
    }

    // The host's clock is the host side of the first path (every path's host side reads the
    // same simulated time: all are advanced together and the host has no offset).
    const sh = try synthetic.openHost(gpa, .{ .clock = slots[0].hclock.clock(), .width = o.width, .height = o.height, .audio = o.audio });
    const hb = sh.backend();
    defer hb.deinit();
    var host = try multi_host.MultiHostApp.init(gpa, hb, .{
        .fps = o.fps,
        .bitrate_bps = o.bitrate_bps,
        .slices = o.slices,
        .audio = o.audio,
        .session = .{ .rate_control = o.rate_control, .loss_policy = o.loss_policy },
    }, .{ .roster = o.roster, .rate = o.rate, .intersect_acks = o.intersect_acks });
    defer host.deinit();
    defer for (slots) |*s| {
        if (s.app) |*a| a.deinit();
        if (s.ctl) |*c| c.deinit();
        if (s.sc) |sc| sc.backend().deinit();
    };

    const end_us: Micros = @as(Micros, o.seconds) * simnet.SEC;
    var t: Micros = 0;
    var loss_on = false;
    var next_event: usize = 0;
    var buf: [128]u8 = undefined;
    var snapped = false;
    while (true) : (t += o.step_us) {
        if (t > end_us + 30 * simnet.SEC) return error.Hung;
        if (!snapped and t >= end_us) {
            for (slots) |*s| s.snap = s.view;
            snapped = true;
        }
        if (!loss_on and t >= o.warmup_us) {
            for (slots) |*s| for (&s.net.links) |*l| {
                l.cfg.loss = s.loss;
            };
            loss_on = true;
        }
        for (slots, 0..) |*s, i| {
            if (s.app == null and t >= s.spec.join_at_us and t < end_us) {
                const sc = try synthetic.openClient(gpa, .{ .clock = s.cclock.clock(), .input_interval_us = o.input_interval_us, .audio = o.audio });
                s.sc = sc;
                s.app = try apps.ClientApp.init(gpa, sc.backend(), .{ .content_ctx = sc, .contentFn = patternContent, .audio = o.audio, .session = .{ .nonce = @intCast(i + 1) } }, s.pipeFor(.b));
                s.peer = try host.m.addPeer(s.pipeFor(.a), s.spec.name, s.spec.may_control);
                s.ctl = try control.Channel.init(gpa, .{ .role = .client, .features = if (s.spec.multi_user) multi.feature_bit else 0, .known = &multi.known }, null);
            }
            if (s.app) |*a| if (!s.closing) {
                const leave = s.spec.leave_at_us orelse end_us;
                if (t >= @min(leave, end_us)) {
                    a.s.close(s.net.localTime(.b));
                    s.closing = true;
                }
            };
        }
        while (next_event < o.events.len and o.events[next_event].at() <= t) : (next_event += 1) {
            switch (o.events[next_event]) {
                .request => |e| if (slots[e.client].ctl) |*c| {
                    c.send(.{ .type = multi.msg.input_request, .body = &multi.msg.encodeRequest(true) }, multi.feature_bit) catch {};
                },
                .give => |e| if (slots[e.from].ctl) |*c| {
                    const to = slots[e.to].view.you;
                    c.send(.{ .type = multi.msg.input_give, .body = &multi.msg.encodeGive(to) }, multi.feature_bit) catch {};
                },
                .host_take => _ = host.m.hostGive(multi.host_id),
            }
        }
        for (slots) |*s| try s.net.runUntil(t);
        // Control channels, back to back.
        for (slots) |*s| {
            const c = if (s.ctl) |*c| c else continue;
            const p = s.peer.?;
            if (p.ctl.pending().len > 0) {
                try c.receive(p.ctl.pending());
                p.ctl.consume(p.ctl.pending().len);
            }
            if (c.pending().len > 0) {
                try p.ctl.receive(c.pending());
                c.consume(c.pending().len);
            }
        }
        host.tick();
        var all_done = host.done();
        for (slots) |*s| {
            if (s.app) |*a| {
                a.tick();
                if (s.ctl) |*c| while (c.poll() catch null) |ev| switch (ev) {
                    .message => |f| if (f.type == multi.msg.roster) {
                        s.view.onRoster(f.body);
                        s.most_members = @max(s.most_members, s.view.len);
                        a.setPresence(s.view.presence(&buf));
                    },
                    else => {},
                };
            }
            if (!s.done()) all_done = false;
        }
        if (t >= end_us and all_done) break;
        // Members that never joined (join time past the end) do not hold the run open.
        if (t >= end_us and host.m.peers.items.len == 0) break;
    }

    var r: Result = .{
        .seconds = o.seconds,
        .host = .{
            .frames = host.m.stats.frames,
            .keyframes = host.m.stats.keyframes,
            .refreshes = host.m.stats.refreshes,
            .keys = sh.injector.keys,
            .keys_wrong = sh.injector.wrong,
            .inputs_applied = host.m.stats.inputs_applied,
            .inputs_dropped = host.m.stats.inputs_dropped,
            .releases = host.m.stats.releases,
            .acks_held = host.m.join.stats.held,
            .acks_released = host.m.join.stats.released,
            .joins = host.m.stats.joins,
            .leaves = host.m.stats.leaves,
            .bitrate_bps = host.m.bitrate_bps,
        },
        .clients = undefined,
        .n = slots.len,
    };
    for (slots, 0..) |*s, i| {
        var c: ClientResult = .{};
        if (s.app) |*a| {
            a.s.freeze.finish(a.s.freeze.last_new_us orelse 0);
            const fz = a.s.freeze.stats;
            const sc = s.sc.?;
            const ps = s.peer.?.s.stats;
            c = .{
                .joined = true,
                .presented = a.s.stats.frames_presented,
                .lost = a.s.stats.frames_lost,
                .freezes = fz.freezes,
                .longest_gap_us = fz.longest_gap_us,
                .corrupt = sc.decoder.stats.corrupt,
                .missing_ref = sc.decoder.stats.missing_ref,
                .unreadable = sc.presenter.stats.unreadable,
                .input_sent = sc.input.sent,
                .retransmits = ps.retransmits,
                .parity_shards = ps.parity_shards,
                .end = @tagName(a.s.end),
                .have_input = if (s.snap) |v| v.haveInput() else false,
                .members_seen = s.most_members,
                .rosters = s.view.stats.rosters,
            };
            const v = s.snap orelse s.view;
            const p = v.presence(&c.presence);
            c.presence_len = @intCast(p.len);
        }
        r.clients[i] = c;
    }
    if (log) |w| {
        try r.print(w);
        try host.m.report(w);
    }
    return r;
}
