//! Browser ABI for the input sender (wasm32). The web client (web/src/input) maps DOM
//! and Gamepad API events to these calls; the core does sequencing, redundancy, motion
//! totals and pad snapshots exactly as on native clients (spec/input-clock-v0.md).
//!
//! One sender per module instance. Buffers are Zig-owned: `moonsec_input_build` writes a
//! whole datagram (envelope included) to `moonsec_input_out_ptr()`, and an incoming
//! datagram is copied to `moonsec_input_in_ptr()` before `moonsec_input_on_datagram`.
//! Times are microseconds on the client's monotonic clock, passed as f64 so JS can hand
//! over `performance.now() * 1000` without BigInt.

const std = @import("std");
const input = @import("root.zig");
const proto = @import("../proto/root.zig");

/// Most events repeated per packet, as on native clients.
const max_events = 32;
const out_cap = proto.Envelope.size + input.maxPacketLen(max_events);
comptime {
    std.debug.assert(out_cap <= proto.max_datagram);
}

var sender: input.Sender = input.Sender.init(.{ .max_events = max_events });
var out_buf: [out_cap]u8 = undefined;
var in_buf: [proto.max_datagram]u8 = undefined;

fn micros(t: f64) input.Micros {
    if (!(t == t)) return 0; // NaN
    return @intFromFloat(std.math.clamp(t, -9.0e15, 9.0e15));
}

fn clampI32(v: i32, comptime T: type) T {
    return @intCast(std.math.clamp(v, std.math.minInt(T), std.math.maxInt(T)));
}

/// Forget all state (a new session).
export fn moonsec_input_reset() void {
    sender = input.Sender.init(.{ .max_events = max_events });
}

/// `code` is a USB HID keyboard usage (page 7).
export fn moonsec_input_key(code: u32, down: u32, now: f64) void {
    if (code == 0 or code > 0xffff) return;
    sender.key(@intCast(code), down != 0, micros(now));
}

/// `code` is the 1-based mouse button; others are ignored.
export fn moonsec_input_button(code: u32, down: u32, now: f64) void {
    if (code < 1 or code > input.max_buttons) return;
    sender.button(@intCast(code), down != 0, micros(now));
}

/// 120 per wheel notch; right and down positive (DOM convention).
export fn moonsec_input_scroll(dx: i32, dy: i32, now: f64) void {
    if (dx == 0 and dy == 0) return;
    sender.scroll(dx, dy, micros(now));
}

/// Relative motion in device pixels (pointer lock).
export fn moonsec_input_move_rel(dx: i32, dy: i32) void {
    sender.moveRel(dx, dy);
}

/// Absolute position, 0..65535 across the streamed display.
export fn moonsec_input_move_abs(x: i32, y: i32) void {
    sender.moveAbs(clampI32(x, u16), clampI32(y, u16));
}

/// A pad's full state (`Gamepad.Button` bits, sticks right/up positive, triggers
/// 0..65535), or a disconnect when `connected` is 0.
export fn moonsec_input_pad(index: u32, connected: u32, buttons: u32, lx: i32, ly: i32, rx: i32, ry: i32, lt: i32, rt: i32) void {
    if (index >= input.max_pads) return;
    if (connected == 0) return sender.pad(@intCast(index), null);
    sender.pad(@intCast(index), .{
        .buttons = buttons,
        .lx = clampI32(lx, i16),
        .ly = clampI32(ly, i16),
        .rx = clampI32(rx, i16),
        .ry = clampI32(ry, i16),
        .lt = clampI32(lt, u16),
        .rt = clampI32(rt, u16),
    });
}

/// 1 when a packet should go out now.
export fn moonsec_input_should_send(now: f64) u32 {
    return @intFromBool(sender.shouldSend(micros(now)));
}

/// When a packet is next due without new input (µs), or -1 for not until input arrives.
export fn moonsec_input_next_send(now: f64) f64 {
    const t = sender.nextSendTime(micros(now)) orelse return -1;
    return @floatFromInt(t);
}

