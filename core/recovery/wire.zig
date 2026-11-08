//! Conversions between recovery's acks and the wire's frame ack (`proto.FrameAck`).

const std = @import("std");
const proto = @import("../proto/root.zig");
const types = @import("types.zig");

/// The wire form of a client ack. `buf` holds the entries and must outlive the result.
pub fn toFrameAck(ack: *const types.Ack, buf: *[types.Ack.max_entries]proto.FrameAck.Entry) proto.FrameAck {
    for (ack.slice(), buf[0..ack.len]) |e, *o| o.* = .{ .frame_id = e.frame_id, .ltr_token = e.token };
    const r = ack.recovery;
    return .{
        .flags = .{ .recovery_needed = r != null, .want_idr = r != null and r.?.want_idr },
        .gap_frame = if (r) |q| q.first_missing else 0,
        .entries = buf[0..ack.len],
    };
}

/// Feeds a decoded frame ack to host recovery (`host` is a `*Host(n)`).
pub fn applyFrameAck(host: anytype, view: proto.FrameAck.View) void {
    var it = view.iterator();
    while (it.next()) |e| host.onAckEntry(.{ .frame_id = e.frame_id, .token = e.ltr_token });
    if (view.flags.recovery_needed) host.onRecoveryRequest(.{ .first_missing = view.gap_frame, .want_idr = view.flags.want_idr });
}

/// Recovery's view of a frame from its first video shard header.
pub fn frameMeta(h: proto.ShardHeader) types.FrameMeta {
    return .{
        .frame_id = h.frame_id,
        .keyframe = h.flags.keyframe,
        .refresh = h.flags.ltr_refresh,
        .ltr_token = if (h.flags.ltr) h.ltr_token else null,
    };
}

/// Sets the recovery flags and token on a shard header the packetizer is filling in.
pub fn stampHeader(h: *proto.ShardHeader, flags: types.FrameFlags, token: ?types.LtrToken) void {
    h.flags.keyframe = flags.keyframe;
    h.flags.ltr_refresh = flags.refresh;
    h.flags.ltr = token != null;
    h.ltr_token = token orelse 0;
}

const testing = std.testing;
const Host = @import("host.zig").Host(64);
const Client = @import("client.zig").Client;

test "client ack -> datagram -> host" {
    var h = Host.init(.{});
    var c = Client.init(.{});
    // Frame 0: keyframe and LTR, through a real shard header.
    _ = h.nextEncode();
    const flags = h.onEncoded(0, 0xdead_beef_0000_0001, true);
    var hdr: proto.ShardHeader = .{
        .media_seq = 0,
        .frame_id = 0,
        .slice = 0,
        .slice_count = 1,
        .group = 0,
        .group_count = 1,
        .shard = 0,
        .data_shards = 1,
        .parity_shards = 0,
        .group_len = 1,
        .capture_us = 0,
        .encode_done_us = 0,
    };
    stampHeader(&hdr, flags, 0xdead_beef_0000_0001);
    var buf: [proto.max_datagram]u8 = undefined;
    const dg = try proto.encodeVideoShard(&buf, 1, hdr, "x");
    const m = (try proto.decode(dg)).video_shard;
    const meta = frameMeta(m.header);
    try testing.expectEqual(@import("client.zig").Verdict.decode, c.onFrame(meta, 0));
    c.onDecoded(meta, true, 0);
    c.onFrameLost(1, 0);

    const ack = c.poll(0).?;
    var ebuf: [types.Ack.max_entries]proto.FrameAck.Entry = undefined;
    const out = try proto.encodeFrameAck(&buf, 2, toFrameAck(&ack, &ebuf));
    const fa = (try proto.decode(out)).frame_ack.ack;
    try testing.expect(fa.flags.recovery_needed);
    try testing.expect(!fa.flags.want_idr);
    try testing.expectEqual(@as(u32, 1), fa.gap_frame);

    _ = h.nextEncode();
    _ = h.onEncoded(1, null, false);
    applyFrameAck(&h, fa);
    const d = h.nextEncode();
    try testing.expectEqual(@import("host.zig").Force.ltr_refresh, d.force);
    try testing.expectEqualSlices(types.LtrToken, &.{0xdead_beef_0000_0001}, d.acked_tokens);
}
