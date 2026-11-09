//! The control channel (spec/control-v0.md), sans-I/O: framing, the `hello` handshake,
//! `close`, the clipboard messages, and pass-through of every other message type for the
//! features that build on it.
//!
//! The I/O layer moves bytes: `receive` what the stream delivered, write out `pending()`
//! and `consume` what was written, and call `poll` until it returns null. One `Channel`
//! lives as long as one stream; the `Clipboard` it is given outlives it (reconnects).
//!
//!     var ch = try Channel.init(gpa, .{ .role = .client }, &clip);
//!     // loop:
//!     try ch.receive(bytes_from_stream);
//!     while (try ch.poll()) |ev| switch (ev) { ... };
//!     n = stream.write(ch.pending()); ch.consume(n);
const std = @import("std");
const frame = @import("frame.zig");
const clipboard = @import("clipboard.zig");

pub const Role = clipboard.Role;
pub const Clipboard = clipboard.Clipboard;
pub const Frame = frame.Frame;

/// Message types this module handles (registry: spec/control-v0.md, "Type registry").
pub const msg = struct {
    pub const hello: u16 = 0x0001;
    pub const close: u16 = 0x0002;
    pub const clip_set: u16 = clipboard.msg_set;
};

/// Feature bits in `hello`.
pub const feature = struct {
    pub const clipboard_text: u64 = 1 << 0;
    pub const clipboard_image: u64 = 1 << 1;
    pub const clipboard_html: u64 = 1 << 2;
    /// Blocks reserved for the features that build on the channel.
    pub const displays_shift = 8;
    pub const multi_user_shift = 16;
    pub const codec_shift = 24;
    pub const file_transfer_shift = 32;
};

pub const hello_len = 16;
pub const max_close_text = 256;

pub const CloseReason = enum(u8) {
    done = 0,
    protocol = 1,
    unsupported = 2,
    too_large = 3,
    _,
};

pub const Hello = struct {
    role: Role,
    max_message: u32,
    features: u64,

    pub fn encode(h: Hello) [hello_len]u8 {
        var b: [hello_len]u8 = @splat(0);
        b[0] = @intFromEnum(h.role);
        std.mem.writeInt(u32, b[4..8], h.max_message, .little);
        std.mem.writeInt(u64, b[8..16], h.features, .little);
        return b;
    }

    pub fn parse(body: []const u8) error{Malformed}!Hello {
        if (body.len < hello_len) return error.Malformed;
        return .{
            .role = @enumFromInt(body[0]),
            .max_message = std.mem.readInt(u32, body[4..8], .little),
            .features = std.mem.readInt(u64, body[8..16], .little),
        };
    }
};

pub const Config = struct {
    role: Role,
    /// Largest frame we accept (`length`), advertised in `hello`.
    max_message: u32 = (1 << 20) + 64,
    /// Feature bits beyond the clipboard's, for features that handle their own messages
    /// (they arrive as `Event.message`). The clipboard bit comes from the clipboard config.
    features: u64 = 0,
    /// Message types (outside this module's) that this side knows, at most this version.
    /// A `required` message of a type not listed closes the channel; others are skipped.
    known: []const Known = &.{},
    /// Cap on bytes queued for the stream; `send` fails with `Backpressure` above it.
    max_pending: usize = 8 << 20,
};

pub const Known = struct { type: u16, max_version: u8 = 0 };

pub const State = enum { handshake, up, closed };

pub const Event = union(enum) {
    /// Both hellos exchanged; the peer's is given.
    up: Hello,
    /// Write this to the system clipboard. Valid until the next `receive` or `poll`.
    clipboard_text: []const u8,
    /// A message for a feature built on the channel (a type listed in `known`).
    message: Frame,
    /// The channel ended: the peer sent `close` or finished the stream, or we saw a
    /// protocol error (then `close` is queued in `pending()` and the stream should be reset
    /// after it is written).
    closed: Closed,
};

pub const Closed = struct {
    reason: CloseReason,
    by_peer: bool,
};

pub const Stats = struct {
    frames_in: u64 = 0,
    frames_out: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    /// Frames of unknown types skipped (not `required`).
    skipped: u64 = 0,
};

pub const SendError = error{
    /// The channel is not up yet (no peer `hello`), or is closed.
    NotUp,
    /// The peer did not advertise the feature this message belongs to.
    FeatureOff,
    /// Larger than the peer's `max_message`.
    TooLarge,
    /// More than `max_pending` bytes would be queued.
    Backpressure,
    OutOfMemory,
};

