//! Input event model, redundancy and gamepad state snapshots.
//!
//! Input rides unreliable datagrams, so every packet is built to survive the
//! loss of the ones before it:
//!
//! - Keys, mouse buttons and scroll are sequenced events. Each packet repeats
//!   every event the host has not acknowledged yet (newest first, at most
//!   `max_events` and none older than `max_event_age`), and the host applies
//!   each sequence number once.
//! - Relative mouse motion is sent as running totals, not deltas: the host
//!   applies the difference from the last total it saw, so a lost packet only
//!   delays motion, never drops it. Each event also carries the totals at the
//!   moment it happened, so a click lands after the motion that preceded it.
//! - Absolute pointer position is latest-wins. Before a click the sender emits
//!   it as a sequenced event so the click lands where the user clicked.
//! - Gamepads are full state snapshots in every packet: idempotent, so any
//!   one packet that arrives brings the pad fully up to date.
//! - Every packet also lists the keys and mouse buttons currently held. The
//!   host reconciles against it, so a key-up lost beyond the redundancy
//!   window cannot leave a key stuck.
//!
//! Packets older than the newest one processed are dropped whole, so totals
//! and snapshots never move backwards.
//!
//! Sans-I/O: the client-side `Sender` turns input calls into packets, the
//! host-side `Receiver` turns packets into `Action`s for the platform to
//! inject. Times are microseconds on the client's monotonic clock.

const std = @import("std");

pub const Micros = i64;

pub const max_pads = 4;
/// Keys tracked in the held-keys list; beyond this the list is marked
/// incomplete and key reconciliation is skipped for that packet.
pub const max_held_keys = 16;
/// Mouse buttons 1..8 (left, right, middle, back, forward, ...).
pub const max_buttons = 8;

/// Message kinds on the input stream (`proto.StreamId.input`), carried in
/// the envelope's kind byte. Events go client to host; acks come back host
/// to client on the same stream.
pub const Kind = enum(u8) {
    events = 1,
    ack = 2,
    _,
};

// ---------------------------------------------------------------------------
// Model

/// Running totals of relative mouse motion. They wrap; differences are
/// computed with wrapping arithmetic.
pub const Motion = struct {
    x: i32 = 0,
    y: i32 = 0,

    fn delta(to: Motion, from: Motion) Motion {
        return .{ .x = to.x -% from.x, .y = to.y -% from.y };
    }
    fn isZero(m: Motion) bool {
        return m.x == 0 and m.y == 0;
    }
};

pub const Gamepad = struct {
    /// Button bits, `Gamepad.Button` (XInput's wButtons order, plus guide).
    buttons: u32 = 0,
    /// Sticks: -32768..32767, right and up positive (XInput's convention).
    lx: i16 = 0,
    ly: i16 = 0,
    rx: i16 = 0,
    ry: i16 = 0,
    /// Triggers: 0 released .. 65535 fully pressed.
    lt: u16 = 0,
    rt: u16 = 0,

    /// Bits of `buttons`. Every client backend reports this layout and every host
    /// injector reads it, so a pad on any client drives a pad on any host.
    pub const Button = struct {
        pub const dpad_up: u32 = 0x0001;
        pub const dpad_down: u32 = 0x0002;
        pub const dpad_left: u32 = 0x0004;
        pub const dpad_right: u32 = 0x0008;
        /// Start / Menu / Options.
        pub const start: u32 = 0x0010;
        /// Back / View / Share.
        pub const back: u32 = 0x0020;
        pub const left_thumb: u32 = 0x0040;
        pub const right_thumb: u32 = 0x0080;
        pub const left_shoulder: u32 = 0x0100;
        pub const right_shoulder: u32 = 0x0200;
        /// Xbox / PS / Home.
        pub const guide: u32 = 0x0400;
        /// Bottom face button (Xbox A, PlayStation cross).
        pub const a: u32 = 0x1000;
        /// Right face button (Xbox B, PlayStation circle).
        pub const b: u32 = 0x2000;
        /// Left face button (Xbox X, PlayStation square).
        pub const x: u32 = 0x4000;
        /// Top face button (Xbox Y, PlayStation triangle).
        pub const y: u32 = 0x8000;
    };
};

pub const EventKind = enum(u8) {
    /// `code` is a USB HID keyboard usage; `down` is press or release.
    key = 1,
    /// `code` is the mouse button, 1-based.
    button = 2,
    /// `a`, `b`: horizontal and vertical scroll, 120 per wheel notch.
    scroll = 3,
    /// `a`, `b`: absolute pointer position, 0..65535 across the display.
    abs_move = 4,
    _,
};

