//! Client side glue: reassembly plus the NACK tracker, kept in step.
//!
//! Feed every video shard to `onShard`; call `poll` until it returns null to get
//! frames and losses in order; call `nacks` to get a NACK datagram to send (if any).
//! `deadline` says when to call back if no packet arrives first.
//! FEC needs nothing here: shards carry their own parity counts, and a group completed
//! by FEC (or with its parity lost) is taken off the NACK list.
const std = @import("std");
const proto = @import("../proto/root.zig");
const reassembly = @import("reassembly.zig");
const nack = @import("nack.zig");

pub const Config = struct {
    reassembly: reassembly.Config = .{},
    nack: nack.Config = .{},
    /// Turn NACK off. The host decides NACK vs FEC (policy.zig) and ignores NACKs it
    /// does not want, so clients normally leave this on.
    nack_enabled: bool = true,
};

pub const Receiver = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    reasm: reassembly.Reassembler,
    tracker: nack.Tracker,

    pub fn init(gpa: std.mem.Allocator, cfg: Config) !Receiver {
        var reasm = try reassembly.Reassembler.init(gpa, cfg.reassembly);
        errdefer reasm.deinit();
        return .{ .gpa = gpa, .cfg = cfg, .reasm = reasm, .tracker = try nack.Tracker.init(gpa, cfg.nack) };
    }

    pub fn deinit(r: *Receiver) void {
        r.reasm.deinit();
        r.tracker.deinit(r.gpa);
    }

    /// One video shard, as `proto.decode` returns it.
    pub fn onShard(r: *Receiver, h: proto.ShardHeader, payload: []const u8, now_us: u64) reassembly.PushResult {
        const res = r.reasm.push(h, payload, now_us);
        switch (res) {
            .rejected, .out_of_memory => {},
            else => r.tracker.onPacket(h.media_seq, h.flags.retransmit, now_us),
        }
        if (r.reasm.completed) |c| r.tracker.forgetRange(c.first, c.count);
        return res;
    }

    pub fn poll(r: *Receiver, now_us: u64) ?reassembly.Event {
        const ev = r.reasm.poll(now_us) orelse return null;
        // Seqs are sent in frame order, so anything up to a settled frame's highest seq
        // is no longer worth asking for.
        switch (ev) {
            .frame => |f| r.tracker.abandonThrough(f.frame.max_seq),
            .lost => |l| if (l.max_seq) |s| r.tracker.abandonThrough(s),
        }
        return ev;
    }

    /// A NACK datagram to send now (envelope `seq` from the caller's transport-wide
    /// counter), written to `out`, or null when nothing is due.
    pub fn nacks(r: *Receiver, now_us: u64, rtt_us: u64, seq: u32, out: []u8) proto.EncodeError!?[]u8 {
        if (!r.cfg.nack_enabled) return null;
        var seqs: [256]u32 = undefined;
        const room = (out.len -| proto.Envelope.size) / nack.entry_len;
        const list = r.tracker.collect(now_us, rtt_us, seqs[0..@min(seqs.len, room)]);
        return nack.encodeMessage(out, seq, list);
    }

    pub fn deadline(r: *Receiver, rtt_us: u64) ?u64 {
        const a = r.reasm.deadline();
        const b = if (r.cfg.nack_enabled) r.tracker.deadline(rtt_us) else null;
        if (a == null) return b;
        if (b == null) return a;
        return @min(a.?, b.?);
    }
};
