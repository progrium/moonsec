//! The control channel inside a session (spec/control-v0.md): runs `core.control.Channel`
//! over a `ByteStream` next to the session's datagram pipe, keeps the clipboard state across
//! reconnects, and queues what the app has to act on.
//!
//! Sans-I/O like the sessions: `step` moves bytes between the stream and the channel and
//! never blocks. The datagram session does not depend on it; a session without a stream, or
//! whose channel closed, streams as before with clipboard sync off.
const std = @import("std");
const core = @import("core");
const pipe_mod = @import("pipe");

const ctl = core.control;
const ByteStream = pipe_mod.ByteStream;

pub const Config = struct {
    clipboard: ctl.clipboard.Config = .{},
    /// Feature bits and message types of features built on the channel (5B, 5D, ...).
    features: u64 = 0,
    known: []const ctl.Known = &.{},
    max_message: u32 = (1 << 20) + 64,
};

pub const Stats = struct {
    /// Channels started (one per stream; a reconnect starts a new one) / came up / closed.
    channels: u64 = 0,
    ups: u64 = 0,
    closes: u64 = 0,
    /// Stream resets (reconnects) and protocol errors seen.
    resets: u64 = 0,
    errors: u64 = 0,
    /// Feature messages dropped because the app did not take them.
    dropped_messages: u64 = 0,
};

/// A feature message (Event.message), copied out of the channel.
pub const Message = struct {
    type: u16,
    version: u8,
    body: []u8,
};

pub const Control = struct {
    gpa: std.mem.Allocator,
    role: ctl.Role,
    cfg: Config,
    stream: ?ByteStream = null,
    ch: ?ctl.Channel = null,
    /// On the heap: the channel points at it, and the session (with this) moves.
    clip: *ctl.Clipboard,
    /// The peer's hello once the current channel is up.
    peer: ?ctl.Hello = null,
    /// Text for the system clipboard, newest only.
    clip_write: std.ArrayList(u8) = .empty,
    clip_pending: bool = false,
    messages: std.ArrayList(Message) = .empty,
    /// The stream ended for good (closed by either side or the connection is gone).
    done: bool = false,
    stats: Stats = .{},

    pub const max_queued_messages = 256;

    pub fn init(gpa: std.mem.Allocator, role: ctl.Role, cfg: Config) !Control {
        const clip = try gpa.create(ctl.Clipboard);
        clip.* = .init(role, cfg.clipboard);
        return .{ .gpa = gpa, .role = role, .cfg = cfg, .clip = clip };
    }

    pub fn deinit(c: *Control) void {
        if (c.ch) |*ch| ch.deinit();
        c.clip.deinit(c.gpa);
        c.gpa.destroy(c.clip);
        c.clip_write.deinit(c.gpa);
        for (c.messages.items) |m| c.gpa.free(m.body);
        c.messages.deinit(c.gpa);
    }

    /// Runs the channel over `s` (the client opens it, the host accepts it; either way the
    /// pipe implementation does that). Replaces a previous stream.
    pub fn attach(c: *Control, s: ByteStream) !void {
        c.stream = s;
        c.done = false;
        try c.restart();
    }

    fn restart(c: *Control) !void {
        if (c.ch) |*ch| ch.deinit();
        c.ch = null;
        c.peer = null;
        c.ch = try ctl.Channel.init(c.gpa, .{
            .role = c.role,
            .max_message = c.cfg.max_message,
            .features = c.cfg.features,
            .known = c.cfg.known,
        }, c.clip);
        c.stats.channels += 1;
    }

    /// The channel is up (both hellos exchanged).
    pub fn up(c: *const Control) bool {
        return c.peer != null and c.ch != null and c.ch.?.state == .up;
    }

    /// Moves bytes both ways and handles events. Call from the session's step.
    pub fn step(c: *Control) void {
        const s = c.stream orelse return;
        if (c.done) return;
        c.pump(s) catch |e| switch (e) {
            error.Reset => {
                c.stats.resets += 1;
                c.restart() catch {
                    c.done = true;
                };
            },
            error.Closed => c.done = true,
            error.OutOfMemory => {
                c.stats.errors += 1;
                c.done = true;
            },
        };
    }

    fn pump(c: *Control, s: ByteStream) (pipe_mod.StreamError || error{OutOfMemory})!void {
        if (c.ch == null) return;
        const ch = &c.ch.?;
        var buf: [16 * 1024]u8 = undefined;
        // Bounded so one step cannot spin on a fast sender.
        for (0..64) |_| {
            const n = try s.read(&buf) orelse break;
            if (n == 0) {
                ch.receiveEnd();
                break;
            }
            try ch.receive(buf[0..n]);
            try c.events(ch);
        }
        try c.events(ch);
        try c.flush(s, ch);
        if (ch.state == .closed and ch.pending().len == 0 and !c.done) {
            s.finish();
            c.done = true;
        }
    }

    fn events(c: *Control, ch: *ctl.Channel) !void {
        while (try ch.poll()) |ev| switch (ev) {
            .up => |h| {
                c.peer = h;
                c.stats.ups += 1;
            },
            .clipboard_text => |t| {
                c.clip_write.clearRetainingCapacity();
                try c.clip_write.appendSlice(c.gpa, t);
                c.clip_pending = true;
            },
            .message => |m| {
                if (c.messages.items.len >= max_queued_messages) {
                    c.stats.dropped_messages += 1;
                    continue;
                }
                const body = try c.gpa.dupe(u8, m.body);
                errdefer c.gpa.free(body);
                try c.messages.append(c.gpa, .{ .type = m.type, .version = m.version, .body = body });
            },
            .closed => |cl| {
                c.stats.closes += 1;
                if (cl.reason != .done) c.stats.errors += 1;
                c.peer = null;
            },
        };
    }

    fn flush(c: *Control, s: ByteStream, ch: *ctl.Channel) !void {
        _ = c;
        while (ch.pending().len > 0) {
            const n = try s.write(ch.pending());
            if (n == 0) break;
            ch.consume(n);
        }
    }

    /// The local system clipboard now holds `text`. Sent if the channel is up (and on the
    /// next channel otherwise); echoes of what `takeClipboard` handed out are dropped.
    pub fn clipboardChanged(c: *Control, text: []const u8) !void {
        if (c.ch) |*ch| {
            try ch.clipboardChanged(text);
        } else if (try c.clip.copied(c.gpa, text)) |_| {}
    }

    /// The system clipboard's content when the app starts watching it (not sent).
    pub fn seedClipboard(c: *Control, text: []const u8) !void {
        try c.clip.seed(c.gpa, text);
    }

    /// Text the system clipboard should take, if the peer copied something since the last
    /// call. Valid until the next `step`.
    pub fn takeClipboard(c: *Control) ?[]const u8 {
        if (!c.clip_pending) return null;
        c.clip_pending = false;
        return c.clip_write.items;
    }

    /// Feature messages received (types in `Config.known`), oldest first. The caller frees
    /// each body with the control's allocator.
    pub fn takeMessage(c: *Control) ?Message {
        if (c.messages.items.len == 0) return null;
        return c.messages.orderedRemove(0);
    }

    /// Sends a feature message (`bits`: feature bits the peer must have).
    pub fn send(c: *Control, f: ctl.Frame, bits: u64) ctl.channel.SendError!void {
        if (c.ch == null) return error.NotUp;
        try c.ch.?.send(f, bits);
    }

    /// Ends the channel (session ending): queues `close`; the next steps write it and
    /// finish the stream.
    pub fn close(c: *Control) void {
        if (c.ch) |*ch| ch.close(.done, "") catch {};
        c.step();
    }
};
