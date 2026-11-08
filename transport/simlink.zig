//! The simulated network between processes: a `Hub` owns a `simnet.Net` and runs
//! it on the wall clock; each endpoint process holds a `Link`, a `PacketPipe`
//! whose calls travel to the hub over loopback UDP. Datagrams cross the
//! simulated path (loss, jitter, reordering, bottleneck) between the two Links
//! exactly as they would between `Net.pipeFor(.a)` and `Net.pipeFor(.b)` in one
//! process; the loopback hops add tens of microseconds.
//!
//! Hub <-> Link messages (one UDP datagram each, first byte is the tag):
//!   'H' side           Link -> hub: register as side a (0) or b (1), repeated until 'W'
//!   'W'                hub -> Link: registered
//!   'D' datagram       either way: a datagram into or out of the simulated path
//!   'R' u64 bps        Link -> hub: `setPacingRate`
//!   'S' i64 rtt_us, u64 send_drops, u64 recv_drops, u64 send_queue_bytes
//!                      hub -> Link: path stats, every 50 ms
//!
//! Wall-clock driving makes runs timing-dependent, unlike the in-process sim;
//! the seeded Config still fixes every random draw for a given packet order.
const std = @import("std");
const simnet = @import("simnet");
const pipe = @import("pipe");
const Io = std.Io;
const net = std.Io.net;

const max_msg = 1 + 1500;

fn nowUs(io: Io) i64 {
    return Io.Clock.awake.now(io).toMicroseconds();
}

/// Fixed ring of received UDP messages, filled by a reader task.
const Inbox = struct {
    const cap = 4096;
    const Slot = struct { len: u16, from: net.IpAddress, t_us: i64, data: [max_msg]u8 };

    mutex: Io.Mutex = .init,
    slots: []Slot,
    head: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,

    fn init(gpa: std.mem.Allocator) !Inbox {
        return .{ .slots = try gpa.alloc(Slot, cap) };
    }

    fn deinit(q: *Inbox, gpa: std.mem.Allocator) void {
        gpa.free(q.slots);
    }

    fn push(q: *Inbox, io: Io, data: []const u8, from: net.IpAddress, t_us: i64) void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.len == cap or data.len > max_msg) {
            q.dropped += 1;
            return;
        }
        const s = &q.slots[(q.head + q.len) % cap];
        s.len = @intCast(data.len);
        s.from = from;
        s.t_us = t_us;
        @memcpy(s.data[0..data.len], data);
        q.len += 1;
    }

    /// Copies the oldest message out; false when empty.
    fn pop(q: *Inbox, io: Io, out: *Slot) bool {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.len == 0) return false;
        const s = &q.slots[q.head];
        out.len = s.len;
        out.from = s.from;
        out.t_us = s.t_us;
        @memcpy(out.data[0..s.len], s.data[0..s.len]);
        q.head = (q.head + 1) % cap;
        q.len -= 1;
        return true;
    }

    fn readLoop(q: *Inbox, io: Io, sock: *const net.Socket, stop: *std.atomic.Value(bool)) void {
        var buf: [max_msg + 64]u8 = undefined;
        while (!stop.load(.acquire)) {
            const m = sock.receive(io, &buf) catch |e| switch (e) {
                error.Canceled => return,
                else => continue,
            };
            if (stop.load(.acquire)) return;
            q.push(io, m.data, m.from, nowUs(io));
        }
    }
};

/// A socket with its reader task. Stopping does not rely on cancelling a blocked
/// receive (not every platform can interrupt one): it sets a flag and sends the
/// socket a datagram to wake the reader.
const Endpoint = struct {
    io: Io,
    sock: net.Socket,
    inbox: Inbox,
    stop: std.atomic.Value(bool) = .init(false),
    reader: ?Io.Future(void) = null,

    fn open(self: *Endpoint, gpa: std.mem.Allocator, io: Io) !void {
        const sock = try loopback(0).bind(io, .{ .mode = .dgram });
        errdefer sock.close(io);
        self.* = .{ .io = io, .sock = sock, .inbox = try Inbox.init(gpa) };
        errdefer self.inbox.deinit(gpa);
        self.reader = try io.concurrent(Inbox.readLoop, .{ &self.inbox, io, &self.sock, &self.stop });
    }

    fn close(self: *Endpoint, gpa: std.mem.Allocator) void {
        if (self.reader) |*r| {
            self.stop.store(true, .release);
            const me = loopback(self.sock.address.getPort());
            self.sock.send(self.io, &me, "x") catch {};
            r.await(self.io);
        }
        self.sock.close(self.io);
        self.inbox.deinit(gpa);
    }
};

