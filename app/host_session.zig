//! Host side of a streaming session: the network stage of the host app.
//!
//! Sans-I/O like the core. `step(now)` drains the pipe and runs timers; the app's
//! capture/encode stage calls `encodeParams` before each encode and `onEncoded` (or
//! `onEncodeDropped`) after, and the input stage takes actions with `popAction`. Under
//! threads the app holds one lock around every call; capture and encode run outside it.
//!
//! Host to client: video shards (packetized frames, NACKed shards resent from history),
//! config, clock pongs, input acks, bye. Client to host: hello, transport feedback (to the
//! rate controller, which sets pacing), NACKs, frame acks (to core/recovery), clock pings
//! and reports, input events, bye.
//!
//! With `loss_policy` on, `core.media.Policy` picks the loss recovery per path: NACK on
//! short RTTs, Reed-Solomon parity sized from transport-feedback loss on long ones, and
//! relay mode (no FEC, caps for the rate ladder) on relayed paths. `lossDecision` is the
//! current choice. Off, every NACK is answered and no parity is sent (Phase 2).
//!
//! Path changes and drops (Phase 3): when the pipe reports the selected path stalled (no
//! ack progress), video stops going out, since it would only be lost or queue up stale
//! behind a dead path; when acks resume or the path changes, the next frame is a recovery
//! frame. A path change also restarts the rate controller's delay and capacity estimates,
//! and a new connection (a reconnecting pipe's `conn_epoch`) gets the pacing rate again.
//! With a pipe that can reconnect, silence ends the session only after
//! `reconnect_timeout_us`, so the client has time to come back.
//!
//! Phase 2 runs at a fixed encoder bitrate. The rate controller still runs on the client's
//! feedback for pacing and the overlay: the pipe paces at its rate, but never below
//! `pace_floor` × the bitrate, so a frame always leaves faster than the encoder makes it.
//!
//! With `rate_control` (Phase 3) the controller drives the encoder through the ladder
//! (core/rate/ladder.zig): bitrate changes go out in `EncodeParams.bitrate_bps`, and
//! resolution or frame-rate steps wait in `takeReconfigure` for the app to apply with
//! `Encoder.configure`. With `loss_policy`, relay mode's caps and the FEC share bound it (`setLimits` otherwise). Every frame also goes
//! through `Controller.onFrame`, so probe frames leave at the probe rate.
//!
//! Multi-user (app/multi_host.zig): with `shared`, the session is one client's peer of a
//! `MultiHost` that owns the encoder side. The peer keeps its own pipe, pacing, rate
//! estimate, NACK/FEC policy, stall handling and input stream; recovery (`rec`) is the
//! multi host's, acks go through its `AckJoin`, and frames arrive through `sendFrame`.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const pipe_mod = @import("pipe");
const wire = @import("wire.zig");
const control = @import("control.zig");
const pathlog = @import("pathlog.zig");

const proto = core.proto;
const media = core.media;
const rate = core.rate;
const recovery = core.recovery;
const telemetry = core.telemetry;
const clock = core.clock;
const PacketPipe = pipe_mod.PacketPipe;
const Micros = i64;

pub const Config = struct {
    /// The codec and format to stream, and the encoder is configured with. With
    /// `negotiate`, only the start: each hello picks them anew.
    codec: api.Codec = .passthrough,
    format: api.VideoFormat = .{},
    /// Pick codec and format per client from the encoder's caps, the hello and the host's
    /// preferences (platform/format.zig). Null: `codec` and `format` are fixed, and a
    /// client that cannot decode them is turned away.
    negotiate: ?Negotiate = null,
    width: u32,
    height: u32,
    fps: u32 = 60,
    bitrate_bps: u64 = 10_000_000,
    slices: u8 = 4,
    /// The encoder has long-term references (`EncoderCaps.ltr`).
    ltr: bool = true,
    /// Apply a pacing rate to the pipe.
    pace: bool = true,
    /// Drive the encoder bitrate from the rate controller through the ladder, starting
    /// at `bitrate_bps`. Off: `bitrate_bps` is fixed, as in Phase 2.
    rate_control: bool = false,
    /// The pipe never paces below this × the encoder bitrate: a frame then takes at most
    /// 1/pace_floor of a frame interval to leave. The controller's rate (link capacity
    /// from frame trains) is used when it is higher.
    pace_floor: f64 = 4.0,
    /// Shards kept for retransmission, by age.
    retransmit_age_us: u64 = 250_000,
    /// A shard is resent at most once per this long, however many NACKs name it: after an
    /// outage the NACKs repeat every RTT while the resends are still queued in the pacer.
    retransmit_interval_us: u64 = 20_000,
    /// Choose NACK, FEC or relay mode per path (`core.media.policy`).
    loss_policy: bool = false,
    policy: media.policy.Config = .{},
    /// End the session when nothing arrives from the client for this long.
    peer_timeout_us: Micros = 5_000_000,
    /// ...or this long when the pipe can reconnect (the client redials after a drop).
    reconnect_timeout_us: Micros = 60_000_000,
    /// Hold video while the pipe reports the selected path stalled, and send a recovery
    /// frame when it recovers (see the file comment).
    pause_on_stall: bool = true,
    /// A stall reported this soon after a path change is the new path's backlog of probes
    /// and keep-alives (S5c lab: ~90 ms after a switch to the relay), not a dead path.
    stall_grace_us: Micros = 250_000,
    /// Byes sent when leaving, `bye_interval_us` apart.
    byes: u8 = 3,
    bye_interval_us: Micros = 20_000,
    /// One client's peer of a `MultiHost` (see the file comment): `rec` is shared and not
    /// owned, frame acks go through `join`, the multi host runs the ladder and the encoder.
    shared: bool = false,
    /// The reliable control channel (spec/control-v0.md): clipboard and the features built
    /// on it. It runs once the app attaches a stream (`control.attach`).
    control: control.Config = .{},
};

