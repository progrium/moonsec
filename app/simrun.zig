//! The host and client apps with the synthetic backend over the in-process simulated
//! network, in virtual time: the unit tests, `moonsec sim` and the soak.
//!
//! Each side's clock is its simulated local clock; nothing blocks, so an hour of
//! streaming runs in a minute or two and every run with the same seed is identical.
const std = @import("std");
const core = @import("core");
const api = @import("platform");
const simnet = @import("simnet");
const synthetic = @import("synthetic");
const apps = @import("apps.zig");
const clipboard = @import("clipboard");
pub const pathsim = @import("pathsim.zig");

const Micros = i64;

pub const Profile = enum {
    /// Wired LAN, the Phase 2 gate's setting: 1 ms each way, 0.3 ms jitter, 100 Mbit/s,
    /// 0.5% random loss and 1% reordering in each direction.
    lan,
    /// The Phase 1 gate's path: 10 ms each way, 3 ms jitter, 50 Mbit/s, 2% loss, 2% reordering.
    wan,
    /// A long-haul path where NACK is too slow: 60 ms each way, 2 ms jitter, 50 Mbit/s,
    /// 5% loss. A retransmit would land after the client's 100 ms frame timeout.
    longhaul,
    /// No loss, no jitter.
    clean,

    pub fn link(p: Profile) simnet.LinkConfig {
        return switch (p) {
            .lan => .{ .steps = &.{.{ .t_us = 0, .bps = 100e6 }}, .delay_us = 1 * simnet.MS, .jitter_us = 300, .loss = 0.005, .reorder_p = 0.01, .reorder_extra_us = 1 * simnet.MS, .overhead_bytes = 48 },
            .wan => .{ .steps = &.{.{ .t_us = 0, .bps = 50e6 }}, .delay_us = 10 * simnet.MS, .jitter_us = 3 * simnet.MS, .loss = 0.02, .reorder_p = 0.02, .reorder_extra_us = 5 * simnet.MS, .overhead_bytes = 48 },
            .longhaul => .{ .steps = &.{.{ .t_us = 0, .bps = 50e6 }}, .delay_us = 60 * simnet.MS, .jitter_us = 2 * simnet.MS, .loss = 0.05, .overhead_bytes = 48 },
            .clean => .{ .steps = &.{.{ .t_us = 0, .bps = 100e6 }}, .delay_us = 1 * simnet.MS, .overhead_bytes = 48 },
        };
    }
};

pub const Options = struct {
    seed: u64 = 1,
    profile: Profile = .lan,
    seconds: u32 = 10,
    fps: u32 = 60,
    bitrate_bps: u64 = 10_000_000,
    width: u32 = 320,
    height: u32 = 180,
    slices: u8 = 4,
    /// Virtual-time step.
    step_us: Micros = 250,
    /// Loss starts this long after the start, so the first keyframe gets through cleanly
    /// (joining under loss is recovery's job, tested in core/recovery).
    warmup_us: Micros = 300_000,
    /// The client's clock runs this far from the host's.
    clock_offset_us: Micros = 3_217_000_000,
    /// Print a progress line every this many simulated seconds (0: never).
    progress_every_s: u32 = 0,
    input_interval_us: Micros = 25_000,
    /// Drop every host-to-client datagram for `outage_us` starting at `outage_at_us`
    /// (0: none), long enough that frames are lost and recovery has to step in.
    outage_at_us: Micros = 0,
    outage_us: Micros = 0,
    /// Stream the synthetic tone over the Opus stage alongside the video.
    audio: bool = true,
    /// Let the rate controller drive the encoder bitrate (Phase 3), from `bitrate_bps`.
    rate_control: bool = false,
    /// Host picks NACK, FEC or relay mode per path (`core.media.policy`).
    loss_policy: bool = false,
    /// Scripted path flaps (direct <-> relay) and connection drops (app/pathsim.zig).
    path: ?pathsim.Config = null,
    /// Host and client session settings that differ from the defaults.
    pause_on_stall: bool = true,
    /// The synthetic host's displays (empty: one, `width`×`height`).
    displays: []const api.Size = &.{},
    /// Scripted display events (Phase 5), in time order.
    display_events: []const DisplayEvent = &.{},
    /// Host-to-client capacity schedule instead of the profile's (for the rate ladder).
    downlink_steps: ?[]const simnet.Step = null,
    /// Its bottleneck queue, bytes (0: the sim's default).
    downlink_queue_bytes: u64 = 0,
    /// Run the control channel with in-memory clipboards and this script of copies; the
    /// outcome is written back into it.
    clipboard: ?*ClipScript = null,
};