pub const Event = struct {
    kind: EventKind,
    down: bool = false,
    code: u16 = 0,
    a: i32 = 0,
    b: i32 = 0,
    /// Client time the event was captured.
    time: Micros,
    /// Relative motion totals when the event happened.
    motion: Motion = .{},
};

/// What the host should inject, in order.
pub const Action = union(enum) {
    key: struct { code: u16, down: bool, time: Micros },
    button: struct { code: u16, down: bool, time: Micros },
    scroll: struct { dx: i32, dy: i32, time: Micros },
    /// Relative pointer motion to apply now.
    motion: struct { dx: i32, dy: i32 },
    /// Absolute pointer position.
    abs: struct { x: u16, y: u16 },
    pad: struct { index: u8, connected: bool, state: Gamepad },
};

// ---------------------------------------------------------------------------
// Wire format (little endian), the payload after the proto envelope:
//
// Events (kind 1), client to host:
//   u32 packet_seq
//   i64 send_time                  client clock
//   u32 first_seq                  sequence number of the first event below
//   u8  n_events
//   i32 motion_x, i32 motion_y     current relative motion totals
//   u8  flags                      bit 0: abs present, bit 1: held keys incomplete
//   [u16 abs_x, u16 abs_y]         if abs present
//   u8  buttons_held               bit (b-1) for button b
//   u8  n_keys_held, u16 × n       HID usages currently held
//   u8  pad_mask                   bit i: pad i connected, snapshot follows
//   pad × popcount: u32 buttons, i16 lx ly rx ry, u16 lt rt
//   event × n: u8 kind, u8 flags (bit 0 down), u16 code, i32 a, i32 b,
//              u32 age (send_time - time, µs), i32 motion_x, i32 motion_y
//
// Ack (kind 2), host to client:  u32 next_expected_seq

pub const event_wire_len = 24;
pub const pad_wire_len = 16;
pub const header_wire_len = 4 + 8 + 4 + 1 + 8 + 1;
pub const ack_wire_len = 4;

/// Largest packet the sender can build with `max_events` events.
pub fn maxPacketLen(max_events: usize) usize {
    return header_wire_len + 4 + 1 + 1 + 2 * max_held_keys + 1 + max_pads * pad_wire_len + max_events * event_wire_len;
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn int(w: *Writer, comptime T: type, v: T) void {
        const n = @sizeOf(T);
        std.mem.writeInt(T, w.buf[w.pos..][0..n], v, .little);
        w.pos += n;
    }
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn int(r: *Reader, comptime T: type) error{Truncated}!T {
        const n = @sizeOf(T);
        if (r.buf.len - r.pos < n) return error.Truncated;
        const v = std.mem.readInt(T, r.buf[r.pos..][0..n], .little);
        r.pos += n;
        return v;
    }
};

pub fn encodeAck(next_expected: u32, buf: *[ack_wire_len]u8) void {
    std.mem.writeInt(u32, buf, next_expected, .little);
}

pub fn decodeAck(buf: []const u8) error{ Truncated, InvalidMessage }!u32 {
    if (buf.len < ack_wire_len) return error.Truncated;
    if (buf.len > ack_wire_len) return error.InvalidMessage;
    return std.mem.readInt(u32, buf[0..4], .little);
}

