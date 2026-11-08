//! Scripted loss tests: host and client recovery driven against a model of VideoToolbox's
//! long-term references, replaying the frame schedules of S7b's runs (101 of 101 losses
//! recovered bit-exact on real hardware) and seeded random loss.
//!
//! The encoder model gives each frame a content hash chained from its reference: a P frame
//! references the previous emitted frame, a refresh the newest LTR the encoder was told is
//! acked, an IDR nothing. The decoder model chains from what the client actually decoded, so a
//! client hash that differs from the host's is what S7b's luma-hash mismatch caught: a frame
//! decoded against the wrong reference.

const std = @import("std");
const r = @import("root.zig");
const Force = r.host.Force;

const testing = std.testing;
const tick_us: u64 = 16_667;

fn mix(a: u64, b: u64) u64 {
    var x = a ^ (b +% 0x9e3779b97f4a7c15 +% (a << 6) +% (a >> 2));
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    return x;
}

const RefKind = enum { none, prev, ltr };

/// What travels over the simulated wire for one frame: our header plus the "bitstream".
const Wire = struct {
    meta: r.FrameMeta,
    ref: RefKind,
    ref_frame: r.FrameId, // for .ltr
    host_hash: u64,
    capture: u32,
};

const Pending = struct { at: u64, ack: r.Ack };

const Options = struct {
    ack_delay_ticks: u32 = 3,
    /// Extra random reverse-path delay in ticks (0..n) and drop probability.
    reverse_jitter_ticks: u32 = 0,
    reverse_loss: f64 = 0,
    /// Forward path: frames arrive in the tick they are sent, or one tick later with this probability.
    forward_late: f64 = 0,
    no_freeze: bool = false,
    host: r.host.Config = .{},
    seed: u64 = 1,
};

const Result = struct {
    emitted: u32 = 0,
    decoded: u32 = 0,
    mismatches: u32 = 0,
    ltr_errors: u32 = 0,
    refreshes: u32 = 0,
    idrs: u32 = 0,
};