/// Build the next input datagram with envelope sequence `seq` (the transport-wide
/// counter the caller owns) into the out buffer; returns its length.
export fn moonsec_input_build(now: f64, seq: u32) u32 {
    var e = proto.wire.Encoder.init(&out_buf);
    (proto.Envelope{ .stream = .input, .kind = @intFromEnum(input.Kind.events), .seq = seq }).encode(&e) catch unreachable;
    const payload = sender.build(micros(now), out_buf[proto.Envelope.size..]);
    return @intCast(proto.Envelope.size + payload.len);
}

export fn moonsec_input_out_ptr() [*]u8 {
    return &out_buf;
}

export fn moonsec_input_in_ptr() [*]u8 {
    return &in_buf;
}

export fn moonsec_input_in_cap() u32 {
    return in_buf.len;
}

/// Offer a received datagram (copied to the in buffer). Returns 1 if it was an input
/// ack and was applied, 0 if it was for another stream or kind, -1 if malformed.
export fn moonsec_input_on_datagram(len: u32) i32 {
    if (len > in_buf.len) return -1;
    var d = proto.wire.Decoder.init(in_buf[0..len]);
    const env = proto.Envelope.decode(&d) catch return -1;
    if (env.stream != .input or env.kind != @intFromEnum(input.Kind.ack)) return 0;
    const next = input.decodeAck(in_buf[proto.Envelope.size..len]) catch return -1;
    sender.onAck(next);
    return 1;
}

/// Events not yet acknowledged by the host.
export fn moonsec_input_unacked() u32 {
    return sender.unacked();
}

const testing = std.testing;

test "wasm ABI: events reach a receiver and acks trim the sender" {
    moonsec_input_reset();
    moonsec_input_move_abs(100, 200);
    moonsec_input_button(1, 1, 1000);
    moonsec_input_button(1, 0, 2000);
    moonsec_input_key(0x04, 1, 3000); // 'a'
    moonsec_input_move_rel(5, -3);
    moonsec_input_pad(0, 1, 0x1000, 40000, -40000, 0, 0, 70000, 0);
    try testing.expectEqual(@as(u32, 1), moonsec_input_should_send(3000));

    const len = moonsec_input_build(3500, 77);
    var d = proto.wire.Decoder.init(out_buf[0..len]);
    const env = try proto.Envelope.decode(&d);
    try testing.expectEqual(proto.StreamId.input, env.stream);
    try testing.expectEqual(@as(u32, 77), env.seq);

    var r = input.Receiver.init();
    var actions: [input.Receiver.max_actions]input.Action = undefined;
    const n = try r.process(out_buf[proto.Envelope.size..len], &actions);
    var saw_pad = false;
    var saw_key = false;
    var clicks: usize = 0;
    for (actions[0..n]) |a| switch (a) {
        .pad => |p| {
            saw_pad = true;
            try testing.expectEqual(@as(i16, 32767), p.state.lx);
            try testing.expectEqual(@as(i16, -32768), p.state.ly);
            try testing.expectEqual(@as(u16, 65535), p.state.lt);
        },
        .key => |k| saw_key = k.code == 0x04 and k.down,
        .button => clicks += 1,
        else => {},
    };
    try testing.expect(saw_pad and saw_key);
    try testing.expectEqual(@as(usize, 2), clicks);
    try testing.expectEqual(@as(u32, 4), moonsec_input_unacked()); // abs_move, 2 buttons, key

    // The ack comes back as a datagram.
    var e = proto.wire.Encoder.init(&in_buf);
    try (proto.Envelope{ .stream = .input, .kind = @intFromEnum(input.Kind.ack), .seq = 1 }).encode(&e);
    var ack: [input.ack_wire_len]u8 = undefined;
    input.encodeAck(r.nextExpected(), &ack);
    try e.bytes(&ack);
    try testing.expectEqual(@as(i32, 1), moonsec_input_on_datagram(@intCast(e.written().len)));
    try testing.expectEqual(@as(u32, 0), moonsec_input_unacked());

    // Other streams are ignored; garbage is rejected.
    in_buf[1] = @intFromEnum(proto.StreamId.video);
    try testing.expectEqual(@as(i32, 0), moonsec_input_on_datagram(@intCast(e.written().len)));
    try testing.expectEqual(@as(i32, -1), moonsec_input_on_datagram(3));
    moonsec_input_reset();
}
