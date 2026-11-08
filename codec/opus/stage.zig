//! The audio stage's two ends, Opus plus `core.audio`, for the session to drive:
//!
//! Host:   `HostAudio.encode(pcm, capture_us, out)` per 10 ms of captured PCM (from the
//!         platform's AudioSource) writes the frame datagram and any parity datagrams.
//! Client: `ClientAudio.onMessage` for every audio-stream datagram, and
//!         `ClientAudio.render(now_us, out)` each time the platform's AudioSink wants a
//!         frame; it runs the jitter buffer's action on the decoder and returns PCM.
//!
//! Both are sans-I/O: no threads, clocks or sockets. PCM is interleaved f32 at 48 kHz.

const std = @import("std");
const core = @import("core");
const opus = @import("opus");

const proto = core.proto;
const audio = core.audio;

pub const HostOptions = struct {
    encoder: opus.EncoderOptions = .{},
    rs: audio.sender.Config = .{},
    /// Samples per channel per frame (480 = 10 ms).
    frame_samples: u16 = 480,
};

pub const HostAudio = struct {
    enc: opus.Encoder,
    tx: audio.Sender,
    frame_samples: u16,
    pkt: [audio.wire.max_packet]u8 = undefined,
    /// The Opus packet of the last frame encoded.
    last: []const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, o: HostOptions) !HostAudio {
        return .{ .enc = try opus.Encoder.init(gpa, o.encoder), .tx = try audio.Sender.init(o.rs), .frame_samples = o.frame_samples };
    }

    pub fn deinit(h: *HostAudio, gpa: std.mem.Allocator) void {
        h.enc.deinit(gpa);
    }

    /// Up to 1 + `max_parity` datagrams for one frame.
    pub const Out = struct {
        bufs: [1 + audio.wire.max_parity][proto.max_datagram]u8 = undefined,
        lens: [1 + audio.wire.max_parity]usize = undefined,
        n: usize = 0,

        pub fn datagram(o: *const Out, i: usize) []const u8 {
            return o.bufs[i][0..o.lens[i]];
        }
    };

    /// Encodes one frame (`frame_samples * channels` samples). `next_seq` is called once
    /// per datagram for the transport-wide envelope sequence number.
    pub fn encode(h: *HostAudio, pcm: []const f32, capture_us: u64, ctx: anytype, comptime next_seq: fn (@TypeOf(ctx)) u32, out: *Out) !void {
        std.debug.assert(pcm.len == @as(usize, h.frame_samples) * h.enc.channels);
        const pkt = try h.enc.encode(pcm, &h.pkt);
        h.last = pkt;
        const dg = try h.tx.frame(&out.bufs[0], next_seq(ctx), capture_us, h.frame_samples, (opus.Packet{ .data = pkt }).hasFec(), pkt);
        out.lens[0] = dg.len;
        out.n = 1;
        while (try h.tx.parity(&out.bufs[out.n], next_seq(ctx))) |p| {
            out.lens[out.n] = p.len;
            out.n += 1;
        }
    }
};

pub const ClientAudio = struct {
    dec: opus.Decoder,
    rx: *audio.Receiver,
    channels: u8,

    pub fn init(gpa: std.mem.Allocator, channels: u8, buffer: audio.receiver.Config) !ClientAudio {
        const rx = try gpa.create(audio.Receiver);
        errdefer gpa.destroy(rx);
        rx.init(buffer);
        return .{ .dec = try opus.Decoder.init(gpa, channels), .rx = rx, .channels = channels };
    }

    pub fn deinit(c: *ClientAudio, gpa: std.mem.Allocator) void {
        c.dec.deinit(gpa);
        gpa.destroy(c.rx);
    }

    pub fn onMessage(c: *ClientAudio, env: proto.Envelope, body: []const u8, recv_us: i64) void {
        c.rx.onMessage(env, body, recv_us);
    }

    pub const Rendered = struct {
        /// Samples per channel written to `out`.
        samples: usize,
        /// What produced them.
        kind: std.meta.Tag(audio.Action),
        /// The frame they stand for (null for silence and for an added frame).
        seq: ?u32,
    };

    /// Produces the next frame of output at client time `now_us` into `out` (at least
    /// `frame_samples * channels` long; longer if the host sends longer frames).
    pub fn render(c: *ClientAudio, now_us: i64, out: []f32) !Rendered {
        const fl = @as(usize, c.rx.cfg.frame_samples) * c.channels;
        while (true) {
            const seq = c.rx.next_seq;
            const inserted = c.rx.stats.inserted;
            const a = c.rx.pull(now_us);
            switch (a) {
                .silence => |n| {
                    @memset(out[0 .. @as(usize, n) * c.channels], 0);
                    return .{ .samples = n, .kind = a, .seq = null };
                },
                .decode => |f| {
                    const n = try c.dec.decode(f.packet, out[0 .. @as(usize, f.header.samples) * c.channels]);
                    return .{ .samples = n, .kind = a, .seq = f.header.seq };
                },
                .fec => |f| {
                    const n = try c.dec.decodeFec(f.packet, out[0..fl]);
                    return .{ .samples = n, .kind = a, .seq = f.header.seq -% 1 };
                },
                .conceal => {
                    const n = try c.dec.conceal(out[0..fl]);
                    return .{ .samples = n, .kind = a, .seq = if (c.rx.stats.inserted == inserted) seq else null };
                },
                // Keep decoder state, discard the output, and play the next frame.
                .drop => |f| _ = try c.dec.decode(f.packet, out[0 .. @as(usize, f.header.samples) * c.channels]),
            }
        }
    }
};

const testing = std.testing;

test "host to client through the stage, one frame lost" {
    const gpa = testing.allocator;
    var host = try HostAudio.init(gpa, .{});
    defer host.deinit(gpa);
    var client = try ClientAudio.init(gpa, 2, .{});
    defer client.deinit(gpa);
    var seq: u32 = 0;
    const next = struct {
        fn f(s: *u32) u32 {
            defer s.* += 1;
            return s.*;
        }
    }.f;
    var pcm: [960]f32 = undefined;
    var out: [960]f32 = undefined;
    var o: HostAudio.Out = .{};
    var kinds: [4]u32 = @splat(0);
    for (0..60) |i| {
        const t: i64 = @intCast(i * 10_000);
        opus.testSignal(&pcm, 2, i * 480, 1);
        try host.encode(&pcm, @intCast(t), &seq, next, &o);
        for (0..o.n) |j| {
            if (i == 20 and j == 0) continue; // lose frame 20; parity rebuilds it
            const m = try proto.decode(o.datagram(j));
            client.onMessage(m.envelope(), m.other.payload, t + 1_000);
        }
        const r = try client.render(t, &out);
        try testing.expectEqual(@as(usize, 480), r.samples);
        switch (r.kind) {
            .silence => kinds[0] += 1,
            .decode => kinds[1] += 1,
            else => kinds[2] += 1,
        }
    }
    try testing.expectEqual(@as(u32, 0), kinds[2]);
    try testing.expectEqual(@as(u64, 1), client.rx.stats.decoded_recovered);
}
