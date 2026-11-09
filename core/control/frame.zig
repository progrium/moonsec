//! Control-channel framing (spec/control-v0.md, "Framing"), sans-I/O.
//!
//!     u32 length | u16 type | u8 version | u8 flags | body
//!
//! `length` counts everything after itself (4 + body). `Decoder` takes the stream in
//! chunks of any size and hands back whole frames; it never trusts a length beyond the
//! limit it was given, so arbitrary input costs at most `max_message` bytes of buffer.
const std = @import("std");

pub const header_len = 8;
/// Bytes of a frame counted by `length` before the body (type, version, flags).
pub const length_overhead = 4;
/// Every receiver accepts frames at least this large (`length` up to this).
pub const min_max_message: u32 = 65_536;

pub const Flags = packed struct(u8) {
    /// A receiver that does not know this type (or version) must close the channel.
    required: bool = false,
    _reserved: u7 = 0,
};

pub const Frame = struct {
    type: u16,
    version: u8 = 0,
    flags: Flags = .{},
    body: []const u8,
};

pub const DecodeError = error{
    /// `length` below 4.
    Malformed,
    /// `length` above the receiver's `max_message`.
    TooLarge,
    /// `type` 0.
    InvalidType,
};

/// Parses one header. `length` is returned as read; the caller checks it against its limit.
pub fn parseHeader(b: *const [header_len]u8) DecodeError!struct { length: u32, type: u16, version: u8, flags: Flags } {
    const length = std.mem.readInt(u32, b[0..4], .little);
    if (length < length_overhead) return error.Malformed;
    const t = std.mem.readInt(u16, b[4..6], .little);
    if (t == 0) return error.InvalidType;
    // Reserved flag bits are ignored on receive.
    const flags: Flags = .{ .required = b[7] & 1 != 0 };
    return .{ .length = length, .type = t, .version = b[6], .flags = flags };
}

pub fn writeHeader(out: *[header_len]u8, t: u16, version: u8, flags: Flags, body_len: usize) void {
    std.debug.assert(t != 0);
    std.mem.writeInt(u32, out[0..4], @intCast(body_len + length_overhead), .little);
    std.mem.writeInt(u16, out[4..6], t, .little);
    out[6] = version;
    out[7] = @bitCast(flags);
}

/// The `length` value of a frame with this body.
pub fn frameLength(body_len: usize) usize {
    return body_len + length_overhead;
}

/// Appends one frame to `out`.
pub fn append(gpa: std.mem.Allocator, out: *std.ArrayList(u8), f: Frame) error{ OutOfMemory, TooLarge }!void {
    if (f.body.len > std.math.maxInt(u32) - length_overhead) return error.TooLarge;
    var h: [header_len]u8 = undefined;
    writeHeader(&h, f.type, f.version, f.flags, f.body.len);
    try out.ensureUnusedCapacity(gpa, header_len + f.body.len);
    out.appendSliceAssumeCapacity(&h);
    out.appendSliceAssumeCapacity(f.body);
}

/// Encodes one frame into `buf`; returns the bytes written.
pub fn encode(buf: []u8, f: Frame) error{NoSpace}![]u8 {
    const n = header_len + f.body.len;
    if (buf.len < n) return error.NoSpace;
    writeHeader(buf[0..header_len], f.type, f.version, f.flags, f.body.len);
    @memcpy(buf[header_len..n], f.body);
    return buf[0..n];
}

/// Reassembles frames from a byte stream delivered in arbitrary chunks.
///
/// After an error the decoder stays failed: a byte stream cannot be resynchronized.
pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Bytes of `buf` already handed out as frames.
    start: usize = 0,
    /// Largest acceptable `length`.
    max_message: u32,
    failed: ?DecodeError = null,

    pub fn init(max_message: u32) Decoder {
        return .{ .max_message = @max(max_message, min_max_message) };
    }

    pub fn deinit(d: *Decoder, gpa: std.mem.Allocator) void {
        d.buf.deinit(gpa);
    }

    /// Bytes buffered and not yet returned as frames.
    pub fn buffered(d: *const Decoder) usize {
        return d.buf.items.len - d.start;
    }

    /// Queues stream bytes. Frames returned by `next` before this call become invalid.
    pub fn push(d: *Decoder, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!void {
        if (d.failed != null or bytes.len == 0) return;
        if (d.start > 0) {
            const rest = d.buf.items.len - d.start;
            std.mem.copyForwards(u8, d.buf.items[0..rest], d.buf.items[d.start..]);
            d.buf.shrinkRetainingCapacity(rest);
            d.start = 0;
        }
        try d.buf.appendSlice(gpa, bytes);
    }

    /// The next whole frame, or null when more bytes are needed. The frame's body points
    /// into the decoder and stays valid until the next `push`.
    pub fn next(d: *Decoder) DecodeError!?Frame {
        if (d.failed) |e| return e;
        const avail = d.buf.items[d.start..];
        if (avail.len < header_len) {
            // Reject a bad length as soon as it is readable, before waiting for the rest.
            if (avail.len >= 4) {
                const length = std.mem.readInt(u32, avail[0..4], .little);
                if (length < length_overhead) return d.fail(error.Malformed);
                if (length > d.max_message) return d.fail(error.TooLarge);
            }
            return null;
        }
        const h = parseHeader(avail[0..header_len]) catch |e| return d.fail(e);
        if (h.length > d.max_message) return d.fail(error.TooLarge);
        const total = 4 + @as(usize, h.length);
        if (avail.len < total) return null;
        d.start += total;
        return .{ .type = h.type, .version = h.version, .flags = h.flags, .body = avail[header_len..total] };
    }

    fn fail(d: *Decoder, e: DecodeError) DecodeError {
        d.failed = e;
        return e;
    }
};