pub const Negotiate = struct {
    /// What the encoder offers (`api.effectiveFormats` of its caps).
    encoder: api.FormatCaps,
    preference: api.format.Preference,
};

/// A codec and format for the app to configure the encoder with (`takeFormat`).
pub const FormatChange = struct { codec: api.Codec, format: api.VideoFormat };

pub const State = enum { waiting, streaming, ended };

pub const End = enum { none, client_bye, peer_timeout, pipe_closed, closed, failed };

pub const Stats = struct {
    frames: u64 = 0,
    keyframes: u64 = 0,
    refreshes: u64 = 0,
    encode_drops: u64 = 0,
    repeats: u64 = 0,
    bytes: u64 = 0,
    shards: u64 = 0,
    parity_shards: u64 = 0,
    nacks: u64 = 0,
    /// NACKs not answered because the policy said FEC only.
    nacks_ignored: u64 = 0,
    retransmits: u64 = 0,
    feedback: u64 = 0,
    frame_acks: u64 = 0,
    recovery_requests: u64 = 0,
    pings: u64 = 0,
    inputs_applied: u64 = 0,
    /// Input events dropped because the device lacks the input permission.
    inputs_denied: u64 = 0,
    hellos: u64 = 0,
    sessions: u64 = 0,
    /// Times a hello changed the codec or format.
    format_changes: u64 = 0,
    /// The pipe's selected path changed / its connection was replaced.
    path_changes: u64 = 0,
    reconnects: u64 = 0,
    /// Times video was held for a stalled path, and the frames not sent meanwhile.
    stall_pauses: u64 = 0,
    stall_frames: u64 = 0,
    /// Longest hold, us.
    stall_longest_us: Micros = 0,
    malformed: u64 = 0,
    unknown: u64 = 0,
};

const Pending = struct { action: core.input.Action, time: Micros };

