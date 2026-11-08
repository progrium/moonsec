//! Simulated network behind `PacketPipe`: two endpoints, A and B, joined by one
//! link in each direction. Discrete-event and deterministic per seed: the same
//! `Config`, the same calls at the same simulated times, give the same deliveries.
//!
//! Each direction runs, in order:
//!
//!   send buffer (evicts oldest) -> pacer (at the rate the core sets, with burst
//!   credit) -> droptail bottleneck shared with cross traffic (capacity steps or
//!   random fades; optional Wi-Fi aggregation and radio stalls) -> random loss
//!   (Bernoulli or bursty Gilbert-Elliott) and blackouts -> propagation delay,
//!   jitter and reordering -> receive buffer (drops when full) -> `recv`.
//!
//! The Wi-Fi model is S11's: packets leave the radio in A-MPDU-like batches at
//! random 0.5-4 ms boundaries, and the radio stalls for 5-60 ms at exponential
//! intervals with a 2 s mean. It is synthetic and uncalibrated (S11's real run is
//! pending), so every parameter is configurable.
//!
//! Time does not pass on its own: the driver calls `runUntil(t)` and reads
//! `nextEventTime()` to know when the network next has something to do. Each
//! source of randomness (loss, jitter, Wi-Fi, cross traffic, fades) has its own
//! stream per direction, so changing one knob does not reshuffle the others.
const std = @import("std");
pub const pipe = @import("pipe.zig");

pub const US: i64 = 1;
pub const MS: i64 = 1000;
pub const SEC: i64 = 1_000_000;

// ---------------------------------------------------------------------------
// Configuration

/// Bottleneck capacity from time `t_us` on.
pub const Step = struct { t_us: i64, bps: f64 };

/// Random capacity changes: every `min_gap_us`..`max_gap_us`, a new capacity
/// uniform in [lo_bps, hi_bps] (models MCS changes). Starts at the first step.
pub const Fade = struct {
    lo_bps: f64,
    hi_bps: f64,
    min_gap_us: i64 = 2 * SEC,
    max_gap_us: i64 = 5 * SEC,
};

/// S11's synthetic Wi-Fi radio.
pub const WiFi = struct {
    agg_min_us: i64 = 500,
    agg_max_us: i64 = 4 * MS,
    stall_mean_gap_us: i64 = 2 * SEC,
    stall_min_us: i64 = 5 * MS,
    stall_max_us: i64 = 60 * MS,

    /// Expected share of airtime lost to stalls.
    pub fn stallDuty(w: WiFi) f64 {
        const mean_stall = @as(f64, @floatFromInt(w.stall_min_us + w.stall_max_us)) / 2;
        return mean_stall / (mean_stall + @as(f64, @floatFromInt(w.stall_mean_gap_us)));
    }
};

/// Traffic from other applications sharing the bottleneck queue.
pub const Cross = union(enum) {
    none,
    /// CBR UDP that toggles on and off with exponential periods (starts off).
    onoff: struct { bps: f64, mean_on_us: i64, mean_off_us: i64, packet: u32 = 1200 },
    /// One Reno flow, active in [start_us, stop_us). Acks return over the
    /// reverse direction's propagation delay.
    reno: struct { start_us: i64, stop_us: i64, packet: u32 = 1500 },
    /// Line-rate bursts (a web page, a download chunk) at exponential intervals.
    bursts: struct { bytes: u32, mean_gap_us: i64, packet: u32 = 1500 },
};

pub const Window = struct { start_us: i64, end_us: i64 };

pub const LinkConfig = struct {
    /// Bottleneck capacity schedule, first entry at t=0. Empty = no bottleneck.
    steps: []const Step = &.{},
    fade: ?Fade = null,
    /// Droptail limit of the bottleneck queue (bytes, including in service).
    queue_limit_bytes: u64 = 500_000,
    /// One-way propagation delay.
    delay_us: i64 = 10 * MS,
    /// Extra delay per packet, uniform in [0, jitter_us].
    jitter_us: i64 = 0,
    /// When false, jitter never reorders: a packet arrives no earlier than the
    /// one before it. When true each packet's jitter is independent.
    reorder: bool = false,
    /// netem-style reordering: this share of packets is held back
    /// `reorder_extra_us` and lets later packets overtake it.
    reorder_p: f64 = 0,
    reorder_extra_us: i64 = 0,
    /// Long-run random loss rate after the bottleneck.
    loss: f64 = 0,
    /// Mean loss burst length in packets (Gilbert-Elliott); 1 = independent.
    loss_burst: f64 = 1,
    /// Everything leaving the bottleneck inside a window is lost.
    blackouts: []const Window = &.{},
    wifi: ?WiFi = null,
    cross: Cross = .none,
    /// Per-datagram bytes added on the wire (e.g. ~48 for QUIC/UDP/IPv4).
    overhead_bytes: u32 = 0,
};

pub const EndpointConfig = struct {
    /// Added to simulated time to give this endpoint's local clock.
    clock_offset_us: i64 = 0,
    /// Send buffer ahead of the pacer; the oldest datagram is evicted when full
    /// (iroh's behavior) and counted in `send_drops`.
    send_buffer_bytes: u64 = 1 << 20,
    /// Datagrams waiting for `recv`; arrivals beyond it count as `recv_drops`.
    recv_buffer_packets: u32 = 4096,
    /// Pacer burst credit.
    pacing_burst_us: i64 = 2 * MS,
    /// Initial pacing rate, 0 = unpaced.
    pacing_bps: u64 = 0,
    max_datagram: usize = 1200,
};

pub const Config = struct {
    seed: u64 = 1,
    a: EndpointConfig = .{},
    b: EndpointConfig = .{},
    a_to_b: LinkConfig = .{},
    b_to_a: LinkConfig = .{},
};

pub const Side = enum(u1) {
    a,
    b,
    pub fn other(s: Side) Side {
        return if (s == .a) .b else .a;
    }
};