/// a is after b, modulo 2^32.
fn seqAfter(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

// ---------------------------------------------------------------------------
// Sender (client)

pub const SenderConfig = struct {
    /// Most events repeated in one packet (the newest unacked ones).
    max_events: usize = 32,
    /// Events older than this are no longer repeated: replaying a stale key
    /// press is worse than losing it (the held-keys list still reconciles).
    max_event_age: Micros = 500_000,
    /// While anything is unacked or a change is recent, repeat at this rate
    /// even without new input.
    resend_interval: Micros = 8_000,
    /// Packets repeated after the last change, acked or not, so motion and
    /// pad snapshots survive the loss of the packet that carried them.
    tail_repeats: u8 = 3,
    /// With a gamepad connected, send at least this often.
    keepalive: Micros = 100_000,
};

pub const Sender = struct {
    const ring_cap = 128;

    cfg: SenderConfig,
    ring: [ring_cap]Event = undefined,
    /// Oldest unacked sequence number and next to assign.
    first_seq: u32 = 0,
    next_seq: u32 = 0,
    packet_seq: u32 = 0,

    motion: Motion = .{},
    abs: ?struct { x: u16, y: u16 } = null,
    /// The absolute position changed since the last sequenced abs_move.
    abs_unsequenced: bool = false,
    buttons_held: u8 = 0,
    keys_held: [max_held_keys]u16 = undefined,
    n_keys_held: usize = 0,
    keys_overflow: bool = false,
    pads: [max_pads]?Gamepad = .{null} ** max_pads,

    dirty: bool = false,
    repeats_left: u8 = 0,
    last_send: ?Micros = null,

    pub fn init(cfg: SenderConfig) Sender {
        std.debug.assert(cfg.max_events <= 255 and cfg.max_events <= ring_cap);
        return .{ .cfg = cfg };
    }

    fn push(s: *Sender, ev: Event) void {
        if (s.next_seq -% s.first_seq == ring_cap) s.first_seq +%= 1; // drop oldest
        var e = ev;
        e.motion = s.motion;
        s.ring[s.next_seq % ring_cap] = e;
        s.next_seq +%= 1;
        s.touch();
    }

    fn touch(s: *Sender) void {
        s.dirty = true;
        s.repeats_left = s.cfg.tail_repeats;
    }

    /// Sequence a pending absolute move so the event that follows lands there.
    fn syncAbs(s: *Sender, now: Micros) void {
        if (!s.abs_unsequenced) return;
        const p = s.abs.?;
        s.abs_unsequenced = false;
        s.push(.{ .kind = .abs_move, .a = p.x, .b = p.y, .time = now });
    }

    pub fn key(s: *Sender, code: u16, down: bool, now: Micros) void {
        s.syncAbs(now);
        s.setKeyHeld(code, down);
        s.push(.{ .kind = .key, .code = code, .down = down, .time = now });
    }

    pub fn button(s: *Sender, code: u16, down: bool, now: Micros) void {
        std.debug.assert(code >= 1 and code <= max_buttons);
        s.syncAbs(now);
        const bit = @as(u8, 1) << @intCast(code - 1);
        if (down) s.buttons_held |= bit else s.buttons_held &= ~bit;
        s.push(.{ .kind = .button, .code = code, .down = down, .time = now });
    }

    pub fn scroll(s: *Sender, dx: i32, dy: i32, now: Micros) void {
        s.syncAbs(now);
        s.push(.{ .kind = .scroll, .a = dx, .b = dy, .time = now });
    }

    /// Relative motion: accumulates; no event is queued.
    pub fn moveRel(s: *Sender, dx: i32, dy: i32) void {
        if (dx == 0 and dy == 0) return;
        s.motion.x +%= dx;
        s.motion.y +%= dy;
        s.touch();
    }

    /// Absolute position: latest wins until a click needs it sequenced.
    pub fn moveAbs(s: *Sender, x: u16, y: u16) void {
        if (s.abs) |p| if (p.x == x and p.y == y) return;
        s.abs = .{ .x = x, .y = y };
        s.abs_unsequenced = true;
        s.touch();
    }

    /// Set a pad's state, or null when it disconnects.
    pub fn pad(s: *Sender, index: u8, state: ?Gamepad) void {
        std.debug.assert(index < max_pads);
        const old = s.pads[index];
        if (old == null and state == null) return;
        if (old != null and state != null and std.meta.eql(old.?, state.?)) return;
        s.pads[index] = state;
        s.touch();
    }

    fn setKeyHeld(s: *Sender, code: u16, down: bool) void {
        const keys = s.keys_held[0..s.n_keys_held];
        const at = std.mem.indexOfScalar(u16, keys, code);
        if (down) {
            if (at != null) return;
            if (s.n_keys_held == max_held_keys) {
                s.keys_overflow = true;
                return;
            }
            s.keys_held[s.n_keys_held] = code;
            s.n_keys_held += 1;
        } else if (at) |i| {
            s.keys_held[i] = s.keys_held[s.n_keys_held - 1];
            s.n_keys_held -= 1;
            if (s.n_keys_held == 0) s.keys_overflow = false;
        } else if (s.n_keys_held == 0) {
            s.keys_overflow = false;
        }
    }

    /// The host has applied everything before `next_expected`.
    pub fn onAck(s: *Sender, next_expected: u32) void {
        // Ignore acks for sequence numbers never sent or already trimmed.
        if (seqAfter(next_expected, s.next_seq) or !seqAfter(next_expected, s.first_seq)) return;
        s.first_seq = next_expected;
    }

    pub fn unacked(s: *const Sender) u32 {
        return s.next_seq -% s.first_seq;
    }

    fn hasPads(s: *const Sender) bool {
        for (s.pads) |p| if (p != null) return true;
        return false;
    }

    fn hasFreshUnacked(s: *const Sender, now: Micros) bool {
        if (s.unacked() == 0) return false;
        const newest = s.ring[(s.next_seq -% 1) % ring_cap];
        return now - newest.time <= s.cfg.max_event_age;
    }

    /// Whether a packet should go out now.
    pub fn shouldSend(s: *const Sender, now: Micros) bool {
        if (s.dirty) return true;
        const since = if (s.last_send) |t| now - t else return false;
        if ((s.repeats_left > 0 or s.hasFreshUnacked(now)) and since >= s.cfg.resend_interval) return true;
        return s.hasPads() and since >= s.cfg.keepalive;
    }

    /// When `shouldSend` will next become true without new input (null: not
    /// until something happens).
    pub fn nextSendTime(s: *const Sender, now: Micros) ?Micros {
        if (s.dirty) return now;
        const last = s.last_send orelse return null;
        var t: ?Micros = null;
        if (s.repeats_left > 0 or s.hasFreshUnacked(now)) t = last + s.cfg.resend_interval;
        if (s.hasPads()) t = @min(t orelse std.math.maxInt(Micros), last + s.cfg.keepalive);
        return t;
    }

    /// Build the next packet into `buf` (at least `maxPacketLen(cfg.max_events)`
    /// bytes) and return it.
    pub fn build(s: *Sender, now: Micros, buf: []u8) []u8 {
        std.debug.assert(buf.len >= maxPacketLen(s.cfg.max_events));
        // The newest unacked events that are still fresh.
        var count: u32 = @min(s.unacked(), @as(u32, @intCast(s.cfg.max_events)));
        while (count > 0) {
            const oldest = s.ring[(s.next_seq -% count) % ring_cap];
            if (now - oldest.time <= s.cfg.max_event_age) break;
            count -= 1;
        }
        const first = s.next_seq -% count;

        var w: Writer = .{ .buf = buf };
        w.int(u32, s.packet_seq);
        w.int(i64, now);
        w.int(u32, first);
        w.int(u8, @intCast(count));
        w.int(i32, s.motion.x);
        w.int(i32, s.motion.y);
        var flags: u8 = 0;
        if (s.abs != null) flags |= 1;
        if (s.keys_overflow) flags |= 2;
        w.int(u8, flags);
        if (s.abs) |p| {
            w.int(u16, p.x);
            w.int(u16, p.y);
        }
        w.int(u8, s.buttons_held);
        w.int(u8, @intCast(s.n_keys_held));
        for (s.keys_held[0..s.n_keys_held]) |k| w.int(u16, k);
        var mask: u8 = 0;
        for (s.pads, 0..) |p, i| {
            if (p != null) mask |= @as(u8, 1) << @intCast(i);
        }
        w.int(u8, mask);
        for (s.pads) |maybe| {
            const p = maybe orelse continue;
            w.int(u32, p.buttons);
            w.int(i16, p.lx);
            w.int(i16, p.ly);
            w.int(i16, p.rx);
            w.int(i16, p.ry);
            w.int(u16, p.lt);
            w.int(u16, p.rt);
        }
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const e = s.ring[(first +% i) % ring_cap];
            w.int(u8, @intFromEnum(e.kind));
            w.int(u8, @intFromBool(e.down));
            w.int(u16, e.code);
            w.int(i32, e.a);
            w.int(i32, e.b);
            w.int(u32, @intCast(std.math.clamp(now - e.time, 0, std.math.maxInt(u32))));
            w.int(i32, e.motion.x);
            w.int(i32, e.motion.y);
        }

        s.packet_seq +%= 1;
        if (!s.dirty and s.repeats_left > 0) s.repeats_left -= 1;
        s.dirty = false;
        s.last_send = now;
        return buf[0..w.pos];
    }
};