pub const HostSession = struct {
    gpa: std.mem.Allocator,
    /// The control channel; the app attaches its stream and feeds the clipboard.
    control: control.Control,
    cfg: Config,
    pipe: PacketPipe,
    state: State = .waiting,
    end: End = .none,
    reason: []const u8 = "",
    stats: Stats = .{},
    path: pipe_mod.PathStats = .{},

    seq: u64 = 0,
    nonce: ?u32 = null,
    last_rx_us: ?Micros = null,
    next_frame_id: u32 = 0,
    in_encoder: bool = false,
    byes_left: u8 = 0,
    next_bye: Micros = 0,
    last_pacing: u64 = 0,
    /// Host minus client clock, from the client's reports.
    offset: ?Micros = null,

    /// Path and connection the pipe last reported (null until the first stats).
    path_epoch: ?u32 = null,
    conn_epoch: u32 = 0,
    /// Video held for a stalled path since this time; the first frame not sent.
    paused_at: ?Micros = null,
    paused_from: ?u32 = null,
    log: pathlog.Log = .{},
    path_changed_at: ?Micros = null,

    packetizer: media.Packetizer = .{},
    parity_buf: *media.ParityBuffer,
    policy: media.Policy,
    decision: ?media.policy.Decision = null,
    history: media.History,
    ctl: *rate.Controller,
    ladder: rate.Ladder,
    limits: rate.ladder.Limits = .{},
    /// The encoder's bitrate now, and a change not yet handed to it.
    bitrate_bps: u64,
    pending_bitrate: u64 = 0,
    pending_reconfigure: ?rate.ladder.Rung = null,
    /// The codec and format being streamed (and named in config), and a change the
    /// encoder has not been configured with yet.
    codec: api.Codec,
    format: api.VideoFormat,
    pending_format: bool = false,
    /// With `cfg.shared`: what the client's last hello said it decodes and shows, and that
    /// hello, held until the multi host has picked the format every member can take
    /// (`setFormat`, then `answerHello`).
    client: ?api.format.Member = null,
    hello: ?wire.Hello = null,
    rec: *recovery.Host,
    input_rx: core.input.Receiver = .{},
    actions: std.Deque(Pending) = .empty,
    tele: *telemetry.Telemetry(512),
    /// With `cfg.shared`: the multi host's ack intersection and this peer's member bit.
    join: ?*core.multi.AckJoin = null,
    join_bit: u5 = 0,

    pub fn init(gpa: std.mem.Allocator, cfg: Config, p: PacketPipe) !HostSession {
        return initWith(gpa, cfg, p, null);
    }

    /// A `shared` peer: recovery is the multi host's `rec`.
    pub fn initPeer(gpa: std.mem.Allocator, cfg: Config, p: PacketPipe, rec: *recovery.Host, join: *core.multi.AckJoin, bit: u5) !HostSession {
        std.debug.assert(cfg.shared);
        var s = try initWith(gpa, cfg, p, rec);
        s.join = join;
        s.join_bit = bit;
        return s;
    }

    fn initWith(gpa: std.mem.Allocator, cfg: Config, p: PacketPipe, shared_rec: ?*recovery.Host) !HostSession {
        var history = try media.History.init(gpa, .{ .max_age_us = cfg.retransmit_age_us, .min_interval_us = cfg.retransmit_interval_us, .capacity = 8192 });
        errdefer history.deinit(gpa);
        const ctl = try gpa.create(rate.Controller);
        errdefer gpa.destroy(ctl);
        if (cfg.rate_control) {
            ctl.reset(.{ .gcc = .{ .start_bps = @floatFromInt(cfg.bitrate_bps) }, .fps = @floatFromInt(cfg.fps) });
        } else ctl.reset(.{});
        const ladder = rate.Ladder.init(.{ .width = cfg.width, .height = cfg.height, .fps = cfg.fps });
        const rec = shared_rec orelse blk: {
            const r = try gpa.create(recovery.Host);
            r.* = recovery.Host.init(.{ .ltr = cfg.ltr });
            break :blk r;
        };
        errdefer if (shared_rec == null) gpa.destroy(rec);
        const tele = try gpa.create(telemetry.Telemetry(512));
        errdefer gpa.destroy(tele);
        tele.* = .init();
        const pb = try gpa.create(media.ParityBuffer);
        var control_ = try control.Control.init(gpa, .host, cfg.control);
        errdefer control_.deinit();
        return .{
            .gpa = gpa,
            .control = control_,
            .cfg = cfg,
            .pipe = p,
            .history = history,
            .ctl = ctl,
            .ladder = ladder,
            .bitrate_bps = cfg.bitrate_bps,
            .codec = cfg.codec,
            .format = cfg.format,
            .rec = rec,
            .tele = tele,
            .parity_buf = pb,
            .packetizer = .{ .parity_buf = pb },
            .policy = .init(cfg.policy),
        };
    }

    pub fn deinit(s: *HostSession) void {
        s.control.deinit();
        s.history.deinit(s.gpa);
        s.gpa.destroy(s.ctl);
        if (!s.cfg.shared) s.gpa.destroy(s.rec);
        s.gpa.destroy(s.tele);
        s.gpa.destroy(s.parity_buf);
        s.actions.deinit(s.gpa);
    }

    pub fn streaming(s: *const HostSession) bool {
        return s.state == .streaming and s.byes_left == 0;
    }

    pub fn ended(s: *const HostSession) bool {
        return s.state == .ended;
    }

    fn finish(s: *HostSession, e: End, why: []const u8) void {
        if (s.state == .ended) return;
        s.state = .ended;
        s.control.close();
        s.end = e;
        s.reason = why;
    }

    /// End the session at once, failed (the app could not go on: the encoder refused).
    pub fn abort(s: *HostSession, why: []const u8) void {
        s.finish(.failed, why);
    }

    /// Leave: send byes, then end.
    pub fn close(s: *HostSession, now: Micros) void {
        if (s.state == .ended or s.byes_left > 0) return;
        s.byes_left = s.cfg.byes;
        s.next_bye = now;
        if (s.byes_left == 0) s.finish(.closed, "closed");
    }

    fn envSeq(s: *const HostSession) u32 {
        return @truncate(s.seq);
    }

    fn sendRaw(s: *HostSession, dg: []const u8) void {
        s.pipe.send(dg) catch |e| switch (e) {
            error.Closed => return s.finish(.pipe_closed, "pipe closed"),
            error.TooLarge => return s.finish(.failed, "datagram too large for the pipe"),
        };
        s.seq += 1;
    }

    fn sendOther(s: *HostSession, stream: proto.StreamId, kind: u8, payload: []const u8, now: Micros) void {
        var buf: [proto.max_datagram]u8 = undefined;
        const dg = wire.message(&buf, stream, kind, s.envSeq(), payload);
        s.ctl.onSent(s.seq, now, @intCast(dg.len), s.next_frame_id, false);
        s.sendRaw(dg);
    }

    fn sendConfig(s: *HostSession, now: Micros) void {
        var b: [wire.Config.len]u8 = undefined;
        (wire.Config{
            .nonce = s.nonce.?,
            .codec = s.codec,
            .format = s.format,
            .slices = s.cfg.slices,
            .fps = @intCast(s.cfg.fps),
            .width = s.cfg.width,
            .height = s.cfg.height,
            .bitrate_bps = s.cfg.bitrate_bps,
        }).encode(&b);
        s.sendOther(.control_fast, @intFromEnum(wire.Kind.config), &b, now);
    }

    pub fn step(s: *HostSession, now: Micros) void {
        s.control.step();
        if (s.state == .ended) return;
        var buf: [2048]u8 = undefined;
        while (s.state != .ended) {
            const r = s.pipe.recv(&buf) catch |e| switch (e) {
                error.Closed => return s.finish(.pipe_closed, "pipe closed"),
                error.BufferTooSmall => {
                    s.stats.malformed += 1;
                    continue;
                },
            };
            const got = r orelse break;
            s.last_rx_us = now;
            s.onDatagram(buf[0..got.len], now);
        }
        if (s.state == .ended) return;
        s.path = s.pipe.stats();
        s.onPathState(now);
        if (s.byes_left > 0 and now >= s.next_bye) {
            s.sendOther(.control_fast, @intFromEnum(wire.Kind.bye), &.{@intFromEnum(wire.ByeReason.done)}, now);
            s.byes_left -= 1;
            s.next_bye = now + s.cfg.bye_interval_us;
            if (s.byes_left == 0) return s.finish(.closed, "closed");
        }
        if (s.state == .streaming) if (s.last_rx_us) |t| {
            const limit = if (s.pipe.canReconnect()) s.cfg.reconnect_timeout_us else s.cfg.peer_timeout_us;
            if (now - t > limit) return s.finish(.peer_timeout, "no datagrams from the client");
        };
    }

    /// React to what the pipe reports about its path: a new connection, a new path, a stall.
    fn onPathState(s: *HostSession, now: Micros) void {
        const p = s.path;
        const last = s.path_epoch orelse {
            s.path_epoch = p.path_epoch;
            s.conn_epoch = p.conn_epoch;
            s.log.start = now;
            return;
        };
        if (p.conn_epoch != s.conn_epoch) {
            // A new connection: what was in flight on the old one is gone, and it paces
            // from scratch. Start the new path's estimates and send a recovery frame.
            s.conn_epoch = p.conn_epoch;
            s.path_epoch = p.path_epoch;
            s.stats.reconnects += 1;
            s.path_changed_at = now;
            s.log.add(now, .reconnect, p.relayed);
            s.ctl.onPathChange();
            s.last_pacing = 0;
            s.applyPacing(now);
            s.resumeVideo(now, true);
        } else if (p.path_epoch != last) {
            s.path_epoch = p.path_epoch;
            s.stats.path_changes += 1;
            s.path_changed_at = now;
            s.log.add(now, .path, p.relayed);
            s.ctl.onPathChange();
            // A path closed under a stall: what we sent since is lost.
            if (s.paused_at != null) s.resumeVideo(now, false);
        }
        if (!s.cfg.pause_on_stall) return;
        const settling = if (s.path_changed_at) |t| now - t < s.cfg.stall_grace_us else false;
        if (p.stalled and !settling and s.paused_at == null and s.state == .streaming) {
            s.paused_at = now;
            s.paused_from = null;
            s.stats.stall_pauses += 1;
            s.log.add(now, .stall, p.relayed);
        } else if (!p.stalled and s.paused_at != null) {
            s.resumeVideo(now, false);
            s.log.add(now, .resume_, p.relayed);
        }
    }

    /// Send video again; the frames held (or, with `lost_in_flight`, any recent frame) are
    /// missing at the client, so the next frame repairs the picture: an LTR refresh when
    /// the client has acked a reference, else an IDR.
    fn resumeVideo(s: *HostSession, now: Micros, lost_in_flight: bool) void {
        if (s.paused_at) |t| s.stats.stall_longest_us = @max(s.stats.stall_longest_us, now - t);
        const held = s.paused_from != null;
        s.paused_at = null;
        s.paused_from = null;
        // Ask for the frame after the last one emitted: a recovery frame emitted while held
        // never left, so it must not count as one in flight.
        if ((held or lost_in_flight) and s.state == .streaming and s.next_frame_id > 0)
            s.rec.onRecoveryRequest(.{ .first_missing = s.next_frame_id, .want_idr = false });
    }

    pub fn nextWake(s: *const HostSession, now: Micros) Micros {
        var t = now + 5_000;
        if (s.byes_left > 0) t = @min(t, s.next_bye);
        return @max(t, now);
    }

    fn onDatagram(s: *HostSession, dg: []const u8, now: Micros) void {
        const m = proto.decode(dg) catch {
            s.stats.malformed += 1;
            return;
        };
        switch (m) {
            .feedback => |f| {
                s.ctl.onFeedbackMsg(now, f.feedback);
                s.policy.onCounts(@intCast(now), f.feedback.count, f.feedback.count - f.feedback.received);
                s.stats.feedback += 1;
                if (s.cfg.rate_control and !s.cfg.shared) s.updateLadder(now);
                s.applyPacing(now);
            },
            .frame_ack => |a| {
                s.stats.frame_acks += 1;
                if (a.ack.flags.recovery_needed) s.stats.recovery_requests += 1;
                if (s.join) |j| {
                    recovery.wire.applyFrameAck(j.member(s.join_bit, s.rec), a.ack);
                } else recovery.wire.applyFrameAck(s.rec, a.ack);
            },
            .video_shard => s.stats.unknown += 1,
            .other => |o| s.onOther(m, o.envelope, o.payload, now),
        }
    }

    fn applyPacing(s: *HostSession, now: Micros) void {
        if (!s.cfg.pace) return;
        const floor = s.cfg.pace_floor * @as(f64, @floatFromInt(s.bitrate_bps));
        const p: u64 = @intFromFloat(@max(s.ctl.pacingAt(now), s.ctl.capacityBps() orelse 0, floor));
        if (p != s.last_pacing) {
            s.pipe.setPacingRate(p);
            s.last_pacing = p;
        }
    }

    fn updateLadder(s: *HostSession, now: Micros) void {
        // With the loss policy on, its caps and FEC share bound the ladder.
        if (s.decision) |d| s.limits = .{
            .max_bitrate_bps = d.caps.max_bitrate_bps,
            .max_height = d.caps.max_height,
            .fec_overhead = d.overhead,
        };
        const req = s.ladder.update(now, s.ctl.encoderBps(), s.limits);
        if (req.bitrate_bps != 0) {
            s.bitrate_bps = req.bitrate_bps;
            s.pending_bitrate = req.bitrate_bps;
        }
        if (req.reconfigure) |r| {
            s.pending_reconfigure = r;
            s.ctl.setFrameRate(@floatFromInt(r.fps));
        }
    }

    /// Caps for the ladder. With `loss_policy`, each update takes them from
    /// `lossDecision` (relay caps and the FEC share) instead.
    pub fn setLimits(s: *HostSession, l: rate.ladder.Limits) void {
        s.limits = l;
    }

    /// A resolution or frame-rate step the ladder wants, once: the app applies it with
    /// The codec and format a hello changed to, once: the app reconfigures the encoder
    /// before the next frame (the next frame is an IDR either way: a new client, or
    /// `onHello` asked recovery for one).
    pub fn takeFormat(s: *HostSession) ?FormatChange {
        if (!s.pending_format) return null;
        s.pending_format = false;
        return .{ .codec = s.codec, .format = s.format };
    }

    /// `Encoder.configure` (expect a keyframe). Only with `rate_control`.
    pub fn takeReconfigure(s: *HostSession) ?rate.ladder.Rung {
        defer s.pending_reconfigure = null;
        return s.pending_reconfigure;
    }

    fn onOther(s: *HostSession, m: proto.Message, env: proto.Envelope, payload: []const u8, now: Micros) void {
        switch (env.stream) {
            .control_fast => {
                if (media.nack.parse(m) catch {
                    s.stats.malformed += 1;
                    return;
                }) |it_| {
                    var it = it_;
                    s.stats.nacks += 1;
                    if (s.decision) |d| if (!d.nack) {
                        s.stats.nacks_ignored += 1;
                        return;
                    };
                    while (it.next()) |mseq| if (s.history.resend(mseq, @intCast(now))) |shard| {
                        s.sendShard(shard, now);
                        s.stats.retransmits += 1;
                    };
                    return;
                }
                switch (@as(wire.Kind, @enumFromInt(env.kind))) {
                    .hello => s.onHello(wire.Hello.decode(payload) orelse {
                        s.stats.malformed += 1;
                        return;
                    }, now),
                    .bye => if (s.state != .waiting) s.finish(.client_bye, "client left"),
                    .clock_report => {
                        const r = wire.ClockReport.decode(payload) orelse {
                            s.stats.malformed += 1;
                            return;
                        };
                        s.offset = r.offset_us;
                    },
                    else => {
                        if (env.kind == @intFromEnum(clock.Kind.clock_ping)) {
                            const ping = clock.Ping.decode(payload) catch {
                                s.stats.malformed += 1;
                                return;
                            };
                            s.stats.pings += 1;
                            var b: [clock.Pong.wire_len]u8 = undefined;
                            clock.respond(ping, now, now).encode(&b);
                            s.sendOther(.control_fast, @intFromEnum(clock.Kind.clock_pong), &b, now);
                        } else s.stats.unknown += 1;
                    },
                }
            },
            .input => {
                if (env.kind != @intFromEnum(core.input.Kind.events)) return;
                var actions: [core.input.Receiver.max_actions]core.input.Action = undefined;
                const n = s.input_rx.process(payload, &actions) catch {
                    s.stats.malformed += 1;
                    return;
                };
                // A view-only device: acknowledged (so the client stops resending), not applied.
                const allowed = if (s.cfg.control.perms) |pm| pm.read().input else true;
                if (!allowed) s.stats.inputs_denied += n;
                for (actions[0..if (allowed) n else 0]) |a| {
                    const t: Micros = switch (a) {
                        .key => |k| k.time,
                        .button => |b| b.time,
                        .scroll => |sc| sc.time,
                        else => 0,
                    };
                    s.actions.pushBack(s.gpa, .{ .action = a, .time = t }) catch {};
                }
                var ack: [core.input.ack_wire_len]u8 = undefined;
                core.input.encodeAck(s.input_rx.nextExpected(), &ack);
                s.sendOther(.input, @intFromEnum(core.input.Kind.ack), &ack, now);
            },
            else => s.stats.unknown += 1,
        }
    }

    fn onHello(s: *HostSession, h: wire.Hello, now: Micros) void {
        s.stats.hellos += 1;
        const decodable = h.decodable();
        if (s.cfg.shared) {
            // One encode for every member: the multi host picks the format.
            s.client = .{ .dec = decodable, .display = h.display };
            s.hello = h;
            return;
        }
        var codec = s.codec;
        var fmt = s.format;
        if (s.cfg.negotiate) |n| {
            const c = api.format.negotiate(n.preference, n.encoder, decodable, h.display) orelse
                return s.finish(.failed, "no codec both the encoder and the client's decoder have");
            codec = @enumFromInt(c.codec);
            fmt = c.format;
        } else if (!decodable.get(@intFromEnum(s.cfg.codec)).supports(s.cfg.format)) {
            return s.finish(.failed, "client cannot decode the host's codec");
        }
        const changed = codec != s.codec or !fmt.eql(s.format);
        if (changed) {
            s.codec = codec;
            s.format = fmt;
            s.pending_format = true;
            s.stats.format_changes += 1;
        }
        s.startStream(h, changed, now);
    }

    /// Answer a hello: start (or restart) the stream and send the config.
    fn startStream(s: *HostSession, h: wire.Hello, changed: bool, now: Micros) void {
        if (s.nonce == null or s.nonce.? != h.nonce) {
            // A new session (or a restarted client): start from a keyframe.
            const first = s.nonce == null;
            s.nonce = h.nonce;
            s.stats.sessions += 1;
            // A peer joining a shared stream mid-way has no reference either.
            if (!first or (s.cfg.shared and s.next_frame_id > 0)) s.rec.onRecoveryRequest(.{ .first_missing = s.next_frame_id, .want_idr = true });
        } else if (changed) {
            s.rec.onRecoveryRequest(.{ .first_missing = s.next_frame_id, .want_idr = true });
        }
        s.state = .streaming;
        s.sendConfig(now);
    }

    /// With `cfg.shared`: the codec and format the multi host's encoder now streams. A
    /// member already streaming gets a new config (the multi host asks for the IDR, once
    /// for everyone). Returns whether it changed.
    pub fn setFormat(s: *HostSession, codec: api.Codec, fmt: api.VideoFormat, now: Micros) bool {
        std.debug.assert(s.cfg.shared);
        if (codec == s.codec and fmt.eql(s.format)) return false;
        s.codec = codec;
        s.format = fmt;
        s.stats.format_changes += 1;
        if (s.state == .streaming and s.nonce != null and s.byes_left == 0) s.sendConfig(now);
        return true;
    }

    /// With `cfg.shared`: answer the hello held for the multi host (after `setFormat`).
    pub fn answerHello(s: *HostSession, now: Micros) void {
        std.debug.assert(s.cfg.shared);
        const h = s.hello orelse return;
        s.hello = null;
        if (s.state == .ended) return;
        s.startStream(h, false, now);
    }

    // --- encode stage ---------------------------------------------------

    /// What the encoder should do with the next frame. Pair with `onEncoded` or `onEncodeDropped`.
    pub fn encodeParams(s: *HostSession) api.EncodeParams {
        std.debug.assert(!s.in_encoder);
        s.in_encoder = true;
        const d = s.rec.nextEncode();
        defer s.pending_bitrate = 0;
        return .{ .force = switch (d.force) {
            .none => .none,
            .ltr_refresh => .ltr_refresh,
            .idr => .idr,
        }, .acked_ltr_tokens = d.acked_tokens, .bitrate_bps = s.pending_bitrate };
    }

    pub fn onEncodeDropped(s: *HostSession) void {
        std.debug.assert(s.in_encoder);
        s.in_encoder = false;
        s.rec.onEncodeDropped();
        s.stats.encode_drops += 1;
    }

    /// An encoded frame from the encode stage: packetize and send it now.
    pub fn onEncoded(s: *HostSession, ef: api.EncodedFrame, cf: *const api.CapturedFrame, now: Micros) void {
        std.debug.assert(s.in_encoder);
        s.in_encoder = false;
        if (s.state != .streaming) {
            s.rec.onEncodeDropped();
            return;
        }
        const id = s.next_frame_id;
        const flags = s.rec.onEncoded(id, ef.ltr_token, ef.keyframe);
        if (s.sendFrame(id, flags, ef, cf, now)) s.rec.setRetryWindow(s.retryWindow());
    }

    /// Recovery's retry window for this client's path: about one RTT in frames, plus one.
    pub fn retryWindow(s: *const HostSession) u32 {
        const rtt: u64 = if (s.path.rtt_us > 0) @intCast(s.path.rtt_us) else 20_000;
        return @intCast(rtt * s.cfg.fps / 1_000_000 + 2);
    }

    /// Packetize and send frame `id`, which recovery already stamped with `flags`. The
    /// multi host calls this on every streaming peer; `onEncoded` does for one client.
    /// False when the frame did not go out (held for a stalled path, or the session failed).
    pub fn sendFrame(s: *HostSession, id: u32, flags: recovery.FrameFlags, ef: api.EncodedFrame, cf: *const api.CapturedFrame, now: Micros) bool {
        s.next_frame_id = id +% 1;
        var vflags: proto.video.Flags = .{ .keyframe = flags.keyframe, .ltr_refresh = flags.refresh, .ltr = ef.ltr_token != null };
        if (!ef.keyframe and ef.ltr_refresh) vflags.ltr_refresh = true;
        const cap: u64 = @bitCast(cf.captured_us);
        const enc: u64 = @bitCast(@max(ef.encoded_us, cf.captured_us));
        const n: u8 = @intCast(ef.slices.len);
        if (s.paused_at != null) {
            // The path is stalled: the frame counts as sent and lost, and the recovery
            // frame on resume repairs it.
            if (s.paused_from == null) s.paused_from = id;
            s.stats.stall_frames += 1;
            s.stats.frames += 1;
            if (flags.keyframe) s.stats.keyframes += 1;
            if (flags.refresh) s.stats.refreshes += 1;
            return false;
        }
        if (s.cfg.loss_policy) {
            s.decision = s.policy.update(@intCast(now), .{
                .rtt_us = @intCast(@max(s.path.rtt_us, 0)),
                .frame_interval_us = 1_000_000 / @max(s.cfg.fps, 1),
                .relayed = s.path.relayed,
            });
            s.packetizer.parity = s.policy.parity;
        }
        if (s.cfg.rate_control) {
            var total: usize = 0;
            for (ef.slices) |sl| total += sl.len;
            s.ctl.onFrame(now, id, total);
            s.applyPacing(now);
        }
        for (ef.slices, 0..) |sl, i| {
            if (sl.len == 0) continue;
            var it = s.packetizer.slice(.{
                .frame_id = id,
                .slice = @intCast(i),
                .slice_count = n,
                .flags = vflags,
                .capture_us = cap,
                .encode_done_us = enc,
                .ltr_token = ef.ltr_token orelse 0,
            }, sl) catch {
                s.finish(.failed, "encoded slice too large to packetize");
                return false;
            };
            while (it.next()) |shard| {
                s.history.record(shard, @intCast(now));
                s.sendShard(shard, now);
                s.stats.shards += 1;
                if (shard.header.shard >= shard.header.data_shards) s.stats.parity_shards += 1;
            }
            s.stats.bytes += sl.len;
        }
        s.stats.frames += 1;
        if (flags.keyframe) s.stats.keyframes += 1;
        if (flags.refresh) s.stats.refreshes += 1;
        if (cf.repeat) s.stats.repeats += 1;
        s.tele.record(.{ .frame_id = id, .capture_start = cf.capture_start_us, .captured = cf.captured_us, .encoded = ef.encoded_us }, null);
        return true;
    }

    fn sendShard(s: *HostSession, shard: media.Shard, now: Micros) void {
        var buf: [proto.max_datagram]u8 = undefined;
        const dg = proto.encodeVideoShard(&buf, s.envSeq(), shard.header, shard.payload) catch unreachable;
        const last = shard.header.slice + 1 == shard.header.slice_count and
            shard.header.group + 1 == shard.header.group_count and
            shard.header.shard + 1 == shard.header.shardCount();
        s.ctl.onSent(s.seq, now, @intCast(dg.len), shard.header.frame_id, last);
        s.sendRaw(dg);
    }

    /// Send one audio datagram (stream 2) with the session's transport-wide seq, so the
    /// rate controller and transport feedback see it. For the audio stage.
    pub fn sendAudio(s: *HostSession, kind: u8, payload: []const u8, now: Micros) void {
        if (s.state != .streaming) return;
        s.sendOther(.audio, kind, payload, now);
    }

    /// The loss policy's current choice (null before the first frame, or with
    /// `loss_policy` off): the mode, the FEC overhead and the caps for the rate ladder.
    pub fn lossDecision(s: *const HostSession) ?media.policy.Decision {
        return s.decision;
    }

    // --- input stage ----------------------------------------------------

    /// The next input action to inject, in order, with its client capture time.
    pub fn popAction(s: *HostSession) ?struct { action: core.input.Action, time: Micros } {
        const p = s.actions.popFront() orelse return null;
        return .{ .action = p.action, .time = p.time };
    }

    /// An action captured at client time `client_time` was injected at host time `now`.
    pub fn onInjected(s: *HostSession, client_time: Micros, now: Micros) void {
        s.stats.inputs_applied += 1;
        if (client_time == 0) return;
        if (s.offset) |off| s.tele.recordInput(client_time, now, off);
    }

    pub fn report(s: *const HostSession, w: *std.Io.Writer) !void {
        const st = s.stats;
        try w.print("host: {s}{s}{s}\n", .{ @tagName(s.end), if (s.reason.len > 0) ": " else "", s.reason });
        try w.print("  frames {d} (keyframes {d}, refreshes {d}, repeats {d}, encoder drops {d}), {d} MB in {d} shards\n", .{ st.frames, st.keyframes, st.refreshes, st.repeats, st.encode_drops, st.bytes / 1_000_000, st.shards });
        var fb: [32]u8 = undefined;
        try w.print("  stream {s} {s}{s}\n", .{ @tagName(s.codec), s.format.name(&fb), if (st.format_changes > 1) " (changed by a hello)" else "" });
        if (s.decision) |d| try w.print("  loss policy: {s}, loss {d:.2}%, FEC overhead {d:.0}%, {d} parity shards, {d} NACKs ignored, {d} mode switches\n", .{ @tagName(d.mode), d.loss * 100, d.overhead * 100, st.parity_shards, st.nacks_ignored, s.policy.switches });
        try w.print("  NACKs {d} -> retransmits {d}; feedback {d}; frame acks {d} (recovery requests {d}); pings {d}; inputs {d} (denied {d})\n", .{ st.nacks, st.retransmits, st.feedback, st.frame_acks, st.recovery_requests, st.pings, st.inputs_applied, st.inputs_denied });
        if (st.path_changes + st.reconnects + st.stall_pauses > 0)
            try w.print("  path changes {d}, reconnects {d}; stalls {d} ({d} frames held, longest {d:.0} ms)\n", .{ st.path_changes, st.reconnects, st.stall_pauses, st.stall_frames, ms(st.stall_longest_us) });
        const snap = s.tele.snapshot();
        try printStage(w, "capture", snap.stage(.capture));
        try printStage(w, "encode", snap.stage(.encode));
        try printStage(w, "input", snap.stage(.input));
        try s.log.print(w, "host");
        const p = s.path;
        try w.print("  pipe: rtt {d} us, pacing {d} kbit/s, sent {d}, send drops {d}{s}\n", .{ p.rtt_us, p.pacing_bps / 1000, p.sent, p.send_drops, if (p.relayed) ", relayed" else "" });
    }
};

