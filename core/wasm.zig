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
