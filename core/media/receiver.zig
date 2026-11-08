//! Client side glue: reassembly plus the NACK tracker, kept in step.
//!
//! Feed every video packet to `onPacket`; call `poll` until it returns null to get
//! frames and losses in order; call `nacks` to get a NACK message to send (if any).
//! `deadline` says when to call back if no packet arrives first.
const std = @import("std");
const hdr = @import("header.zig");
const reassembly = @import("reassembly.zig");
const nack = @import("nack.zig");

pub const Config = struct {
    reassembly: reassembly.Config = .{},
    nack: nack.Config = .{},
    /// Turn NACK off (FEC-only or relayed paths).
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

    pub fn onPacket(r: *Receiver, pkt: []const u8, now_us: u64) reassembly.PushResult {
        const res = r.reasm.push(pkt, now_us);
        switch (res) {
            .rejected, .out_of_memory => {},
            else => r.tracker.onPacket(hdr.mediaSeq(pkt), hdr.isRetransmit(pkt), now_us),
        }
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

    /// A NACK message payload to send now, written to `out`, or null.
    pub fn nacks(r: *Receiver, now_us: u64, rtt_us: u64, out: []u8) ?[]u8 {
        if (!r.cfg.nack_enabled) return null;
        var seqs: [256]u32 = undefined;
        const list = r.tracker.collect(now_us, rtt_us, seqs[0..@min(seqs.len, out.len / nack.entry_len)]);
        if (list.len == 0) return null;
        return out[0..nack.encode(list, out)];
    }

    pub fn deadline(r: *Receiver, rtt_us: u64) ?u64 {
        const a = r.reasm.deadline();
        const b = if (r.cfg.nack_enabled) r.tracker.deadline(rtt_us) else null;
        if (a == null) return b;
        if (b == null) return a;
        return @min(a.?, b.?);
    }
};