/// Replays one schedule. `sched[i]` is the encoder's outcome for capture index i: 't' (frame
/// with an LTR token), 'p' (no token) or '.' (dropped). `lost(i)` says whether the frame for
/// capture index i is lost on the way to the client.
fn Sim(comptime Lost: type) type {
    return struct {
        const Self = @This();

        a: std.mem.Allocator,
        opt: Options,
        lost: Lost,
        rng: std.Random.DefaultPrng,
        host: r.Host,
        client: r.Client,
        res: Result = .{},

        // encoder model
        next_id: r.FrameId = 0,
        prev_hash: u64 = 0,
        enc_acked: std.AutoHashMapUnmanaged(r.LtrToken, struct { id: r.FrameId, hash: u64 }) = .empty,
        token_of: std.ArrayListUnmanaged(?r.LtrToken) = .empty,
        host_hash: std.ArrayListUnmanaged(u64) = .empty,
        capture_of: std.ArrayListUnmanaged(u32) = .empty,
        flags_of: std.ArrayListUnmanaged(r.FrameFlags) = .empty,
        // decoder model
        dec_hash: std.AutoHashMapUnmanaged(r.FrameId, u64) = .empty,
        dec_last: ?u64 = null,
        /// Capture index of each frame the client decoded with a matching hash.
        decoded_ok: std.DynamicBitSetUnmanaged = .{},
        decoded_bad: std.DynamicBitSetUnmanaged = .{},
        // network
        reverse: std.ArrayListUnmanaged(Pending) = .empty,
        late: ?Wire = null,

        fn init(a: std.mem.Allocator, n: usize, lost: Lost, opt: Options) !Self {
            var s: Self = .{
                .a = a,
                .opt = opt,
                .lost = lost,
                .rng = .init(opt.seed),
                .host = .init(opt.host),
                .client = .init(.{ .frame_interval_us = tick_us }),
            };
            s.client.setRtt(@as(u64, opt.ack_delay_ticks) * tick_us);
            s.host.setRetryWindow(opt.ack_delay_ticks + 1);
            s.decoded_ok = try .initEmpty(a, n);
            s.decoded_bad = try .initEmpty(a, n);
            return s;
        }

        fn deinit(s: *Self) void {
            s.enc_acked.deinit(s.a);
            s.token_of.deinit(s.a);
            s.host_hash.deinit(s.a);
            s.capture_of.deinit(s.a);
            s.flags_of.deinit(s.a);
            s.dec_hash.deinit(s.a);
            s.decoded_ok.deinit(s.a);
            s.decoded_bad.deinit(s.a);
            s.reverse.deinit(s.a);
        }

        fn run(s: *Self, sched: []const u8) !void {
            for (sched, 0..) |outcome, i| try s.tick(@intCast(i), outcome);
        }

        fn tick(s: *Self, i: u32, outcome: u8) !void {
            const now = @as(u64, i) * tick_us;
            // Client-to-host messages due by this frame's encode.
            var k: usize = 0;
            while (k < s.reverse.items.len) {
                if (s.reverse.items[k].at <= now) {
                    s.host.onAck(&s.reverse.items[k].ack);
                    _ = s.reverse.orderedRemove(k);
                } else k += 1;
            }

            // Late frame from the previous tick arrives first.
            if (s.late) |w| {
                s.late = null;
                try s.deliver(w, now);
            }

            const d = s.host.nextEncode();
            for (d.acked_tokens) |t| {
                // Encoder learns the ack; it can only refer to frames it emitted with that token.
                for (s.token_of.items, 0..) |tok, id| if (tok != null and tok.? == t) {
                    try s.enc_acked.put(s.a, t, .{ .id = @intCast(id), .hash = s.host_hash.items[id] });
                };
            }
            if (outcome == '.') {
                s.host.onEncodeDropped();
            } else {
                try s.emit(i, outcome, d.force, now);
            }

            // Client output.
            if (s.client.poll(now)) |a| try s.send(a, now);
        }

        fn emit(s: *Self, i: u32, outcome: u8, force: Force, now: u64) !void {
            const id = s.next_id;
            s.next_id += 1;
            const key = force == .idr or id == 0;
            var ref: RefKind = if (key) .none else .prev;
            var ref_frame: r.FrameId = 0;
            var base: u64 = if (key) 0 else s.prev_hash;
            if (force == .ltr_refresh) {
                // VideoToolbox refreshes from the newest acked long-term reference.
                var best: ?r.FrameId = null;
                var it = s.enc_acked.valueIterator();
                while (it.next()) |v| if (best == null or v.id > best.?) {
                    best = v.id;
                    base = v.hash;
                };
                try testing.expect(best != null); // host only forces a refresh with an acked LTR
                ref = .ltr;
                ref_frame = best.?;
            }
            if (key) s.enc_acked.clearRetainingCapacity();
            const h = mix(base, id);
            s.prev_hash = h;
            const token: ?r.LtrToken = if (outcome == 't') id *% 7919 +% 13 else null;
            const flags = s.host.onEncoded(id, token, key);
            try testing.expectEqual(key, flags.keyframe);
            try testing.expectEqual(force == .ltr_refresh, flags.refresh);
            if (flags.refresh) s.res.refreshes += 1;
            if (flags.keyframe and id != 0) s.res.idrs += 1;
            try s.token_of.append(s.a, token);
            try s.host_hash.append(s.a, h);
            try s.capture_of.append(s.a, i);
            try s.flags_of.append(s.a, flags);
            s.res.emitted += 1;

            const w: Wire = .{
                .meta = .{ .frame_id = id, .keyframe = flags.keyframe, .refresh = flags.refresh, .ltr_token = token },
                .ref = ref,
                .ref_frame = ref_frame,
                .host_hash = h,
                .capture = i,
            };
            if (s.lost.isLost(i, w.meta, &s.rng)) return;
            if (s.opt.forward_late > 0 and s.late == null and s.rng.random().float(f64) < s.opt.forward_late) {
                s.late = w;
                return;
            }
            try s.deliver(w, now);
        }

        fn deliver(s: *Self, w: Wire, now: u64) !void {
            const v = s.client.onFrame(w.meta, now);
            if (v == .drop and !s.opt.no_freeze) return;
            // Decoder model.
            var ok = true;
            const base: ?u64 = switch (w.ref) {
                .none => 0,
                .prev => s.dec_last,
                .ltr => s.dec_hash.get(w.ref_frame),
            };
            if (base == null) {
                ok = false; // missing reference: decode error
                if (w.ref == .ltr) s.res.ltr_errors += 1;
            }
            if (ok) {
                const h = mix(base.?, w.meta.frame_id);
                s.dec_last = h;
                try s.dec_hash.put(s.a, w.meta.frame_id, h);
                s.res.decoded += 1;
                if (h == w.host_hash) s.decoded_ok.set(w.capture) else {
                    s.res.mismatches += 1;
                    s.decoded_bad.set(w.capture);
                }
            }
            s.client.onDecoded(w.meta, ok, now);
        }

        fn send(s: *Self, a: r.Ack, now: u64) !void {
            if (s.opt.reverse_loss > 0 and s.rng.random().float(f64) < s.opt.reverse_loss) return;
            var delay: u64 = s.opt.ack_delay_ticks;
            if (s.opt.reverse_jitter_ticks > 0) delay += s.rng.random().uintAtMost(u32, s.opt.reverse_jitter_ticks);
            try s.reverse.append(s.a, .{ .at = now + delay * tick_us, .ack = a });
        }
    };
}