// --- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "frame round trip through the decoder" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try append(gpa, &out, .{ .type = 0x0100, .version = 2, .flags = .{ .required = true }, .body = "hello" });
    try append(gpa, &out, .{ .type = 7, .body = "" });
    try testing.expectEqual(@as(usize, 8 + 5 + 8), out.items.len);
    try testing.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 0x00, 0x01, 2, 1 }, out.items[0..8]);

    var d = Decoder.init(min_max_message);
    defer d.deinit(gpa);
    try d.push(gpa, out.items);
    const a = (try d.next()).?;
    try testing.expectEqual(@as(u16, 0x0100), a.type);
    try testing.expectEqual(@as(u8, 2), a.version);
    try testing.expect(a.flags.required);
    try testing.expectEqualStrings("hello", a.body);
    const b = (try d.next()).?;
    try testing.expectEqual(@as(u16, 7), b.type);
    try testing.expectEqual(@as(usize, 0), b.body.len);
    try testing.expectEqual(@as(?Frame, null), try d.next());
}

test "decoder takes frames split at every byte" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..20) |i| {
        var body: [40]u8 = undefined;
        for (&body, 0..) |*x, j| x.* = @truncate(i * 7 + j);
        try append(gpa, &out, .{ .type = @intCast(i + 1), .body = body[0 .. i * 2] });
    }
    var d = Decoder.init(0);
    defer d.deinit(gpa);
    var got: usize = 0;
    for (out.items) |byte| {
        try d.push(gpa, &.{byte});
        while (try d.next()) |f| {
            try testing.expectEqual(@as(u16, @intCast(got + 1)), f.type);
            try testing.expectEqual(got * 2, f.body.len);
            for (f.body, 0..) |x, j| try testing.expectEqual(@as(u8, @truncate(got * 7 + j)), x);
            got += 1;
        }
    }
    try testing.expectEqual(@as(usize, 20), got);
    try testing.expectEqual(@as(usize, 0), d.buffered());
}

test "decoder rejects bad lengths and type 0, and stays failed" {
    const gpa = testing.allocator;
    {
        var d = Decoder.init(0);
        defer d.deinit(gpa);
        try d.push(gpa, &.{ 3, 0, 0, 0 });
        try testing.expectError(error.Malformed, d.next());
        try d.push(gpa, &.{ 1, 2, 3 });
        try testing.expectError(error.Malformed, d.next());
    }
    {
        // Too large is caught from the length alone, before the body arrives.
        var d = Decoder.init(0);
        defer d.deinit(gpa);
        try d.push(gpa, &.{ 0x01, 0x00, 0x01, 0x00 });
        try testing.expectError(error.TooLarge, d.next());
    }
    {
        var d = Decoder.init(0);
        defer d.deinit(gpa);
        try d.push(gpa, &.{ 4, 0, 0, 0, 0, 0, 0, 0 });
        try testing.expectError(error.InvalidType, d.next());
    }
    {
        // Exactly the limit is accepted.
        var d = Decoder.init(0);
        defer d.deinit(gpa);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const body = try gpa.alloc(u8, min_max_message - length_overhead);
        defer gpa.free(body);
        @memset(body, 0xab);
        try append(gpa, &buf, .{ .type = 1, .body = body });
        try d.push(gpa, buf.items);
        try testing.expectEqual(body.len, (try d.next()).?.body.len);
    }
}

test "decoder survives random input" {
    // Fuzz-style: random bytes in random chunks never crash or over-allocate.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var bytes: [512]u8 = undefined;
    for (0..2000) |_| {
        var d = Decoder.init(0);
        defer d.deinit(gpa);
        const n = r.uintLessThan(usize, bytes.len);
        r.bytes(bytes[0..n]);
        // Bias toward plausible small lengths so bodies get parsed too.
        if (n >= 4 and r.boolean()) std.mem.writeInt(u32, bytes[0..4], r.uintLessThan(u32, 64), .little);
        var i: usize = 0;
        while (i < n) {
            const k = @min(n - i, 1 + r.uintLessThan(usize, 32));
            try d.push(gpa, bytes[i .. i + k]);
            i += k;
            while (d.next() catch null) |_| {}
        }
        try testing.expect(d.buf.capacity <= 4096);
    }
}

test "encode into a fixed buffer" {
    var buf: [16]u8 = undefined;
    const b = try encode(&buf, .{ .type = 2, .body = "ab" });
    try testing.expectEqualSlices(u8, &.{ 6, 0, 0, 0, 2, 0, 0, 0, 'a', 'b' }, b);
    try testing.expectError(error.NoSpace, encode(buf[0..9], .{ .type = 2, .body = "ab" }));
}
