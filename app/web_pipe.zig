//! The PacketPipe a browser page implements for the core in wasm (app/web.zig, the
//! client; app/web_host.zig, the browser host): JavaScript writes each arriving datagram
//! into a Zig-owned receive ring and gets every outgoing one through the imported
//! `ms_send(ctx, ptr, len)`, which must copy it before returning.
const pipe_mod = @import("pipe");
const core = @import("core");
const proto = core.proto;
const Micros = i64;

/// Supplied by JavaScript: send one datagram (copy it; the bytes are reused).
extern "env" fn ms_send(ctx: u32, ptr: [*]const u8, len: usize) void;

/// The PacketPipe JavaScript implements: a receive ring it fills, `ms_send` out, and
/// the path stats its transport reports (`ms_set_path`).
pub const JsPipe = struct {
    ctx: u32,
    slots: [ring][slot_cap]u8 = undefined,
    lens: [ring]u16 = undefined,
    times: [ring]Micros = undefined,
    head: usize = 0,
    len: usize = 0,
    path: pipe_mod.PathStats = .{},
    recv_drops: u64 = 0,
    closed: bool = false,

    pub const ring = 1024;
    pub const slot_cap = 2048;

    fn send(p: *anyopaque, data: []const u8) pipe_mod.SendError!void {
        const s: *JsPipe = @ptrCast(@alignCast(p));
        if (s.closed) return error.Closed;
        if (data.len > proto.max_datagram) return error.TooLarge;
        ms_send(s.ctx, data.ptr, data.len);
        s.path.sent += 1;
    }

    fn recv(p: *anyopaque, buf: []u8) pipe_mod.RecvError!?pipe_mod.Received {
        const s: *JsPipe = @ptrCast(@alignCast(p));
        if (s.len == 0) return if (s.closed) error.Closed else null;
        const n = s.lens[s.head];
        if (buf.len < n) return error.BufferTooSmall;
        @memcpy(buf[0..n], s.slots[s.head][0..n]);
        const t = s.times[s.head];
        s.head = (s.head + 1) % ring;
        s.len -= 1;
        s.path.received += 1;
        return .{ .len = n, .recv_us = t };
    }

    fn setPacingRate(p: *anyopaque, bps: u64) void {
        const s: *JsPipe = @ptrCast(@alignCast(p));
        s.path.pacing_bps = bps;
    }

    fn stats(p: *anyopaque) pipe_mod.PathStats {
        const s: *JsPipe = @ptrCast(@alignCast(p));
        var st = s.path;
        st.recv_drops = s.recv_drops;
        return st;
    }

    fn maxDatagramSize(_: *anyopaque) usize {
        return proto.max_datagram;
    }

    pub const vtable: pipe_mod.PacketPipe.VTable = .{ .send = send, .recv = recv, .setPacingRate = setPacingRate, .stats = stats, .maxDatagramSize = maxDatagramSize };
};