// ---------------------------------------------------------------------------------------------
// S7b replay

const s7b_every = 300;
const s7b_len = 5;
const s7b_ack = 3;

const S7bLoss = struct {
    fn isLost(_: S7bLoss, i: u32, _: r.FrameMeta, _: *std.Random.DefaultPrng) bool {
        return i >= s7b_every and i % s7b_every < s7b_len;
    }
};

const Run = struct {
    name: []const u8,
    frames: u32,
    events: u32,
    s7b_recovered: u32,
    sched: []u8,
};

fn parseRuns(a: std.mem.Allocator) !std.ArrayListUnmanaged(Run) {
    var runs: std.ArrayListUnmanaged(Run) = .empty;
    // Any line ending: a Windows checkout may turn the file into CRLF.
    var lines = std.mem.tokenizeAny(u8, @embedFile("testdata/s7b_runs.txt"), "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        var run: Run = .{
            .name = f.next().?,
            .frames = try std.fmt.parseInt(u32, f.next().?, 10),
            .events = try std.fmt.parseInt(u32, f.next().?, 10),
            .s7b_recovered = try std.fmt.parseInt(u32, f.next().?, 10),
            .sched = undefined,
        };
        var sched: std.ArrayListUnmanaged(u8) = .empty;
        while (f.next()) |rl| try sched.appendNTimes(a, rl[0], try std.fmt.parseInt(usize, rl[1..], 10));
        try testing.expectEqual(run.frames, sched.items.len);
        run.sched = try sched.toOwnedSlice(a);
        try runs.append(a, run);
    }
    return runs;
}

const S7bSim = Sim(S7bLoss);

const EventOutcome = struct { recovered: bool, refresh_capture: ?u32 };

/// S7b's pass rule for the loss at capture `at`: the stream recovers with a non-IDR refresh, and
/// every frame from the recovery point to the next loss decodes bit-exact.
fn checkEvent(s: *const S7bSim, sched: []const u8, at: u32) EventOutcome {
    const end: u32 = @intCast(@min(at + s7b_every, sched.len));
    var lost_any = false;
    for (at..at + s7b_len) |i| if (sched[i] != '.') {
        lost_any = true;
    };
    // First recovery frame emitted at or after the loss.
    var rf: ?u32 = null;
    for (s.capture_of.items, s.flags_of.items) |c, fl| {
        if (c >= at and c < end and (fl.refresh or fl.keyframe)) {
            if (fl.keyframe) return .{ .recovered = false, .refresh_capture = null };
            rf = c;
            break;
        }
    }
    if (lost_any and rf == null) return .{ .recovered = false, .refresh_capture = null };
    const from = rf orelse at + s7b_len;
    for (from..end) |i| {
        if (sched[i] == '.') continue;
        if (!s.decoded_ok.isSet(i)) return .{ .recovered = false, .refresh_capture = rf };
    }
    return .{ .recovered = true, .refresh_capture = rf };
}

test "S7b replay: every loss recovers bit-exact with an LTR refresh" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runs = try parseRuns(a);

    var events: u32 = 0;
    var recovered: u32 = 0;
    var s7b_total: u32 = 0;
    var s7b_ok: u32 = 0;
    for (runs.items) |run| {
        var s = try S7bSim.init(a, run.sched.len, .{}, .{});
        try s.run(run.sched);

        try testing.expectEqual(@as(u32, 0), s.res.mismatches);
        try testing.expectEqual(@as(u32, 0), s.res.ltr_errors);
        try testing.expectEqual(@as(u32, 0), s.res.idrs);

        var at: u32 = s7b_every;
        var n: u32 = 0;
        while (at + s7b_len + s7b_ack < run.frames) : (at += s7b_every) {
            n += 1;
            const o = checkEvent(&s, run.sched, at);
            if (!o.recovered) std.debug.print("{s}: loss at {d} not recovered\n", .{ run.name, at });
            try testing.expect(o.recovered);
            recovered += 1;
            // Same timing as S7b: the client sees the gap at the first frame after the loss and
            // the request lands ack_delay frames later, so the refresh is the first frame emitted
            // at or after (first post-loss frame + 3); for S7b's usual schedule that is loss + 8.
            if (o.refresh_capture) |c| {
                var seen: u32 = at + s7b_len;
                while (run.sched[seen] == '.') seen += 1;
                var want: u32 = seen + s7b_ack;
                while (run.sched[want] == '.') want += 1;
                try testing.expectEqual(want, c);
            }
        }
        try testing.expectEqual(run.events, n);
        events += n;
        s7b_total += run.events;
        s7b_ok += run.s7b_recovered;
    }
    // S7b counted 104 loss events: 101 recovered bit-exact on hardware, and 3 in the noise run
    // failed only because the encoder dropped the fixed refresh frame. Here the force carries
    // to the next emitted frame, so all 104 recover.
    try testing.expectEqual(@as(u32, 104), s7b_total);
    try testing.expectEqual(@as(u32, 101), s7b_ok);
    try testing.expectEqual(@as(u32, 104), events);
    try testing.expectEqual(@as(u32, 104), recovered);
}