/// Per-direction counters (ground truth; the pipe's `PathStats` sees less).
pub const LinkStats = struct {
    /// Media datagrams accepted by `send`.
    sent: u64 = 0,
    send_drops: u64 = 0,
    /// Media datagrams that left the pacer onto the wire.
    paced: u64 = 0,
    queue_drops: u64 = 0,
    random_losses: u64 = 0,
    blackout_drops: u64 = 0,
    recv_drops: u64 = 0,
    /// Media datagrams that reached the receive buffer.
    delivered: u64 = 0,
    delivered_bytes: u64 = 0,
    /// Media datagrams read by the application.
    received: u64 = 0,
    /// Deliveries that arrived after a later-sent datagram.
    reordered: u64 = 0,
    cross_sent_bytes: u64 = 0,
    cross_delivered_bytes: u64 = 0,
    cross_drops: u64 = 0,
    stall_us: i64 = 0,
    stalls: u64 = 0,
    max_queue_bytes: u64 = 0,
};

// ---------------------------------------------------------------------------
// Internals

const Flow = enum(u8) { media, udp, reno };

const Packet = struct {
    flow: Flow = .media,
    live: bool = true,
    link: u1 = 0,
    wire: u32 = 0,
    data: []u8 = &.{},
    seq: u64 = 0,
    send_us: i64 = 0,
    arrive_us: i64 = 0,
};

const EvKind = enum(u8) {
    pacer,
    service_done,
    deliver,
    stall_start,
    stall_end,
    cap_step,
    cap_fade,
    udp_toggle,
    udp_tick,
    reno_toggle,
    reno_ack,
    reno_loss,
    burst,
};

const Event = struct {
    t: i64,
    order: u64,
    kind: EvKind,
    link: u1,
    a: u64 = 0,
    b: f64 = 0,
};

fn evOrder(_: void, x: Event, y: Event) std.math.Order {
    if (x.t != y.t) return std.math.order(x.t, y.t);
    return std.math.order(x.order, y.order);
}

fn Fifo(comptime T: type) type {
    return struct {
        items: std.ArrayList(T) = .empty,
        head: usize = 0,

        const Self = @This();

        fn push(self: *Self, gpa: std.mem.Allocator, x: T) !void {
            try self.items.append(gpa, x);
        }
        fn peek(self: *const Self) ?T {
            return if (self.head < self.items.items.len) self.items.items[self.head] else null;
        }
        fn pop(self: *Self) ?T {
            if (self.head >= self.items.items.len) return null;
            const x = self.items.items[self.head];
            self.head += 1;
            if (self.head == self.items.items.len) {
                self.items.clearRetainingCapacity();
                self.head = 0;
            } else if (self.head > 1024 and self.head * 2 > self.items.items.len) {
                const rest = self.items.items[self.head..];
                std.mem.copyForwards(T, self.items.items[0..rest.len], rest);
                self.items.shrinkRetainingCapacity(rest.len);
                self.head = 0;
            }
            return x;
        }
        fn len(self: *const Self) usize {
            return self.items.items.len - self.head;
        }
        fn slice(self: *const Self) []const T {
            return self.items.items[self.head..];
        }
        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.items.deinit(gpa);
        }
    };
}

const Rng = enum { loss, jitter, wifi, cross, fade };

const Link = struct {
    cfg: LinkConfig,
    rng: [5]std.Random.DefaultPrng,
    stats: LinkStats = .{},

    // sender (owned by the sending endpoint)
    send_fifo: Fifo(u32) = .{},
    send_bytes: u64 = 0,
    pacing_bps: u64 = 0,
    pacer_next: i64 = 0,
    pacer_armed: bool = false,
    next_seq: u64 = 0,

    // bottleneck
    cap: f64 = std.math.inf(f64),
    queue: Fifo(u32) = .{},
    qbytes: u64 = 0,
    busy: bool = false,
    stalled: bool = false,
    agg_next: i64 = 0,

    // loss and delivery
    ge_bad: bool = false,
    last_arrive: i64 = std.math.minInt(i64),
    max_seq_arrived: ?u64 = null,

    // receiver (owned by the receiving endpoint)
    inbox: Fifo(u32) = .{},

    // cross traffic
    udp_on: bool = false,
    reno_active: bool = false,
    reno_cwnd: f64 = 10,
    reno_ssthresh: f64 = 1e9,
    reno_inflight: u32 = 0,
    reno_last_cut: i64 = std.math.minInt(i64) / 2,

    fn random(self: *Link, which: Rng) std.Random {
        return self.rng[@intFromEnum(which)].random();
    }
};

/// Called as each media datagram leaves an endpoint's pacer onto the wire,
/// with the sender's local time. The real shim paces inside iroh, so this is
/// the simulator's stand-in for a "sent" timestamp taken at the pacer.
pub const PacedHook = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, data: []const u8, local_us: i64) void,
};

/// One endpoint's handle; `Net.pipeFor(side)` wraps it in a `PacketPipe`.
pub const End = struct {
    net: *Net,
    side: Side,
    cfg: EndpointConfig,
    on_paced: ?PacedHook = null,

    fn out(self: *End) *Link {
        return &self.net.links[@intFromEnum(self.side)];
    }
    fn in(self: *End) *Link {
        return &self.net.links[@intFromEnum(self.side.other())];
    }

    fn send(ptr: *anyopaque, data: []const u8) pipe.SendError!void {
        const self: *End = @ptrCast(@alignCast(ptr));
        if (data.len > self.cfg.max_datagram) return error.TooLarge;
        self.net.sendMedia(self, data) catch {
            // Out of memory in the simulator reads as a send-buffer drop.
            self.out().stats.sent += 1;
            self.out().stats.send_drops += 1;
        };
    }

    fn recv(ptr: *anyopaque, buf: []u8) pipe.RecvError!?pipe.Received {
        const self: *End = @ptrCast(@alignCast(ptr));
        const link = self.in();
        const idx = link.inbox.peek() orelse return null;
        const p = &self.net.pkts.items[idx];
        if (buf.len < p.data.len) return error.BufferTooSmall;
        _ = link.inbox.pop();
        @memcpy(buf[0..p.data.len], p.data);
        const r = pipe.Received{ .len = p.data.len, .recv_us = p.arrive_us + self.cfg.clock_offset_us };
        link.stats.received += 1;
        self.net.free(idx);
        return r;
    }

    fn setPacingRate(ptr: *anyopaque, bps: u64) void {
        const self: *End = @ptrCast(@alignCast(ptr));
        self.out().pacing_bps = bps;
    }

    fn stats(ptr: *anyopaque) pipe.PathStats {
        const self: *End = @ptrCast(@alignCast(ptr));
        const o = self.out();
        const i = self.in();
        return .{
            .rtt_us = o.cfg.delay_us + i.cfg.delay_us,
            .pacing_bps = o.pacing_bps,
            .sent = o.stats.sent,
            .received = i.stats.received,
            .send_drops = o.stats.send_drops,
            .recv_drops = i.stats.recv_drops,
            .send_queue_bytes = o.send_bytes,
        };
    }

    fn maxDatagramSize(ptr: *anyopaque) usize {
        const self: *End = @ptrCast(@alignCast(ptr));
        return self.cfg.max_datagram;
    }

    const vtable = pipe.PacketPipe.VTable{
        .send = send,
        .recv = recv,
        .setPacingRate = setPacingRate,
        .stats = stats,
        .maxDatagramSize = maxDatagramSize,
    };
};