pub const Channel = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    clip: ?*Clipboard,
    state: State = .handshake,
    peer: ?Hello = null,
    dec: frame.Decoder,
    out: std.ArrayList(u8) = .empty,
    out_start: usize = 0,
    /// A protocol error waiting to be reported by `poll`.
    pending_close: ?Closed = null,
    stats: Stats = .{},

    /// Queues our `hello` at once (it must be the first thing on the stream).
    pub fn init(gpa: std.mem.Allocator, cfg: Config, clip: ?*Clipboard) !Channel {
        var ch: Channel = .{ .gpa = gpa, .cfg = cfg, .clip = clip, .dec = .init(cfg.max_message) };
        errdefer ch.out.deinit(gpa);
        const h = ch.ownHello().encode();
        try ch.queue(.{ .type = msg.hello, .flags = .{ .required = true }, .body = &h });
        return ch;
    }

    pub fn deinit(ch: *Channel) void {
        ch.dec.deinit(ch.gpa);
        ch.out.deinit(ch.gpa);
    }

    pub fn ownHello(ch: *const Channel) Hello {
        var f = ch.cfg.features;
        if (ch.clip) |c| {
            if (c.cfg.receive) f |= feature.clipboard_text;
        }
        return .{ .role = ch.cfg.role, .max_message = @max(ch.cfg.max_message, frame.min_max_message), .features = f };
    }

    /// The peer advertised all of `bits`.
    pub fn peerHas(ch: *const Channel, bits: u64) bool {
        const p = ch.peer orelse return false;
        return p.features & bits == bits;
    }

    /// Largest frame body the peer accepts.
    pub fn maxBody(ch: *const Channel) usize {
        const m = if (ch.peer) |p| p.max_message else frame.min_max_message;
        return m - frame.length_overhead;
    }

    // --- output --------------------------------------------------------------------

    /// Bytes waiting to be written to the stream.
    pub fn pending(ch: *const Channel) []const u8 {
        return ch.out.items[ch.out_start..];
    }

    /// `n` bytes of `pending()` were written.
    pub fn consume(ch: *Channel, n: usize) void {
        std.debug.assert(n <= ch.out.items.len - ch.out_start);
        ch.out_start += n;
        ch.stats.bytes_out += n;
        if (ch.out_start == ch.out.items.len) {
            ch.out.clearRetainingCapacity();
            ch.out_start = 0;
        }
    }

    fn queue(ch: *Channel, f: Frame) !void {
        if (ch.out_start > 0 and ch.out_start * 2 > ch.out.items.len) {
            const rest = ch.out.items.len - ch.out_start;
            std.mem.copyForwards(u8, ch.out.items[0..rest], ch.out.items[ch.out_start..]);
            ch.out.shrinkRetainingCapacity(rest);
            ch.out_start = 0;
        }
        frame.append(ch.gpa, &ch.out, f) catch |e| switch (e) {
            error.TooLarge => unreachable, // callers check against maxBody
            error.OutOfMemory => return error.OutOfMemory,
        };
        ch.stats.frames_out += 1;
    }

    /// Sends a message of a feature built on the channel. `bits` are the feature bits the
    /// peer must have advertised (0 for none).
    pub fn send(ch: *Channel, f: Frame, bits: u64) SendError!void {
        if (ch.state != .up) return error.NotUp;
        if (!ch.peerHas(bits)) return error.FeatureOff;
        if (f.body.len > ch.maxBody()) return error.TooLarge;
        if (ch.pending().len + frame.header_len + f.body.len > ch.cfg.max_pending) return error.Backpressure;
        try ch.queue(f);
    }

    /// Ends the channel from our side: queues `close`. Finish the stream after writing it.
    pub fn close(ch: *Channel, reason: CloseReason, text: []const u8) !void {
        if (ch.state == .closed) return;
        ch.state = .closed;
        try ch.queueClose(reason, text);
    }

    fn queueClose(ch: *Channel, reason: CloseReason, text: []const u8) !void {
        var b: [1 + max_close_text]u8 = undefined;
        b[0] = @intFromEnum(reason);
        const t = text[0..@min(text.len, max_close_text)];
        @memcpy(b[1..][0..t.len], t);
        try ch.queue(.{ .type = msg.close, .body = b[0 .. 1 + t.len] });
    }

    // --- clipboard -----------------------------------------------------------------

    /// The local system clipboard now holds `text` (call on every change the platform
    /// reports; echoes and repeats are filtered). Sends it if the channel is up and the
    /// peer takes clipboard text; otherwise it is remembered and goes out on the next
    /// channel's `up` if it is still the newest copy.
    pub fn clipboardChanged(ch: *Channel, text: []const u8) !void {
        const c = ch.clip orelse return;
        const s = try c.copied(ch.gpa, text) orelse return;
        try ch.sendClip(s);
    }

    fn sendClip(ch: *Channel, s: clipboard.Set) !void {
        if (ch.state != .up or !ch.peerHas(feature.clipboard_text)) return;
        if (clipboard.set_header_len + s.text.len > ch.maxBody()) {
            if (ch.clip) |c| c.stats.too_large += 1;
            return;
        }
        var h: [clipboard.set_header_len]u8 = undefined;
        clipboard.writeSetHeader(&h, s.clock, .text);
        // Header and text go out as one frame without an intermediate copy.
        var fh: [frame.header_len]u8 = undefined;
        frame.writeHeader(&fh, msg.clip_set, 0, .{}, h.len + s.text.len);
        try ch.out.ensureUnusedCapacity(ch.gpa, fh.len + h.len + s.text.len);
        ch.out.appendSliceAssumeCapacity(&fh);
        ch.out.appendSliceAssumeCapacity(&h);
        ch.out.appendSliceAssumeCapacity(s.text);
        ch.stats.frames_out += 1;
    }

    // --- input ---------------------------------------------------------------------

    /// Bytes read from the stream. Call `poll` until it returns null afterwards.
    pub fn receive(ch: *Channel, bytes: []const u8) !void {
        if (ch.state == .closed) return;
        ch.stats.bytes_in += bytes.len;
        try ch.dec.push(ch.gpa, bytes);
    }

    /// The peer finished its side of the stream (read returned end of stream).
    pub fn receiveEnd(ch: *Channel) void {
        if (ch.state == .closed) return;
        ch.state = .closed;
        ch.pending_close = .{ .reason = if (ch.dec.buffered() > 0) .protocol else .done, .by_peer = true };
    }

    /// The next event, or null when the bytes received so far hold no more.
    pub fn poll(ch: *Channel) !?Event {
        if (ch.pending_close) |c| {
            ch.pending_close = null;
            return .{ .closed = c };
        }
        if (ch.state == .closed) return null;
        while (true) {
            const f = ch.dec.next() catch |e| {
                const reason: CloseReason = if (e == error.TooLarge) .too_large else .protocol;
                return try ch.fail(reason, @errorName(e));
            } orelse return null;
            ch.stats.frames_in += 1;
            if (try ch.handle(f)) |ev| return ev;
            if (ch.state == .closed) return null;
        }
    }

    fn fail(ch: *Channel, reason: CloseReason, text: []const u8) !Event {
        ch.state = .closed;
        try ch.queueClose(reason, text);
        return .{ .closed = .{ .reason = reason, .by_peer = false } };
    }

    fn handle(ch: *Channel, f: Frame) !?Event {
        if (ch.peer == null) {
            if (f.type != msg.hello) return try ch.fail(.protocol, "expected hello");
            const h = Hello.parse(f.body) catch return try ch.fail(.protocol, "short hello");
            if (h.role == ch.cfg.role or (h.role != .host and h.role != .client)) return try ch.fail(.protocol, "bad role");
            if (h.max_message < frame.min_max_message) return try ch.fail(.protocol, "max_message below minimum");
            ch.peer = h;
            ch.state = .up;
            if (ch.clip) |c| if (c.resend()) |s| try ch.sendClip(s);
            return .{ .up = h };
        }
        switch (f.type) {
            msg.hello => return try ch.fail(.protocol, "second hello"),
            msg.close => {
                ch.state = .closed;
                const reason: CloseReason = if (f.body.len > 0) @enumFromInt(f.body[0]) else .done;
                return .{ .closed = .{ .reason = reason, .by_peer = true } };
            },
            msg.clip_set => {
                const c = ch.clip orelse return ch.skip(f);
                if (f.version > 0) return ch.skip(f);
                const s = clipboard.parseSet(f.body) catch {
                    c.stats.invalid += 1;
                    return null;
                };
                const text = try c.received(ch.gpa, ch.peer.?.role, s) orelse return null;
                return .{ .clipboard_text = text };
            },
            else => {
                for (ch.cfg.known) |k| if (k.type == f.type) {
                    if (f.version > k.max_version) return ch.skip(f);
                    return .{ .message = f };
                };
                return ch.skip(f);
            },
        }
    }

    fn skip(ch: *Channel, f: Frame) !?Event {
        if (f.flags.required) return try ch.fail(.unsupported, "unknown required message");
        ch.stats.skipped += 1;
        return null;
    }
};