// ---------------------------------------------------------------------------
// Receiver (host)

pub const Stats = struct {
    packets: u64 = 0,
    /// Packets dropped because a newer one was already processed.
    stale_packets: u64 = 0,
    events: u64 = 0,
    /// Event copies already applied from an earlier packet.
    duplicate_events: u64 = 0,
    /// Events that never arrived in any packet (beyond the redundancy).
    lost_events: u64 = 0,
    /// Key or button releases (or presses) synthesised from the held lists.
    reconciled: u64 = 0,
};

pub const Receiver = struct {
    started: bool = false,
    last_packet: u32 = 0,
    next_seq: u32 = 0,
    motion: Motion = .{},
    abs: ?struct { x: u16, y: u16 } = null,
    buttons_down: u8 = 0,
    keys_down: [max_held_keys]u16 = undefined,
    n_keys_down: usize = 0,
    pads: [max_pads]?Gamepad = .{null} ** max_pads,
    stats: Stats = .{},

    /// Room `out` needs for any packet.
    pub const max_actions = 2 * 255 + 1 + 1 + max_buttons + 2 * max_held_keys + max_pads;

    pub fn init() Receiver {
        return .{};
    }

    /// Sequence number the host expects next; send it back in an ack.
    pub fn nextExpected(r: *const Receiver) u32 {
        return r.next_seq;
    }

    /// Decode a packet and append the actions to inject to `out` (at least
    /// `max_actions` long). Returns how many were written. A malformed packet
    /// (truncated, trailing bytes, impossible counts) changes nothing.
    pub fn process(r: *Receiver, packet: []const u8, out: []Action) error{ Truncated, InvalidMessage }!usize {
        std.debug.assert(out.len >= max_actions);
        var rd: Reader = .{ .buf = packet };
        const pseq = try rd.int(u32);
        const send_time = try rd.int(i64);
        const first = try rd.int(u32);
        const n_events = try rd.int(u8);
        const motion: Motion = .{ .x = try rd.int(i32), .y = try rd.int(i32) };
        const flags = try rd.int(u8);
        var abs: ?struct { x: u16, y: u16 } = null;
        if (flags & 1 != 0) abs = .{ .x = try rd.int(u16), .y = try rd.int(u16) };
        const keys_complete = flags & 2 == 0;
        const buttons_held = try rd.int(u8);
        const n_keys = try rd.int(u8);
        if (n_keys > max_held_keys) return error.InvalidMessage;
        var keys: [max_held_keys]u16 = undefined;
        for (keys[0..n_keys]) |*k| k.* = try rd.int(u16);
        const mask = try rd.int(u8);
        if (mask >> max_pads != 0) return error.InvalidMessage;
        var pads: [max_pads]?Gamepad = .{null} ** max_pads;
        for (&pads, 0..) |*p, i| {
            if (mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
            p.* = .{
                .buttons = try rd.int(u32),
                .lx = try rd.int(i16),
                .ly = try rd.int(i16),
                .rx = try rd.int(i16),
                .ry = try rd.int(i16),
                .lt = try rd.int(u16),
                .rt = try rd.int(u16),
            };
        }
        const rest = packet.len - rd.pos;
        if (rest < @as(usize, n_events) * event_wire_len) return error.Truncated;
        if (rest > @as(usize, n_events) * event_wire_len) return error.InvalidMessage; // trailing bytes

        // Fully validated from here on.
        if (r.started and !seqAfter(pseq, r.last_packet)) {
            r.stats.stale_packets += 1;
            return 0;
        }
        r.stats.packets += 1;
        var n: usize = 0;

        if (!r.started) {
            // Join mid-stream: take the stream's current state as the base.
            r.started = true;
            r.next_seq = first;
            // Motion before the first event we can see is not ours to apply.
            r.motion = motion;
            if (n_events > 0) {
                const ev = packet[rd.pos..][0..event_wire_len];
                r.motion = .{
                    .x = std.mem.readInt(i32, ev[16..20], .little),
                    .y = std.mem.readInt(i32, ev[20..24], .little),
                };
            }
        }
        r.last_packet = pseq;

        var i: u32 = 0;
        while (i < n_events) : (i += 1) {
            const seq = first +% i;
            const kind: EventKind = @enumFromInt(try rd.int(u8));
            const ev_flags = try rd.int(u8);
            const code = try rd.int(u16);
            const a = try rd.int(i32);
            const b = try rd.int(i32);
            const age = try rd.int(u32);
            const m: Motion = .{ .x = try rd.int(i32), .y = try rd.int(i32) };
            if (seqAfter(r.next_seq, seq)) {
                r.stats.duplicate_events += 1;
                continue;
            }
            if (seq != r.next_seq) r.stats.lost_events += seq -% r.next_seq;
            r.next_seq = seq +% 1;
            r.stats.events += 1;

            n += r.applyMotion(m, out[n..]);
            const time = send_time - age;
            const down = ev_flags & 1 != 0;
            switch (kind) {
                .key => {
                    r.trackKey(code, down);
                    out[n] = .{ .key = .{ .code = code, .down = down, .time = time } };
                    n += 1;
                },
                .button => {
                    if (code < 1 or code > max_buttons) continue;
                    const bit = @as(u8, 1) << @intCast(code - 1);
                    if (down) r.buttons_down |= bit else r.buttons_down &= ~bit;
                    out[n] = .{ .button = .{ .code = code, .down = down, .time = time } };
                    n += 1;
                },
                .scroll => {
                    out[n] = .{ .scroll = .{ .dx = a, .dy = b, .time = time } };
                    n += 1;
                },
                .abs_move => {
                    n += r.applyAbs(@truncate(@as(u32, @bitCast(a))), @truncate(@as(u32, @bitCast(b))), out[n..]);
                },
                _ => {}, // unknown kinds from a newer client are skipped
            }
        }
        // Events beyond what this packet carried were never seen.
        if (seqAfter(first +% n_events, r.next_seq)) {
            r.stats.lost_events += (first +% n_events) -% r.next_seq;
            r.next_seq = first +% n_events;
        }

        n += r.applyMotion(motion, out[n..]);
        if (abs) |p| n += r.applyAbs(p.x, p.y, out[n..]);
        n += r.reconcile(buttons_held, keys[0..n_keys], keys_complete, send_time, out[n..]);

        for (pads, 0..) |p, idx| {
            const old = r.pads[idx];
            if (old == null and p == null) continue;
            if (old != null and p != null and std.meta.eql(old.?, p.?)) continue;
            r.pads[idx] = p;
            out[n] = .{ .pad = .{ .index = @intCast(idx), .connected = p != null, .state = p orelse .{} } };
            n += 1;
        }
        return n;
    }

    fn applyMotion(r: *Receiver, to: Motion, out: []Action) usize {
        const d = to.delta(r.motion);
        r.motion = to;
        if (d.isZero()) return 0;
        out[0] = .{ .motion = .{ .dx = d.x, .dy = d.y } };
        return 1;
    }

    fn applyAbs(r: *Receiver, x: u16, y: u16, out: []Action) usize {
        if (r.abs) |p| if (p.x == x and p.y == y) return 0;
        r.abs = .{ .x = x, .y = y };
        out[0] = .{ .abs = .{ .x = x, .y = y } };
        return 1;
    }

    fn trackKey(r: *Receiver, code: u16, down: bool) void {
        const at = std.mem.indexOfScalar(u16, r.keys_down[0..r.n_keys_down], code);
        if (down) {
            if (at == null and r.n_keys_down < max_held_keys) {
                r.keys_down[r.n_keys_down] = code;
                r.n_keys_down += 1;
            }
        } else if (at) |i| {
            r.keys_down[i] = r.keys_down[r.n_keys_down - 1];
            r.n_keys_down -= 1;
        }
    }

    /// Bring held keys and buttons in line with the sender's lists. After a
    /// packet's events this is a no-op unless events were lost.
    fn reconcile(r: *Receiver, buttons: u8, keys: []const u16, keys_complete: bool, time: Micros, out: []Action) usize {
        var n: usize = 0;
        const diff = buttons ^ r.buttons_down;
        if (diff != 0) {
            for (0..max_buttons) |bi| {
                const bit = @as(u8, 1) << @intCast(bi);
                if (diff & bit == 0) continue;
                out[n] = .{ .button = .{ .code = @intCast(bi + 1), .down = buttons & bit != 0, .time = time } };
                n += 1;
            }
            r.buttons_down = buttons;
        }
        if (keys_complete) {
            // Release what the sender no longer holds.
            var i: usize = 0;
            while (i < r.n_keys_down) {
                const k = r.keys_down[i];
                if (std.mem.indexOfScalar(u16, keys, k) == null) {
                    out[n] = .{ .key = .{ .code = k, .down = false, .time = time } };
                    n += 1;
                    r.keys_down[i] = r.keys_down[r.n_keys_down - 1];
                    r.n_keys_down -= 1;
                } else i += 1;
            }
        }
        // Press what the sender holds and we missed.
        for (keys) |k| {
            if (std.mem.indexOfScalar(u16, r.keys_down[0..r.n_keys_down], k) != null) continue;
            if (r.n_keys_down == max_held_keys) break;
            r.keys_down[r.n_keys_down] = k;
            r.n_keys_down += 1;
            out[n] = .{ .key = .{ .code = k, .down = true, .time = time } };
            n += 1;
        }
        r.stats.reconciled += n;
        return n;
    }
};

test {
    _ = @import("test.zig");
}
