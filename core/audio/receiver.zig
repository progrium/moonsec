//! Client side of the audio stream: a jitter buffer that hands the audio stage one
//! codec action per frame, plus Reed-Solomon recovery from parity datagrams.
//!
//! Sans-I/O and codec-agnostic. The audio stage calls `pull(now)` each time the output
//! device needs a frame and runs the returned action on its decoder:
//!
//!   .decode  decode `frame.packet`
//!   .fec     the frame is lost but the next one carries in-band FEC: decode
//!            `frame.packet` (the next frame's packet) in FEC mode for `samples`
//!   .conceal packet-loss concealment for `samples` (decoder called with no packet)
//!   .drop    decode `frame.packet` to keep decoder state, discard the output, and
//!            call `pull` again (the buffer is trimming one frame of latency)
//!   .silence the stream has not started; play `samples` of silence, do not decode
//!
//! Playout is driven by the device clock, not the host's: audio is not the clock
//! master. Each arriving frame's slack (when it will play minus when it arrived) is
//! measured; the largest slack in a window is the buffering seen by the fastest packets,
//! which the buffer holds at `target_us` (20 ms by default) by dropping or concealing
//! one frame when it stays more than half a frame off for `hysteresis` windows. That
//! absorbs up to `target_us` of network jitter and any clock drift between host and
//! client, without growing latency. Frames that arrive after their slot are late and
//! dropped; their slot was already filled by FEC or concealment.

const std = @import("std");
const proto = @import("../proto/root.zig");
const fec = @import("../media/fec.zig");
const wire = @import("wire.zig");

pub const Config = struct {
    /// Samples per channel per frame at 48 kHz (480 = 10 ms).
    frame_samples: u16 = 480,
    /// Buffering the earliest-arriving frames get; jitter up to this is absorbed.
    target_us: i64 = 20_000,
    /// Slack is checked once per window, and at most one frame is trimmed or added.
    window_us: i64 = 1_000_000,
    /// Windows in a row out of band before trimming or adding a frame.
    hysteresis: u8 = 2,

    pub fn frameUs(c: Config) i64 {
        return @divTrunc(@as(i64, c.frame_samples) * 1_000_000, 48_000);
    }
};

pub const Action = union(enum) {
    silence: u16,
    decode: wire.Frame,
    fec: wire.Frame,
    conceal: u16,
    drop: wire.Frame,
};

pub const Stats = struct {
    /// Actions returned, by kind.
    decoded: u64 = 0,
    fec: u64 = 0,
    concealed: u64 = 0,
    dropped: u64 = 0,
    inserted: u64 = 0,
    silence: u64 = 0,
    /// Frames dropped at the first pull to start playout at `target_us` (also `.drop`).
    skipped_at_start: u64 = 0,
    /// Frames rebuilt from RS parity (counted again in `decoded` when played).
    rs_recovered: u64 = 0,
    /// Played frames that came from RS recovery.
    decoded_recovered: u64 = 0,
    /// Frames that arrived after their slot was played.
    late: u64 = 0,
    duplicate: u64 = 0,
    invalid: u64 = 0,
    /// Frames so far ahead of playout that the buffer restarted on them.
    resyncs: u64 = 0,
    /// Largest slack in the last complete window (the fastest frames' buffering), µs.
    delay_us: i64 = 0,
};

const slots = 32;
const groups = 4;
const max_body = wire.FrameHeader.size + wire.max_packet;

const Slot = struct {
    seq: u32 = 0,
    filled: bool = false,
    recovered: bool = false,
    len: u16 = 0,
    body: [max_body]u8 = undefined,
};

const Group = struct {
    used: bool = false,
    done: bool = false,
    first_seq: u32 = 0,
    k: u8 = 0,
    m: u8 = 0,
    lens: [wire.max_group]u16 = undefined,
    shard_len: usize = 0,
    have: [wire.max_parity]bool = @splat(false),
    shards: [wire.max_parity][max_body]u8 = undefined,
};