pub fn printStage(w: *std.Io.Writer, name: []const u8, st: telemetry.StageStats) !void {
    if (st.count == 0) return w.print("  {s: <8} -\n", .{name});
    try w.print("  {s: <8} p50 {d:.2} ms  p95 {d:.2}  p99 {d:.2}  max {d:.2}  (n {d})\n", .{
        name,
        ms(st.p50),
        ms(st.p95),
        ms(st.p99),
        ms(st.max),
        st.count,
    });
}

fn ms(us: Micros) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A pipe the test writes the client's datagrams into and reads the host's back from.
const TestPipe = struct {
    in: [8][Recv.cap]u8 = undefined,
    in_len: [8]usize = undefined,
    n_in: usize = 0,
    configs: [8]wire.Config = undefined,
    n_configs: usize = 0,

    const Recv = struct {
        const cap = 256;
    };

    fn push(t: *TestPipe, kind: wire.Kind, payload: []const u8) void {
        const m = wire.message(&t.in[t.n_in], .control_fast, @intFromEnum(kind), 0, payload);
        t.in_len[t.n_in] = m.len;
        t.n_in += 1;
    }
    fn hello(t: *TestPipe, h: wire.Hello) void {
        var b: [wire.Hello.len]u8 = undefined;
        h.encode(&b);
        t.push(.hello, &b);
    }

    fn send(p: *anyopaque, d: []const u8) pipe_mod.SendError!void {
        const t: *TestPipe = @ptrCast(@alignCast(p));
        var dec = proto.wire.Decoder.init(d);
        const env = proto.Envelope.decode(&dec) catch return;
        if (env.stream == .control_fast and env.kind == @intFromEnum(wire.Kind.config)) {
            t.configs[t.n_configs % 8] = wire.Config.decode(dec.rest()).?;
            t.n_configs += 1;
        }
    }
    fn recv(p: *anyopaque, b: []u8) pipe_mod.RecvError!?pipe_mod.Received {
        const t: *TestPipe = @ptrCast(@alignCast(p));
        if (t.n_in == 0) return null;
        const n = t.in_len[0];
        @memcpy(b[0..n], t.in[0][0..n]);
        for (1..t.n_in) |i| {
            t.in[i - 1] = t.in[i];
            t.in_len[i - 1] = t.in_len[i];
        }
        t.n_in -= 1;
        return .{ .len = n, .recv_us = 0 };
    }
    fn setRate(_: *anyopaque, _: u64) void {}
    fn stats(_: *anyopaque) pipe_mod.PathStats {
        return .{};
    }
    fn max(_: *anyopaque) usize {
        return 1200;
    }
    const vt = PacketPipe.VTable{ .send = send, .recv = recv, .setPacingRate = setRate, .stats = stats, .maxDatagramSize = max };
};

