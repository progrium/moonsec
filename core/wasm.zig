//! wasm32 build root for the core. Exports a few entry points so the compiler analyzes
//! the codec paths for wasm32; the real browser ABI comes with the web client.

const core = @import("root.zig");
const proto = core.proto;

comptime {
    // Input sender ABI for the web client (web/src/input).
    _ = @import("input/wasm.zig");
}

/// Parses one datagram; returns its stream ID, or 0 if it does not parse.
export fn moonsec_proto_stream(ptr: [*]const u8, len: usize) u8 {
    const m = proto.decode(ptr[0..len]) catch return 0;
    switch (m) {
        .feedback => |f| {
            var it = f.feedback.iterator();
            while (it.next()) |_| {}
        },
        .frame_ack => |f| {
            var it = f.ack.iterator();
            while (it.next()) |_| {}
        },
        else => {},
    }
    return @intFromEnum(m.envelope().stream);
}

/// Encodes a frame ack with no entries; returns the length written, or 0 on error.
export fn moonsec_proto_encode_empty_ack(ptr: [*]u8, cap: usize, seq: u32) usize {
    const out = proto.encodeFrameAck(ptr[0..cap], seq, .{ .entries = &.{} }) catch return 0;
    return out.len;
}

/// Encodes a video shard; returns the length written, or 0 on error.
export fn moonsec_proto_encode_shard(ptr: [*]u8, cap: usize, seq: u32, header: *const proto.ShardHeader, payload: [*]const u8, payload_len: usize) usize {
    const out = proto.encodeVideoShard(ptr[0..cap], seq, header.*, payload[0..payload_len]) catch return 0;
    return out.len;
}

/// Encodes transport feedback for `n` arrivals (0 = lost); returns length or 0.
export fn moonsec_proto_encode_feedback(ptr: [*]u8, cap: usize, seq: u32, base_seq: u32, ref_us: u64, arrivals: [*]const u64, n: usize) usize {
    var tmp: [256]?u64 = undefined;
    if (n > tmp.len) return 0;
    for (arrivals[0..n], tmp[0..n]) |a, *t| t.* = if (a == 0) null else a;
    const out = proto.encodeFeedback(ptr[0..cap], seq, .{ .feedback_seq = 0, .base_seq = base_seq, .ref_time_us = ref_us, .arrivals = tmp[0..n] }) catch return 0;
    return out.len;
}

/// Feeds stream bytes to a fresh client control channel and returns the number of events
/// they produce (analyzes the control channel for wasm32; the real ABI comes with 6B).
export fn moonsec_control_events(ptr: [*]const u8, len: usize) u32 {
    var mem: [1 << 16]u8 = undefined;
    var fba = @import("std").heap.FixedBufferAllocator.init(&mem);
    const gpa = fba.allocator();
    var clip = core.control.Clipboard.init(.client, .{ .max_text = 4096 });
    var ch = core.control.Channel.init(gpa, .{ .role = .client, .max_message = 1 << 16 }, &clip) catch return 0;
    ch.receive(ptr[0..len]) catch return 0;
    var n: u32 = 0;
    while (ch.poll() catch return n) |_| n += 1;
    return n;
}

/// Parses a display list into `out` (up to `cap` entries); returns the count, or -1.
export fn moonsec_display_list_decode(ptr: [*]const u8, len: usize, out: [*]core.display.DisplayInfo, cap: usize) i32 {
    const d = core.display.DisplayList.decode(ptr[0..len], out[0..cap]) orelse return -1;
    return @intCast(d.n);
}

/// Parses a multi-user roster message body; returns 1 if it gives this client input, 0 if
/// not, -1 if it does not parse.
export fn moonsec_multi_roster_have_input(ptr: [*]const u8, len: usize) i32 {
    var v: core.multi.View = .{};
    v.onRoster(ptr[0..len]);
    if (!v.have) return -1;
    return @intFromBool(v.haveInput());
}