pub const Receiver = struct {
    cfg: Config,
    frame_us: i64,
    slots: [slots]Slot = @splat(.{}),
    groups: [groups]Group = @splat(.{}),
    scratch: [wire.max_group + wire.max_parity][max_body]u8 = undefined,

    anchored: bool = false,
    started: bool = false,
    next_seq: u32 = 0,
    start_us: i64 = 0,
    last_pull_us: i64 = 0,

    window_end: ?i64 = null,
    win_max_slack: ?i64 = null,
    high: u8 = 0,
    low: u8 = 0,
    pending: enum { none, drop, insert } = .none,
    start_drops: u8 = 0,

    stats: Stats = .{},

    /// The receiver is large (about 45 KB); create it in place.
    pub fn init(self: *Receiver, cfg: Config) void {
        self.* = .{ .cfg = cfg, .frame_us = cfg.frameUs() };
    }

    /// Feeds one audio-stream datagram body (what follows the envelope). `recv_us` is
    /// the arrival time on the client clock (`PacketPipe` `Received.recv_us`).
    pub fn onMessage(r: *Receiver, env: proto.Envelope, body: []const u8, recv_us: i64) void {
        std.debug.assert(env.stream == .audio);
        switch (@as(wire.Kind, @enumFromInt(env.kind))) {
            .frame => r.pushFrame(body, recv_us, false),
            .parity => r.pushParity(body),
            _ => {},
        }
    }

    fn slotFor(r: *Receiver, seq: u32) ?*Slot {
        const s = &r.slots[seq % slots];
        return if (s.filled and s.seq == seq) s else null;
    }

    fn frameOf(s: *const Slot) wire.Frame {
        return wire.Frame.parse(s.body[0..s.len]) catch unreachable;
    }

    /// When frame `seq` is due to play, on the client clock.
    fn playTime(r: *const Receiver, seq: u32) i64 {
        const next_play = if (r.started) r.last_pull_us + r.frame_us else r.start_us;
        return next_play + @as(i64, proto.seqDiff(seq, r.next_seq)) * r.frame_us;
    }

    fn anchor(r: *Receiver, seq: u32, recv_us: i64) void {
        for (&r.slots) |*s| s.filled = false;
        for (&r.groups) |*g| g.used = false;
        r.anchored = true;
        r.started = false;
        r.next_seq = seq;
        r.start_us = recv_us + r.cfg.target_us;
        r.window_end = null;
        r.win_max_slack = null;
        r.high = 0;
        r.low = 0;
        r.pending = .none;
        r.start_drops = 0;
    }

    fn pushFrame(r: *Receiver, body: []const u8, recv_us: i64, recovered: bool) void {
        const f = wire.Frame.parse(body) catch {
            r.stats.invalid += 1;
            return;
        };
        const seq = f.header.seq;
        if (!r.anchored) r.anchor(seq, recv_us);
        const d = proto.seqDiff(seq, r.next_seq);
        if (d < 0) {
            if (!recovered) r.stats.late += 1;
            return;
        }
        if (d >= slots) {
            if (recovered) return;
            r.stats.resyncs += 1;
            r.anchor(seq, recv_us);
        }
        const s = &r.slots[seq % slots];
        if (s.filled and s.seq == seq) {
            r.stats.duplicate += 1;
            return;
        }
        s.* = .{ .seq = seq, .filled = true, .recovered = recovered, .len = @intCast(body.len) };
        @memcpy(s.body[0..body.len], body);
        if (recovered) {
            r.stats.rs_recovered += 1;
        } else {
            const slack = r.playTime(seq) - recv_us;
            r.win_max_slack = if (r.win_max_slack) |m| @max(m, slack) else slack;
            r.tryRecoverFor(seq);
        }
    }

    fn pushParity(r: *Receiver, body: []const u8) void {
        const p = wire.Parity.parse(body) catch {
            r.stats.invalid += 1;
            return;
        };
        const h = p.header;
        if (!r.anchored) return;
        // Nothing left to rebuild if the group's last frame has played.
        if (proto.seqDiff(h.first_seq +% (h.k - 1), r.next_seq) < 0) return;
        const g = r.groupFor(h.first_seq);
        if (!g.used or g.first_seq != h.first_seq) {
            g.* = .{ .used = true, .first_seq = h.first_seq, .k = h.k, .m = h.m, .shard_len = p.shard.len };
            @memcpy(g.lens[0..h.k], h.lens[0..h.k]);
        } else if (g.k != h.k or g.m != h.m or g.shard_len != p.shard.len) {
            r.stats.invalid += 1;
            return;
        }
        if (g.done or g.have[h.index]) return;
        @memcpy(g.shards[h.index][0..p.shard.len], p.shard);
        g.have[h.index] = true;
        r.tryRecover(g);
    }

    /// The group slot for `first_seq`: the one holding it, else an unused or the oldest.
    fn groupFor(r: *Receiver, first_seq: u32) *Group {
        var pick: *Group = &r.groups[0];
        for (&r.groups) |*g| {
            if (g.used and g.first_seq == first_seq) return g;
            if (!g.used) {
                pick = g;
            } else if (pick.used and proto.seqBefore(g.first_seq, pick.first_seq)) pick = g;
        }
        return pick;
    }

    fn tryRecoverFor(r: *Receiver, seq: u32) void {
        for (&r.groups) |*g| {
            if (g.used and !g.done and proto.seqDiff(seq, g.first_seq) >= 0 and proto.seqDiff(seq, g.first_seq) < g.k) r.tryRecover(g);
        }
    }

    fn tryRecover(r: *Receiver, g: *Group) void {
        const k = g.k;
        var present: [wire.max_group + wire.max_parity]bool = undefined;
        var missing: usize = 0;
        var useful = false;
        for (0..k) |i| {
            const seq = g.first_seq +% @as(u32, @intCast(i));
            present[i] = r.slotFor(seq) != null;
            if (!present[i]) {
                missing += 1;
                if (proto.seqDiff(seq, r.next_seq) >= 0) useful = true;
            }
        }
        var parity: usize = 0;
        for (0..g.m) |i| {
            present[k + i] = g.have[i];
            if (g.have[i]) parity += 1;
        }
        if (missing == 0) {
            g.done = true;
            return;
        }
        if (!useful or missing > parity) return;

        const len = g.shard_len;
        var shards: [wire.max_group + wire.max_parity][]u8 = undefined;
        for (0..k) |i| {
            const buf = r.scratch[i][0..len];
            if (r.slotFor(g.first_seq +% @as(u32, @intCast(i)))) |s| {
                if (s.len > len) return; // inconsistent with the parity header
                @memcpy(buf[0..s.len], s.body[0..s.len]);
                @memset(buf[s.len..], 0);
            }
            shards[i] = buf;
        }
        for (0..g.m) |i| shards[k + i] = g.shards[i][0..len];
        const codec = fec.Codec.init(k, g.m) catch return;
        codec.reconstruct(shards[0 .. k + g.m], present[0 .. k + g.m]) catch return;
        g.done = true;
        for (0..k) |i| {
            if (present[i]) continue;
            r.pushFrame(r.scratch[i][0..g.lens[i]], r.last_pull_us, true);
        }
    }

    /// The action for the next frame the device needs, at client time `now_us`.
    pub fn pull(r: *Receiver, now_us: i64) Action {
        const n = r.cfg.frame_samples;
        if (!r.anchored or (!r.started and now_us < r.start_us)) {
            r.stats.silence += 1;
            return .{ .silence = n };
        }
        if (!r.started) {
            r.started = true;
            // The first pull comes up to a frame after `start_us`; drop whole frames of
            // that lateness so playout starts on target.
            const late = now_us - r.start_us;
            r.start_drops = @intCast(@divTrunc(late + @divTrunc(r.frame_us, 2) - 1, r.frame_us));
        }
        r.last_pull_us = now_us;
        r.checkWindow(now_us);

        const seq = r.next_seq;
        if (r.pending == .insert) {
            r.pending = .none;
            r.stats.inserted += 1;
            return .{ .conceal = n };
        }
        const cur = r.slotFor(seq);
        if ((r.pending == .drop or r.start_drops > 0) and cur != null and r.slotFor(seq +% 1) != null) {
            if (r.start_drops > 0) {
                r.start_drops -= 1;
                r.stats.skipped_at_start += 1;
            } else {
                r.pending = .none;
                r.stats.dropped += 1;
            }
            r.next_seq +%= 1;
            return .{ .drop = frameOf(cur.?) };
        }
        r.start_drops = 0;
        r.next_seq +%= 1;
        if (cur) |s| {
            r.stats.decoded += 1;
            if (s.recovered) r.stats.decoded_recovered += 1;
            return .{ .decode = frameOf(s) };
        }
        if (r.slotFor(seq +% 1)) |next| {
            const f = frameOf(next);
            if (f.header.hasFec()) {
                r.stats.fec += 1;
                return .{ .fec = f };
            }
        }
        r.stats.concealed += 1;
        return .{ .conceal = n };
    }

    fn checkWindow(r: *Receiver, now_us: i64) void {
        const end = r.window_end orelse {
            r.window_end = now_us + r.cfg.window_us;
            return;
        };
        if (now_us < end) return;
        r.window_end = end + r.cfg.window_us;
        const slack = r.win_max_slack orelse return;
        r.win_max_slack = null;
        r.stats.delay_us = slack;
        const half = @divTrunc(r.frame_us, 2);
        if (slack > r.cfg.target_us + half) {
            r.high += 1;
            r.low = 0;
        } else if (slack < r.cfg.target_us - half) {
            r.low += 1;
            r.high = 0;
        } else {
            r.high = 0;
            r.low = 0;
        }
        if (r.high >= r.cfg.hysteresis) {
            r.high = 0;
            r.pending = .drop;
        } else if (r.low >= r.cfg.hysteresis) {
            r.low = 0;
            r.pending = .insert;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: a sender, a scripted channel and a periodic device, all in this file. The
// libopus-backed runs over transport/sim.zig are in sim/audio.zig.

const testing = std.testing;
const Sender = @import("sender.zig").Sender;

const Harness = struct {
    rx: *Receiver,
    tx: Sender,
    buf: [proto.max_datagram]u8 = undefined,
    env: u32 = 0,

    fn deliver(h: *Harness, dg: []const u8, at: i64) void {
        const m = proto.decode(dg) catch unreachable;
        h.rx.onMessage(m.envelope(), m.other.payload, at);
    }

    /// Sends frame `i` (payload = its index), returns frame datagram and parity datagrams.
    fn send(h: *Harness, i: u32, out: *[3][proto.max_datagram]u8, lens: *[3]usize) usize {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, i, .little);
        const dg = h.tx.frame(&h.buf, h.env, @as(u64, i) * 10_000, 480, true, &payload) catch unreachable;
        h.env += 1;
        @memcpy(out[0][0..dg.len], dg);
        lens[0] = dg.len;
        var n: usize = 1;
        while (h.tx.parity(&h.buf, h.env) catch unreachable) |p| {
            h.env += 1;
            @memcpy(out[n][0..p.len], p);
            lens[n] = p.len;
            n += 1;
        }
        return n;
    }
};

fn payloadIndex(f: wire.Frame) u32 {
    return std.mem.readInt(u32, f.packet[0..4], .little);
}

/// What one pull played: the action's kind and, for decode/fec, the frame index the
/// packet carries (the slices in an `Action` are only valid until the next call).
const Played = struct {
    tag: std.meta.Tag(Action),
    idx: u32 = 0,

    fn of(a: Action) Played {
        return switch (a) {
            .decode, .fec, .drop => |f| .{ .tag = a, .idx = payloadIndex(f) },
            else => .{ .tag = a },
        };
    }
};

const Run = struct {
    /// Per frame: dropped by the channel (frame datagram only).
    lose: []const u32 = &.{},
    lose_parity: bool = false,
    /// Extra delay per frame index (µs), for jitter.
    jitter: ?*const fn (u32) i64 = null,
    one_way_us: i64 = 5_000,
    frames: u32 = 300,
    /// Device pull period, µs per frame (10_000 = no drift).
    pull_period_ns: i64 = 10_000_000,
    rs: bool = true,
};

fn simulate(rx: *Receiver, run: Run, played: []?Played) !void {
    var h: Harness = .{ .rx = rx, .tx = try Sender.init(if (run.rs) .{} else .{ .m = 0 }) };
    const Arrival = struct { at: i64, len: usize, data: [proto.max_datagram]u8 };
    var q: std.ArrayList(Arrival) = .empty;
    defer q.deinit(testing.allocator);
    var next_frame: u32 = 0;
    var pull_ns: i64 = 0;
    var pulls: usize = 0;
    var t: i64 = 0;
    while (pulls < played.len) : (t += 500) {
        while (next_frame < run.frames and @as(i64, next_frame) * 10_000 <= t) : (next_frame += 1) {
            var out: [3][proto.max_datagram]u8 = undefined;
            var lens: [3]usize = undefined;
            const n = h.send(next_frame, &out, &lens);
            for (0..n) |j| {
                if (j == 0 and std.mem.indexOfScalar(u32, run.lose, next_frame) != null) continue;
                if (j > 0 and run.lose_parity) continue;
                const extra = if (run.jitter) |jf| jf(next_frame) else 0;
                var a: Arrival = .{ .at = t + run.one_way_us + extra, .len = lens[j], .data = undefined };
                @memcpy(a.data[0..lens[j]], out[j][0..lens[j]]);
                try q.append(testing.allocator, a);
            }
        }
        var i: usize = 0;
        while (i < q.items.len) {
            if (q.items[i].at <= t) {
                const a = q.orderedRemove(i);
                h.deliver(a.data[0..a.len], t);
            } else i += 1;
        }
        while (pull_ns <= t * 1000 and pulls < played.len) {
            var a = rx.pull(t);
            while (a == .drop) a = rx.pull(t);
            played[pulls] = Played.of(a);
            pulls += 1;
            pull_ns += run.pull_period_ns;
        }
    }
}

test "clean channel: every frame decodes in order after a 20 ms start" {
    const rx = try testing.allocator.create(Receiver);
    defer testing.allocator.destroy(rx);
    rx.init(.{});
    var played: [250]?Played = @splat(null);
    try simulate(rx, .{}, &played);
    // Frame 0 arrives at 5 ms and starts playing at the first pull at or after 25 ms.
    for (played[0..3]) |a| try testing.expectEqual(.silence, a.?.tag);
    var want: u32 = 0;
    for (played[3..]) |a| {
        try testing.expectEqual(.decode, a.?.tag);
        try testing.expectEqual(want, a.?.idx);
        want += 1;
    }
    try testing.expectEqual(@as(u64, 0), rx.stats.concealed + rx.stats.fec + rx.stats.dropped + rx.stats.inserted + rx.stats.late);
    try testing.expect(rx.stats.delay_us >= 15_000 and rx.stats.delay_us <= 25_000);
}

test "single losses: RS rebuilds them; without RS in-band FEC covers them" {
    const lose = [_]u32{ 10, 51, 90, 133 };
    {
        const rx = try testing.allocator.create(Receiver);
        defer testing.allocator.destroy(rx);
        rx.init(.{});
        var played: [200]?Played = @splat(null);
        try simulate(rx, .{ .lose = &lose }, &played);
        try testing.expectEqual(@as(u64, 4), rx.stats.rs_recovered);
        try testing.expectEqual(@as(u64, 4), rx.stats.decoded_recovered);
        try testing.expectEqual(@as(u64, 0), rx.stats.fec + rx.stats.concealed);
        for (played[3..], 0..) |a, i| {
            try testing.expectEqual(.decode, a.?.tag);
            try testing.expectEqual(@as(u32, @intCast(i)), a.?.idx);
        }
    }
    {
        const rx = try testing.allocator.create(Receiver);
        defer testing.allocator.destroy(rx);
        rx.init(.{});
        var played: [200]?Played = @splat(null);
        try simulate(rx, .{ .lose = &lose, .rs = false }, &played);
        try testing.expectEqual(@as(u64, 4), rx.stats.fec);
        try testing.expectEqual(@as(u64, 0), rx.stats.concealed);
        // Frame 10's slot plays frame 11's packet in FEC mode.
        try testing.expectEqual(Played{ .tag = .fec, .idx = 11 }, played[13].?);
        try testing.expectEqual(Played{ .tag = .decode, .idx = 11 }, played[14].?);
    }
}

test "a burst longer than RS and FEC cover is concealed" {
    const rx = try testing.allocator.create(Receiver);
    defer testing.allocator.destroy(rx);
    rx.init(.{});
    var played: [100]?Played = @splat(null);
    // Frames 20-23 lost and no parity: 20-22 conceal, 23 plays from 24's FEC.
    try simulate(rx, .{ .lose = &.{ 20, 21, 22, 23 }, .lose_parity = true }, &played);
    try testing.expectEqual(@as(u64, 3), rx.stats.concealed);
    try testing.expectEqual(@as(u64, 1), rx.stats.fec);
}

fn jitter15(i: u32) i64 {
    // Deterministic pseudo-random 0-15 ms, in order of arrival not preserved.
    return @intCast((@as(u64, i) *% 2654435761) % 15_000);
}

fn jitter35(i: u32) i64 {
    return @intCast((@as(u64, i) *% 2654435761) % 35_000);
}

test "jitter within the target plays every frame; beyond it frames are late" {
    {
        const rx = try testing.allocator.create(Receiver);
        defer testing.allocator.destroy(rx);
        rx.init(.{});
        var played: [280]?Played = @splat(null);
        try simulate(rx, .{ .jitter = jitter15 }, &played);
        try testing.expectEqual(@as(u64, 0), rx.stats.late);
        try testing.expectEqual(@as(u64, 0), rx.stats.concealed);
    }
    {
        const rx = try testing.allocator.create(Receiver);
        defer testing.allocator.destroy(rx);
        rx.init(.{});
        var played: [280]?Played = @splat(null);
        try simulate(rx, .{ .jitter = jitter35 }, &played);
        try testing.expect(rx.stats.late > 10);
    }
}

test "device clock drift is absorbed by trimming or adding frames" {
    // Device 0.25% slow: the buffer grows by a frame every 4 s, so frames get dropped.
    // (Real clocks drift about 100 ppm; this is 25x that.)
    {
        const rx = try testing.allocator.create(Receiver);
        defer testing.allocator.destroy(rx);
        rx.init(.{});
        var played: [3000]?Played = @splat(null);
        try simulate(rx, .{ .frames = 3100, .pull_period_ns = 10_025_000 }, &played);
        try testing.expect(rx.stats.dropped >= 6 and rx.stats.dropped <= 9);
        try testing.expectEqual(@as(u64, 0), rx.stats.concealed + rx.stats.inserted + rx.stats.late);
        // At most a frame over target while the hysteresis waits out two windows.
        try testing.expect(rx.stats.delay_us <= 20_000 + 10_000);
    }
    // Device 0.25% fast: the buffer drains, so frames get added before any arrives late.
    {
        const rx = try testing.allocator.create(Receiver);
        defer testing.allocator.destroy(rx);
        rx.init(.{});
        var played: [3000]?Played = @splat(null);
        try simulate(rx, .{ .frames = 3100, .pull_period_ns = 9_975_000 }, &played);
        try testing.expect(rx.stats.inserted >= 6 and rx.stats.inserted <= 9);
        try testing.expectEqual(@as(u64, 0), rx.stats.late + rx.stats.concealed);
    }
}

test "a frame far ahead of playout restarts the buffer" {
    const rx = try testing.allocator.create(Receiver);
    defer testing.allocator.destroy(rx);
    rx.init(.{});
    var tx = try Sender.init(.{ .m = 0 });
    var buf: [proto.max_datagram]u8 = undefined;
    const dg0 = try tx.frame(&buf, 0, 0, 480, false, "a");
    const m0 = try proto.decode(dg0);
    rx.onMessage(m0.envelope(), m0.other.payload, 0);
    tx.next_seq = 1000;
    const dg1 = try tx.frame(&buf, 1, 0, 480, false, "b");
    const m1 = try proto.decode(dg1);
    rx.onMessage(m1.envelope(), m1.other.payload, 5_000);
    try testing.expectEqual(@as(u64, 1), rx.stats.resyncs);
    try testing.expect(rx.pull(10_000) == .silence);
    const a = rx.pull(25_000);
    try testing.expectEqual(@as(u32, 1000), a.decode.header.seq);
}