test "each hello negotiates the codec and format; a change waits for the app and forces an IDR" {
    var tp: TestPipe = .{};
    const enc = api.effectiveFormats(.{ .h264 = true, .hevc = true, .av1 = true }, .{
        .h264 = .{ .yuv420_8 = true, .yuv444_8 = true },
        .hevc = api.Formats.all,
        .av1 = .{ .yuv420_8 = true, .yuv420_10 = true, .hdr10 = true },
    });
    var s = try HostSession.init(testing.allocator, .{
        .codec = .hevc,
        .width = 1920,
        .height = 1080,
        .negotiate = .{ .encoder = enc, .preference = .{ .codecs = .of(&.{ 2, 1, 3 }), .yuv444 = true, .source_is_hdr = true } },
    }, .{ .ptr = &tp, .vtable = &TestPipe.vt });
    defer s.deinit();

    // An HEVC 4:4:4 client with an SDR display: HEVC 4:4:4 8-bit.
    tp.hello(.{ .nonce = 1, .codecs = .{ .h264 = true, .hevc = true }, .formats = .{ .hevc = .{ .yuv420_8 = true, .yuv444_8 = true } } });
    s.step(1000);
    try testing.expect(s.streaming());
    try testing.expectEqual(@as(usize, 1), tp.n_configs);
    try testing.expectEqual(api.Codec.hevc, tp.configs[0].codec);
    try testing.expectEqual(api.format.Chroma.yuv444, tp.configs[0].format.chroma);
    const fc = s.takeFormat().?;
    try testing.expectEqual(api.format.Chroma.yuv444, fc.format.chroma);
    try testing.expectEqual(@as(?FormatChange, null), s.takeFormat());
    // The same hello again: the same config, nothing for the app.
    tp.hello(.{ .nonce = 1, .codecs = .{ .h264 = true, .hevc = true }, .formats = .{ .hevc = .{ .yuv420_8 = true, .yuv444_8 = true } } });
    s.step(2000);
    try testing.expectEqual(@as(?FormatChange, null), s.takeFormat());
    try testing.expectEqual(@as(usize, 2), tp.n_configs);

    // A new client: AV1 only, HDR display. AV1 10-bit HDR10, and an IDR.
    tp.hello(.{ .nonce = 2, .codecs = .{ .av1 = true }, .formats = .{ .av1 = .{ .yuv420_8 = true, .yuv420_10 = true, .hdr10 = true } }, .display = .{ .hdr10 = true } });
    s.step(3000);
    const c = tp.configs[2];
    try testing.expectEqual(api.Codec.av1, c.codec);
    try testing.expectEqual(api.ColorSpace.hdr10, c.format.color);
    try testing.expectEqual(@as(u8, 10), c.format.bit_depth);
    try testing.expectEqual(api.HdrMetadata.default_hdr10, c.format.hdr.?);
    try testing.expectEqual(api.Codec.av1, s.takeFormat().?.codec);
    try testing.expectEqual(api.Force.idr, s.encodeParams().force);
    s.onEncodeDropped();
    try testing.expectEqual(@as(u64, 2), s.stats.format_changes);

    // An old client (16-byte hello, H.264 only): H.264 8-bit 4:2:0 SDR.
    var old: [wire.Hello.len]u8 = undefined;
    (wire.Hello{ .nonce = 3, .codecs = .{ .h264 = true } }).encode(&old);
    tp.push(.hello, old[0..wire.Hello.base_len]);
    s.step(4000);
    try testing.expectEqual(api.Codec.h264, tp.configs[3].codec);
    try testing.expect(tp.configs[3].format.eql(.{}));

    // A client with nothing in common is turned away.
    tp.hello(.{ .nonce = 4, .codecs = .{ .passthrough = true } });
    s.step(5000);
    try testing.expect(s.ended());
    try testing.expectEqual(End.failed, s.end);
}