fn loopback(port: u16) net.IpAddress {
    return net.IpAddress.parse("127.0.0.1", port) catch unreachable;
}

pub const Hub = struct {
    gpa: std.mem.Allocator,
    io: Io,
    net: *simnet.Net,
    ep: Endpoint,
    peers: [2]?net.IpAddress = .{ null, null },
    start_us: i64,
    /// Called once, `warmup_us` after both sides registered (the gate turns loss on).
    on_warm: ?*const fn (*simnet.Net) void = null,
    warmup_us: i64 = 0,
    warm_at: ?i64 = null,
    next_stats: i64 = 0,

    /// The hub holds pointers to itself; create it in place and don't move it.
    pub fn init(self: *Hub, gpa: std.mem.Allocator, io: Io, cfg: simnet.Config) !void {
        const n = try gpa.create(simnet.Net);
        errdefer gpa.destroy(n);
        try n.init(gpa, cfg);
        errdefer n.deinit();
        self.* = .{ .gpa = gpa, .io = io, .net = n, .ep = undefined, .start_us = nowUs(io) };
        try self.ep.open(gpa, io);
    }

    pub fn deinit(self: *Hub) void {
        self.ep.close(self.gpa);
        self.net.deinit();
        self.gpa.destroy(self.net);
    }

    pub fn port(self: *const Hub) u16 {
        return self.ep.sock.address.getPort();
    }

    fn simNow(self: *const Hub) i64 {
        return @max(self.net.now(), nowUs(self.io) - self.start_us);
    }

    fn sendTo(self: *Hub, side: usize, tag: u8, body: []const u8) void {
        const to = self.peers[side] orelse return;
        var buf: [max_msg]u8 = undefined;
        buf[0] = tag;
        @memcpy(buf[1..][0..body.len], body);
        self.ep.sock.send(self.io, &to, buf[0 .. 1 + body.len]) catch {};
    }

    /// One pass: take what the Links sent, advance the network to now, hand
    /// deliveries to the Links. Returns when it next has something to do.
    pub fn poll(self: *Hub) !i64 {
        var slot: Inbox.Slot = undefined;
        while (self.ep.inbox.pop(self.io, &slot)) {
            if (slot.len == 0) continue;
            const msg = slot.data[0..slot.len];
            const side: ?usize = for (self.peers, 0..) |p, i| {
                if (p != null and p.?.eql(&slot.from)) break i;
            } else null;
            switch (msg[0]) {
                'H' => {
                    if (msg.len != 2 or msg[1] > 1) continue;
                    self.peers[msg[1]] = slot.from;
                    self.sendTo(msg[1], 'W', "");
                    if (self.warm_at == null and self.peers[0] != null and self.peers[1] != null)
                        self.warm_at = self.simNow() + self.warmup_us;
                },
                'D' => {
                    const s = side orelse continue;
                    try self.net.runUntil(self.simNow());
                    self.net.pipeFor(@enumFromInt(s)).send(msg[1..]) catch {};
                },
                'R' => {
                    const s = side orelse continue;
                    if (msg.len != 9) continue;
                    self.net.pipeFor(@enumFromInt(s)).setPacingRate(std.mem.readInt(u64, msg[1..9], .little));
                },
                else => {},
            }
        }
        const now = self.simNow();
        try self.net.runUntil(now);
        if (self.warm_at) |w| if (now >= w) {
            if (self.on_warm) |f| f(self.net);
            self.on_warm = null;
        };
        var buf: [max_msg]u8 = undefined;
        for (0..2) |s| {
            if (self.peers[s] == null) continue;
            const p = self.net.pipeFor(@enumFromInt(s));
            while (try p.recv(&buf)) |r| self.sendTo(s, 'D', buf[0..r.len]);
        }
        if (now >= self.next_stats) {
            self.next_stats = now + 50 * simnet.MS;
            for (0..2) |s| {
                const st = self.net.pipeFor(@enumFromInt(s)).stats();
                var b: [32]u8 = undefined;
                std.mem.writeInt(i64, b[0..8], st.rtt_us, .little);
                std.mem.writeInt(u64, b[8..16], st.send_drops, .little);
                std.mem.writeInt(u64, b[16..24], st.recv_drops, .little);
                std.mem.writeInt(u64, b[24..32], st.send_queue_bytes, .little);
                self.sendTo(s, 'S', &b);
            }
        }
        var next = @min(now + 500, self.next_stats);
        if (self.net.nextEventTime()) |t| next = @min(next, t);
        return next;
    }

    /// Runs `poll` until `stop` is set (from another task).
    pub fn run(self: *Hub, stop: *std.atomic.Value(bool)) anyerror!void {
        while (!stop.load(.acquire)) {
            const next = try self.poll();
            const wait = next - self.simNow();
            if (wait > 0) self.io.sleep(.fromMicroseconds(@min(wait, 500)), .awake) catch return;
        }
    }
};

