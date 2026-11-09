//! Client side of a streaming session: the network stage of the client app.
//!
//! Sans-I/O. `step(now)` drains the pipe and runs timers. The decode/present stage takes
//! frames with `nextAccessUnit`, reports `onDecoded` and `onPresented`; the input stage
//! feeds local events to `onInput`. Under threads the app holds one lock around every
//! call; decode and present run outside it.
//!
//! Per frame it keeps the stage timestamps (host capture and encode from the video header,
//! client receive, decode and present) and records them in the telemetry window once the
//! frame is presented, with the clock offset from ping/pong; the freeze detector sees
//! every present.
//!
//! Drops (Phase 3): with a pipe that can reconnect, the client asks it for a new connection
//! after `reconnect_after_us` without a datagram from the host, and again every
//! `reconnect_after_us` while the silence lasts; the session ends only after
//! `reconnect_timeout_us`. On a new connection it repeats `hello` until the host answers,
//! and recovery repairs the picture as after any loss.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const pipe_mod = @import("pipe");
const wire = @import("wire.zig");
const control = @import("control.zig");
const host_session = @import("host_session.zig");
const pathlog = @import("pathlog.zig");

const proto = core.proto;
const media = core.media;
const recovery = core.recovery;
const telemetry = core.telemetry;
const clock = core.clock;
const PacketPipe = pipe_mod.PacketPipe;
const Micros = i64;

pub const Config = struct {
    codecs: api.CodecSet = .{ .passthrough = true },
    /// Formats per codec the decoder and presenter take, and the display (sent in hello).
    formats: api.FormatCaps = .{},
    display: api.DisplayCaps = .{},
    max_width: u32 = 0,
    max_height: u32 = 0,
    nonce: u32 = 1,
    hello_interval_us: Micros = 100_000,
    feedback_interval_us: Micros = 10_000,
    ping_interval_us: Micros = 200_000,
    report_interval_us: Micros = 1_000_000,
    /// How long reassembly and NACKs keep trying for a frame.
    recovery_window_us: u64 = 100_000,
    peer_timeout_us: Micros = 5_000_000,
    /// With a pipe that can reconnect: ask for a new connection after this long without a
    /// datagram from the host (0: never), and end the session only after `reconnect_timeout_us`.
    /// Under `peer_timeout_us`'s 5 s and well over the path idle timeout (0.3-1 s), so iroh
    /// gets to move to the relay first.
    reconnect_after_us: Micros = 2_000_000,
    reconnect_timeout_us: Micros = 60_000_000,
    /// Give up if no config comes within this long.
    connect_timeout_us: Micros = 10_000_000,
    freeze: telemetry.freeze.Config = .{},
    byes: u8 = 3,
    bye_interval_us: Micros = 20_000,
    /// Frames waiting for the decoder before newer ones are counted lost.
    max_queued: usize = 8,
    /// A frame completed this long after capture (host clock, via the clock offset) is
    /// treated as lost: showing it would only replay the past. Recovery then asks for a
    /// refresh, which catches the picture up. 0: never.
    max_frame_age_us: Micros = 200_000,
    /// Every audio datagram (stream 2), for the audio stage: envelope, payload, arrival.
    audio_ctx: ?*anyopaque = null,
    onAudio: ?*const fn (ctx: ?*anyopaque, env: proto.Envelope, payload: []const u8, recv_us: Micros) void = null,
    /// The reliable control channel (spec/control-v0.md): clipboard and the features built
    /// on it. It runs once the app attaches a stream (`control.attach`).
    control: control.Config = .{},
};

pub const State = enum { connecting, streaming, ended };
pub const End = enum { none, host_bye, peer_timeout, connect_timeout, pipe_closed, closed, failed };

pub const Stats = struct {
    frames_received: u64 = 0,
    frames_lost: u64 = 0,
    frames_dropped: u64 = 0,
    frames_stale: u64 = 0,
    frames_decoded: u64 = 0,
    decode_errors: u64 = 0,
    frames_presented: u64 = 0,
    queue_overflows: u64 = 0,
    shards: u64 = 0,
    nacks: u64 = 0,
    feedback: u64 = 0,
    frame_acks: u64 = 0,
    pongs: u64 = 0,
    input_events: u64 = 0,
    input_packets: u64 = 0,
    malformed: u64 = 0,
    unknown: u64 = 0,
    path_changes: u64 = 0,
    /// Reconnects asked of the pipe, and new connections it made.
    reconnect_requests: u64 = 0,
    reconnects: u64 = 0,
    /// Configs that changed the stream mid-session (a multi-user host re-picking the
    /// format as members join and leave).
    config_changes: u64 = 0,
};

