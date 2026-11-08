//! Scripted path changes and connection drops over the simulated network, for the session
//! tests: what iroh does on a real network (spikes S5b/S5c), reduced to a timeline.
//!
//! - A flap is an outage of the direct path. From `stall_after_us` into it both ends see
//!   the path `stalled` (the shim's no-ack-progress flag). If it lasts longer than
//!   `idle_us` (the path idle timeout, effectively), the direct path closes and the relay
//!   carries traffic: `path_epoch` bumps, `relayed` is set and the one-way delay becomes
//!   `relay_delay_us`. `repunch_us` after the outage ends, the direct path is back
//!   (S5c: 0.13-1.07 s with the re-punch patch, 21-57 s on stock iroh).
//! - A drop kills the connection: nothing gets through from `at_us` until the outage is
//!   over and the client has asked the pipe to reconnect; the new connection is up
//!   `dial_us` later, and both ends see `conn_epoch` bump.
//!
//! Wraps the sim pipes of both sides; `update(t)` runs the timeline, before the apps tick.
const std = @import("std");
const simnet = @import("simnet");
const pipe = @import("pipe");

const Micros = i64;

pub const Outage = struct { at_us: Micros, outage_us: Micros };

pub const Config = struct {
    flaps: []const Outage = &.{},
    drops: []const Outage = &.{},
    idle_us: Micros = 300_000,
    repunch_us: Micros = 500_000,
    relay_delay_us: Micros = 25_000,
    stall_after_us: Micros = 150_000,
    dial_us: Micros = 300_000,
};

pub const Model = struct {
    cfg: Config,
    net: *simnet.Net,
    /// Random loss of the profile, restored after an outage.
    loss: f64 = 0,
    direct_delay: [2]Micros = .{ 0, 0 },
    ends: [2]End = undefined,

    // Timeline state.
    path_epoch: u32 = 0,
    conn_epoch: u32 = 0,
    relayed: bool = false,
    stalled: bool = false,
    blocked: bool = false,
    /// A dropped connection: since when, and whether the client asked to reconnect.
    dead_since: ?Micros = null,
    dead_until: Micros = 0,
    reconnect_asked: ?Micros = null,
    stats: struct { reconnect_requests: u64 = 0, dropped: u64 = 0 } = .{},

    pub const End = struct {
        model: *Model,
        side: simnet.Side,
        inner: pipe.PacketPipe,

        fn send(ptr: *anyopaque, data: []const u8) pipe.SendError!void {
            const e: *End = @ptrCast(@alignCast(ptr));
            if (e.model.dead_since != null) {
                e.model.stats.dropped += 1;
                return;
            }
            return e.inner.send(data);
        }

        fn recv(ptr: *anyopaque, buf: []u8) pipe.RecvError!?pipe.Received {
            const e: *End = @ptrCast(@alignCast(ptr));
            while (true) {
                const r = try e.inner.recv(buf) orelse return null;
                if (e.model.dead_since == null) return r;
                e.model.stats.dropped += 1;
            }
        }

        fn setPacingRate(ptr: *anyopaque, bps: u64) void {
            const e: *End = @ptrCast(@alignCast(ptr));
            e.inner.setPacingRate(bps);
        }

        fn stats(ptr: *anyopaque) pipe.PathStats {
            const e: *End = @ptrCast(@alignCast(ptr));
            const m = e.model;
            var s = e.inner.stats();
            s.path_epoch = m.path_epoch;
            s.path_id = m.path_epoch;
            s.conn_epoch = m.conn_epoch;
            s.relayed = m.relayed;
            s.stalled = m.stalled;
            s.connected = m.dead_since == null;
            return s;
        }

        fn maxDatagramSize(ptr: *anyopaque) usize {
            const e: *End = @ptrCast(@alignCast(ptr));
            return e.inner.maxDatagramSize();
        }

        fn reconnect(ptr: *anyopaque) void {
            const e: *End = @ptrCast(@alignCast(ptr));
            const m = e.model;
            if (e.side != .b) return; // the host waits; the client dials
            m.stats.reconnect_requests += 1;
            if (m.dead_since != null and m.reconnect_asked == null) m.reconnect_asked = m.net.now();
        }

        const vtable = pipe.PacketPipe.VTable{ .send = send, .recv = recv, .setPacingRate = setPacingRate, .stats = stats, .maxDatagramSize = maxDatagramSize, .reconnect = reconnect };
    };

    /// `self` must not move afterwards (the pipes point into it).
    pub fn init(self: *Model, cfg: Config, net: *simnet.Net) void {
        self.* = .{ .cfg = cfg, .net = net, .direct_delay = .{ net.links[0].cfg.delay_us, net.links[1].cfg.delay_us } };
        for (&self.ends, 0..) |*e, i| {
            const side: simnet.Side = @enumFromInt(i);
            e.* = .{ .model = self, .side = side, .inner = net.pipeFor(side) };
        }
    }

    pub fn pipeFor(self: *Model, side: simnet.Side) pipe.PacketPipe {
        return .{ .ptr = &self.ends[@intFromEnum(side)], .vtable = &End.vtable };
    }

    /// The profile's random loss is on from now (simrun's warm-up).
    pub fn setLoss(self: *Model, loss: f64) void {
        self.loss = loss;
        if (!self.blocked) for (&self.net.links) |*l| {
            l.cfg.loss = loss;
        };
    }

    fn block(self: *Model, on: bool) void {
        self.blocked = on;
        for (&self.net.links) |*l| l.cfg.loss = if (on) 1.0 else self.loss;
    }

    fn setRelay(self: *Model, on: bool) void {
        if (self.relayed == on) return;
        self.relayed = on;
        self.path_epoch +%= 1;
        for (&self.net.links, 0..) |*l, i| l.cfg.delay_us = if (on) self.cfg.relay_delay_us else self.direct_delay[i];
    }

    /// Advance the timeline to (global sim time) `t`.
    pub fn update(self: *Model, t: Micros) void {
        var blocked = false;
        var stalled = false;
        var relay = false;
        for (self.cfg.flaps) |f| {
            const end = f.at_us + f.outage_us;
            if (t < f.at_us or t >= end + self.cfg.repunch_us) continue;
            const closes = f.outage_us > self.cfg.idle_us;
            if (closes and t >= f.at_us + self.cfg.idle_us) {
                relay = true; // the relay carries traffic until the direct path is back
            } else if (t < end) {
                blocked = true;
                if (t >= f.at_us + self.cfg.stall_after_us) stalled = true;
            }
        }
        for (self.cfg.drops) |d| if (t >= d.at_us and self.dead_since == null and self.dead_until < d.at_us) {
            self.dead_since = t;
            self.dead_until = d.at_us + d.outage_us;
            self.reconnect_asked = null;
        };
        if (self.dead_since) |since| {
            if (self.reconnect_asked) |asked| if (t >= self.dead_until and t >= asked + self.cfg.dial_us) {
                self.dead_since = null;
                self.conn_epoch +%= 1;
            };
            if (self.dead_since != null) {
                if (t - since >= self.cfg.stall_after_us) stalled = true;
                if (t < self.dead_until) blocked = true;
            }
        }
        if (blocked != self.blocked) self.block(blocked);
        self.setRelay(relay);
        self.stalled = stalled;
    }
};