// --- tests ---------------------------------------------------------------------------

const testing = std.testing;

/// Moves every pending byte from `a` to `b` in chunks of `chunk` bytes.
fn pump(a: *Channel, b: *Channel, chunk: usize) !void {
    while (a.pending().len > 0) {
        const n = @min(chunk, a.pending().len);
        try b.receive(a.pending()[0..n]);
        a.consume(n);
    }
}

fn expectUp(ch: *Channel) !Hello {
    const ev = (try ch.poll()).?;
    try testing.expect(ev == .up);
    return ev.up;
}

test "handshake, clipboard both ways, and close" {
    const gpa = testing.allocator;
    var hc = Clipboard.init(.host, .{});
    defer hc.deinit(gpa);
    var cc = Clipboard.init(.client, .{});
    defer cc.deinit(gpa);
    var host = try Channel.init(gpa, .{ .role = .host }, &hc);
    defer host.deinit();
    var client = try Channel.init(gpa, .{ .role = .client }, &cc);
    defer client.deinit();

    // A copy before the channel is up is held and sent on `up`.
    try client.clipboardChanged("early");
    try testing.expectEqual(@as(usize, 8 + hello_len), client.pending().len);

    try pump(&client, &host, 3);
    try pump(&host, &client, 5);
    const ph = try expectUp(&host);
    try testing.expectEqual(Role.client, ph.role);
    try testing.expect(host.peerHas(feature.clipboard_text));
    _ = try expectUp(&client);
    // The client's `up` queued its early copy.
    try pump(&client, &host, 1000);
    try testing.expectEqualStrings("early", (try host.poll()).?.clipboard_text);
    try testing.expectEqual(@as(?Event, null), try host.poll());
    try host.clipboardChanged("early"); // the host app wrote it: echo
    try testing.expectEqual(@as(usize, 0), host.pending().len);

    try host.clipboardChanged("from host ✓");
    try pump(&host, &client, 7);
    try testing.expectEqualStrings("from host ✓", (try client.poll()).?.clipboard_text);

    try client.close(.done, "bye");
    try pump(&client, &host, 64);
    const ev = (try host.poll()).?;
    try testing.expectEqual(CloseReason.done, ev.closed.reason);
    try testing.expect(ev.closed.by_peer);
    try testing.expectError(error.NotUp, host.send(.{ .type = 0x0200, .body = "" }, 0));
}

