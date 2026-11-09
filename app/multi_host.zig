//! Host side of a multi-user session: one capture and one encode, fanned out to N clients
//! (spec/multi-user-v0.md).
//!
//! Each client is a `HostSession` peer (`Config.shared`) with its own pipe, pacing, rate
//! estimate, NACK/FEC policy, stall handling, clock and input stream. The `MultiHost` owns
//! what there is one of:
//!
//! - Recovery (`core.recovery.Host`): a recovery request from any client makes the next
//!   frame a recovery frame for all of them. LTR acks go through `core.multi.AckJoin`, so
//!   the encoder only hears of a reference once every receiving client decoded it, and a
//!   refresh is decodable everywhere. A client that joins mid-stream asks for an IDR.
//! - The encoder bitrate: `core.multi.rate.combine` over the peers' estimates (lowest by
//!   default) through one ladder, bounded by the strictest peer's loss-policy caps.
//! - The roster and input policy (`core.multi.Roster`): only the input of members the
//!   policy allows reaches the injector; the rest is acked (so the clients stop resending
//!   it) and dropped. When input changes hands, keys and buttons the previous holder left
//!   down are released.
//! - The codec and format: one encode has one, so it is the best one every member decodes
//!   (`api.format.negotiateCommon` over the members' hellos, with `session.negotiate`).
//!   Each hello is held until the choice is made; a join, a leave or a member's new
//!   capabilities can change it, and then every member gets a new config, the app
//!   reconfigures the encoder (`takeFormat`) and the next frame is an IDR. A member whose
//!   decoder has nothing in common with the others is turned away; the others keep theirs.
//! - One control channel per peer (`core.control.Channel`, host role): the roster goes to
//!   every member that advertised the multi-user feature, on every change, and
//!   `input_request` / `input_give` come back. The app moves the channel's bytes (iroh
//!   stream, or the sim harness in app/multisim.zig).
//!
//! Sans-I/O like `HostSession`: `step(now)`, then `encodeParams` / `onEncoded` around each
//! encode, and `popAction` for the injector.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const pipe_mod = @import("pipe");
const host_session = @import("host_session.zig");
const apps = @import("apps.zig");

const HostSession = host_session.HostSession;
const multi = core.multi;
const recovery = core.recovery;
const rate = core.rate;
const Micros = i64;

pub const Config = struct {
    /// Settings every peer session gets (`shared` is set for them).
    session: host_session.Config,
    roster: multi.roster.Config = .{},
    rate: multi.rate.Config = .{},
    /// Intersect LTR acks across members (`core.multi.AckJoin`). Off only to show what
    /// goes wrong without it (a refresh against a reference one member never decoded).
    intersect_acks: bool = true,
};

pub const Stats = struct {
    frames: u64 = 0,
    keyframes: u64 = 0,
    refreshes: u64 = 0,
    encode_drops: u64 = 0,
    joins: u64 = 0,
    leaves: u64 = 0,
    /// Input actions from members whose input the policy does not apply.
    inputs_dropped: u64 = 0,
    inputs_applied: u64 = 0,
    /// Key/button releases injected for the previous holder on a handoff.
    releases: u64 = 0,
    rosters_sent: u64 = 0,
    control_malformed: u64 = 0,
    gives_refused: u64 = 0,
    /// Times the members' common format changed (the first pick counts when it is not the
    /// configured start), and members turned away for having none in common.
    format_changes: u64 = 0,
    format_refusals: u64 = 0,
};

pub const Peer = struct {
    s: HostSession,
    /// Roster id (0 once the member left).
    id: u16,
    bit: u5,
    /// The session control channel's `ups` when the roster last went out: a new channel
    /// (a reconnect) gets the roster again.
    ups_seen: u64 = 0,
    left: bool = false,
    roster_epoch_sent: ?u32 = null,
};

/// Keys and buttons a member holds down, so a handoff can release them.
const Held = struct {
    const max = 32;
    keys: [max]struct { button: bool, code: u16 } = undefined,
    n: u8 = 0,

    fn track(h: *Held, a: core.input.Action) void {
        const button, const code, const down = switch (a) {
            .key => |k| .{ false, k.code, k.down },
            .button => |b| .{ true, b.code, b.down },
            else => return,
        };
        for (h.keys[0..h.n], 0..) |k, i| if (k.button == button and k.code == code) {
            if (!down) {
                h.keys[i] = h.keys[h.n - 1];
                h.n -= 1;
            }
            return;
        };
        if (down and h.n < max) {
            h.keys[h.n] = .{ .button = button, .code = code };
            h.n += 1;
        }
    }
};