// ---------------------------------------------------------------------------
// The network

pub const Net = struct {
    gpa: std.mem.Allocator,
    seed: u64,
    links: [2]Link,
    ends: [2]End,
    q: std.PriorityQueue(Event, void, evOrder) = .empty,
    order: u64 = 0,
    t: i64 = 0,
    pkts: std.ArrayList(Packet) = .empty,
    free_list: std.ArrayList(u32) = .empty,
    hasher: std.hash.Wyhash,

    /// `Net` holds pointers to itself; create it in place and don't move it.
    pub fn init(self: *Net, gpa: std.mem.Allocator, cfg: Config) !void {
        self.* = .{
            .gpa = gpa,
            .seed = cfg.seed,
            .links = .{ newLink(cfg.a_to_b, cfg.seed, 0), newLink(cfg.b_to_a, cfg.seed, 1) },
            .ends = .{
                .{ .net = self, .side = .a, .cfg = cfg.a },
                .{ .net = self, .side = .b, .cfg = cfg.b },
            },
            .hasher = std.hash.Wyhash.init(cfg.seed),
        };
        self.links[0].pacing_bps = cfg.a.pacing_bps;
        self.links[1].pacing_bps = cfg.b.pacing_bps;
        for (0..2) |li| try self.startLink(@intCast(li));
    }

    pub fn deinit(self: *Net) void {
        for (self.pkts.items) |p| if (p.live) self.gpa.free(p.data);
        self.pkts.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
        self.q.deinit(self.gpa);
        for (&self.links) |*l| {
            l.send_fifo.deinit(self.gpa);
            l.queue.deinit(self.gpa);
            l.inbox.deinit(self.gpa);
        }
    }

    fn newLink(cfg: LinkConfig, seed: u64, li: u64) Link {
        var l = Link{ .cfg = cfg, .rng = undefined };
        // Independent streams per (seed, direction, purpose), derived by SplitMix64.
        var sm = std.Random.SplitMix64.init(seed ^ (0x9e3779b97f4a7c15 *% (li + 1)));
        for (&l.rng) |*r| r.* = std.Random.DefaultPrng.init(sm.next());
        if (cfg.steps.len > 0) l.cap = cfg.steps[0].bps;
        return l;
    }

    fn startLink(self: *Net, li: u1) !void {
        const l = &self.links[li];
        const c = l.cfg;
        if (c.steps.len > 1) for (c.steps[1..]) |st| try self.at(st.t_us, .cap_step, li, 0, st.bps);
        if (c.fade) |f| try self.at(self.gapIn(l, .fade, f.min_gap_us, f.max_gap_us), .cap_fade, li, 0, 0);
        if (c.wifi) |w| try self.at(expDur(l, .wifi, w.stall_mean_gap_us), .stall_start, li, 0, 0);
        switch (c.cross) {
            .none => {},
            .onoff => |o| try self.at(expDur(l, .cross, o.mean_off_us), .udp_toggle, li, 0, 0),
            .reno => |r| {
                try self.at(r.start_us, .reno_toggle, li, 1, 0);
                try self.at(r.stop_us, .reno_toggle, li, 0, 0);
            },
            .bursts => |b| try self.at(expDur(l, .cross, b.mean_gap_us), .burst, li, 0, 0),
        }
    }

    // --- public driver API -------------------------------------------------

    /// The endpoint's `PacketPipe`.
    pub fn pipeFor(self: *Net, side: Side) pipe.PacketPipe {
        return .{ .ptr = &self.ends[@intFromEnum(side)], .vtable = &End.vtable };
    }

    /// Observe datagrams leaving `side`'s pacer (see `PacedHook`); null clears it.
    pub fn setPacedHook(self: *Net, side: Side, hook: ?PacedHook) void {
        self.ends[@intFromEnum(side)].on_paced = hook;
    }

    /// Simulated time (µs since start).
    pub fn now(self: *const Net) i64 {
        return self.t;
    }

    /// An endpoint's local clock.
    pub fn localTime(self: *const Net, side: Side) i64 {
        return self.t + self.ends[@intFromEnum(side)].cfg.clock_offset_us;
    }

    /// When the network next changes state, or null when it is idle forever.
    /// Recurring sources (stalls, fades, cross traffic) keep this non-null.
    pub fn nextEventTime(self: *const Net) ?i64 {
        const ev = self.q.peek() orelse return null;
        return ev.t;
    }

    /// Process every event at or before `t_us`, then set the clock to `t_us`.
    pub fn runUntil(self: *Net, t_us: i64) !void {
        std.debug.assert(t_us >= self.t);
        while (self.q.peek()) |ev| {
            if (ev.t > t_us) break;
            _ = self.q.pop();
            self.t = ev.t;
            try self.dispatch(ev);
        }
        self.t = t_us;
    }

    /// Ground-truth counters for the direction `from` sends on.
    pub fn linkStats(self: *const Net, from: Side) LinkStats {
        return self.links[@intFromEnum(from)].stats;
    }

    /// Current bottleneck capacity of the direction `from` sends on.
    pub fn capacity(self: *const Net, from: Side) f64 {
        return self.links[@intFromEnum(from)].cap;
    }

    /// Capacity left for media: capacity less expected stall airtime and less
    /// active on/off UDP, halved while a Reno flow runs (its fair share).
    pub fn available(self: *const Net, from: Side) f64 {
        const l = &self.links[@intFromEnum(from)];
        var a = l.cap;
        if (l.cfg.wifi) |w| a *= 1 - w.stallDuty();
        switch (l.cfg.cross) {
            .onoff => |o| if (l.udp_on) {
                a -= o.bps;
            },
            .reno => if (l.reno_active) {
                a /= 2;
            },
            else => {},
        }
        return @max(a, 0);
    }

    /// Bytes in the bottleneck queue right now.
    pub fn queueBytes(self: *const Net, from: Side) u64 {
        return self.links[@intFromEnum(from)].qbytes;
    }

    /// A hash over every media delivery and drop so far (side, sequence, time,
    /// outcome). Equal digests mean equal runs.
    pub fn digest(self: *const Net) u64 {
        var h = self.hasher;
        return h.final();
    }

    // --- events -------------------------------------------------------------

    fn at(self: *Net, t: i64, kind: EvKind, li: u1, a: u64, b: f64) !void {
        self.order += 1;
        try self.q.push(self.gpa, .{ .t = t, .order = self.order, .kind = kind, .link = li, .a = a, .b = b });
    }

    fn expDur(l: *Link, which: Rng, mean: i64) i64 {
        return @intFromFloat(l.random(which).floatExp(f64) * @as(f64, @floatFromInt(mean)));
    }

    fn gapIn(self: *Net, l: *Link, which: Rng, lo: i64, hi: i64) i64 {
        return self.t + lo + uniform(l, which, hi - lo);
    }

    fn uniform(l: *Link, which: Rng, span: i64) i64 {
        if (span <= 0) return 0;
        return @intCast(l.random(which).uintLessThan(u64, @intCast(span + 1)));
    }

    fn record(self: *Net, li: u1, p: *const Packet, outcome: u8) void {
        var buf: [26]u8 = undefined;
        buf[0] = li;
        buf[1] = outcome;
        std.mem.writeInt(u64, buf[2..10], p.seq, .little);
        std.mem.writeInt(i64, buf[10..18], self.t, .little);
        std.mem.writeInt(u64, buf[18..26], p.wire, .little);
        self.hasher.update(&buf);
    }

    fn alloc(self: *Net, p: Packet) !u32 {
        if (self.free_list.pop()) |idx| {
            self.pkts.items[idx] = p;
            return idx;
        }
        try self.pkts.append(self.gpa, p);
        return @intCast(self.pkts.items.len - 1);
    }

    fn free(self: *Net, idx: u32) void {
        const p = &self.pkts.items[idx];
        std.debug.assert(p.live);
        self.gpa.free(p.data);
        p.* = .{ .live = false };
        // Never fails: capacity was reserved when the packet was allocated.
        self.free_list.appendAssumeCapacity(idx);
    }

    fn reserveFree(self: *Net) !void {
        try self.free_list.ensureTotalCapacity(self.gpa, self.pkts.items.len + 1);
    }

    fn sendMedia(self: *Net, e: *End, data: []const u8) !void {
        const li: u1 = @intFromEnum(e.side);
        const l = &self.links[li];
        try self.reserveFree();
        const copy = try self.gpa.dupe(u8, data);
        errdefer self.gpa.free(copy);
        const idx = try self.alloc(.{ .link = li, .data = copy, .wire = @intCast(data.len + l.cfg.overhead_bytes), .send_us = self.t });
        try self.reserveFree();
        try l.send_fifo.push(self.gpa, idx);
        l.stats.sent += 1;
        l.send_bytes += data.len;
        while (l.send_bytes > e.cfg.send_buffer_bytes) {
            const old = l.send_fifo.pop().?;
            l.send_bytes -= self.pkts.items[old].data.len;
            l.stats.send_drops += 1;
            self.record(li, &self.pkts.items[old], 's');
            self.free(old);
        }
        if (!l.pacer_armed and l.send_fifo.len() > 0) {
            l.pacer_armed = true;
            try self.at(@max(self.t, l.pacer_next), .pacer, li, 0, 0);
        }
    }

    fn onPacer(self: *Net, li: u1) !void {
        const l = &self.links[li];
        const burst = self.ends[li].cfg.pacing_burst_us;
        while (l.send_fifo.peek()) |idx| {
            if (l.pacing_bps > 0 and l.pacer_next > self.t) break;
            _ = l.send_fifo.pop();
            const p = &self.pkts.items[idx];
            l.send_bytes -= p.data.len;
            p.seq = l.next_seq;
            l.next_seq += 1;
            p.send_us = self.t;
            l.stats.paced += 1;
            if (self.ends[li].on_paced) |h| h.func(h.ctx, p.data, self.t + self.ends[li].cfg.clock_offset_us);
            if (l.pacing_bps > 0) {
                const tx: i64 = @intFromFloat(@as(f64, @floatFromInt(p.wire)) * 8e6 / @as(f64, @floatFromInt(l.pacing_bps)));
                l.pacer_next = @max(l.pacer_next, self.t - burst) + tx;
            } else l.pacer_next = self.t;
            try self.enqueue(li, idx);
        }
        if (l.send_fifo.len() > 0) {
            try self.at(l.pacer_next, .pacer, li, 0, 0);
        } else l.pacer_armed = false;
    }

    fn enqueue(self: *Net, li: u1, idx: u32) !void {
        const l = &self.links[li];
        const p = &self.pkts.items[idx];
        if (l.qbytes + p.wire > l.cfg.queue_limit_bytes) {
            switch (p.flow) {
                .media => {
                    l.stats.queue_drops += 1;
                    self.record(li, p, 'q');
                },
                .reno => {
                    l.stats.cross_drops += 1;
                    try self.at(self.t + self.rtt(), .reno_loss, li, 0, 0);
                },
                .udp => l.stats.cross_drops += 1,
            }
            self.free(idx);
            return;
        }
        try l.queue.push(self.gpa, idx);
        l.qbytes += p.wire;
        l.stats.max_queue_bytes = @max(l.stats.max_queue_bytes, l.qbytes);
        try self.kick(li);
    }

    fn kick(self: *Net, li: u1) !void {
        const l = &self.links[li];
        if (l.busy or l.stalled) return;
        const idx = l.queue.peek() orelse return;
        l.busy = true;
        const wire: f64 = @floatFromInt(self.pkts.items[idx].wire);
        const tx: i64 = if (std.math.isInf(l.cap)) 0 else @max(1, @as(i64, @intFromFloat(@ceil(wire * 8e6 / l.cap))));
        try self.at(self.t + tx, .service_done, li, idx, 0);
    }

    fn onServiceDone(self: *Net, li: u1, idx: u32) !void {
        const l = &self.links[li];
        _ = l.queue.pop();
        const p = &self.pkts.items[idx];
        l.qbytes -= p.wire;
        l.busy = false;
        var out = self.t;
        if (l.cfg.wifi) |w| {
            // A-MPDU style: packets leave the radio in aggregates, so the
            // receiver sees them in batches at aggregate boundaries.
            while (l.agg_next < self.t) l.agg_next += w.agg_min_us + uniform(l, .wifi, w.agg_max_us - w.agg_min_us);
            out = l.agg_next;
        }
        try self.kick(li);

        // Loss after the bottleneck: blackouts first, then random loss.
        for (l.cfg.blackouts) |win| if (out >= win.start_us and out < win.end_us) {
            if (p.flow == .media) {
                l.stats.blackout_drops += 1;
                self.record(li, p, 'b');
            }
            return self.lose(li, idx);
        };
        if (l.cfg.loss > 0 and self.lossDraw(l)) {
            if (p.flow == .media) {
                l.stats.random_losses += 1;
                self.record(li, p, 'l');
            }
            return self.lose(li, idx);
        }

        var arrive = out + l.cfg.delay_us + uniform(l, .jitter, l.cfg.jitter_us);
        var held = false;
        if (l.cfg.reorder_p > 0 and l.random(.jitter).float(f64) < l.cfg.reorder_p) {
            arrive += l.cfg.reorder_extra_us;
            held = true;
        }
        if (!l.cfg.reorder and !held) {
            arrive = @max(arrive, l.last_arrive);
            l.last_arrive = arrive;
        }
        try self.at(arrive, .deliver, li, idx, 0);
    }

    /// Gilbert-Elliott with a lossless good state and an all-loss bad state:
    /// mean burst = loss_burst, long-run rate = loss.
    fn lossDraw(self: *Net, l: *Link) bool {
        _ = self;
        const r = l.random(.loss);
        const c = l.cfg;
        if (c.loss_burst <= 1) return r.float(f64) < c.loss;
        const p_bg = 1 / c.loss_burst;
        const p_gb = @min(1, c.loss * p_bg / @max(1e-12, 1 - c.loss));
        if (l.ge_bad) {
            if (r.float(f64) < p_bg) l.ge_bad = false;
        } else if (r.float(f64) < p_gb) l.ge_bad = true;
        return l.ge_bad;
    }

    fn lose(self: *Net, li: u1, idx: u32) !void {
        const p = self.pkts.items[idx];
        if (p.flow == .reno) {
            self.links[li].stats.cross_drops += 1;
            try self.at(self.t + self.rtt(), .reno_loss, li, 0, 0);
        } else if (p.flow == .udp) self.links[li].stats.cross_drops += 1;
        self.free(idx);
    }

    fn onDeliver(self: *Net, li: u1, idx: u32) !void {
        const l = &self.links[li];
        const p = &self.pkts.items[idx];
        switch (p.flow) {
            .media => {
                if (l.max_seq_arrived) |m| {
                    if (p.seq < m) l.stats.reordered += 1;
                }
                l.max_seq_arrived = @max(l.max_seq_arrived orelse 0, p.seq);
                const rcv = &self.ends[li ^ 1];
                if (l.inbox.len() >= rcv.cfg.recv_buffer_packets) {
                    l.stats.recv_drops += 1;
                    self.record(li, p, 'r');
                    self.free(idx);
                    return;
                }
                p.arrive_us = self.t;
                l.stats.delivered += 1;
                l.stats.delivered_bytes += p.data.len;
                self.record(li, p, 'd');
                try l.inbox.push(self.gpa, idx);
            },
            .udp => {
                l.stats.cross_delivered_bytes += p.wire;
                self.free(idx);
            },
            .reno => {
                l.stats.cross_delivered_bytes += p.wire;
                self.free(idx);
                try self.at(self.t + self.links[li ^ 1].cfg.delay_us, .reno_ack, li, 0, 0);
            },
        }
    }

    fn rtt(self: *const Net) i64 {
        return self.links[0].cfg.delay_us + self.links[1].cfg.delay_us;
    }

    fn crossPacket(self: *Net, li: u1, flow: Flow, size: u32) !void {
        try self.reserveFree();
        const idx = try self.alloc(.{ .flow = flow, .link = li, .wire = size, .send_us = self.t });
        try self.reserveFree();
        self.links[li].stats.cross_sent_bytes += size;
        try self.enqueue(li, idx);
    }

    fn renoSend(self: *Net, li: u1) !void {
        const l = &self.links[li];
        if (!l.reno_active) return;
        const size = l.cfg.cross.reno.packet;
        while (@as(f64, @floatFromInt(l.reno_inflight)) < l.reno_cwnd) {
            l.reno_inflight += 1;
            try self.crossPacket(li, .reno, size);
        }
    }

    fn dispatch(self: *Net, ev: Event) !void {
        const li = ev.link;
        const l = &self.links[li];
        switch (ev.kind) {
            .pacer => try self.onPacer(li),
            .service_done => try self.onServiceDone(li, @intCast(ev.a)),
            .deliver => try self.onDeliver(li, @intCast(ev.a)),
            .stall_start => {
                const w = l.cfg.wifi.?;
                const d = w.stall_min_us + uniform(l, .wifi, w.stall_max_us - w.stall_min_us);
                l.stalled = true;
                l.stats.stalls += 1;
                l.stats.stall_us += d;
                try self.at(self.t + d, .stall_end, li, 0, 0);
            },
            .stall_end => {
                const w = l.cfg.wifi.?;
                l.stalled = false;
                try self.kick(li);
                try self.at(self.t + expDur(l, .wifi, w.stall_mean_gap_us), .stall_start, li, 0, 0);
            },
            .cap_step => l.cap = ev.b,
            .cap_fade => {
                const f = l.cfg.fade.?;
                l.cap = f.lo_bps + l.random(.fade).float(f64) * (f.hi_bps - f.lo_bps);
                try self.at(self.gapIn(l, .fade, f.min_gap_us, f.max_gap_us), .cap_fade, li, 0, 0);
            },
            .udp_toggle => {
                const o = l.cfg.cross.onoff;
                l.udp_on = !l.udp_on;
                if (l.udp_on) try self.at(self.t, .udp_tick, li, 0, 0);
                try self.at(self.t + expDur(l, .cross, if (l.udp_on) o.mean_on_us else o.mean_off_us), .udp_toggle, li, 0, 0);
            },
            .udp_tick => if (l.udp_on) {
                const o = l.cfg.cross.onoff;
                try self.crossPacket(li, .udp, o.packet);
                try self.at(self.t + @as(i64, @intFromFloat(@as(f64, @floatFromInt(o.packet)) * 8e6 / o.bps)), .udp_tick, li, 0, 0);
            },
            .reno_toggle => {
                l.reno_active = ev.a == 1;
                if (l.reno_active) {
                    l.reno_cwnd = 10;
                    l.reno_ssthresh = 1e9;
                    try self.renoSend(li);
                }
            },
            .reno_ack => {
                l.reno_inflight -|= 1;
                if (l.reno_cwnd < l.reno_ssthresh) l.reno_cwnd += 1 else l.reno_cwnd += 1 / l.reno_cwnd;
                l.reno_cwnd = @min(l.reno_cwnd, 20000);
                try self.renoSend(li);
            },
            .reno_loss => {
                l.reno_inflight -|= 1;
                if (self.t - l.reno_last_cut > self.rtt()) {
                    l.reno_cwnd = @max(l.reno_cwnd / 2, 2);
                    l.reno_ssthresh = l.reno_cwnd;
                    l.reno_last_cut = self.t;
                }
                try self.renoSend(li);
            },
            .burst => {
                const b = l.cfg.cross.bursts;
                var left = b.bytes;
                while (left > 0) {
                    const sz = @min(left, b.packet);
                    left -= sz;
                    try self.crossPacket(li, .udp, sz);
                }
                try self.at(self.t + expDur(l, .cross, b.mean_gap_us), .burst, li, 0, 0);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Send `n` datagrams of `size` bytes from A at a fixed interval, run until all
/// settle, and return the net (caller deinits).
fn blast(net: *Net, cfg: Config, n: usize, size: usize, every_us: i64) !void {
    try net.init(testing.allocator, cfg);
    const a = net.pipeFor(.a);
    var buf: [1500]u8 = undefined;
    for (0..n) |i| {
        std.mem.writeInt(u64, buf[0..8], i, .little);
        try net.runUntil(@as(i64, @intCast(i)) * every_us);
        try a.send(buf[0..size]);
    }
    try net.runUntil(@as(i64, @intCast(n)) * every_us + 2 * SEC);
}

fn drain(p: pipe.PacketPipe, seqs: *std.ArrayList(u64)) !void {
    var buf: [1500]u8 = undefined;
    while (try p.recv(&buf)) |_| try seqs.append(testing.allocator, std.mem.readInt(u64, buf[0..8], .little));
}

test "clean link delivers everything in order after the propagation delay" {
    var net: Net = undefined;
    try blast(&net, .{ .a_to_b = .{ .delay_us = 7 * MS } }, 100, 100, MS);
    defer net.deinit();
    const s = net.linkStats(.a);
    try testing.expectEqual(@as(u64, 100), s.delivered);
    var seqs: std.ArrayList(u64) = .empty;
    defer seqs.deinit(testing.allocator);
    try drain(net.pipeFor(.b), &seqs);
    for (seqs.items, 0..) |x, i| try testing.expectEqual(@as(u64, i), x);
    const st = net.pipeFor(.b).stats();
    try testing.expectEqual(@as(u64, 100), st.received);
}

test "recv timestamp is on the receiver clock" {
    var net: Net = undefined;
    try net.init(testing.allocator, .{ .b = .{ .clock_offset_us = 987 * SEC }, .a_to_b = .{ .delay_us = 5 * MS } });
    defer net.deinit();
    try net.pipeFor(.a).send("x" ** 8);
    try net.runUntil(SEC);
    var buf: [64]u8 = undefined;
    const r = (try net.pipeFor(.b).recv(&buf)).?;
    try testing.expectEqual(@as(i64, 987 * SEC + 5 * MS), r.recv_us);
    try testing.expectEqual(@as(i64, 987 * SEC + SEC), net.localTime(.b));
}

test "same seed gives the same run, a different seed a different one" {
    const cfg = Config{ .seed = 42, .a_to_b = .{
        .steps = &.{.{ .t_us = 0, .bps = 20e6 }},
        .loss = 0.05,
        .loss_burst = 3,
        .jitter_us = 4 * MS,
        .reorder = true,
        .wifi = .{},
    } };
    var d: [3]u64 = undefined;
    for (&d, [_]u64{ 42, 42, 43 }) |*out, seed| {
        var c = cfg;
        c.seed = seed;
        var net: Net = undefined;
        try blast(&net, c, 2000, 1200, 500);
        defer net.deinit();
        out.* = net.digest();
    }
    try testing.expectEqual(d[0], d[1]);
    try testing.expect(d[0] != d[2]);
}

test "random loss hits its rate and bursts have the configured mean length" {
    for ([_]f64{ 1, 4 }) |burst| {
        var net: Net = undefined;
        try blast(&net, .{ .seed = 7, .b = .{ .recv_buffer_packets = 1 << 20 }, .a_to_b = .{ .loss = 0.05, .loss_burst = burst } }, 20000, 64, 100);
        defer net.deinit();
        var seqs: std.ArrayList(u64) = .empty;
        defer seqs.deinit(testing.allocator);
        try drain(net.pipeFor(.b), &seqs);
        const lost = 20000 - seqs.items.len;
        try testing.expectEqual(@as(u64, lost), net.linkStats(.a).random_losses);
        const rate = @as(f64, @floatFromInt(lost)) / 20000;
        try testing.expect(rate > 0.04 and rate < 0.06);
        // count bursts: gaps in the received sequence
        var gaps: usize = 0;
        var prev: u64 = 0;
        for (seqs.items, 0..) |x, i| {
            if ((i == 0 and x > 0) or (i > 0 and x != prev + 1)) gaps += 1;
            prev = x;
        }
        const mean_burst = @as(f64, @floatFromInt(lost)) / @as(f64, @floatFromInt(gaps));
        try testing.expect(@abs(mean_burst - burst) < 0.25 * burst);
    }
}

test "jitter stays in bounds and keeps order unless reordering is on" {
    for ([_]bool{ false, true }) |reorder| {
        var net: Net = undefined;
        try net.init(testing.allocator, .{ .seed = 3, .a_to_b = .{ .delay_us = 10 * MS, .jitter_us = 5 * MS, .reorder = reorder } });
        defer net.deinit();
        const a = net.pipeFor(.a);
        const b = net.pipeFor(.b);
        var buf: [64]u8 = undefined;
        var sent_at: [2000]i64 = undefined;
        var last: u64 = 0;
        var out_of_order: usize = 0;
        for (0..2000) |i| {
            try net.runUntil(@as(i64, @intCast(i)) * 500);
            std.mem.writeInt(u64, buf[0..8], i, .little);
            sent_at[i] = net.now();
            try a.send(buf[0..16]);
            try net.runUntil(net.now());
            while (try b.recv(&buf)) |r| {
                const s = std.mem.readInt(u64, buf[0..8], .little);
                const owd = r.recv_us - sent_at[s];
                try testing.expect(owd >= 10 * MS);
                if (!reorder) try testing.expect(owd <= 15 * MS + 500) else try testing.expect(owd <= 15 * MS);
                if (s < last) out_of_order += 1;
                last = @max(last, s);
            }
        }
        if (reorder) {
            try testing.expect(out_of_order > 100);
            try testing.expect(net.linkStats(.a).reordered == out_of_order);
        } else try testing.expectEqual(@as(usize, 0), out_of_order);
    }
}

test "netem-style reordering holds back a share of packets" {
    var net: Net = undefined;
    try blast(&net, .{ .seed = 5, .b = .{ .recv_buffer_packets = 1 << 20 }, .a_to_b = .{ .reorder_p = 0.1, .reorder_extra_us = 3 * MS } }, 5000, 64, 1000);
    defer net.deinit();
    const s = net.linkStats(.a);
    try testing.expectEqual(@as(u64, 5000), s.delivered);
    // each held packet is overtaken by the next two or three
    try testing.expect(s.reordered > 400 and s.reordered < 600);
}

test "droptail bottleneck drops beyond its buffer and serves at capacity" {
    // 10 Mbit/s, 30 KB buffer, offered 20 Mbit/s for one second.
    var net: Net = undefined;
    try blast(&net, .{ .a_to_b = .{ .steps = &.{.{ .t_us = 0, .bps = 10e6 }}, .queue_limit_bytes = 30_000 } }, 2083, 1200, 480);
    defer net.deinit();
    const s = net.linkStats(.a);
    try testing.expectEqual(s.paced, s.delivered + s.queue_drops);
    const got = @as(f64, @floatFromInt(s.delivered_bytes)) * 8;
    try testing.expect(got > 9.9e6 and got < 10.4e6);
    try testing.expect(s.max_queue_bytes <= 30_000);
}

test "bandwidth steps change the service rate" {
    var net: Net = undefined;
    try net.init(testing.allocator, .{ .a_to_b = .{ .delay_us = 0, .steps = &.{ .{ .t_us = 0, .bps = 50e6 }, .{ .t_us = SEC, .bps = 10e6 } }, .queue_limit_bytes = 10_000_000 } });
    defer net.deinit();
    const a = net.pipeFor(.a);
    const b = net.pipeFor(.b);
    var buf: [1200]u8 = undefined;
    var bytes = [2]f64{ 0, 0 };
    var t: i64 = 0;
    while (t < 2 * SEC) : (t += 100) {
        try net.runUntil(t);
        try a.send(&buf); // 96 Mbit/s offered, always backlogged
        while (try b.recv(&buf)) |r| bytes[@intCast(@divTrunc(r.recv_us, SEC))] += @floatFromInt(r.len);
    }
    try testing.expect(bytes[0] * 8 > 49e6 and bytes[0] * 8 < 51e6);
    try testing.expect(bytes[1] * 8 > 9.5e6 and bytes[1] * 8 < 10.5e6);
}

test "pacer spaces sends at the pacing rate after its burst credit" {
    var net: Net = undefined;
    try net.init(testing.allocator, .{ .a_to_b = .{ .delay_us = 0 } });
    defer net.deinit();
    const a = net.pipeFor(.a);
    a.setPacingRate(9_600_000); // 1200 B every 1 ms
    var buf: [1200]u8 = undefined;
    for (0..100) |_| try a.send(&buf);
    try testing.expectEqual(@as(u64, 120_000), a.stats().send_queue_bytes);
    try net.runUntil(50 * MS);
    const s = net.linkStats(.a);
    // one at t=0, then one per ms up to t=50 ms
    try testing.expectEqual(@as(u64, 51), s.delivered);
    try net.runUntil(SEC);
    try testing.expectEqual(@as(u64, 100), net.linkStats(.a).delivered);
}

test "paced hook sees each datagram as it leaves the pacer" {
    var net: Net = undefined;
    try net.init(testing.allocator, .{ .a = .{ .clock_offset_us = 100, .pacing_burst_us = 0 } });
    defer net.deinit();
    const Rec = struct {
        times: [3]i64 = undefined,
        n: usize = 0,
        fn f(ctx: ?*anyopaque, data: []const u8, t: i64) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            std.debug.assert(data.len == 1200);
            r.times[r.n] = t;
            r.n += 1;
        }
    };
    var rec = Rec{};
    net.setPacedHook(.a, .{ .ctx = &rec, .func = Rec.f });
    const a = net.pipeFor(.a);
    a.setPacingRate(9_600_000);
    var buf: [1200]u8 = undefined;
    for (0..3) |_| try a.send(&buf);
    try net.runUntil(SEC);
    try testing.expectEqualSlices(i64, &.{ 100, 1100, 2100 }, rec.times[0..rec.n]);
}

test "send buffer evicts the oldest and receive buffer drops when full" {
    var net: Net = undefined;
    try net.init(testing.allocator, .{
        .a = .{ .send_buffer_bytes = 12_000, .pacing_bps = 1_000_000 },
        .b = .{ .recv_buffer_packets = 5 },
    });
    defer net.deinit();
    const a = net.pipeFor(.a);
    var buf: [1200]u8 = undefined;
    for (0..30) |i| {
        std.mem.writeInt(u64, buf[0..8], i, .little);
        try a.send(&buf);
    }
    try testing.expectEqual(@as(u64, 20), a.stats().send_drops); // 10 fit; the pacer runs on the next event
    try net.runUntil(5 * SEC);
    const b = net.pipeFor(.b);
    try testing.expectEqual(@as(u64, 5), b.stats().recv_drops);
    var seqs: std.ArrayList(u64) = .empty;
    defer seqs.deinit(testing.allocator);
    try drain(b, &seqs);
    try testing.expectEqualSlices(u64, &.{ 20, 21, 22, 23, 24 }, seqs.items);
    try testing.expectError(error.TooLarge, a.send(&([_]u8{0} ** 1201)));
}

test "blackouts drop everything inside the window" {
    var net: Net = undefined;
    try blast(&net, .{ .a_to_b = .{ .blackouts = &.{.{ .start_us = 100 * MS, .end_us = 300 * MS }} } }, 1000, 64, MS);
    defer net.deinit();
    try testing.expectEqual(@as(u64, 200), net.linkStats(.a).blackout_drops);
    try testing.expectEqual(@as(u64, 800), net.linkStats(.a).delivered);
}

test "wifi model batches arrivals and stalls about 1.6% of airtime" {
    var net: Net = undefined;
    try net.init(testing.allocator, .{ .seed = 11, .a_to_b = .{ .steps = &.{.{ .t_us = 0, .bps = 50e6 }}, .wifi = .{} } });
    defer net.deinit();
    const a = net.pipeFor(.a);
    const b = net.pipeFor(.b);
    var buf: [1200]u8 = undefined;
    var t: i64 = 0;
    var arrivals: usize = 0;
    var distinct: usize = 0;
    var last_arr: i64 = -1;
    while (t < 120 * SEC) : (t += 400) { // 24 Mbit/s offered
        try net.runUntil(t);
        try a.send(&buf);
        while (try b.recv(&buf)) |r| {
            arrivals += 1;
            if (r.recv_us != last_arr) distinct += 1;
            last_arr = r.recv_us;
        }
    }
    const s = net.linkStats(.a);
    const duty = @as(f64, @floatFromInt(s.stall_us)) / @as(f64, @floatFromInt(120 * SEC));
    try testing.expect(duty > 0.010 and duty < 0.024);
    try testing.expect(@abs(WiFi.stallDuty(.{}) - 0.0159) < 0.001);
    // a packet every 400 us but aggregates every 0.5-4 ms: several per batch
    try testing.expect(@as(f64, @floatFromInt(arrivals)) / @as(f64, @floatFromInt(distinct)) > 3);
    try testing.expectEqual(@as(u64, 0), s.queue_drops);
}

test "cross traffic shares the bottleneck" {
    const flat = [_]Step{.{ .t_us = 0, .bps = 50e6 }};
    // Reno alone fills the link; bursts and on/off UDP put bytes through it.
    const cases = [_]Cross{
        .{ .reno = .{ .start_us = 0, .stop_us = 10 * SEC } },
        .{ .bursts = .{ .bytes = 300_000, .mean_gap_us = SEC } },
        .{ .onoff = .{ .bps = 20e6, .mean_on_us = SEC, .mean_off_us = SEC } },
    };
    // Expected: Reno ~1.0, bursts 300 KB/s of 50 Mbit/s = 0.048, UDP half the time 0.2.
    const lo = [_]f64{ 0.8, 0.02, 0.1 };
    const hi = [_]f64{ 1.0, 0.09, 0.35 };
    for (cases, lo, hi) |c, l, h| {
        var net: Net = undefined;
        try net.init(testing.allocator, .{ .seed = 9, .a_to_b = .{ .steps = &flat, .cross = c } });
        defer net.deinit();
        try net.runUntil(10 * SEC);
        const share = @as(f64, @floatFromInt(net.linkStats(.a).cross_delivered_bytes)) * 8 / 10 / 50e6;
        try testing.expect(share > l and share < h);
    }
}

test "fades pick capacities inside the range" {
    var net: Net = undefined;
    try net.init(testing.allocator, .{ .seed = 2, .a_to_b = .{ .steps = &.{.{ .t_us = 0, .bps = 60e6 }}, .fade = .{ .lo_bps = 25e6, .hi_bps = 120e6 } } });
    defer net.deinit();
    var changes: usize = 0;
    var last = net.capacity(.a);
    var t: i64 = 0;
    while (t < 60 * SEC) : (t += 100 * MS) {
        try net.runUntil(t);
        const c = net.capacity(.a);
        try testing.expect(c >= 25e6 and c <= 120e6);
        if (c != last) changes += 1;
        last = c;
    }
    try testing.expect(changes >= 12 and changes <= 30);
}
