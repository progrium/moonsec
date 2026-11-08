//! The Phase 1 gate's session: a host and a client exchanging stream-tagged
//! datagrams through the core over any `PacketPipe` (docs/design.md, Phase 1).
//!
//! Host to client:
//!   video        frames from `core.media.Packetizer`, sized from the rate
//!                controller's encoder rate; NACKed shards resent from `History`
//!   audio        a numbered synthetic payload every 10 ms (no codec yet)
//!   input        acks for the client's input packets (`core.input`)
//!   gate         the bye ack, carrying the host's counts
//! Client to host:
//!   control_fast transport-wide `proto.Feedback` every 20 ms (fed to
//!                `core.rate.Controller`, whose pacing rate goes back to the pipe)
//!                and NACKs from `core.media.Receiver`
//!   input        key presses and releases from `core.input.Sender`
//!   gate         hello (until the host answers) and bye (with the client's counts)
//!
//! The `gate` stream (id 240) is test-only and outside spec/wire-v0.md; receivers
//! that don't know it skip it, as the spec says for unknown streams.
//!
//! Frame contents are a function of (seed, frame id), so the client checks every
//! byte without a copy of what was sent. The host keeps streaming past
//! `cfg.frames` until the client says bye, as a live stream would, so losses at
//! the tail are detected and recovered like any other.
//!
//! Sans-I/O like the core: `step(now)` drains the pipe and runs the timers;
//! `nextWake` says when to call again. The same code runs in-process over the sim
//! (tools/gate/test.zig, virtual time) and in two processes over iroh or the sim
//! hub (tools/gate/main.zig, wall clock).
const std = @import("std");
const core = @import("core");
const pipe_mod = @import("pipe");

const proto = core.proto;
const media = core.media;
const input = core.input;
const rate = core.rate;
const PacketPipe = pipe_mod.PacketPipe;

pub const Role = enum { host, client };

/// The gate's own stream: hello, bye and bye-ack.
pub const gate_stream: proto.StreamId = @enumFromInt(240);
pub const GateKind = enum(u8) { hello = 1, bye = 2, bye_ack = 3, _ };
pub const AudioKind: u8 = 1;
pub const audio_payload_len = 160;

pub const Config = struct {
    seed: u64 = 1,
    /// Frames the client must receive intact, in order, starting at frame 0.
    frames: u32 = 300,
    fps: u32 = 60,
    audio_interval_us: i64 = 10_000,
    /// Key events the client sends (alternating press and release).
    input_events: u32 = 120,
    input_interval_us: i64 = 25_000,
    feedback_interval_us: i64 = 20_000,
    hello_interval_us: i64 = 50_000,
    bye_interval_us: i64 = 20_000,
    /// The host keeps answering repeated byes this long after the first.
    bye_linger_us: i64 = 300_000,
    /// The client gives up waiting for the bye ack after this long.
    bye_timeout_us: i64 = 3_000_000,
    /// Whole session limit, from the first call to `step`.
    timeout_us: i64 = 60_000_000,
    /// Smallest share of audio datagrams that must arrive (no retransmission).
    min_audio_share: f64 = 0.9,
    /// Generous loss-recovery windows so a stalled CI runner does not turn a
    /// late retransmit into a lost frame.
    recovery_window_us: u64 = 1_000_000,
    /// Apply the rate controller's pacing rate to the pipe.
    pace: bool = true,
};

/// One direction's per-stream datagram counts.
pub const StreamCounts = struct {
    video: u64 = 0,
    audio: u64 = 0,
    input: u64 = 0,
    control_fast: u64 = 0,
    gate: u64 = 0,
    unknown: u64 = 0,
    malformed: u64 = 0,

    fn add(c: *StreamCounts, s: proto.StreamId) void {
        switch (s) {
            .video => c.video += 1,
            .audio => c.audio += 1,
            .input => c.input += 1,
            .control_fast => c.control_fast += 1,
            else => if (s == gate_stream) {
                c.gate += 1;
            } else {
                c.unknown += 1;
            },
        }
    }

    pub fn total(c: StreamCounts) u64 {
        return c.video + c.audio + c.input + c.control_fast + c.gate + c.unknown;
    }
};