const Pending = struct { action: core.input.Action, time: Micros, from: u16 };

pub const MultiHost = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    peers: std.ArrayList(*Peer) = .empty,
    rec: *recovery.Host,
    join: *multi.AckJoin,
    roster: multi.Roster,
    ladder: rate.Ladder,
    limits: rate.ladder.Limits = .{},
    bitrate_bps: u64,
    pending_bitrate: u64 = 0,
    pending_reconfigure: ?rate.ladder.Rung = null,
    next_frame_id: u32 = 0,
    in_encoder: bool = false,
    /// The encoder's codec and format, and a change the app has not applied yet.
    codec: api.Codec,
    format: api.VideoFormat,
    pending_format: bool = false,
    /// A member left: the common format may be better now.
    renegotiate: bool = false,
    /// Members whose actions were applied last, and what they hold down.
    holder: u16 = multi.host_id,
    held: Held = .{},
    releases: std.Deque(core.input.Action) = .empty,
    actions: std.Deque(Pending) = .empty,
    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, cfg: Config) !MultiHost {
        const rec = try gpa.create(recovery.Host);
        errdefer gpa.destroy(rec);
        rec.* = recovery.Host.init(.{ .ltr = cfg.session.ltr });
        const join = try gpa.create(multi.AckJoin);
        join.* = .{};
        var c = cfg;
        c.session.shared = true;
        c.session.control.features |= multi.feature_bit;
        if (c.session.control.known.len == 0) c.session.control.known = &multi.known;
        return .{
            .gpa = gpa,
            .cfg = c,
            .rec = rec,
            .join = join,
            .roster = .init(cfg.roster),
            .ladder = .init(.{ .width = cfg.session.width, .height = cfg.session.height, .fps = cfg.session.fps }),
            .bitrate_bps = cfg.session.bitrate_bps,
            .codec = cfg.session.codec,
            .format = cfg.session.format,
        };
    }

    pub fn deinit(m: *MultiHost) void {
        for (m.peers.items) |p| {
            p.s.deinit();
            m.gpa.destroy(p);
        }
        m.peers.deinit(m.gpa);
        m.gpa.destroy(m.rec);
        m.gpa.destroy(m.join);
        m.actions.deinit(m.gpa);
        m.releases.deinit(m.gpa);
    }

    /// A client the host admitted (the allowlist said yes, and whether it may control).
    /// Returns its peer, or `error.Full` when the roster or the member masks are full.
    /// `control_stream` is the client's control stream (spec/control-v0.md), if it has one.
    pub fn addPeer(m: *MultiHost, p: pipe_mod.PacketPipe, control_stream: ?pipe_mod.ByteStream, name: []const u8, may_control: bool) !*Peer {
        const bit = m.freeBit() orelse return error.Full;
        const id = m.roster.join(name, may_control) orelse return error.Full;
        errdefer m.roster.leave(id);
        const peer = try m.gpa.create(Peer);
        errdefer m.gpa.destroy(peer);
        peer.* = .{
            .s = try HostSession.initPeer(m.gpa, m.cfg.session, p, m.rec, m.join, bit),
            .id = id,
            .bit = bit,
        };
        errdefer peer.s.deinit();
        if (!m.cfg.intersect_acks) peer.s.join = null;
        peer.s.next_frame_id = m.next_frame_id;
        peer.s.bitrate_bps = m.bitrate_bps;
        peer.s.codec = m.codec;
        peer.s.format = m.format;
        if (control_stream) |cs| try peer.s.control.attach(cs);
        try m.peers.append(m.gpa, peer);
        m.stats.joins += 1;
        return peer;
    }

    fn freeBit(m: *const MultiHost) ?u5 {
        var used: u32 = 0;
        for (m.peers.items) |p| if (!p.left) {
            used |= @as(u32, 1) << p.bit;
        };
        if (used == std.math.maxInt(u32)) return null;
        return @intCast(@ctz(~used));
    }

    /// Any member streaming: the encoder runs.
    pub fn streaming(m: *const MultiHost) bool {
        for (m.peers.items) |p| if (!p.left and p.s.streaming()) return true;
        return false;
    }

    /// Every member has left (and at least one joined).
    pub fn ended(m: *const MultiHost) bool {
        if (m.peers.items.len == 0) return false;
        for (m.peers.items) |p| if (!p.left) return false;
        return true;
    }

    /// End every member's session at once, failed (the encoder refused).
    pub fn abort(m: *MultiHost, why: []const u8) void {
        for (m.peers.items) |p| if (!p.left) p.s.abort(why);
    }

    pub fn close(m: *MultiHost, now: Micros) void {
        for (m.peers.items) |p| if (!p.left) p.s.close(now);
    }

    pub fn step(m: *MultiHost, now: Micros) void {
        for (m.peers.items) |p| {
            if (p.left) continue;
            p.s.step(now);
            m.pollControl(p);
            if (p.s.ended()) {
                m.onLeft(p);
                continue;
            }
            m.roster.setRelayed(p.id, p.s.path.relayed);
            m.takeInput(p);
        }
        m.negotiate(now);
        if (m.cfg.session.rate_control) m.updateRate(now);
        m.sendRosters();
        if (m.roster.owner != m.holder and m.cfg.roster.policy == .owner) m.handoff();
    }

    fn onLeft(m: *MultiHost, p: *Peer) void {
        p.left = true;
        m.join.remove(p.bit, if (m.next_frame_id > 0) m.next_frame_id -% 1 else null, m.rec);
        m.roster.leave(p.id);
        p.s.control.close();
        m.stats.leaves += 1;
        m.renegotiate = true;
    }

    // --- codec and format -----------------------------------------------

    /// Re-pick the codec and format when a hello came in or a member left, then answer the
    /// held hellos. Members already streaming count first; a newcomer (or a member whose
    /// new hello says it lost a format) with nothing in common with them is turned away.
    fn negotiate(m: *MultiHost, now: Micros) void {
        var hellos = false;
        for (m.peers.items) |p| if (!p.left and p.s.hello != null) {
            hellos = true;
        };
        if (!hellos and !m.renegotiate) return;
        m.renegotiate = false;

        var members: [multi.max_members]api.format.Member = undefined;
        var n: usize = 0;
        var choice: ?api.format.Choice = null;
        for ([_]bool{ false, true }) |newcomers| for (m.peers.items) |p| {
            if (p.left) continue;
            const c = p.s.client orelse continue;
            const is_new = p.s.hello != null and !p.s.streaming();
            if (is_new != newcomers) continue;
            members[n] = c;
            if (m.choose(members[0 .. n + 1])) |ch| {
                choice = ch;
                n += 1;
            } else {
                m.stats.format_refusals += 1;
                p.s.abort("no codec and format common with the other members");
                m.onLeft(p);
                m.renegotiate = false;
            }
        };
        if (choice) |ch| m.setFormat(@enumFromInt(ch.codec), ch.format, now);
        for (m.peers.items) |p| if (!p.left) p.s.answerHello(now);
    }

    /// The best codec and format for these members, or the fixed one if every member
    /// decodes it (`session.negotiate` null). Null: none.
    fn choose(m: *const MultiHost, members: []const api.format.Member) ?api.format.Choice {
        if (m.cfg.session.negotiate) |ng| return api.format.negotiateCommon(ng.preference, ng.encoder, members);
        const fixed: api.format.Choice = .{ .codec = @intFromEnum(m.cfg.session.codec), .format = m.cfg.session.format };
        for (members) |c| if (!c.dec.get(fixed.codec).supports(fixed.format)) return null;
        return fixed;
    }

    fn setFormat(m: *MultiHost, codec: api.Codec, fmt: api.VideoFormat, now: Micros) void {
        if (codec == m.codec and fmt.eql(m.format)) return;
        m.codec = codec;
        m.format = fmt;
        m.pending_format = true;
        m.stats.format_changes += 1;
        for (m.peers.items) |p| if (!p.left) {
            _ = p.s.setFormat(codec, fmt, now);
        };
        // A new sequence: everyone starts again from an IDR.
        if (m.next_frame_id > 0) m.rec.onRecoveryRequest(.{ .first_missing = m.next_frame_id, .want_idr = true });
    }

    /// The codec and format the members' hellos changed to, once: the app reconfigures the
    /// encoder before the next frame (which is an IDR).
    pub fn takeFormat(m: *MultiHost) ?host_session.FormatChange {
        if (!m.pending_format) return null;
        m.pending_format = false;
        return .{ .codec = m.codec, .format = m.format };
    }

    // --- control channel ------------------------------------------------

    fn pollControl(m: *MultiHost, p: *Peer) void {
        const c = &p.s.control;
        if (c.stats.ups != p.ups_seen) {
            p.ups_seen = c.stats.ups;
            p.roster_epoch_sent = null;
        }
        while (c.takeMessage()) |f| {
            defer c.gpa.free(f.body);
            switch (f.type) {
                multi.msg.input_request => {
                    const want = multi.msg.parseRequest(f.body) catch {
                        m.stats.control_malformed += 1;
                        continue;
                    };
                    m.roster.request(p.id, want);
                },
                multi.msg.input_give => {
                    const to = multi.msg.parseGive(f.body) catch {
                        m.stats.control_malformed += 1;
                        continue;
                    };
                    if (m.roster.give(p.id, to) != .ok) m.stats.gives_refused += 1;
                },
                else => {},
            }
        }
    }

    fn sendRosters(m: *MultiHost) void {
        var buf: [multi.msg.max_roster_len]u8 = undefined;
        for (m.peers.items) |p| {
            const c = &p.s.control;
            if (p.left or !c.up() or c.peer.?.features & multi.feature_bit == 0) continue;
            if (p.roster_epoch_sent) |e| if (e == m.roster.epoch) continue;
            const body = m.roster.encodeFor(p.id, &buf);
            c.send(.{ .type = multi.msg.roster, .body = body }, multi.feature_bit) catch continue;
            p.roster_epoch_sent = m.roster.epoch;
            m.stats.rosters_sent += 1;
        }
    }

    /// The host's own user hands input to member `to` (`multi.host_id`: takes it back).
    pub fn hostGive(m: *MultiHost, to: u16) multi.roster.GiveResult {
        return m.roster.hostGive(to);
    }

    // --- input ----------------------------------------------------------

    fn takeInput(m: *MultiHost, p: *Peer) void {
        while (p.s.popAction()) |a| {
            if (!m.roster.mayInput(p.id)) {
                m.stats.inputs_dropped += 1;
                continue;
            }
            m.actions.pushBack(m.gpa, .{ .action = a.action, .time = a.time, .from = p.id }) catch {};
        }
    }

    /// Input changed hands: release what the previous holder held down.
    fn handoff(m: *MultiHost) void {
        for (m.held.keys[0..m.held.n]) |k| {
            const a: core.input.Action = if (k.button) .{ .button = .{ .code = k.code, .down = false, .time = 0 } } else .{ .key = .{ .code = k.code, .down = false, .time = 0 } };
            m.releases.pushBack(m.gpa, a) catch {};
            m.stats.releases += 1;
        }
        m.held = .{};
        m.holder = m.roster.owner;
        // Actions queued from the old holder do not apply any more.
        var keep: std.Deque(Pending) = .empty;
        while (m.actions.popFront()) |a| if (m.roster.mayInput(a.from)) keep.pushBack(m.gpa, a) catch {} else {
            m.stats.inputs_dropped += 1;
        };
        m.actions.deinit(m.gpa);
        m.actions = keep;
    }

    /// The next input action to inject, with its client capture time (0 for releases).
    pub fn popAction(m: *MultiHost) ?struct { action: core.input.Action, time: Micros, from: u16 } {
        if (m.releases.popFront()) |a| return .{ .action = a, .time = 0, .from = multi.host_id };
        const p = m.actions.popFront() orelse return null;
        if (m.cfg.roster.policy == .owner) m.held.track(p.action);
        return .{ .action = p.action, .time = p.time, .from = p.from };
    }

    /// An action from member `from`, captured at its client's `client_time`, was injected.
    pub fn onInjected(m: *MultiHost, from: u16, client_time: Micros, now: Micros) void {
        m.stats.inputs_applied += 1;
        for (m.peers.items) |p| if (p.id == from and !p.left) return p.s.onInjected(client_time, now);
    }

    // --- rate -----------------------------------------------------------

    fn updateRate(m: *MultiHost, now: Micros) void {
        var est: [multi.max_members]u64 = undefined;
        var n: usize = 0;
        var lim: rate.ladder.Limits = m.limits;
        for (m.peers.items) |p| {
            if (p.left or !p.s.streaming()) continue;
            est[n] = @intFromFloat(@max(p.s.ctl.encoderBps(), 0));
            n += 1;
            // The strictest member's loss-policy caps bound everyone.
            if (p.s.decision) |d| {
                lim.max_bitrate_bps = minCap(lim.max_bitrate_bps, d.caps.max_bitrate_bps);
                lim.max_height = minCap(lim.max_height, d.caps.max_height);
                lim.fec_overhead = @max(lim.fec_overhead, d.overhead);
            }
        }
        const shared = multi.rate.combine(m.cfg.rate, est[0..n]) orelse return;
        const req = m.ladder.update(now, @floatFromInt(shared), lim);
        if (req.bitrate_bps != 0) {
            m.bitrate_bps = req.bitrate_bps;
            m.pending_bitrate = req.bitrate_bps;
            for (m.peers.items) |p| p.s.bitrate_bps = req.bitrate_bps;
        }
        if (req.reconfigure) |r| {
            m.pending_reconfigure = r;
            for (m.peers.items) |p| p.s.ctl.setFrameRate(@floatFromInt(r.fps));
        }
    }

    /// The tighter of two optional caps (null: none).
    fn minCap(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        const x = a orelse return b;
        const y = b orelse return a;
        return @min(x, y);
    }

    /// Caps for the ladder besides the members' loss-policy caps.
    pub fn setLimits(m: *MultiHost, l: rate.ladder.Limits) void {
        m.limits = l;
    }

    pub fn takeReconfigure(m: *MultiHost) ?rate.ladder.Rung {
        defer m.pending_reconfigure = null;
        return m.pending_reconfigure;
    }

    // --- encode stage ---------------------------------------------------

    pub fn encodeParams(m: *MultiHost) api.EncodeParams {
        std.debug.assert(!m.in_encoder);
        m.in_encoder = true;
        const d = m.rec.nextEncode();
        defer m.pending_bitrate = 0;
        return .{ .force = switch (d.force) {
            .none => .none,
            .ltr_refresh => .ltr_refresh,
            .idr => .idr,
        }, .acked_ltr_tokens = d.acked_tokens, .bitrate_bps = m.pending_bitrate };
    }

    pub fn onEncodeDropped(m: *MultiHost) void {
        std.debug.assert(m.in_encoder);
        m.in_encoder = false;
        m.rec.onEncodeDropped();
        m.stats.encode_drops += 1;
    }

    /// One encoded frame: stamp it once, send it to every streaming member.
    pub fn onEncoded(m: *MultiHost, ef: api.EncodedFrame, cf: *const api.CapturedFrame, now: Micros) void {
        std.debug.assert(m.in_encoder);
        m.in_encoder = false;
        if (!m.streaming()) {
            m.rec.onEncodeDropped();
            return;
        }
        const id = m.next_frame_id;
        const flags = m.rec.onEncoded(id, ef.ltr_token, ef.keyframe);
        m.next_frame_id +%= 1;
        var required: u32 = 0;
        var window: u32 = 0;
        for (m.peers.items) |p| {
            if (p.left) continue;
            if (p.s.streaming()) {
                required |= @as(u32, 1) << p.bit;
                _ = p.s.sendFrame(id, flags, ef, cf, now);
                window = @max(window, p.s.retryWindow());
            }
            p.s.next_frame_id = m.next_frame_id;
        }
        m.join.onEncoded(id, ef.ltr_token, required);
        // Copies of a request from the farthest member are still in flight for its RTT.
        m.rec.setRetryWindow(window);
        m.stats.frames += 1;
        if (flags.keyframe) m.stats.keyframes += 1;
        if (flags.refresh) m.stats.refreshes += 1;
    }

    /// Audio goes to every streaming member (for `apps.HostAudio.pump`).
    pub fn sendAudio(m: *MultiHost, kind: u8, payload: []const u8, now: Micros) void {
        for (m.peers.items) |p| if (!p.left) p.s.sendAudio(kind, payload, now);
    }

    pub fn report(m: *const MultiHost, w: *std.Io.Writer) !void {
        const st = m.stats;
        try w.print("multi host: {d} joined, {d} left; frames {d} (keyframes {d}, refreshes {d}); acks held {d}, released {d}; input applied {d}, dropped {d}, releases {d}; rosters sent {d}\n", .{ st.joins, st.leaves, st.frames, st.keyframes, st.refreshes, m.join.stats.held, m.join.stats.released, st.inputs_applied, st.inputs_dropped, st.releases, st.rosters_sent });
        for (m.peers.items) |p| {
            try w.print("  member {d}{s}: ", .{ p.id, if (p.left) " (left)" else "" });
            try p.s.report(w);
        }
    }
};

