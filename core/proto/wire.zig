//! Bounds-checked little-endian cursors over caller-owned buffers. No allocation.

const std = @import("std");

pub const EncodeError = error{BufferTooSmall};
pub const DecodeError = error{ Truncated, VarintOverflow };

/// Writes into a fixed buffer; every put fails with BufferTooSmall instead of overrunning.
pub const Encoder = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Encoder {
        return .{ .buf = buf };
    }

    pub fn written(self: Encoder) []u8 {
        return self.buf[0..self.pos];
    }

    pub fn reserve(self: *Encoder, n: usize) EncodeError![]u8 {
        if (self.buf.len - self.pos < n) return error.BufferTooSmall;
        const out = self.buf[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    pub fn int(self: *Encoder, comptime T: type, v: T) EncodeError!void {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const dst = try self.reserve(n);
        std.mem.writeInt(T, dst[0..n], v, .little);
    }

    pub fn bytes(self: *Encoder, src: []const u8) EncodeError!void {
        @memcpy(try self.reserve(src.len), src);
    }

    /// Unsigned LEB128.
    pub fn uvarint(self: *Encoder, v: u64) EncodeError!void {
        var x = v;
        while (true) {
            const b: u8 = @truncate(x & 0x7f);
            x >>= 7;
            if (x == 0) return self.int(u8, b);
            try self.int(u8, b | 0x80);
        }
    }

    /// Signed value as zigzag LEB128 (small magnitudes of either sign stay short).
    pub fn svarint(self: *Encoder, v: i64) EncodeError!void {
        return self.uvarint(zigzag(v));
    }
};

/// Reads from a fixed buffer; every get fails with Truncated instead of overrunning.
pub const Decoder = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Decoder {
        return .{ .buf = buf };
    }

    pub fn rest(self: Decoder) []const u8 {
        return self.buf[self.pos..];
    }

    pub fn take(self: *Decoder, n: usize) DecodeError![]const u8 {
        if (self.buf.len - self.pos < n) return error.Truncated;
        const out = self.buf[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    pub fn int(self: *Decoder, comptime T: type) DecodeError!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const src = try self.take(n);
        return std.mem.readInt(T, src[0..n], .little);
    }

    pub fn uvarint(self: *Decoder) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try self.int(u8);
            const low: u64 = b & 0x7f;
            if (shift == 63 and low > 1) return error.VarintOverflow;
            result |= low << @intCast(shift);
            if (b & 0x80 == 0) {
                // Reject non-minimal encodings (trailing zero groups) so every value has one form.
                if (b == 0 and shift != 0) return error.VarintOverflow;
                return result;
            }
            shift += 7;
            if (shift > 63) return error.VarintOverflow;
        }
    }

    pub fn svarint(self: *Decoder) DecodeError!i64 {
        return unzigzag(try self.uvarint());
    }
};

pub fn zigzag(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}

pub fn unzigzag(u: u64) i64 {
    const half: i64 = @bitCast(u >> 1);
    return half ^ -@as(i64, @intCast(u & 1));
}

const testing = std.testing;

test "fixed-width ints are little-endian" {
    var buf: [16]u8 = undefined;
    var e = Encoder.init(&buf);
    try e.int(u16, 0x0102);
    try e.int(u32, 0x03040506);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x06, 0x05, 0x04, 0x03 }, e.written());
    var d = Decoder.init(e.written());
    try testing.expectEqual(@as(u16, 0x0102), try d.int(u16));
    try testing.expectEqual(@as(u32, 0x03040506), try d.int(u32));
    try testing.expectError(error.Truncated, d.int(u8));
}

test "encoder refuses to overrun" {
    var buf: [3]u8 = undefined;
    var e = Encoder.init(&buf);
    try testing.expectError(error.BufferTooSmall, e.int(u32, 1));
    try e.int(u16, 1);
    try testing.expectError(error.BufferTooSmall, e.bytes("ab"));
}

test "varint round trip and edge values" {
    const values = [_]i64{ 0, 1, -1, 63, -64, 64, -65, 8191, -8192, 1 << 40, std.math.maxInt(i64), std.math.minInt(i64) };
    var buf: [256]u8 = undefined;
    var e = Encoder.init(&buf);
    for (values) |v| try e.svarint(v);
    try e.uvarint(std.math.maxInt(u64));
    var d = Decoder.init(e.written());
    for (values) |v| try testing.expectEqual(v, try d.svarint());
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try d.uvarint());
    try testing.expectEqual(@as(usize, 0), d.rest().len);
}

test "varint sizes" {
    var buf: [16]u8 = undefined;
    var e = Encoder.init(&buf);
    try e.svarint(-64); // zigzag 127
    try testing.expectEqual(@as(usize, 1), e.pos);
    try e.svarint(8191); // zigzag 16382
    try testing.expectEqual(@as(usize, 3), e.pos);
}

test "varint rejects overlong and non-minimal input" {
    var d = Decoder.init(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02 });
    try testing.expectError(error.VarintOverflow, d.uvarint());
    d = Decoder.init(&.{ 0x80, 0x00 });
    try testing.expectError(error.VarintOverflow, d.uvarint());
    d = Decoder.init(&.{0x80});
    try testing.expectError(error.Truncated, d.uvarint());
}