test "S7b replay, negative control: decoding through the gap corrupts the stream" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runs = try parseRuns(a);
    const run = runs.items[0];
    var s = try S7bSim.init(a, run.sched.len, .{}, .{ .no_freeze = true });
    try s.run(run.sched);
    try testing.expect(s.res.mismatches > 0);
}

test "S7b replay with IDR-only backend recovers every loss with an IDR" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runs = try parseRuns(a);
    for (runs.items) |run| {
        var s = try S7bSim.init(a, run.sched.len, .{}, .{ .host = .{ .ltr = false } });
        try s.run(run.sched);
        try testing.expectEqual(@as(u32, 0), s.res.mismatches);
        try testing.expectEqual(@as(u32, 0), s.res.refreshes);
        try testing.expect(s.res.idrs >= 1);
        try testing.expectEqual(@as(u32, 0), s.client.stats.retries);
        try testing.expectEqual(State.decoding, s.client.state);
    }
}

const State = r.client.State;

// ---------------------------------------------------------------------------------------------
// Scripted edge cases on a clean schedule

const ListLoss = struct {
    lost: []const u32,
    fn isLost(l: ListLoss, i: u32, _: r.FrameMeta, _: *std.Random.DefaultPrng) bool {
        return std.mem.indexOfScalar(u32, l.lost, i) != null;
    }
};

fn allTokens(a: std.mem.Allocator, n: usize) ![]u8 {
    const s = try a.alloc(u8, n);
    @memset(s, 't');
    return s;
}

test "lost refresh: client retries, host refreshes again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Loss at 100; refresh lands at 104 (first post-loss frame 101 + 3) and is lost too.
    var s = try Sim(ListLoss).init(a, 400, .{ .lost = &.{ 100, 104 } }, .{});
    try s.run(try allTokens(a, 400));
    try testing.expectEqual(@as(u32, 0), s.res.mismatches);
    try testing.expectEqual(@as(u32, 2), s.res.refreshes);
    try testing.expectEqual(@as(u32, 0), s.res.idrs);
    try testing.expectEqual(@as(u64, 1), s.client.stats.retries);
    try testing.expectEqual(State.decoding, s.client.state);
    try testing.expect(s.decoded_ok.isSet(399));
}

/// Loses capture `at` and every refresh frame.
const RefreshLoss = struct {
    at: u32,
    fn isLost(l: RefreshLoss, i: u32, m: r.FrameMeta, _: *std.Random.DefaultPrng) bool {
        return i == l.at or m.refresh;
    }
};

test "refreshes keep getting lost: host falls back to IDR" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sim(RefreshLoss).init(a, 400, .{ .at = 100 }, .{});
    try s.run(try allTokens(a, 400));
    try testing.expectEqual(@as(u32, 0), s.res.mismatches);
    // max_ltr_attempts (2) refreshes, both lost, then the client's next retry gets an IDR.
    try testing.expectEqual(@as(u32, 2), s.res.refreshes);
    try testing.expectEqual(@as(u32, 1), s.res.idrs);
    try testing.expectEqual(@as(u64, 2), s.client.stats.retries);
    try testing.expectEqual(State.decoding, s.client.state);
    try testing.expect(s.decoded_ok.isSet(399));
}

test "nothing acked (encoder marks no long-term references): IDR" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sched = try a.alloc(u8, 100);
    @memset(sched, 'p');
    var s = try Sim(ListLoss).init(a, 100, .{ .lost = &.{50} }, .{});
    try s.run(sched);
    try testing.expectEqual(@as(u32, 0), s.res.mismatches);
    try testing.expectEqual(@as(u32, 0), s.res.refreshes);
    try testing.expectEqual(@as(u32, 1), s.res.idrs);
    try testing.expect(s.decoded_ok.isSet(99));
}