test "feature messages pass through to `known` types; unknown required closes" {
    const gpa = testing.allocator;
    const known = [_]Known{.{ .type = 0x0201, .max_version = 1 }};
    var host = try Channel.init(gpa, .{ .role = .host, .known = &known, .features = 1 << feature.displays_shift }, null);
    defer host.deinit();
    var client = try Channel.init(gpa, .{ .role = .client, .known = &known }, null);
    defer client.deinit();
    try pump(&client, &host, 100);
    try pump(&host, &client, 100);
    _ = try expectUp(&host);
    _ = try expectUp(&client);
    // No clipboard: the bit is not advertised.
    try testing.expect(!host.peerHas(feature.clipboard_text));
    // The client did not advertise displays; the host did.
    try testing.expectError(error.FeatureOff, host.send(.{ .type = 0x0201, .body = "x" }, 1 << feature.displays_shift));
    try client.send(.{ .type = 0x0201, .body = "list" }, 1 << feature.displays_shift);
    // Unknown, not required: skipped. Known at a higher version: skipped too.
    try client.send(.{ .type = 0x0777, .body = "?" }, 0);
    try client.send(.{ .type = 0x0201, .version = 2, .body = "v2" }, 0);
    try client.send(.{ .type = 0x0201, .version = 1, .body = "v1" }, 0);
    try pump(&client, &host, 2);
    const m = (try host.poll()).?.message;
    try testing.expectEqual(@as(u16, 0x0201), m.type);
    try testing.expectEqualStrings("list", m.body);
    try testing.expectEqualStrings("v1", (try host.poll()).?.message.body);
    try testing.expectEqual(@as(u64, 2), host.stats.skipped);

    try client.send(.{ .type = 0x0778, .flags = .{ .required = true }, .body = "" }, 0);
    try pump(&client, &host, 100);
    const ev = (try host.poll()).?;
    try testing.expectEqual(CloseReason.unsupported, ev.closed.reason);
    try testing.expect(!ev.closed.by_peer);
    // The host queued `close` for the client.
    try pump(&host, &client, 100);
    try testing.expectEqual(CloseReason.unsupported, (try client.poll()).?.closed.reason);
}

