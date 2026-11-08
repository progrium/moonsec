//! wasm32 module for the browser test harness's stub host (web/e2e/stub-host.mjs): the
//! core's input `Receiver`, so input from the web client is decoded by the same code a
//! real host runs. Test-only; not shipped.
//!
//! Each decoded action is written as `action_words` i32s to `moonsec_host_actions_ptr()`:
//! [kind, a, b, c, d, e, f, g, h, i] with kind 1 key (code, down), 2 button (code, down),
//! 3 scroll (dx, dy), 4 motion (dx, dy), 5 abs (x, y), 6 pad (index, connected, buttons,
//! lx, ly, rx, ry, lt, rt).

const std = @import("std");
const core = @import("core");
const input = core.input;
const proto = core.proto;

pub const action_words = 10;

var rx: input.Receiver = .{};
var in_buf: [proto.max_datagram]u8 = undefined;
var out_buf: [proto.Envelope.size + input.ack_wire_len]u8 = undefined;
var actions: [input.Receiver.max_actions]input.Action = undefined;
var words: [input.Receiver.max_actions * action_words]i32 = undefined;

export fn moonsec_host_reset() void {
    rx = .{};
}

export fn moonsec_host_in_ptr() [*]u8 {
    return &in_buf;
}

export fn moonsec_host_in_cap() u32 {
    return in_buf.len;
}

export fn moonsec_host_actions_ptr() [*]i32 {
    return &words;
}

export fn moonsec_host_out_ptr() [*]u8 {
    return &out_buf;
}

/// Decode an input datagram (envelope included). Returns the number of actions written,
/// -1 if malformed, -2 if it is not an input events message.
export fn moonsec_host_on_datagram(len: u32) i32 {
    if (len > in_buf.len) return -1;
    var d = proto.wire.Decoder.init(in_buf[0..len]);
    const env = proto.Envelope.decode(&d) catch return -1;
    if (env.stream != .input or env.kind != @intFromEnum(input.Kind.events)) return -2;
    const n = rx.process(in_buf[proto.Envelope.size..len], &actions) catch return -1;
    for (actions[0..n], 0..) |a, i| {
        const w = words[i * action_words ..][0..action_words];
        @memset(w, 0);
        switch (a) {
            .key => |k| w[0..3].* = .{ 1, k.code, @intFromBool(k.down) },
            .button => |b| w[0..3].* = .{ 2, b.code, @intFromBool(b.down) },
            .scroll => |s| w[0..3].* = .{ 3, s.dx, s.dy },
            .motion => |m| w[0..3].* = .{ 4, m.dx, m.dy },
            .abs => |p| w[0..3].* = .{ 5, p.x, p.y },
            .pad => |p| w.* = .{ 6, p.index, @intFromBool(p.connected), @bitCast(p.state.buttons), p.state.lx, p.state.ly, p.state.rx, p.state.ry, p.state.lt, p.state.rt },
        }
    }
    return @intCast(n);
}

/// Build the ack for everything applied so far, with envelope sequence `seq`; returns
/// its length (written to the out buffer).
export fn moonsec_host_build_ack(seq: u32) u32 {
    var e = proto.wire.Encoder.init(&out_buf);
    (proto.Envelope{ .stream = .input, .kind = @intFromEnum(input.Kind.ack), .seq = seq }).encode(&e) catch unreachable;
    var ack: [input.ack_wire_len]u8 = undefined;
    input.encodeAck(rx.nextExpected(), &ack);
    e.bytes(&ack) catch unreachable;
    return @intCast(e.written().len);
}

export fn moonsec_host_stat(which: u32) f64 {
    const s = rx.stats;
    const v: u64 = switch (which) {
        0 => s.packets,
        1 => s.stale_packets,
        2 => s.events,
        3 => s.duplicate_events,
        4 => s.lost_events,
        5 => s.reconciled,
        else => 0,
    };
    return @floatFromInt(v);
}