/// A `MultiHost` over a host platform backend: capture and encode once, network for every
/// member, input from the members the policy allows. `tick` runs it on the caller's thread
/// (the sim runs); `runThreadedWith` splits it as `apps.HostApp.runThreaded` does, the
/// network on the calling thread and capture+encode on their own.
pub const MultiHostApp = struct {
    be: api.HostBackend,
    m: MultiHost,
    opts: apps.HostOptions,
    size: api.Size,
    slices: u8,
    ltr: bool,
    last_frame_us: ?Micros = null,
    audio: ?*apps.HostAudio = null,
    /// The member whose action is being injected (the injector may ask).
    injecting_from: u16 = multi.host_id,
    stats: struct { capture_timeouts: u64 = 0, encode_errors: u64 = 0, inject_errors: u64 = 0, reconfigures: u64 = 0 } = .{},

    pub const Options = struct {
        roster: multi.roster.Config = .{},
        rate: multi.rate.Config = .{},
        intersect_acks: bool = true,
    };

    pub fn init(gpa: std.mem.Allocator, be: api.HostBackend, o: apps.HostOptions, mo: Options) !MultiHostApp {
        const size = try be.capture.start(.{ .display = o.display, .fps = o.fps, .width = o.width, .height = o.height, .hdr = o.hdr });
        errdefer be.capture.stop();
        const caps = be.encoder.caps();
        if (!caps.codecs.has(o.codec)) return error.Unsupported;
        const slices = @min(o.slices, caps.max_slices);
        try be.encoder.configure(.{ .codec = o.codec, .width = size.width, .height = size.height, .fps = o.fps, .bitrate_bps = o.bitrate_bps, .slices = slices, .ltr = caps.ltr });
        // As `apps.HostApp`: the host's codec first, then HEVC, H.264, AV1.
        var order: api.format.Order = .{};
        for ([_]api.Codec{ o.codec, .hevc, .h264, .av1, .passthrough }) |c| {
            if (caps.codecs.has(c)) order.add(@intFromEnum(c));
        }
        var m = try MultiHost.init(gpa, .{
            .session = .{
                .negotiate = .{
                    .encoder = api.effectiveFormats(caps.codecs, caps.coded),
                    .preference = .{
                        .codecs = order,
                        .yuv444 = o.yuv444,
                        .ten_bit = o.ten_bit,
                        .hdr = o.hdr,
                        .source_is_hdr = size.color == .hdr10,
                        .source_hdr = size.hdr,
                    },
                },
                .codec = o.codec,
                .width = size.width,
                .height = size.height,
                .fps = o.fps,
                .bitrate_bps = o.bitrate_bps,
                .slices = slices,
                .ltr = caps.ltr,
                .pace = o.session.pace,
                .rate_control = o.session.rate_control,
                .peer_timeout_us = o.session.peer_timeout_us,
                .loss_policy = o.session.loss_policy,
                .pause_on_stall = o.pause_on_stall,
            },
            .roster = mo.roster,
            .rate = mo.rate,
            .intersect_acks = mo.intersect_acks,
        });
        errdefer m.deinit();
        var app: MultiHostApp = .{ .be = be, .m = m, .opts = o, .size = size, .slices = slices, .ltr = caps.ltr };
        if (o.audio) if (be.audio) |src| {
            app.audio = try apps.HostAudio.init(gpa, src);
        };
        return app;
    }

    pub fn deinit(a: *MultiHostApp) void {
        a.be.capture.stop();
        if (a.audio) |au| au.deinit();
        a.m.deinit();
    }

    /// Network stage: every member's session, audio, input. With the lock held.
    fn network(a: *MultiHostApp, now: Micros) void {
        a.m.step(now);
        if (a.audio) |au| au.pump(&a.m, now);
        while (a.m.popAction()) |p| {
            a.injecting_from = p.from;
            if (a.be.input) |inj| inj.inject(p.action) catch {
                a.stats.inject_errors += 1;
            };
            a.injecting_from = multi.host_id;
            a.m.onInjected(p.from, p.time, a.be.clock.now());
        }
    }

    pub fn tick(a: *MultiHostApp) void {
        a.network(a.be.clock.now());
        if (!a.m.streaming()) return;
        const f = (a.grab(0) catch return) orelse return;
        defer a.be.capture.release(&f);
        a.encodeOne(&f, null);
    }

    /// One encode of a captured frame; the lock, if any, is taken around the session calls.
    fn encodeOne(a: *MultiHostApp, f: *const api.CapturedFrame, lock: ?apps.Lock) void {
        if (lock) |l| l.lock();
        const live = a.m.streaming();
        const change = if (live) a.m.takeFormat() else null;
        const bitrate = a.m.bitrate_bps;
        const params = if (live) a.m.encodeParams() else api.EncodeParams{};
        if (lock) |l| l.unlock();
        if (!live) return;
        if (change) |c| {
            a.be.encoder.configure(.{
                .codec = c.codec,
                .format = c.format,
                .width = f.image.width,
                .height = f.image.height,
                .fps = a.opts.fps,
                .bitrate_bps = bitrate,
                .slices = a.slices,
                .ltr = a.ltr,
            }) catch {
                // Negotiation only picks what the encoder's caps offer; a refusal is the
                // backend's bug, and every member would get frames its config does not name.
                if (lock) |l| l.lock();
                defer if (lock) |l| l.unlock();
                a.stats.encode_errors += 1;
                a.m.onEncodeDropped();
                a.m.abort("the encoder rejected the members' common codec or format");
                return;
            };
            a.stats.reconfigures += 1;
        }
        const r = a.be.encoder.encode(f, params);
        if (lock) |l| l.lock();
        defer if (lock) |l| l.unlock();
        if (r) |ef_| {
            if (ef_) |ef| {
                a.m.onEncoded(ef, f, a.be.clock.now());
                a.last_frame_us = f.captured_us;
            } else a.m.onEncodeDropped();
        } else |_| {
            a.stats.encode_errors += 1;
            a.m.onEncodeDropped();
        }
    }

    /// Network on this thread, capture+encode on their own, until `stop` is set or every
    /// member has left (members may still join meanwhile: `addPeer` under the lock).
    /// `hook` runs under the lock after every network step.
    pub fn runThreadedWith(a: *MultiHostApp, io: std.Io, lock: apps.Lock, hook: ?apps.Hook, stop: *std.atomic.Value(bool)) !void {
        var media_stop: std.atomic.Value(bool) = .init(false);
        var media = try io.concurrent(mediaLoop, .{ a, lock, &media_stop });
        defer {
            media_stop.store(true, .release);
            media.await(io);
        }
        while (true) {
            lock.lock();
            a.network(a.be.clock.now());
            if (hook) |h| h.f(h.ctx);
            const finished = a.m.ended() or stop.load(.acquire);
            lock.unlock();
            if (finished) return;
            io.sleep(.fromMicroseconds(1000), .awake) catch {};
        }
    }

    fn mediaLoop(a: *MultiHostApp, lock: apps.Lock, stop: *std.atomic.Value(bool)) void {
        const interval = @divTrunc(1_000_000, @as(Micros, a.opts.fps));
        while (!stop.load(.acquire)) {
            lock.lock();
            const live = a.m.streaming();
            lock.unlock();
            if (!live) {
                lock.io.sleep(.fromMilliseconds(2), .awake) catch {};
                continue;
            }
            const f = (a.grab(interval) catch {
                lock.io.sleep(.fromMilliseconds(2), .awake) catch {};
                continue;
            }) orelse continue;
            a.encodeOne(&f, lock);
            a.be.capture.release(&f);
        }
    }

    fn grab(a: *MultiHostApp, timeout_us: Micros) api.Error!?api.CapturedFrame {
        if (try a.be.capture.acquire(timeout_us)) |f| return f;
        a.stats.capture_timeouts += 1;
        const last = a.last_frame_us orelse return null;
        if (a.be.clock.now() - last < a.opts.repeat_after_us) return null;
        return a.be.capture.repeatLast();
    }

    pub fn done(a: *const MultiHostApp) bool {
        return a.m.ended();
    }
};
