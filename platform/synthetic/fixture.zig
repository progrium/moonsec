//! Fixture encoder: replays a committed H.264 or HEVC Annex B stream as if it were
//! encoding, so a client with a real decoder (the browser's WebCodecs, a hardware
//! decoder) can be tested against a host with no encoder (web/testdata/gen.sh).
//!
//! The stream is split into access units at access unit delimiters (H.264 NAL type 9,
//! HEVC type 35), so the fixture must carry one per frame (x264 `aud=1`). Each `encode`
//! returns the next access unit, whatever was captured, and loops at the end; the first
//! frame must be a keyframe. There are no long-term references (`caps.ltr` is false), so
//! every recovery the host asks for is an IDR: the encoder answers `force` by skipping to
//! the next keyframe in the stream (the picture jumps ahead, as after any recovery).
const std = @import("std");
const api = @import("platform");

pub const Error = error{ NoAccessUnits, FirstNotKeyframe, TooManyAccessUnits };

pub const AccessUnit = struct { start: usize, end: usize, keyframe: bool };

const NalKind = enum { aud, irap, other };

fn nalKind(codec: api.Codec, first: u8) NalKind {
    switch (codec) {
        .h264 => return switch (first & 0x1f) {
            9 => .aud,
            5 => .irap,
            else => .other,
        },
        .hevc => {
            const t = (first >> 1) & 0x3f;
            if (t == 35) return .aud;
            // IRAP pictures (BLA, IDR, CRA): decoding can start there.
            if (t >= 16 and t <= 21) return .irap;
            return .other;
        },
        else => return .other,
    }
}

/// Splits an Annex B stream into access units at its access unit delimiters.
pub fn split(codec: api.Codec, data: []const u8, units: []AccessUnit) Error![]AccessUnit {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (!(data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1)) continue;
        // A 4-byte start code's leading zero belongs to this NAL unit.
        const start = if (i > 0 and data[i - 1] == 0) i - 1 else i;
        switch (nalKind(codec, data[i + 3])) {
            .aud => {
                if (n > 0) units[n - 1].end = start;
                if (n == units.len) return error.TooManyAccessUnits;
                units[n] = .{ .start = start, .end = data.len, .keyframe = false };
                n += 1;
            },
            .irap => if (n > 0) {
                units[n - 1].keyframe = true;
            },
            .other => {},
        }
        i += 3;
    }
    if (n == 0) return error.NoAccessUnits;
    if (!units[0].keyframe) return error.FirstNotKeyframe;
    return units[0..n];
}

pub const Encoder = struct {
    clock: api.Clock,
    codec: api.Codec,
    data: []const u8,
    units: []const AccessUnit,
    next: usize = 0,
    slice: [1][]const u8 = undefined,
    stats: struct { frames: u64 = 0, keyframes: u64 = 0, skipped: u64 = 0, bytes: u64 = 0 } = .{},

    /// `data` and `units` (from `split`) must outlive the encoder.
    pub fn init(clock: api.Clock, codec: api.Codec, data: []const u8, units: []const AccessUnit) Encoder {
        return .{ .clock = clock, .codec = codec, .data = data, .units = units };
    }

    pub fn caps(e: *Encoder) api.EncoderCaps {
        var set: api.CodecSet = .{};
        switch (e.codec) {
            .h264 => set.h264 = true,
            .hevc => set.hevc = true,
            else => {},
        }
        return .{ .codecs = set, .ltr = false, .max_slices = 1, .cpu_input = true };
    }

    pub fn configure(e: *Encoder, cfg: api.EncoderConfig) api.Error!void {
        if (cfg.codec != e.codec) return error.Unsupported;
        e.next = 0;
    }

    pub fn encode(e: *Encoder, _: *const api.CapturedFrame, p: api.EncodeParams) api.Error!?api.EncodedFrame {
        const t0 = e.clock.now();
        if (p.force != .none) {
            var skipped: usize = 0;
            while (!e.units[e.next].keyframe) : (skipped += 1) e.next = (e.next + 1) % e.units.len;
            e.stats.skipped += skipped;
        }
        const u = e.units[e.next];
        e.next = (e.next + 1) % e.units.len;
        e.slice[0] = e.data[u.start..u.end];
        e.stats.frames += 1;
        if (u.keyframe) e.stats.keyframes += 1;
        e.stats.bytes += u.end - u.start;
        return .{ .slices = &e.slice, .keyframe = u.keyframe, .encode_start_us = t0, .encoded_us = e.clock.now() };
    }

    pub fn deinit(_: *Encoder) void {}
};

const testing = std.testing;

fn fakeNow(_: ?*anyopaque) i64 {
    return 0;
}

test "split an H.264 stream at its delimiters and skip to a keyframe on demand" {
    // AUD, SPS, IDR | AUD, P | AUD, P (4-byte start code) | AUD, IDR
    const s = [_]u8{
        0, 0, 1, 0x09, 0xf0, 0, 0, 1, 0x67, 1,    2, 0, 0, 1,    0x65, 0xaa,
        0, 0, 1, 0x09, 0xf0, 0, 0, 1, 0x41, 0xbb, 0, 0, 0, 1,    0x09, 0xf0,
        0, 0, 1, 0x41, 0xcc, 0, 0, 1, 0x09, 0xf0, 0, 0, 1, 0x65, 0xdd,
    };
    var buf: [8]AccessUnit = undefined;
    const units = try split(.h264, &s, &buf);
    try testing.expectEqual(@as(usize, 4), units.len);
    try testing.expect(units[0].keyframe and !units[1].keyframe and !units[2].keyframe and units[3].keyframe);
    try testing.expectEqual(@as(usize, 26), units[2].start); // the 4-byte start code's zero
    try testing.expectEqual(s.len, units[3].end);

    var e = Encoder.init(.{ .nowFn = fakeNow }, .h264, &s, units);
    try e.configure(.{ .codec = .h264, .width = 16, .height = 16, .bitrate_bps = 1 });
    const f: api.CapturedFrame = .{ .image = undefined, .seq = 0, .capture_start_us = 0, .captured_us = 0 };
    const a = (try e.encode(&f, .{})).?;
    try testing.expect(a.keyframe);
    try testing.expectEqualSlices(u8, s[0..units[0].end], a.slices[0]);
    try testing.expect(!(try e.encode(&f, .{})).?.keyframe);
    // A forced recovery from frame 2 jumps to the IDR at frame 3.
    const r = (try e.encode(&f, .{ .force = .idr })).?;
    try testing.expect(r.keyframe);
    try testing.expectEqual(@as(u8, 0xdd), r.slices[0][r.slices[0].len - 1]);
    try testing.expectEqual(@as(u64, 1), e.stats.skipped);
    // Loops back to the start.
    try testing.expect((try e.encode(&f, .{})).?.keyframe);
    try testing.expectError(error.Unsupported, e.configure(.{ .codec = .hevc, .width = 16, .height = 16, .bitrate_bps = 1 }));
}

test "a stream without delimiters or starting mid-GOP is refused" {
    var buf: [4]AccessUnit = undefined;
    try testing.expectError(error.NoAccessUnits, split(.h264, &[_]u8{ 0, 0, 1, 0x65, 1 }, &buf));
    try testing.expectError(error.FirstNotKeyframe, split(.h264, &[_]u8{ 0, 0, 1, 0x09, 0xf0, 0, 0, 1, 0x41, 1 }, &buf));
}