/// Counts one side reports to the other in its bye or bye ack.
pub const Summary = struct {
    frames_sent: u32 = 0,
    frames_delivered: u32 = 0,
    frames_lost: u32 = 0,
    frames_corrupt: u32 = 0,
    audio_sent: u32 = 0,
    audio_received: u32 = 0,
    audio_corrupt: u32 = 0,
    input_sent: u32 = 0,
    input_applied: u32 = 0,
    input_wrong: u32 = 0,
    retransmits: u32 = 0,
    nacks: u32 = 0,
    feedback: u32 = 0,

    const n_fields = @typeInfo(Summary).@"struct".fields.len;
    pub const wire_len = 4 * n_fields;

    fn encode(s: Summary, out: *[wire_len]u8) void {
        inline for (@typeInfo(Summary).@"struct".fields, 0..) |f, i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], @field(s, f.name), .little);
        }
    }

    fn decode(buf: []const u8) ?Summary {
        if (buf.len != wire_len) return null;
        var s: Summary = .{};
        inline for (@typeInfo(Summary).@"struct".fields, 0..) |f, i| {
            @field(s, f.name) = std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
        }
        return s;
    }
};

pub const Outcome = enum { running, passed, failed };

/// Frame `id`'s contents: deterministic in (seed, id), so the client can check them.
fn frameBytes(seed: u64, id: u32, out: []u8) void {
    var prng = std.Random.DefaultPrng.init(seed ^ (@as(u64, id) *% 0x9e3779b97f4a7c15));
    prng.random().bytes(out);
}

fn audioBytes(seed: u64, n: u32, out: *[audio_payload_len]u8) void {
    std.mem.writeInt(u32, out[0..4], n, .little);
    var prng = std.Random.DefaultPrng.init(seed +% n);
    prng.random().bytes(out[4..]);
}

/// The key event the client sends as its `i`th input: HID usages 4.. (a, b, ...),
/// press on even i, release on odd.
fn expectedKey(i: u32) struct { code: u16, down: bool } {
    return .{ .code = @intCast(4 + (i / 2) % 26), .down = i % 2 == 0 };
}

const max_frame = 256 * 1024;

/// The 64-bit sequence number nearest `ref` whose low 32 bits are `seq`.
fn widen(ref: u64, seq: u32) u64 {
    const diff: i32 = @bitCast(seq -% @as(u32, @truncate(ref)));
    const r = @as(i128, ref) + diff;
    return if (r < 0) seq else @intCast(r);
}