test "lost first keyframe: client asks for an IDR" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Sim(ListLoss).init(a, 100, .{ .lost = &.{0} }, .{});
    try s.run(try allTokens(a, 100));
    try testing.expectEqual(@as(u32, 0), s.res.mismatches);
    try testing.expectEqual(@as(u32, 1), s.res.idrs);
    try testing.expect(s.decoded_ok.isSet(99));
}

test "tokens on only some frames: refresh uses the newest acked one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sched = try a.alloc(u8, 300);
    for (sched, 0..) |*c, i| c.* = if (i % 3 == 0) 't' else 'p';
    var s = try Sim(ListLoss).init(a, 300, .{ .lost = &.{ 50, 51, 200 } }, .{});
    try s.run(sched);
    try testing.expectEqual(@as(u32, 0), s.res.mismatches);
    try testing.expectEqual(@as(u32, 2), s.res.refreshes);
    try testing.expectEqual(@as(u32, 0), s.res.idrs);
}

// ---------------------------------------------------------------------------------------------
// Seeded random loss

/// Gilbert-Elliott bursts: mean burst `1/p_bad_to_good`, overall rate about `rate`.
const BurstLoss = struct {
    rate: f64,
    burst: f64,
    bad: bool = false,
    fn isLost(l: *BurstLoss, _: u32, rng: *std.Random.DefaultPrng) bool {
        const rnd = rng.random();
        const leave = 1.0 / l.burst;
        const enter = l.rate * leave / (1.0 - l.rate);
        l.bad = if (l.bad) rnd.float(f64) >= leave else rnd.float(f64) < enter;
        return l.bad;
    }
};

const BurstPtr = struct {
    p: *BurstLoss,
    fn isLost(l: BurstPtr, i: u32, _: r.FrameMeta, rng: *std.Random.DefaultPrng) bool {
        return l.p.isLost(i, rng);
    }
};

test "seeded random loss: never decodes against a wrong reference and always recovers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 6000; // 100 s at 60 fps
    const cases = [_]struct { rate: f64, burst: f64, rev_loss: f64, jitter: u32, late: f64, delay: u32 }{
        .{ .rate = 0.01, .burst = 1, .rev_loss = 0, .jitter = 0, .late = 0, .delay = 1 },
        .{ .rate = 0.02, .burst = 3, .rev_loss = 0.02, .jitter = 2, .late = 0, .delay = 3 },
        .{ .rate = 0.05, .burst = 2, .rev_loss = 0.05, .jitter = 3, .late = 0.01, .delay = 5 },
        .{ .rate = 0.10, .burst = 4, .rev_loss = 0.10, .jitter = 4, .late = 0.02, .delay = 8 },
    };
    for (cases) |c| {
        var seed: u64 = 1;
        while (seed <= 10) : (seed += 1) {
            var rng: std.Random.DefaultPrng = .init(seed * 7777);
            const sched = try a.alloc(u8, n);
            for (sched) |*ch| {
                const x = rng.random().float(f64);
                ch.* = if (x < 0.02) '.' else if (x < 0.30) 'p' else 't';
            }
            sched[0] = 't';
            var bl: BurstLoss = .{ .rate = c.rate, .burst = c.burst };
            var s = try Sim(BurstPtr).init(a, n + 200, .{ .p = &bl }, .{
                .seed = seed,
                .ack_delay_ticks = c.delay,
                .reverse_jitter_ticks = c.jitter,
                .reverse_loss = c.rev_loss,
                .forward_late = c.late,
            });
            try s.run(sched);
            // Feed a clean tail so the last freeze can end.
            bl.rate = 0;
            bl.bad = false;
            for (0..200) |k| try s.tick(@intCast(n + k), 't');

            try testing.expectEqual(@as(u32, 0), s.res.mismatches);
            try testing.expectEqual(@as(u32, 0), s.res.ltr_errors);
            if (s.client.state != .decoding) {
                std.debug.print("case {any} seed {d}: still {t}, {any}\n", .{ c, seed, s.client.state, s.client.stats });
                return error.StillFrozen;
            }
            // Most recoveries are LTR refreshes, not IDRs.
            try testing.expect(s.res.refreshes > 4 * s.res.idrs);
            // A freeze lasts about one round trip plus a frame unless retries were needed.
            const rt_us = (@as(u64, c.delay) * 2 + c.jitter + 4) * tick_us;
            const mean = s.client.stats.frozen_us_total / @max(1, s.client.stats.freezes);
            if (mean > 2 * rt_us) {
                std.debug.print("case {any} seed {d}: mean freeze {d} us\n", .{ c, seed, mean });
                return error.FreezeTooLong;
            }
        }
    }
}