pub const Link = struct {
    io: Io,
    gpa: std.mem.Allocator,
    ep: Endpoint,
    hub: net.IpAddress,
    pacing_bps: u64 = 0,
    sent: u64 = 0,
    received: u64 = 0,
    remote: struct { rtt_us: i64 = 0, send_drops: u64 = 0, recv_drops: u64 = 0, send_queue_bytes: u64 = 0 } = .{},
    max_datagram: usize = 1200,

    /// Registers with the hub on 127.0.0.1:`hub_port` as `side`. Create in place.
    pub fn init(self: *Link, gpa: std.mem.Allocator, io: Io, hub_port: u16, side: simnet.Side) !void {
        self.* = .{ .io = io, .gpa = gpa, .ep = undefined, .hub = loopback(hub_port) };
        try self.ep.open(gpa, io);
        errdefer self.ep.close(gpa);
        const hello = [2]u8{ 'H', @intFromEnum(side) };
        const deadline = nowUs(io) + 10 * simnet.SEC;
        var slot: Inbox.Slot = undefined;
        while (nowUs(io) < deadline) {
            try self.ep.sock.send(io, &self.hub, &hello);
            const until = nowUs(io) + 100 * simnet.MS;
            while (nowUs(io) < until) {
                if (self.ep.inbox.pop(io, &slot)) {
                    if (slot.len == 1 and slot.data[0] == 'W') return;
                    continue;
                }
                io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
        }
        return error.HubUnreachable;
    }

    pub fn deinit(self: *Link) void {
        self.ep.close(self.gpa);
    }

    pub fn packetPipe(self: *Link) pipe.PacketPipe {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn send(ptr: *anyopaque, data: []const u8) pipe.SendError!void {
        const self: *Link = @ptrCast(@alignCast(ptr));
        if (data.len > self.max_datagram) return error.TooLarge;
        var buf: [max_msg]u8 = undefined;
        buf[0] = 'D';
        @memcpy(buf[1..][0..data.len], data);
        self.ep.sock.send(self.io, &self.hub, buf[0 .. 1 + data.len]) catch return error.Closed;
        self.sent += 1;
    }

    fn recv(ptr: *anyopaque, out: []u8) pipe.RecvError!?pipe.Received {
        const self: *Link = @ptrCast(@alignCast(ptr));
        var slot: Inbox.Slot = undefined;
        while (self.ep.inbox.pop(self.io, &slot)) {
            if (slot.len == 0) continue;
            const msg = slot.data[0..slot.len];
            switch (msg[0]) {
                'D' => {
                    const d = msg[1..];
                    // A datagram never exceeds max_datagram, so a short buffer is the
                    // caller's bug; drop it rather than requeue at the back.
                    if (out.len < d.len) return error.BufferTooSmall;
                    @memcpy(out[0..d.len], d);
                    self.received += 1;
                    return .{ .len = d.len, .recv_us = slot.t_us };
                },
                'S' => if (msg.len == 33) {
                    self.remote = .{
                        .rtt_us = std.mem.readInt(i64, msg[1..9], .little),
                        .send_drops = std.mem.readInt(u64, msg[9..17], .little),
                        .recv_drops = std.mem.readInt(u64, msg[17..25], .little),
                        .send_queue_bytes = std.mem.readInt(u64, msg[25..33], .little),
                    };
                },
                else => {},
            }
        }
        return null;
    }

    fn setPacingRate(ptr: *anyopaque, bps: u64) void {
        const self: *Link = @ptrCast(@alignCast(ptr));
        var b: [9]u8 = undefined;
        b[0] = 'R';
        std.mem.writeInt(u64, b[1..9], bps, .little);
        self.ep.sock.send(self.io, &self.hub, &b) catch return;
        self.pacing_bps = bps;
    }

    fn stats(ptr: *anyopaque) pipe.PathStats {
        const self: *Link = @ptrCast(@alignCast(ptr));
        return .{
            .rtt_us = self.remote.rtt_us,
            .pacing_bps = self.pacing_bps,
            .sent = self.sent,
            .received = self.received,
            .send_drops = self.remote.send_drops,
            .recv_drops = self.remote.recv_drops + self.ep.inbox.dropped,
            .send_queue_bytes = self.remote.send_queue_bytes,
        };
    }

    fn maxDatagramSize(ptr: *anyopaque) usize {
        const self: *Link = @ptrCast(@alignCast(ptr));
        return self.max_datagram;
    }

    const vtable = pipe.PacketPipe.VTable{
        .send = send,
        .recv = recv,
        .setPacingRate = setPacingRate,
        .stats = stats,
        .maxDatagramSize = maxDatagramSize,
    };
};

test "two Links exchange datagrams through the hub's simulated path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const hub = try gpa.create(Hub);
    defer gpa.destroy(hub);
    try hub.init(gpa, io, .{ .a_to_b = .{ .delay_us = 2 * simnet.MS }, .b_to_a = .{ .delay_us = 2 * simnet.MS } });
    defer hub.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    var task = try io.concurrent(Hub.run, .{ hub, &stop });
    defer {
        stop.store(true, .release);
        task.await(io) catch {};
    }

    var a: Link = undefined;
    try a.init(gpa, io, hub.port(), .a);
    defer a.deinit();
    var b: Link = undefined;
    try b.init(gpa, io, hub.port(), .b);
    defer b.deinit();
    const pa = a.packetPipe();
    const pb = b.packetPipe();
    pa.setPacingRate(10_000_000);
    for (0..20) |i| try pa.send(&[_]u8{ 'a', @intCast(i) });
    try pb.send("from b");
    try std.testing.expectError(error.TooLarge, pa.send(&([_]u8{0} ** 1201)));

    var got_b: usize = 0;
    var got_a = false;
    var buf: [1200]u8 = undefined;
    const deadline = nowUs(io) + 5 * simnet.SEC;
    while ((got_b < 20 or !got_a) and nowUs(io) < deadline) {
        if (try pb.recv(&buf)) |r| {
            try std.testing.expectEqualSlices(u8, &.{ 'a', @intCast(got_b) }, buf[0..r.len]);
            got_b += 1;
        }
        if (try pa.recv(&buf)) |r| {
            try std.testing.expectEqualStrings("from b", buf[0..r.len]);
            got_a = true;
        }
        io.sleep(.fromMicroseconds(200), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 20), got_b);
    try std.testing.expect(got_a);
    try std.testing.expectEqual(@as(u64, 10_000_000), pa.stats().pacing_bps);
    try std.testing.expectEqual(@as(u64, 20), hub.net.linkStats(.a).sent);
}