pub const Session = struct {
    gpa: std.mem.Allocator,
    role: Role,
    cfg: Config,
    pipe: PacketPipe,

    start_us: ?i64 = null,
    outcome: Outcome = .running,
    /// Why the session failed (static string).
    reason: []const u8 = "",
    rx: StreamCounts = .{},
    tx: StreamCounts = .{},
    mine: Summary = .{},
    /// The other side's summary, from its bye or bye ack.
    theirs: ?Summary = null,
    /// Transport-wide envelope seq for this direction.
    seq: u64 = 0,
    send_drops_at_end: u64 = 0,
    stats: pipe_mod.PathStats = .{},

    // Shared timers.
    next_audio: i64 = 0,
    next_feedback: i64 = 0,

    host: ?*Host = null,
    client: ?*Client = null,

    const Host = struct {
        started: bool = false,
        t0: i64 = 0,
        next_frame_id: u32 = 0,
        packetizer: media.Packetizer = .{},
        history: media.History,
        ctl: rate.Controller,
        input_rx: input.Receiver = .{},
        bye_at: ?i64 = null,
        frame_buf: []u8,
        last_pacing: u64 = 0,
    };

    const Client = struct {
        receiver: media.Receiver,
        started: bool = false,
        next_hello: i64 = 0,
        sender: input.Sender,
        next_input: i64 = 0,
        /// Arrivals of host datagrams since `fb_base`, by envelope seq.
        fb_base: u64 = 0,
        fb_arrivals: std.ArrayList(?u64) = .empty,
        fb_seq: u16 = 0,
        audio_seen: std.DynamicBitSetUnmanaged = .{},
        bye_since: ?i64 = null,
        next_bye: i64 = 0,
        frame_buf: []u8,
        check_buf: []u8,
    };

    pub fn init(gpa: std.mem.Allocator, role: Role, cfg: Config, p: PacketPipe) !Session {
        var s: Session = .{ .gpa = gpa, .role = role, .cfg = cfg, .pipe = p };
        const window = cfg.recovery_window_us;
        switch (role) {
            .host => {
                const h = try gpa.create(Host);
                errdefer gpa.destroy(h);
                h.* = .{
                    .history = try media.History.init(gpa, .{ .max_age_us = window }),
                    .ctl = undefined,
                    .frame_buf = undefined,
                };
                errdefer h.history.deinit(gpa);
                h.ctl.reset(.{});
                h.frame_buf = try gpa.alloc(u8, max_frame);
                s.host = h;
            },
            .client => {
                const c = try gpa.create(Client);
                errdefer gpa.destroy(c);
                c.* = .{
                    .receiver = try media.Receiver.init(gpa, .{
                        // Room for a second of frames in flight, so a frame waiting on a
                        // retransmit is timed out by `window`, not pushed out by newer frames.
                        .reassembly = .{ .frame_timeout_us = window, .window = 128 },
                        .nack = .{ .max_age_us = window, .max_retries = 30 },
                    }),
                    .sender = input.Sender.init(.{}),
                    .frame_buf = undefined,
                    .check_buf = undefined,
                };
                errdefer c.receiver.deinit();
                c.frame_buf = try gpa.alloc(u8, max_frame);
                errdefer gpa.free(c.frame_buf);
                c.check_buf = try gpa.alloc(u8, max_frame);
                s.client = c;
            },
        }
        return s;
    }

    pub fn deinit(s: *Session) void {
        if (s.host) |h| {
            h.history.deinit(s.gpa);
            s.gpa.free(h.frame_buf);
            s.gpa.destroy(h);
        }
        if (s.client) |c| {
            c.receiver.deinit();
            c.fb_arrivals.deinit(s.gpa);
            c.audio_seen.deinit(s.gpa);
            s.gpa.free(c.frame_buf);
            s.gpa.free(c.check_buf);
            s.gpa.destroy(c);
        }
    }

    pub fn done(s: *const Session) bool {
        return s.outcome != .running;
    }

    fn fail(s: *Session, why: []const u8) void {
        if (s.outcome == .running) {
            s.outcome = .failed;
            s.reason = why;
        }
    }

    /// Send one datagram; the envelope seq it carries must be `s.seq` (see `nextSeq`).
    fn sendRaw(s: *Session, data: []const u8, stream: proto.StreamId) void {
        s.pipe.send(data) catch |e| switch (e) {
            error.Closed => return s.fail("pipe closed"),
            error.TooLarge => return s.fail("datagram too large for the pipe"),
        };
        s.tx.add(stream);
        s.seq += 1;
    }

    fn envSeq(s: *const Session) u32 {
        return @truncate(s.seq);
    }

    fn sendOther(s: *Session, stream: proto.StreamId, kind: u8, payload: []const u8, now: i64) void {
        var buf: [proto.max_datagram]u8 = undefined;
        var e = proto.wire.Encoder.init(&buf);
        (proto.Envelope{ .stream = stream, .kind = kind, .seq = s.envSeq() }).encode(&e) catch unreachable;
        e.bytes(payload) catch unreachable;
        if (s.host) |h| h.ctl.onSent(s.seq, now, @intCast(e.pos), h.next_frame_id, false);
        s.sendRaw(e.written(), stream);
    }

    /// Drain the pipe, run the timers. `now` is this endpoint's monotonic clock, µs.
    pub fn step(s: *Session, now: i64) void {
        if (s.done()) return;
        const start = s.start_us orelse blk: {
            s.start_us = now;
            s.next_audio = now;
            s.next_feedback = now;
            break :blk now;
        };
        if (now - start > s.cfg.timeout_us) return s.fail("timed out");

        var buf: [2048]u8 = undefined;
        while (!s.done()) {
            const r = s.pipe.recv(&buf) catch |e| switch (e) {
                // The client may hang up once it has the bye ack; judge on what we have.
                error.Closed => return if (s.host != null and s.host.?.bye_at != null) s.hostVerdict() else s.fail("pipe closed"),
                error.BufferTooSmall => return s.fail("datagram larger than 2048 bytes"),
            };
            const got = r orelse break;
            s.onDatagram(buf[0..got.len], now);
        }
        if (s.done()) return;
        switch (s.role) {
            .host => s.hostTimers(now),
            .client => s.clientTimers(now),
        }
        s.stats = s.pipe.stats();
    }

    /// When `step` next has something to do (it may also be called earlier).
    pub fn nextWake(s: *const Session, now: i64) i64 {
        var t = now + 5_000;
        if (s.host) |h| {
            if (h.started) {
                t = @min(t, s.next_audio, h.t0 + frameTime(s.cfg, h.next_frame_id));
            }
        }
        if (s.client) |c| {
            t = @min(t, s.next_feedback);
            if (!c.started) t = @min(t, c.next_hello);
            if (c.bye_since != null) t = @min(t, c.next_bye);
            if (c.sender.nextSendTime(now)) |x| t = @min(t, x);
            if (s.mine.input_sent < s.cfg.input_events) t = @min(t, c.next_input);
            if (c.receiver.deadline(rttUs(s))) |d| t = @min(t, @as(i64, @intCast(d)));
        }
        return @max(t, now);
    }

    fn frameTime(cfg: Config, id: u32) i64 {
        return @divTrunc(@as(i64, id) * 1_000_000, cfg.fps);
    }

    fn rttUs(s: *const Session) u64 {
        return if (s.stats.rtt_us > 0) @intCast(s.stats.rtt_us) else 20_000;
    }

    fn onDatagram(s: *Session, dg: []const u8, now: i64) void {
        const m = proto.decode(dg) catch {
            s.rx.malformed += 1;
            return;
        };
        const env = m.envelope();
        s.rx.add(env.stream);
        switch (s.role) {
            .host => s.hostOn(m, now),
            .client => s.clientOn(m, env, dg.len, now),
        }
    }

    // --- host -------------------------------------------------------------

    fn hostOn(s: *Session, m: proto.Message, now: i64) void {
        const h = s.host.?;
        switch (m) {
            .feedback => |f| {
                h.ctl.onFeedbackMsg(now, f.feedback);
                s.mine.feedback += 1;
                if (s.cfg.pace) {
                    const p: u64 = @intFromFloat(h.ctl.pacingBps());
                    if (p != h.last_pacing) {
                        s.pipe.setPacingRate(p);
                        h.last_pacing = p;
                    }
                }
            },
            .other => |o| {
                if (media.nack.parse(m) catch {
                    s.rx.malformed += 1;
                    return;
                }) |it_| {
                    var it = it_;
                    s.mine.nacks += 1;
                    while (it.next()) |mseq| if (h.history.resend(mseq, @intCast(now))) |shard| {
                        s.sendShard(shard, now);
                        s.mine.retransmits += 1;
                    };
                    return;
                }
                if (o.envelope.stream == .input and o.envelope.kind == @intFromEnum(input.Kind.events)) {
                    var actions: [input.Receiver.max_actions]input.Action = undefined;
                    const n = h.input_rx.process(o.payload, &actions) catch {
                        s.rx.malformed += 1;
                        return;
                    };
                    for (actions[0..n]) |a| switch (a) {
                        .key => |k| {
                            const want = expectedKey(s.mine.input_applied);
                            if (k.code != want.code or k.down != want.down) s.mine.input_wrong += 1;
                            s.mine.input_applied += 1;
                        },
                        else => {},
                    };
                    var ack: [input.ack_wire_len]u8 = undefined;
                    input.encodeAck(h.input_rx.nextExpected(), &ack);
                    s.sendOther(.input, @intFromEnum(input.Kind.ack), &ack, now);
                    return;
                }
                if (o.envelope.stream == gate_stream) switch (@as(GateKind, @enumFromInt(o.envelope.kind))) {
                    .hello => {
                        if (o.payload.len != 12 or
                            std.mem.readInt(u64, o.payload[0..8], .little) != s.cfg.seed or
                            std.mem.readInt(u32, o.payload[8..12], .little) != s.cfg.frames)
                            return s.fail("client runs a different seed or frame count");
                        if (!h.started) {
                            h.started = true;
                            h.t0 = now;
                            s.next_audio = now;
                        }
                    },
                    .bye => {
                        s.theirs = Summary.decode(o.payload) orelse return s.fail("malformed bye");
                        if (h.bye_at == null) h.bye_at = now;
                        var out: [Summary.wire_len]u8 = undefined;
                        s.mine.encode(&out);
                        s.sendOther(gate_stream, @intFromEnum(GateKind.bye_ack), &out, now);
                    },
                    else => {},
                };
            },
            else => {},
        }
    }

    fn sendShard(s: *Session, shard: media.Shard, now: i64) void {
        const h = s.host.?;
        var buf: [proto.max_datagram]u8 = undefined;
        const dg = proto.encodeVideoShard(&buf, s.envSeq(), shard.header, shard.payload) catch unreachable;
        const last = shard.header.slice + 1 == shard.header.slice_count and
            shard.header.group + 1 == shard.header.group_count and
            shard.header.shard + 1 == shard.header.data_shards;
        h.ctl.onSent(s.seq, now, @intCast(dg.len), shard.header.frame_id, last);
        s.sendRaw(dg, .video);
    }

    fn hostTimers(s: *Session, now: i64) void {
        const h = s.host.?;
        if (h.bye_at) |t| {
            if (now - t >= s.cfg.bye_linger_us) s.hostVerdict();
            return;
        }
        if (!h.started) return;
        // Frames on schedule (catching up if we fell behind), sized like an encoder at
        // the controller's rate would size them.
        var budget: u32 = 4;
        while (budget > 0 and now >= h.t0 + frameTime(s.cfg, h.next_frame_id)) : (budget -= 1) {
            const id = h.next_frame_id;
            var prng = std.Random.DefaultPrng.init(s.cfg.seed *% 31 +% id);
            const rnd = prng.random();
            const mean = h.ctl.encoderBps() / 8.0 / @as(f64, @floatFromInt(s.cfg.fps));
            const want = mean * (0.5 + rnd.float(f64));
            const size: usize = std.math.clamp(@as(usize, @intFromFloat(want)), 64, max_frame);
            const data = h.frame_buf[0..size];
            frameBytes(s.cfg.seed, id, data);
            const slices: u8 = if (size < 4096) 1 else rnd.intRangeAtMost(u8, 1, 3);
            const cut = size / slices;
            for (0..slices) |si| {
                const lo = si * cut;
                const hi = if (si + 1 == slices) size else lo + cut;
                var it = h.packetizer.slice(.{
                    .frame_id = id,
                    .slice = @intCast(si),
                    .slice_count = slices,
                    .flags = .{ .keyframe = id == 0 },
                    .capture_us = @intCast(now),
                    .encode_done_us = @intCast(now),
                }, data[lo..hi]) catch unreachable;
                while (it.next()) |shard| {
                    h.history.record(shard, @intCast(now));
                    s.sendShard(shard, now);
                }
            }
            h.next_frame_id += 1;
            s.mine.frames_sent = h.next_frame_id;
        }
        while (now >= s.next_audio) {
            var payload: [audio_payload_len]u8 = undefined;
            audioBytes(s.cfg.seed, s.mine.audio_sent, &payload);
            s.sendOther(.audio, AudioKind, &payload, now);
            s.mine.audio_sent += 1;
            s.next_audio += s.cfg.audio_interval_us;
        }
    }

    fn hostVerdict(s: *Session) void {
        const h = s.host.?;
        const c = s.theirs orelse return s.fail("no bye from the client");
        if (c.frames_delivered < s.cfg.frames) return s.fail("client did not get every frame");
        if (c.frames_corrupt > 0 or c.audio_corrupt > 0) return s.fail("client saw corrupt payloads");
        if (s.mine.input_applied != s.cfg.input_events) return s.fail("not every input event was applied");
        if (s.mine.input_wrong > 0 or h.input_rx.stats.lost_events > 0) return s.fail("input events arrived wrong or were lost");
        if (s.mine.feedback == 0) return s.fail("no transport feedback");
        if (s.rx.unknown > 0 or s.rx.malformed > 0) return s.fail("unknown or malformed datagrams");
        s.outcome = .passed;
    }

    // --- client -----------------------------------------------------------

    fn clientOn(s: *Session, m: proto.Message, env: proto.Envelope, len: usize, now: i64) void {
        const c = s.client.?;
        _ = len;
        c.started = true;
        // Transport feedback covers every host datagram, whatever its stream.
        const seq = widen(c.fb_base, env.seq);
        if (seq >= c.fb_base) {
            const i: usize = @intCast(seq - c.fb_base);
            if (i < 1 << 16) {
                while (c.fb_arrivals.items.len <= i) c.fb_arrivals.append(s.gpa, null) catch return s.fail("out of memory");
                c.fb_arrivals.items[i] = @intCast(now);
            }
        }
        switch (m) {
            .video_shard => |v| {
                const r = c.receiver.onShard(v.header, v.payload, @intCast(now));
                if (r == .rejected or r == .out_of_memory) s.rx.malformed += 1;
            },
            .other => |o| {
                if (o.envelope.stream == .audio and o.envelope.kind == AudioKind) {
                    if (o.payload.len != audio_payload_len) {
                        s.mine.audio_corrupt += 1;
                        return;
                    }
                    const n = std.mem.readInt(u32, o.payload[0..4], .little);
                    var want: [audio_payload_len]u8 = undefined;
                    audioBytes(s.cfg.seed, n, &want);
                    if (!std.mem.eql(u8, &want, o.payload)) {
                        s.mine.audio_corrupt += 1;
                        return;
                    }
                    if (n >= 1 << 20) return;
                    if (c.audio_seen.bit_length <= n) c.audio_seen.resize(s.gpa, @max(n + 1, c.audio_seen.bit_length * 2), false) catch return s.fail("out of memory");
                    if (!c.audio_seen.isSet(n)) {
                        c.audio_seen.set(n);
                        s.mine.audio_received += 1;
                    }
                } else if (o.envelope.stream == .input and o.envelope.kind == @intFromEnum(input.Kind.ack)) {
                    const next = input.decodeAck(o.payload) catch {
                        s.rx.malformed += 1;
                        return;
                    };
                    c.sender.onAck(next);
                } else if (o.envelope.stream == gate_stream and o.envelope.kind == @intFromEnum(GateKind.bye_ack)) {
                    s.theirs = Summary.decode(o.payload) orelse return s.fail("malformed bye ack");
                    s.clientVerdict();
                }
            },
            else => {},
        }
    }

    fn clientTimers(s: *Session, now: i64) void {
        const c = s.client.?;
        if (!c.started and now >= c.next_hello) {
            var hello: [12]u8 = undefined;
            std.mem.writeInt(u64, hello[0..8], s.cfg.seed, .little);
            std.mem.writeInt(u32, hello[8..12], s.cfg.frames, .little);
            s.sendOther(gate_stream, @intFromEnum(GateKind.hello), &hello, now);
            c.next_hello = now + s.cfg.hello_interval_us;
        }
        // Frames and losses, in order; check every byte of the first `cfg.frames`.
        while (c.receiver.poll(@intCast(now))) |ev| switch (ev) {
            .frame => |f| {
                if (f.id >= s.cfg.frames) continue;
                if (f.id != s.mine.frames_delivered + s.mine.frames_lost) {
                    s.mine.frames_lost += 1; // a skipped id (cannot happen: losses are reported)
                }
                const got = f.copyTo(c.frame_buf);
                const want = c.check_buf[0..got.len];
                frameBytes(s.cfg.seed, f.id, want);
                if (!std.mem.eql(u8, got, want) or f.meta.flags.keyframe != (f.id == 0)) s.mine.frames_corrupt += 1;
                s.mine.frames_delivered += 1;
            },
            .lost => |l| {
                if (l.id < s.cfg.frames) s.mine.frames_lost += 1;
            },
        };
        var buf: [proto.max_datagram]u8 = undefined;
        if (c.receiver.nacks(@intCast(now), rttUs(s), s.envSeq(), &buf) catch null) |dg| {
            s.sendRaw(dg, .control_fast);
            s.mine.nacks += 1;
        }
        // Input: one key event per interval, sent with the sender's redundancy.
        if (c.started and s.mine.input_sent < s.cfg.input_events and now >= c.next_input) {
            const k = expectedKey(s.mine.input_sent);
            c.sender.key(k.code, k.down, now);
            s.mine.input_sent += 1;
            c.next_input = now + s.cfg.input_interval_us;
        }
        if (c.sender.shouldSend(now)) {
            var ibuf: [input.maxPacketLen(32)]u8 = undefined;
            const pkt = c.sender.build(now, &ibuf);
            s.sendOther(.input, @intFromEnum(input.Kind.events), pkt, now);
        }
        if (now >= s.next_feedback) {
            s.sendFeedback(now);
            s.next_feedback = now + s.cfg.feedback_interval_us;
        }
        // Bye once every frame is in and every input event acked.
        const frames_done = s.mine.frames_delivered + s.mine.frames_lost >= s.cfg.frames;
        const input_done = s.mine.input_sent == s.cfg.input_events and c.sender.unacked() == 0;
        if (frames_done and input_done) {
            const since = c.bye_since orelse blk: {
                c.bye_since = now;
                c.next_bye = now;
                break :blk now;
            };
            if (now - since > s.cfg.bye_timeout_us) return s.fail("no bye ack from the host");
            if (now >= c.next_bye) {
                var out: [Summary.wire_len]u8 = undefined;
                s.mine.encode(&out);
                s.sendOther(gate_stream, @intFromEnum(GateKind.bye), &out, now);
                c.next_bye = now + s.cfg.bye_interval_us;
            }
        }
    }

    fn sendFeedback(s: *Session, now: i64) void {
        const c = s.client.?;
        if (c.fb_arrivals.items.len == 0) return;
        var buf: [proto.max_datagram]u8 = undefined;
        // Cut to what fits one datagram; the rest goes next time.
        var n = @min(c.fb_arrivals.items.len, proto.Feedback.max_count);
        while (true) {
            const msg = proto.Feedback{
                .feedback_seq = c.fb_seq,
                .base_seq = @truncate(c.fb_base),
                .ref_time_us = @intCast(now),
                .arrivals = c.fb_arrivals.items[0..n],
            };
            if (proto.encodeFeedback(&buf, s.envSeq(), msg)) |dg| {
                s.sendRaw(dg, .control_fast);
                break;
            } else |_| {
                n /= 2;
                if (n == 0) return;
            }
        }
        c.fb_seq +%= 1;
        s.mine.feedback += 1;
        const rest = c.fb_arrivals.items.len - n;
        std.mem.copyForwards(?u64, c.fb_arrivals.items[0..rest], c.fb_arrivals.items[n..]);
        c.fb_arrivals.shrinkRetainingCapacity(rest);
        c.fb_base += n;
    }

    fn clientVerdict(s: *Session) void {
        const h = s.theirs.?;
        if (s.mine.frames_delivered < s.cfg.frames or s.mine.frames_lost > 0) return s.fail("frames lost");
        if (s.mine.frames_corrupt > 0) return s.fail("corrupt frames");
        if (s.mine.audio_corrupt > 0) return s.fail("corrupt audio datagrams");
        if (h.audio_sent == 0) return s.fail("no audio sent");
        const share = @as(f64, @floatFromInt(s.mine.audio_received)) / @as(f64, @floatFromInt(h.audio_sent));
        // The bye ack can be built before the last few audio datagrams land; allow for that.
        if (share < s.cfg.min_audio_share) return s.fail("too few audio datagrams arrived");
        if (h.input_applied != s.cfg.input_events or h.input_wrong > 0) return s.fail("host did not apply every input event");
        if (s.rx.unknown > 0 or s.rx.malformed > 0) return s.fail("unknown or malformed datagrams");
        s.outcome = .passed;
    }

    /// Human-readable report, one block per side.
    pub fn report(s: *const Session, w: *std.Io.Writer) !void {
        try w.print("{s}: {s}{s}{s}\n", .{
            @tagName(s.role),
            @tagName(s.outcome),
            if (s.reason.len > 0) ": " else "",
            s.reason,
        });
        try w.print("  sent     video {d} audio {d} input {d} control_fast {d} gate {d}\n", .{ s.tx.video, s.tx.audio, s.tx.input, s.tx.control_fast, s.tx.gate });
        try w.print("  received video {d} audio {d} input {d} control_fast {d} gate {d} unknown {d} malformed {d}\n", .{ s.rx.video, s.rx.audio, s.rx.input, s.rx.control_fast, s.rx.gate, s.rx.unknown, s.rx.malformed });
        const m = s.mine;
        switch (s.role) {
            .host => try w.print("  frames sent {d}, retransmits {d} (from {d} NACKs), audio sent {d}, input applied {d}/{d}, feedback {d}\n", .{ m.frames_sent, m.retransmits, m.nacks, m.audio_sent, m.input_applied, s.cfg.input_events, m.feedback }),
            .client => try w.print("  frames delivered {d}/{d} (lost {d}, corrupt {d}), audio {d} (corrupt {d}), input sent {d}, NACKs {d}, feedback {d}\n", .{ m.frames_delivered, s.cfg.frames, m.frames_lost, m.frames_corrupt, m.audio_received, m.audio_corrupt, m.input_sent, m.nacks, m.feedback }),
        }
        const st = s.stats;
        try w.print("  pipe: rtt {d} us, pacing {d} bit/s, sent {d}, received {d}, send drops {d}, recv drops {d}{s}\n", .{ st.rtt_us, st.pacing_bps, st.sent, st.received, st.send_drops, st.recv_drops, if (st.relayed) ", relayed" else "" });
    }
};