test "protocol errors: no hello first, same role, oversize frame" {
    const gpa = testing.allocator;
    {
        var host = try Channel.init(gpa, .{ .role = .host }, null);
        defer host.deinit();
        var b: [8]u8 = undefined;
        try host.receive(try frame.encode(&b, .{ .type = 0x0100, .body = "" }));
        try testing.expectEqual(CloseReason.protocol, (try host.poll()).?.closed.reason);
        try testing.expectEqual(@as(?Event, null), try host.poll());
    }
    {
        var a = try Channel.init(gpa, .{ .role = .host }, null);
        defer a.deinit();
        var b = try Channel.init(gpa, .{ .role = .host }, null);
        defer b.deinit();
        try pump(&a, &b, 100);
        try testing.expectEqual(CloseReason.protocol, (try b.poll()).?.closed.reason);
    }
    {
        var host = try Channel.init(gpa, .{ .role = .host, .max_message = frame.min_max_message }, null);
        defer host.deinit();
        try host.receive(&.{ 0xff, 0xff, 0x01, 0x00 });
        try testing.expectEqual(CloseReason.too_large, (try host.poll()).?.closed.reason);
    }
}

test "large clipboard text respects the peer's max_message" {
    const gpa = testing.allocator;
    var hc = Clipboard.init(.host, .{});
    defer hc.deinit(gpa);
    var cc = Clipboard.init(.client, .{});
    defer cc.deinit(gpa);
    var host = try Channel.init(gpa, .{ .role = .host, .max_message = frame.min_max_message }, &hc);
    defer host.deinit();
    var client = try Channel.init(gpa, .{ .role = .client }, &cc);
    defer client.deinit();
    try pump(&client, &host, 4096);
    try pump(&host, &client, 4096);
    _ = try expectUp(&host);
    _ = try expectUp(&client);
    const big = try gpa.alloc(u8, 100_000);
    defer gpa.free(big);
    @memset(big, 'a');
    // Host to client fits (the client takes 1 MiB)...
    try host.clipboardChanged(big);
    try pump(&host, &client, 1500);
    try testing.expectEqual(big.len, (try client.poll()).?.clipboard_text.len);
    // ...client to host does not (the host takes 64 KiB): nothing is sent.
    big[0] = 'b';
    try client.clipboardChanged(big);
    try testing.expectEqual(@as(usize, 0), client.pending().len);
    try testing.expectEqual(@as(u64, 1), cc.stats.too_large);
}

test "end of stream with a partial frame is a protocol close" {
    const gpa = testing.allocator;
    var host = try Channel.init(gpa, .{ .role = .host }, null);
    defer host.deinit();
    try host.receive(&.{ 10, 0 });
    host.receiveEnd();
    const ev = (try host.poll()).?;
    try testing.expectEqual(CloseReason.protocol, ev.closed.reason);
    try testing.expect(ev.closed.by_peer);
}

test "random bytes after a valid hello never crash" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (0..500) |_| {
        var cc = Clipboard.init(.client, .{});
        defer cc.deinit(gpa);
        var client = try Channel.init(gpa, .{ .role = .client, .known = &.{.{ .type = 0x0201 }} }, &cc);
        defer client.deinit();
        var hb: [8 + hello_len]u8 = undefined;
        const hh = (Hello{ .role = .host, .max_message = frame.min_max_message, .features = r.int(u64) }).encode();
        try client.receive(try frame.encode(&hb, .{ .type = msg.hello, .body = &hh }));
        var junk: [300]u8 = undefined;
        const n = r.uintLessThan(usize, junk.len);
        r.bytes(junk[0..n]);
        // Mostly-plausible frames: small lengths and known types.
        var i: usize = 0;
        while (i + 8 <= n) : (i += 8 + r.uintLessThan(usize, 24)) {
            if (r.boolean()) std.mem.writeInt(u32, junk[i..][0..4], 4 + r.uintLessThan(u32, 20), .little);
            if (r.boolean()) std.mem.writeInt(u16, junk[i + 4 ..][0..2], r.uintLessThan(u16, 3) + 0x0100 * r.uintLessThan(u16, 3), .little);
        }
        try client.receive(junk[0..n]);
        while (try client.poll()) |_| {}
    }
}