const Queued = struct {
    au: api.AccessUnit,
    meta: recovery.FrameMeta,
    buf: []u8,
};

/// Per-frame timestamps until the frame is presented (or dropped).
const Times = struct { valid: bool = false, t: telemetry.FrameTimes = .{ .frame_id = 0 }, meta: recovery.FrameMeta = .{ .frame_id = 0 } };
const times_cap = 128;

pub const ClientSession = struct {
    gpa: std.mem.Allocator,
    /// The control channel; the app attaches its stream and feeds the clipboard.
    control: control.Control,
    cfg: Config,
    pipe: PacketPipe,
    state: State = .connecting,
    end: End = .none,
    reason: []const u8 = "",
    stats: Stats = .{},
    path: pipe_mod.PathStats = .{},
    config: ?wire.Config = null,
    /// Bumped by every config that starts the stream anew (the first, and each change of
    /// codec, format or size): the app configures its decoder and presenter again.
    config_seq: u32 = 0,

    seq: u64 = 0,
    start_us: ?Micros = null,
    last_rx_us: ?Micros = null,
    next_hello: Micros = 0,
    next_feedback: Micros = 0,
    next_ping: Micros = 0,
    next_report: Micros = 0,
    ping_seq: u32 = 0,
    rtt_us: Micros = 0,
    byes_left: u8 = 0,
    next_bye: Micros = 0,
    /// Path and connection the pipe last reported (null until the first stats).
    path_epoch: ?u32 = null,
    conn_epoch: u32 = 0,
    next_reconnect: Micros = 0,
    /// On a new connection: say hello until the host is heard from on it.
    resync: bool = false,
    log: pathlog.Log = .{},

    receiver: media.Receiver,
    rec: recovery.Client,
    sender: core.input.Sender,
    est: *clock.Estimator(512),
    tele: *telemetry.Telemetry(512),
    freeze: telemetry.freeze.Detector,

    fb_base: u64 = 0,
    fb_arrivals: std.ArrayList(?u64) = .empty,
    fb_seq: u16 = 0,
    /// Video datagrams seen and the share that needed a retransmit (overlay loss figure).
    video_rx: u64 = 0,
    video_retx: u64 = 0,

    queue: std.Deque(Queued) = .empty,
    free_bufs: std.ArrayList([]u8) = .empty,
    current: ?Queued = null,
    times: []Times,

    pub fn init(gpa: std.mem.Allocator, cfg: Config, p: PacketPipe) !ClientSession {
        var receiver = try media.Receiver.init(gpa, .{
            .reassembly = .{ .frame_timeout_us = cfg.recovery_window_us, .window = 64 },
            .nack = .{ .max_age_us = cfg.recovery_window_us, .max_retries = 20 },
        });
        errdefer receiver.deinit();
        const est = try gpa.create(clock.Estimator(512));
        errdefer gpa.destroy(est);
        est.* = .init(.{});
        const tele = try gpa.create(telemetry.Telemetry(512));
        errdefer gpa.destroy(tele);
        tele.* = .init();
        const times = try gpa.alloc(Times, times_cap);
        @memset(times, .{});
        var control_ = try control.Control.init(gpa, .client, cfg.control);
        errdefer control_.deinit();
        return .{
            .gpa = gpa,
            .control = control_,
            .cfg = cfg,
            .pipe = p,
            .receiver = receiver,
            .rec = recovery.Client.init(.{}),
            .sender = core.input.Sender.init(.{}),
            .est = est,
            .tele = tele,
            .freeze = .init(cfg.freeze),
            .times = times,
        };
    }

    pub fn deinit(s: *ClientSession) void {
        s.control.deinit();
        s.receiver.deinit();
        s.gpa.destroy(s.est);
        s.gpa.destroy(s.tele);
        s.fb_arrivals.deinit(s.gpa);
        while (s.queue.popFront()) |q| s.gpa.free(q.buf);
        s.queue.deinit(s.gpa);
        if (s.current) |q| s.gpa.free(q.buf);
        for (s.free_bufs.items) |b| s.gpa.free(b);
        s.free_bufs.deinit(s.gpa);
        s.gpa.free(s.times);
    }

    pub fn ended(s: *const ClientSession) bool {
        return s.state == .ended;
    }

    fn finish(s: *ClientSession, e: End, why: []const u8) void {
        if (s.state == .ended) return;
        s.state = .ended;
        s.control.close();
        s.end = e;
        s.reason = why;
    }

    pub fn close(s: *ClientSession, now: Micros) void {
        if (s.state == .ended or s.byes_left > 0) return;
        s.byes_left = s.cfg.byes;
        s.next_bye = now;
        if (s.byes_left == 0) s.finish(.closed, "closed");
    }

    fn envSeq(s: *const ClientSession) u32 {
        return @truncate(s.seq);
    }

    fn sendRaw(s: *ClientSession, dg: []const u8) void {
        s.pipe.send(dg) catch |e| switch (e) {
            error.Closed => return s.finish(.pipe_closed, "pipe closed"),
            error.TooLarge => return s.finish(.failed, "datagram too large for the pipe"),
        };
        s.seq += 1;
    }

    fn sendOther(s: *ClientSession, stream: proto.StreamId, kind: u8, payload: []const u8) void {
        var buf: [proto.max_datagram]u8 = undefined;
        s.sendRaw(wire.message(&buf, stream, kind, s.envSeq(), payload));
    }

    pub fn offset(s: *const ClientSession, now: Micros) ?Micros {
        const e = s.est.estimate() orelse return null;
        return e.offsetAt(now);
    }

    fn rttUs(s: *const ClientSession) u64 {
        if (s.path.rtt_us > 0) return @intCast(s.path.rtt_us);
        if (s.rtt_us > 0) return @intCast(s.rtt_us);
        return 20_000;
    }

    pub fn step(s: *ClientSession, now: Micros) void {
        s.control.step();
        if (s.state == .ended) return;
        const start = s.start_us orelse blk: {
            s.start_us = now;
            s.next_hello = now;
            s.next_feedback = now;
            s.next_ping = now;
            s.next_report = now + s.cfg.report_interval_us;
            break :blk now;
        };
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
            s.resync = false;
            s.onDatagram(buf[0..got.len], now);
        }
        if (s.state == .ended) return;
        s.path = s.pipe.stats();
        if (s.path_epoch) |last| {
            if (s.path.conn_epoch != s.conn_epoch) {
                s.conn_epoch = s.path.conn_epoch;
                s.stats.reconnects += 1;
                s.log.add(now, .reconnect, s.path.relayed);
                if (s.state == .streaming) {
                    s.resync = true;
                    s.next_hello = now;
                }
            } else if (s.path.path_epoch != last) {
                s.stats.path_changes += 1;
                s.log.add(now, .path, s.path.relayed);
            }
        } else {
            s.conn_epoch = s.path.conn_epoch;
            s.log.start = now;
        }
        s.path_epoch = s.path.path_epoch;
        s.rec.setRtt(s.rttUs());

        if (s.byes_left > 0) {
            if (now >= s.next_bye) {
                s.sendOther(.control_fast, @intFromEnum(wire.Kind.bye), &.{@intFromEnum(wire.ByeReason.done)});
                s.byes_left -= 1;
                s.next_bye = now + s.cfg.bye_interval_us;
                if (s.byes_left == 0) return s.finish(.closed, "closed");
            }
            return;
        }
        switch (s.state) {
            .connecting => {
                if (now - start > s.cfg.connect_timeout_us) return s.finish(.connect_timeout, "no config from the host");
                if (now >= s.next_hello) {
                    s.sendHello();
                    s.next_hello = now + s.cfg.hello_interval_us;
                }
            },
            .streaming => {
                if (s.last_rx_us) |t| {
                    const silent = now - t;
                    const can = s.pipe.canReconnect();
                    if (silent > (if (can) s.cfg.reconnect_timeout_us else s.cfg.peer_timeout_us)) return s.finish(.peer_timeout, "no datagrams from the host");
                    if (can and s.cfg.reconnect_after_us > 0 and silent > s.cfg.reconnect_after_us and now >= s.next_reconnect) {
                        s.pipe.reconnect();
                        s.stats.reconnect_requests += 1;
                        s.log.add(now, .redial, s.path.relayed);
                        s.next_reconnect = now + s.cfg.reconnect_after_us;
                    }
                }
                if (s.resync and now >= s.next_hello) {
                    s.sendHello();
                    s.next_hello = now + s.cfg.hello_interval_us;
                }
                s.pollFrames(now);
            },
            .ended => return,
        }
        if (now >= s.next_ping) {
            var b: [clock.Ping.wire_len]u8 = undefined;
            (clock.Ping{ .seq = s.ping_seq, .t1 = now }).encode(&b);
            s.ping_seq +%= 1;
            s.sendOther(.control_fast, @intFromEnum(clock.Kind.clock_ping), &b);
            s.next_ping = now + s.cfg.ping_interval_us;
        }
        if (now >= s.next_report) {
            if (s.est.estimate()) |e| {
                var b: [wire.ClockReport.len]u8 = undefined;
                (wire.ClockReport{ .offset_us = e.offsetAt(now), .error_bound_us = e.error_bound }).encode(&b);
                s.sendOther(.control_fast, @intFromEnum(wire.Kind.clock_report), &b);
            }
            s.next_report = now + s.cfg.report_interval_us;
        }
        if (s.sender.shouldSend(now)) {
            var ibuf: [core.input.maxPacketLen(32)]u8 = undefined;
            const pkt = s.sender.build(now, &ibuf);
            s.sendOther(.input, @intFromEnum(core.input.Kind.events), pkt);
            s.stats.input_packets += 1;
        }
        if (now >= s.next_feedback) {
            s.sendFeedback(now);
            s.next_feedback = now + s.cfg.feedback_interval_us;
        }
    }

    fn sendHello(s: *ClientSession) void {
        var b: [wire.Hello.len]u8 = undefined;
        (wire.Hello{ .nonce = s.cfg.nonce, .codecs = s.cfg.codecs, .max_width = s.cfg.max_width, .max_height = s.cfg.max_height, .formats = s.cfg.formats, .display = s.cfg.display }).encode(&b);
        s.sendOther(.control_fast, @intFromEnum(wire.Kind.hello), &b);
    }

    pub fn nextWake(s: *ClientSession, now: Micros) Micros {
        var t = @min(now + 5_000, s.next_feedback, s.next_ping);
        if (s.state == .connecting or s.resync) t = @min(t, s.next_hello);
        if (s.byes_left > 0) t = @min(t, s.next_bye);
        if (s.sender.nextSendTime(now)) |x| t = @min(t, x);
        if (s.receiver.deadline(s.rttUs())) |d| t = @min(t, @as(Micros, @intCast(d)));
        return @max(t, now);
    }

    fn onDatagram(s: *ClientSession, dg: []const u8, now: Micros) void {
        const m = proto.decode(dg) catch {
            s.stats.malformed += 1;
            return;
        };
        const env = m.envelope();
        // Transport feedback covers every host datagram, whatever its stream.
        const seq = widen(s.fb_base, env.seq);
        if (seq >= s.fb_base) {
            const i: usize = @intCast(seq - s.fb_base);
            if (i < 1 << 16) {
                while (s.fb_arrivals.items.len <= i) s.fb_arrivals.append(s.gpa, null) catch return;
                s.fb_arrivals.items[i] = @intCast(now);
            }
        }
        switch (m) {
            .video_shard => |v| {
                if (s.state != .streaming) return;
                s.stats.shards += 1;
                s.video_rx += 1;
                if (v.header.flags.retransmit) s.video_retx += 1;
                const r = s.receiver.onShard(v.header, v.payload, @intCast(now));
                if (r == .rejected or r == .out_of_memory) s.stats.malformed += 1;
            },
            .other => |o| switch (o.envelope.stream) {
                .control_fast => switch (@as(wire.Kind, @enumFromInt(o.envelope.kind))) {
                    .config => {
                        const c = wire.Config.decode(o.payload) orelse {
                            s.stats.malformed += 1;
                            return;
                        };
                        if (c.nonce != s.cfg.nonce) return;
                        if (s.config) |old| {
                            if (!sameStream(old, c)) s.restart(c, now);
                        } else {
                            s.config = c;
                            s.config_seq +%= 1;
                            s.state = .streaming;
                            s.rec = recovery.Client.init(.{ .frame_interval_us = 1_000_000 / @as(u64, c.fps) });
                        }
                    },
                    .bye => if (s.state == .streaming) s.finish(.host_bye, "host left"),
                    else => if (o.envelope.kind == @intFromEnum(clock.Kind.clock_pong)) {
                        const pong = clock.Pong.decode(o.payload) catch {
                            s.stats.malformed += 1;
                            return;
                        };
                        s.stats.pongs += 1;
                        if (clock.sampleOf(pong, now)) |smp| {
                            s.rtt_us = smp.rtt;
                            s.est.add(smp);
                        }
                    } else {
                        s.stats.unknown += 1;
                    },
                },
                .input => if (o.envelope.kind == @intFromEnum(core.input.Kind.ack)) {
                    const next = core.input.decodeAck(o.payload) catch {
                        s.stats.malformed += 1;
                        return;
                    };
                    s.sender.onAck(next);
                },
                .audio => if (s.cfg.onAudio) |f| f(s.cfg.audio_ctx, o.envelope, o.payload, now),
                else => s.stats.unknown += 1,
            },
            else => s.stats.unknown += 1,
        }
    }

    fn timesFor(s: *ClientSession, id: u32) *Times {
        return &s.times[id % times_cap];
    }

    fn takeBuf(s: *ClientSession, n: usize) ![]u8 {
        if (s.free_bufs.pop()) |b| {
            if (b.len >= n) return b;
            s.gpa.free(b);
        }
        return s.gpa.alloc(u8, @max(n, 64 * 1024));
    }

    fn giveBuf(s: *ClientSession, b: []u8) void {
        s.free_bufs.append(s.gpa, b) catch s.gpa.free(b);
    }

    fn pollFrames(s: *ClientSession, now: Micros) void {
        const c = s.config.?;
        const unow: u64 = @intCast(now);
        while (s.receiver.poll(unow)) |ev| switch (ev) {
            .frame => |f| {
                s.stats.frames_received += 1;
                if (s.cfg.max_frame_age_us > 0) if (s.offset(now)) |off| {
                    const cap_local = @as(Micros, @bitCast(f.meta.capture_us)) - off;
                    if (now - cap_local > s.cfg.max_frame_age_us) {
                        s.stats.frames_stale += 1;
                        s.rec.onFrameLost(f.id, unow);
                        continue;
                    }
                };
                const meta: recovery.FrameMeta = .{
                    .frame_id = f.id,
                    .keyframe = f.meta.flags.keyframe,
                    .refresh = f.meta.flags.ltr_refresh,
                    .ltr_token = if (f.meta.flags.ltr) f.meta.ltr_token else null,
                };
                if (s.rec.onFrame(meta, unow) == .drop) {
                    s.stats.frames_dropped += 1;
                    continue;
                }
                if (s.queue.len >= s.cfg.max_queued) {
                    // The decoder fell behind; treat this frame as lost so recovery resyncs.
                    s.stats.queue_overflows += 1;
                    s.rec.onFrameLost(f.id, unow);
                    continue;
                }
                const buf = s.takeBuf(f.len) catch {
                    s.rec.onFrameLost(f.id, unow);
                    continue;
                };
                const data = f.copyTo(buf);
                s.queue.pushBack(s.gpa, .{
                    .au = .{
                        .codec = c.codec,
                        .frame_id = f.id,
                        .data = data,
                        .keyframe = meta.keyframe,
                        .capture_us = f.meta.capture_us,
                        .received_us = now,
                    },
                    .meta = meta,
                    .buf = buf,
                }) catch {
                    s.giveBuf(buf);
                    s.rec.onFrameLost(f.id, unow);
                    continue;
                };
                s.timesFor(f.id).* = .{ .valid = true, .meta = meta, .t = .{
                    .frame_id = f.id,
                    .captured = @bitCast(f.meta.capture_us),
                    .encoded = @bitCast(f.meta.encode_done_us),
                    .received = now,
                } };
            },
            .lost => |l| {
                s.stats.frames_lost += 1;
                s.rec.onFrameLost(l.id, unow);
            },
        };
        var buf: [proto.max_datagram]u8 = undefined;
        if (s.receiver.nacks(unow, s.rttUs(), s.envSeq(), &buf) catch null) |dg| {
            s.sendRaw(dg);
            s.stats.nacks += 1;
        }
        if (s.rec.poll(unow)) |ack| {
            var entries: [recovery.Ack.max_entries]proto.FrameAck.Entry = undefined;
            const fa = recovery.wire.toFrameAck(&ack, &entries);
            if (proto.encodeFrameAck(&buf, s.envSeq(), fa)) |dg| {
                s.sendRaw(dg);
                s.stats.frame_acks += 1;
            } else |_| {}
        }
    }

    fn sendFeedback(s: *ClientSession, now: Micros) void {
        if (s.fb_arrivals.items.len == 0) return;
        var buf: [proto.max_datagram]u8 = undefined;
        var n = @min(s.fb_arrivals.items.len, proto.Feedback.max_count);
        while (true) {
            const msg = proto.Feedback{
                .feedback_seq = s.fb_seq,
                .base_seq = @truncate(s.fb_base),
                .ref_time_us = @intCast(now),
                .arrivals = s.fb_arrivals.items[0..n],
            };
            if (proto.encodeFeedback(&buf, s.envSeq(), msg)) |dg| {
                s.sendRaw(dg);
                break;
            } else |_| {
                n /= 2;
                if (n == 0) return;
            }
        }
        s.fb_seq +%= 1;
        s.stats.feedback += 1;
        const rest = s.fb_arrivals.items.len - n;
        std.mem.copyForwards(?u64, s.fb_arrivals.items[0..rest], s.fb_arrivals.items[n..]);
        s.fb_arrivals.shrinkRetainingCapacity(rest);
        s.fb_base += n;
    }

    // --- decode/present stage --------------------------------------------

    /// The next frame to decode, or null. Its data is valid until the next call.
    /// The decoder takes the same stream under both configs.
    fn sameStream(a: wire.Config, b: wire.Config) bool {
        return a.codec == b.codec and a.format.eql(b.format) and a.width == b.width and a.height == b.height;
    }

    /// The host switched the stream to another codec, format or size mid-session (spec/
    /// wire-v0.md, "Session"): what is queued is in the old one, and so is everything
    /// before the IDR the host sends next.
    fn restart(s: *ClientSession, c: wire.Config, now: Micros) void {
        s.config = c;
        s.config_seq +%= 1;
        s.stats.config_changes += 1;
        while (s.queue.popFront()) |q| {
            s.timesFor(q.au.frame_id).valid = false;
            s.giveBuf(q.buf);
        }
        s.rec.restart(@intCast(now));
    }

    pub fn nextAccessUnit(s: *ClientSession) ?api.AccessUnit {
        if (s.current) |q| {
            s.giveBuf(q.buf);
            s.current = null;
        }
        const q = s.queue.popFront() orelse return null;
        s.current = q;
        return q.au;
    }

    /// The decoder finished (or failed) frame `id` at `decoded_us`.
    pub fn onDecoded(s: *ClientSession, id: u32, ok: bool, decoded_us: Micros) void {
        const t = s.timesFor(id);
        if (!t.valid or t.t.frame_id != id) return;
        s.rec.onDecoded(t.meta, ok, @intCast(decoded_us));
        if (ok) {
            s.stats.frames_decoded += 1;
            t.t.decoded = decoded_us;
        } else {
            s.stats.decode_errors += 1;
            t.valid = false;
        }
    }

    /// Frame `id` reached the screen at `presented_us`. `content` identifies what is on
    /// screen for the freeze detector (the frame id, or the pattern's frame number).
    pub fn onPresented(s: *ClientSession, id: u32, presented_us: Micros, content: u64) void {
        s.stats.frames_presented += 1;
        s.freeze.onPresent(presented_us, content);
        const t = s.timesFor(id);
        if (!t.valid or t.t.frame_id != id) return;
        t.t.presented = presented_us;
        s.tele.record(t.t, s.offset(t.t.received orelse presented_us));
        t.valid = false;
    }

    /// A local input event (on the client clock).
    pub fn onInput(s: *ClientSession, ev: api.InputEvent) void {
        if (s.state != .streaming) return;
        s.stats.input_events += 1;
        const t = ev.time_us;
        switch (ev.what) {
            .key => |k| s.sender.key(k.code, k.down, t),
            .button => |b| if (b.code >= 1 and b.code <= core.input.max_buttons) s.sender.button(b.code, b.down, t),
            .scroll => |sc| s.sender.scroll(sc.dx, sc.dy, t),
            .move_rel => |m| s.sender.moveRel(m.dx, m.dy),
            .move_abs => |m| s.sender.moveAbs(m.x, m.y),
            .pad => |p| if (p.index < core.input.max_pads) s.sender.pad(p.index, p.state),
            .quit => {},
        }
    }

    pub fn overlay(s: *const ClientSession, now: Micros) api.Overlay {
        return .{
            .telemetry = s.tele.snapshot(),
            .bitrate_bps = if (s.config) |c| c.bitrate_bps else 0,
            .pacing_bps = s.path.pacing_bps,
            .rtt_us = @intCast(s.rttUs()),
            .loss = if (s.video_rx == 0) 0 else @floatCast(@as(f64, @floatFromInt(s.video_retx)) / @as(f64, @floatFromInt(s.video_rx))),
            .relayed = s.path.relayed,
            .freezes = @intCast(s.freeze.stats.freezes),
            .clock_synced = s.offset(now) != null,
        };
    }

    pub fn report(s: *const ClientSession, w: *std.Io.Writer) !void {
        const st = s.stats;
        try w.print("client: {s}{s}{s}\n", .{ @tagName(s.end), if (s.reason.len > 0) ": " else "", s.reason });
        var fb: [32]u8 = undefined;
        if (s.config) |c| try w.print("  stream {s} {s} {d}x{d}@{d} at {d} kbit/s, {d} slices\n", .{ @tagName(c.codec), c.format.name(&fb), c.width, c.height, c.fps, c.bitrate_bps / 1000, c.slices });
        try w.print("  frames received {d}, presented {d}, lost {d}, stale {d}, dropped while frozen {d}, decode errors {d}, queue overflows {d}\n", .{ st.frames_received, st.frames_presented, st.frames_lost, st.frames_stale, st.frames_dropped, st.decode_errors, st.queue_overflows });
        try w.print("  shards {d} (retransmitted {d}), NACKs {d}, feedback {d}, frame acks {d}, pongs {d}, input events {d}\n", .{ st.shards, s.video_retx, st.nacks, st.feedback, st.frame_acks, st.pongs, st.input_events });
        const r = s.rec.stats;
        try w.print("  recovery: freezes {d}, requests {d} (retries {d}), longest frozen {d:.1} ms\n", .{ r.freezes, r.requests, r.retries, @as(f64, @floatFromInt(r.frozen_us_max)) / 1000.0 });
        const fz = s.freeze.stats;
        try w.print("  freeze detector: {d} freezes over {d} ms, longest gap {d:.1} ms, stalls >{d} ms {d}, >{d} ms {d}\n", .{
            fz.freezes,
            @divTrunc(s.cfg.freeze.threshold_us, 1000),
            @as(f64, @floatFromInt(fz.longest_gap_us)) / 1000.0,
            @divTrunc(s.cfg.freeze.stall_us[0], 1000),
            fz.stalls[0],
            @divTrunc(s.cfg.freeze.stall_us[1], 1000),
            fz.stalls[1],
        });
        const snap = s.tele.snapshot();
        inline for (.{ "network", "decode", "present", "total" }) |n| try host_session.printStage(w, n, snap.stage(@field(telemetry.Stage, n)));
        if (st.path_changes + st.reconnects + st.reconnect_requests > 0)
            try w.print("  path changes {d}, reconnects {d} (asked {d})\n", .{ st.path_changes, st.reconnects, st.reconnect_requests });
        try s.log.print(w, "client");
        if (s.est.estimate()) |e| try w.print("  clock offset {d} us (±{d}), rtt {d} us\n", .{ e.offsetAt(s.last_rx_us orelse 0), e.error_bound, s.rtt_us });
    }
};

/// The 64-bit sequence number nearest `ref` whose low 32 bits are `seq`.
fn widen(ref: u64, seq: u32) u64 {
    const diff: i32 = @bitCast(seq -% @as(u32, @truncate(ref)));
    const r = @as(i128, ref) + diff;
    return if (r < 0) seq else @intCast(r);
}
