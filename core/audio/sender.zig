//! Host side of the audio stream: numbers frames, writes frame datagrams, and every `k`
//! frames writes `m` Reed-Solomon parity datagrams over the group (the "light RS" of the
//! design doc; `m = 0` turns it off).
//!
//! The caller owns the transport-wide envelope sequence numbers and passes one per
//! datagram:
//!
//!     const dg = try sender.frame(&buf, next_env_seq(), capture_us, 480, fec, packet);
//!     send(dg);
//!     while (try sender.parity(&buf, next_env_seq())) |p| send(p);

const std = @import("std");
const proto = @import("../proto/root.zig");
const fec = @import("../media/fec.zig");
const wire = @import("wire.zig");

pub const Config = struct {
    /// Frames per parity group. With 10 ms frames and a 20 ms jitter buffer, k = 2 lets
    /// the first frame of a group be rebuilt in time; larger k recovers too late.
    k: u8 = 2,
    /// Parity datagrams per group; 0 disables RS.
    m: u8 = 1,
};

const max_body = wire.FrameHeader.size + wire.max_packet;

pub const Sender = struct {
    cfg: Config,
    codec: ?fec.Codec,
    next_seq: u32 = 0,
    /// Bodies of the current group's frames, kept until the group completes.
    bodies: [wire.max_group][max_body]u8 = undefined,
    lens: [wire.max_group]u16 = @splat(0),
    in_group: u8 = 0,
    group_first: u32 = 0,
    parity_buf: [wire.max_parity][max_body]u8 = undefined,
    parity_len: usize = 0,
    parity_next: u8 = 0,
    parity_ready: u8 = 0,
    stats: Stats = .{},

    pub const Stats = struct {
        frames: u64 = 0,
        frames_with_fec: u64 = 0,
        parity: u64 = 0,
        bytes: u64 = 0,
    };

    pub fn init(cfg: Config) error{InvalidConfig}!Sender {
        if (cfg.m > wire.max_parity or (cfg.m > 0 and (cfg.k == 0 or cfg.k > wire.max_group))) return error.InvalidConfig;
        return .{ .cfg = cfg, .codec = if (cfg.m > 0) fec.Codec.init(cfg.k, cfg.m) catch unreachable else null };
    }

    /// Writes the datagram for the next frame. `has_fec` says the codec packet carries
    /// in-band FEC for the previous frame (for Opus, `opus.Packet.hasFec`).
    pub fn frame(s: *Sender, buf: []u8, env_seq: u32, capture_us: u64, samples: u16, has_fec: bool, packet: []const u8) proto.EncodeError![]u8 {
        std.debug.assert(s.parity_ready == 0); // drain `parity` after each frame
        const h: wire.FrameHeader = .{ .seq = s.next_seq, .capture_us = capture_us, .samples = samples, .flags = if (has_fec) wire.FrameHeader.flag_fec else 0 };
        const dg = try wire.encodeFrame(buf, env_seq, h, packet);
        s.next_seq +%= 1;
        s.stats.frames += 1;
        if (has_fec) s.stats.frames_with_fec += 1;
        s.stats.bytes += dg.len;
        if (s.codec) |codec| {
            if (s.in_group == 0) s.group_first = h.seq;
            const body = dg[proto.Envelope.size..];
            @memcpy(s.bodies[s.in_group][0..body.len], body);
            s.lens[s.in_group] = @intCast(body.len);
            s.in_group += 1;
            if (s.in_group == s.cfg.k) s.finishGroup(codec);
        }
        return dg;
    }

    fn finishGroup(s: *Sender, codec: fec.Codec) void {
        const k = s.cfg.k;
        var longest: usize = 0;
        for (s.lens[0..k]) |l| longest = @max(longest, l);
        var data: [wire.max_group][]const u8 = undefined;
        for (0..k) |i| {
            @memset(s.bodies[i][s.lens[i]..longest], 0);
            data[i] = s.bodies[i][0..longest];
        }
        var par: [wire.max_parity][]u8 = undefined;
        for (0..s.cfg.m) |i| par[i] = s.parity_buf[i][0..longest];
        codec.encode(data[0..k], par[0..s.cfg.m]) catch unreachable;
        s.parity_len = longest;
        s.parity_next = 0;
        s.parity_ready = s.cfg.m;
        s.in_group = 0;
    }

    /// The next parity datagram of a group that just completed, or null.
    pub fn parity(s: *Sender, buf: []u8, env_seq: u32) proto.EncodeError!?[]u8 {
        if (s.parity_ready == 0) return null;
        var h: wire.ParityHeader = .{ .first_seq = s.group_first, .k = s.cfg.k, .m = s.cfg.m, .index = s.parity_next };
        @memcpy(h.lens[0..s.cfg.k], s.lens[0..s.cfg.k]);
        const dg = try wire.encodeParity(buf, env_seq, h, s.parity_buf[s.parity_next][0..s.parity_len]);
        s.parity_next += 1;
        s.parity_ready -= 1;
        s.stats.parity += 1;
        s.stats.bytes += dg.len;
        return dg;
    }
};

const testing = std.testing;

test "frames are numbered and every k-th frame is followed by m parity datagrams" {
    var s = try Sender.init(.{ .k = 2, .m = 1 });
    var buf: [proto.max_datagram]u8 = undefined;
    var env: u32 = 0;
    var parities: u32 = 0;
    for (0..6) |i| {
        const dg = try s.frame(&buf, env, i * 10_000, 480, i % 2 == 1, "pkt-data"[0 .. 3 + i % 4]);
        env += 1;
        const f = try wire.Frame.parse((try proto.decode(dg)).other.payload);
        try testing.expectEqual(@as(u32, @intCast(i)), f.header.seq);
        try testing.expectEqual(i % 2 == 1, f.header.hasFec());
        while (try s.parity(&buf, env)) |p| {
            env += 1;
            parities += 1;
            const par = try wire.Parity.parse((try proto.decode(p)).other.payload);
            try testing.expectEqual(@as(u32, @intCast(i - 1)), par.header.first_seq);
        }
    }
    try testing.expectEqual(@as(u32, 3), parities);
    try testing.expectEqual(@as(u64, 3), s.stats.parity);
}

test "m = 0 sends no parity" {
    var s = try Sender.init(.{ .m = 0 });
    var buf: [proto.max_datagram]u8 = undefined;
    for (0..4) |i| {
        _ = try s.frame(&buf, @intCast(i), 0, 480, false, "x");
        try testing.expectEqual(@as(?[]u8, null), try s.parity(&buf, 0));
    }
    try testing.expectError(error.InvalidConfig, Sender.init(.{ .k = 9 }));
}