pub const DisplayEvent = struct {
    at_us: Micros,
    what: union(enum) {
        /// The client asks for a display (`core.display.keep_display`: the current one)
        /// with these caps (0 = none).
        select: struct { display: u32, max_width: u32 = 0, max_height: u32 = 0, max_fps: u16 = 0 },
        /// A host display changes mode.
        mode: struct { display: u32, width: u32, height: u32 },
        /// A display is plugged into the host.
        hotplug: api.Size,
    },
};

/// Copies made on either side during a run, and what each clipboard held at the end.
pub const ClipScript = struct {
    copies: []const Copy = &.{},
    /// Initial content of each side's clipboard (seeded, not sent).
    host_start: []const u8 = "",
    client_start: []const u8 = "",
    // Results.
    host_text: [4096]u8 = undefined,
    host_len: usize = 0,
    client_text: [4096]u8 = undefined,
    client_len: usize = 0,
    /// Writes of the peer's copies into each side's clipboard.
    host_writes: u64 = 0,
    client_writes: u64 = 0,
    /// Copies each side sent, and echoes it suppressed.
    host_sent: u64 = 0,
    client_sent: u64 = 0,
    echoes: u64 = 0,
    /// Control channels that came up (a reconnect brings up a new one).
    host_ups: u64 = 0,
    client_ups: u64 = 0,

    pub const Copy = struct { at_us: Micros, client: bool, text: []const u8 };

    pub fn host(c: *const ClipScript) []const u8 {
        return c.host_text[0..c.host_len];
    }
    pub fn client(c: *const ClipScript) []const u8 {
        return c.client_text[0..c.client_len];
    }
};

pub const Result = struct {
    seconds: u32,
    host: struct {
        frames: u64,
        keyframes: u64,
        refreshes: u64,
        retransmits: u64,
        parity_shards: u64,
        shards: u64,
        keys: u64,
        keys_wrong: u64,
        audio_frames: u64,
        path_changes: u64 = 0,
        reconnects: u64 = 0,
        stall_pauses: u64 = 0,
        stall_frames: u64 = 0,
        reconfigures: u64 = 0,
        display_switches: u64 = 0,
        mode_changes: u64 = 0,
        config_resends: u64 = 0,
        /// The stream at the end.
        width: u32 = 0,
        height: u32 = 0,
        fps: u32 = 0,
        display: u32 = 0,
        end: []const u8,
    },
    client: struct {
        presented: u64,
        unreadable: u64,
        corrupt: u64,
        decode_errors: u64,
        lost: u64,
        freezes: u64,
        longest_gap_us: Micros,
        stalls_100ms: u64,
        input_sent: u64,
        total_p50_us: Micros,
        total_p99_us: Micros,
        audio: Audio,
        path_changes: u64 = 0,
        reconnects: u64 = 0,
        reconnect_requests: u64 = 0,
        config_changes: u64 = 0,
        decoder_reconfigures: u64 = 0,
        /// Displays the client last heard of, and the size of the last presented picture.
        displays: usize = 0,
        width: u32 = 0,
        height: u32 = 0,
        end: []const u8,
    },
    sim_losses: u64,

    pub const Audio = struct {
        /// Frames played from a packet (RS-rebuilt ones included), from FEC, concealed.
        decoded: u64 = 0,
        fec: u64 = 0,
        concealed: u64 = 0,
        rs_recovered: u64 = 0,
        late: u64 = 0,
        /// Sink: times it ran dry once playing, and frames of the tone it played.
        underruns: u64 = 0,
        loud: u64 = 0,
        written: u64 = 0,
        delay_us: i64 = 0,
    };

    pub fn expectedFrames(r: Result, fps: u32) u64 {
        return @as(u64, r.seconds) * fps;
    }

    /// What `moonsec sim`/`soak` and the tests hold a run to. Null when it passes.
    pub fn failure(r: Result, o: Options) ?[]const u8 {
        const want = r.expectedFrames(o.fps);
        if (o.path != null) {
            // Scripted outages freeze the picture by design: hold the run to a clean end,
            // an intact picture, and most frames.
            if (r.client.corrupt > 0) return "the decoder saw a corrupt access unit";
            if (r.client.unreadable > 0) return "a presented frame's pattern did not read back";
            if (!std.mem.eql(u8, r.client.end, "closed") or !std.mem.eql(u8, r.host.end, "client_bye")) return "the session did not end cleanly";
            if (r.client.presented * 100 < want * 50) return "client presented under half of the frames";
            return null;
        }
        if (r.client.presented * 100 < want * 95) return "client presented under 95% of the frames";
        if (r.client.freezes > 0) return "the freeze detector saw a freeze";
        if (r.client.unreadable > 0) return "a presented frame's pattern did not read back";
        if (r.client.corrupt > 0) return "the decoder saw a corrupt access unit";
        if (r.host.keys_wrong > 0) return "input arrived out of order";
        if (o.input_interval_us > 0 and r.host.keys * 100 < r.client.input_sent * 95) return "input events went missing";
        if (r.client.total_p50_us <= 0) return "no glass-to-glass samples";
        if (o.audio) {
            const au = r.client.audio;
            // 100 frames a second; the first few hundred ms go to session setup.
            if ((au.decoded + au.fec) * 100 < (@as(u64, r.seconds) * 100 -| 50) * 95) return "audio played under 95% of its frames";
            if (au.underruns > 0) return "the audio sink ran dry";
            if (au.loud * 100 < au.written * 50) return "the audio sink played mostly silence";
        }
        return null;
    }

    pub fn print(r: Result, w: *std.Io.Writer) !void {
        try w.print("{d} s: host sent {d} frames (keyframes {d}, LTR refreshes {d}, retransmits {d}, parity shards {d}); client presented {d}, lost {d}, decode errors {d}, unreadable {d}, corrupt {d}\n", .{ r.seconds, r.host.frames, r.host.keyframes, r.host.refreshes, r.host.retransmits, r.host.parity_shards, r.client.presented, r.client.lost, r.client.decode_errors, r.client.unreadable, r.client.corrupt });
        try w.print("  freezes {d}, longest gap {d:.1} ms, stalls >100 ms {d}; glass-to-glass p50 {d:.2} ms p99 {d:.2} ms; keys {d}/{d} (wrong {d}); sim losses {d}\n", .{
            r.client.freezes,
            @as(f64, @floatFromInt(r.client.longest_gap_us)) / 1000,
            r.client.stalls_100ms,
            @as(f64, @floatFromInt(r.client.total_p50_us)) / 1000,
            @as(f64, @floatFromInt(r.client.total_p99_us)) / 1000,
            r.host.keys,
            r.client.input_sent,
            r.host.keys_wrong,
            r.sim_losses,
        });
        const au = r.client.audio;
        try w.print("  audio: host sent {d} frames; client played {d} (FEC {d}, RS rebuilt {d}), concealed {d}, late {d}; sink underruns {d}, buffer delay {d:.1} ms\n", .{ r.host.audio_frames, au.decoded + au.fec, au.fec, au.rs_recovered, au.concealed, au.late, au.underruns, @as(f64, @floatFromInt(au.delay_us)) / 1000 });
        try w.print("  host: {s}; client: {s}\n", .{ r.host.end, r.client.end });
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

pub fn run(gpa: std.mem.Allocator, o: Options, log: ?*std.Io.Writer) !Result {
    const net = try gpa.create(simnet.Net);
    defer gpa.destroy(net);
    var cfg: simnet.Config = .{ .seed = o.seed, .a_to_b = o.profile.link(), .b_to_a = o.profile.link() };
    if (o.downlink_steps) |st| cfg.a_to_b.steps = st;
    if (o.downlink_queue_bytes > 0) cfg.a_to_b.queue_limit_bytes = o.downlink_queue_bytes;
    cfg.b.clock_offset_us = o.clock_offset_us;
    const loss = cfg.a_to_b.loss;
    cfg.a_to_b.loss = 0;
    cfg.b_to_a.loss = 0;
    try net.init(gpa, cfg);
    defer net.deinit();

    var hc: SideClock = .{ .net = net, .side = .a };
    var cc: SideClock = .{ .net = net, .side = .b };
    const sh = try synthetic.openHost(gpa, .{ .clock = hc.clock(), .width = o.width, .height = o.height, .displays = o.displays, .audio = o.audio });
    const hb = sh.backend();
    defer hb.deinit();
    const sc = try synthetic.openClient(gpa, .{ .clock = cc.clock(), .input_interval_us = o.input_interval_us, .audio = o.audio });
    const cb = sc.backend();
    defer cb.deinit();

    var model: pathsim.Model = undefined;
    if (o.path) |pc| model.init(pc, net);
    const pipes = if (o.path != null) [2]@TypeOf(net.pipeFor(.a)){ model.pipeFor(.a), model.pipeFor(.b) } else .{ net.pipeFor(.a), net.pipeFor(.b) };
    var host_clip = clipboard.Memory.init(gpa);
    defer host_clip.deinit();
    var client_clip = clipboard.Memory.init(gpa);
    defer client_clip.deinit();
    if (o.clipboard) |cs| {
        if (cs.host_start.len > 0) try host_clip.set(cs.host_start);
        if (cs.client_start.len > 0) try client_clip.set(cs.client_start);
    }
    const with_clip = o.clipboard != null;
    var host = try apps.HostApp.init(gpa, hb, .{
        .fps = o.fps,
        .bitrate_bps = o.bitrate_bps,
        .slices = o.slices,
        .pause_on_stall = o.pause_on_stall,
        .session = .{ .rate_control = o.rate_control, .loss_policy = o.loss_policy },
        .control_stream = if (with_clip) net.streamFor(.a) else null,
        .clipboard = if (with_clip) host_clip.clipboard() else null,
        .clipboard_poll_us = 50_000,
    }, pipes[0]);
    defer host.deinit();
    var client = try apps.ClientApp.init(gpa, cb, .{
        .content_ctx = sc,
        .contentFn = patternContent,
        .control_stream = if (with_clip) net.streamFor(.b) else null,
        .clipboard = if (with_clip) client_clip.clipboard() else null,
        .clipboard_poll_us = 50_000,
    }, pipes[1]);
    defer client.deinit();
    var next_copy: usize = 0;

    const end_us: Micros = @as(Micros, o.seconds) * simnet.SEC;
    var t: Micros = 0;
    var loss_on = false;
    var next_progress: Micros = @as(Micros, o.progress_every_s) * simnet.SEC;
    var closing = false;
    var next_event: usize = 0;
    while (!(host.done() and client.done())) : (t += o.step_us) {
        while (next_event < o.display_events.len and t >= o.display_events[next_event].at_us) : (next_event += 1) switch (o.display_events[next_event].what) {
            .select => |q| client.s.selectDisplay(q.display, q.max_width, q.max_height, q.max_fps, net.localTime(.b)),
            .mode => |m| sh.capture.setMode(m.display, m.width, m.height),
            .hotplug => |sz| _ = sh.capture.addDisplay(sz),
        };
        if (!loss_on and t >= o.warmup_us) {
            if (o.path != null) {
                model.setLoss(loss);
            } else for (&net.links) |*l| {
                l.cfg.loss = loss;
            }
            loss_on = true;
        }
        if (o.path != null) model.update(t);
        if (o.outage_us > 0) {
            if (t == o.outage_at_us) net.links[0].cfg.loss = 1.0;
            if (t == o.outage_at_us + o.outage_us) net.links[0].cfg.loss = loss;
        }
        if (!closing and t >= end_us) {
            client.s.close(net.localTime(.b));
            closing = true;
        }
        if (t > end_us + 30 * simnet.SEC) return error.Hung;
        try net.runUntil(t);
        if (o.clipboard) |cs| while (next_copy < cs.copies.len and cs.copies[next_copy].at_us <= t) : (next_copy += 1) {
            const cp = cs.copies[next_copy];
            try (if (cp.client) &client_clip else &host_clip).set(cp.text);
        };
        host.tick();
        client.tick();
        if (log) |w| if (o.progress_every_s > 0 and t >= next_progress) {
            const fz = client.s.freeze.stats;
            try w.print("  t={d} s: presented {d}, freezes {d}, longest gap {d:.1} ms; host encoder {d} kbit/s, pacing {d} kbit/s, stream {d}x{d}@{d}\n", .{ @divTrunc(t, simnet.SEC), client.s.stats.frames_presented, fz.freezes, @as(f64, @floatFromInt(fz.longest_gap_us)) / 1000, host.s.bitrate_bps / 1000, host.s.last_pacing / 1000, host.s.cfg.width, host.s.cfg.height, host.s.cfg.fps });
            try w.flush();
            next_progress += @as(Micros, o.progress_every_s) * simnet.SEC;
        };
    }
    client.s.freeze.finish(client.s.freeze.last_new_us orelse 0);
    if (o.clipboard) |cs| {
        const ht = host_clip.get() orelse "";
        const ct = client_clip.get() orelse "";
        cs.host_len = @min(ht.len, cs.host_text.len);
        @memcpy(cs.host_text[0..cs.host_len], ht[0..cs.host_len]);
        cs.client_len = @min(ct.len, cs.client_text.len);
        @memcpy(cs.client_text[0..cs.client_len], ct[0..cs.client_len]);
        cs.host_writes = host_clip.writes;
        cs.client_writes = client_clip.writes;
        cs.host_sent = host.s.control.clip.stats.sent;
        cs.client_sent = client.s.control.clip.stats.sent;
        cs.echoes = host.s.control.clip.stats.echoes + client.s.control.clip.stats.echoes;
        cs.host_ups = host.s.control.stats.ups;
        cs.client_ups = client.s.control.stats.ups;
    }

    if (log) |w| {
        try host.s.report(w);
        try client.s.report(w);
    }
    const snap = client.s.tele.snapshot();
    var au: Result.Audio = .{};
    if (client.audio) |ca| {
        const bs = ca.bufferStats();
        au = .{ .decoded = bs.decoded, .fec = bs.fec, .concealed = bs.concealed, .rs_recovered = bs.rs_recovered, .late = bs.late, .delay_us = bs.delay_us, .underruns = sc.audio.stats.underruns, .loud = sc.audio.stats.loud, .written = sc.audio.stats.written };
    }
    const fz = client.s.freeze.stats;
    return .{
        .seconds = o.seconds,
        .host = .{
            .frames = host.s.stats.frames,
            .keyframes = host.s.stats.keyframes,
            .refreshes = host.s.stats.refreshes,
            .retransmits = host.s.stats.retransmits,
            .parity_shards = host.s.stats.parity_shards,
            .shards = host.s.stats.shards,
            .keys = sh.injector.keys,
            .keys_wrong = sh.injector.wrong,
            .audio_frames = if (host.audio) |ha| ha.stats.frames else 0,
            .path_changes = host.s.stats.path_changes,
            .reconnects = host.s.stats.reconnects,
            .stall_pauses = host.s.stats.stall_pauses,
            .stall_frames = host.s.stats.stall_frames,
            .reconfigures = host.s.stats.reconfigures,
            .display_switches = host.s.stats.display_switches,
            .mode_changes = host.s.stats.mode_changes,
            .config_resends = host.s.stats.config_resends,
            .width = host.s.cfg.width,
            .height = host.s.cfg.height,
            .fps = host.s.cfg.fps,
            .display = host.s.cfg.display,
            .end = @tagName(host.s.end),
        },
        .client = .{
            .presented = client.s.stats.frames_presented,
            .unreadable = sc.presenter.stats.unreadable,
            .corrupt = sc.decoder.stats.corrupt,
            .decode_errors = client.s.stats.decode_errors,
            .lost = client.s.stats.frames_lost,
            .freezes = fz.freezes,
            .longest_gap_us = fz.longest_gap_us,
            .stalls_100ms = fz.stalls[1],
            .input_sent = sc.input.sent,
            .total_p50_us = snap.stage(.total).p50,
            .total_p99_us = snap.stage(.total).p99,
            .audio = au,
            .path_changes = client.s.stats.path_changes,
            .reconnects = client.s.stats.reconnects,
            .reconnect_requests = client.s.stats.reconnect_requests,
            .config_changes = client.s.stats.config_changes,
            .decoder_reconfigures = client.s.stats.decoder_reconfigures,
            .displays = client.s.n_displays,
            .width = if (sc.presenter.last_size) |z| z.width else 0,
            .height = if (sc.presenter.last_size) |z| z.height else 0,
            .end = @tagName(client.s.end),
        },
        .sim_losses = net.linkStats(.a).random_losses + net.linkStats(.b).random_losses,
    };
}
