//! Regional refine in the host loop (core/qpmap): one `Refiner` next to the encoder, in
//! the media stage of `HostApp` and `MultiHostApp` (one encode for every member).
//!
//! Per frame: `observe` the captured frame's damage, `plan` a QP map into the encode
//! params, then `commit` what came out. No map on forced frames (an IDR or an LTR
//! refresh), on idle-refine frames (`refine_qp` set: the whole screen is still and
//! core/still is refining it), or while the session says refinement isn't ok (the rate
//! controller is cutting, the path is stalled). Encoders without QP maps
//! (`caps.qp_map.block` 0) cost nothing here: the ledger is never made.
const std = @import("std");
const core = @import("core");
const api = @import("platform");

const qpmap = core.qpmap;

pub const Refiner = struct {
    gpa: std.mem.Allocator,
    cfg: qpmap.Config = .{},
    ledger: ?qpmap.Ledger = null,
    /// What the ledger was made for.
    width: u32 = 0,
    height: u32 = 0,
    block: u16 = 0,
    max_regions: u16 = 0,
    /// The current frame's map was planned (so `commit` has something to settle).
    planned: bool = false,
    /// New (not repeated) frames whose capture reported damage, and maps planned.
    damaged_frames: u64 = 0,
    maps: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, cfg: qpmap.Config) Refiner {
        return .{ .gpa = gpa, .cfg = cfg };
    }

    pub fn deinit(r: *Refiner) void {
        if (r.ledger) |*l| l.deinit();
        r.ledger = null;
    }

    /// The next captured frame, with the encoder's caps for the codec it is configured for.
    /// A new size or block size starts the ledger over.
    pub fn observe(r: *Refiner, caps: api.EncoderCaps, f: *const api.CapturedFrame) void {
        const q = caps.qp_map;
        const w = f.image.width;
        const h = f.image.height;
        if (q.block == 0) {
            r.deinit();
            r.block = 0;
            return;
        }
        if (r.ledger == null or w != r.width or h != r.height or q.block != r.block or q.max_regions != r.max_regions) {
            r.deinit();
            var cfg = r.cfg;
            cfg.max_regions = q.max_regions;
            r.ledger = qpmap.Ledger.init(r.gpa, w, h, q.block, cfg) catch null;
            r.width = w;
            r.height = h;
            r.block = q.block;
            r.max_regions = q.max_regions;
            if (r.ledger) |*l| l.observe(null);
            return;
        }
        if (!f.repeat and f.damage != null) r.damaged_frames += 1;
        r.ledger.?.observe(if (f.repeat) &.{} else f.damage);
    }

    /// Fills `params.qp_map` for the frame about to be encoded, when there's something to
    /// refine. `ok`: the session's go-ahead (`refineOk`).
    pub fn plan(r: *Refiner, params: *api.EncodeParams, ok: bool) void {
        r.planned = false;
        const l = &(r.ledger orelse return);
        const allow = ok and params.force == .none and params.refine_qp == 0;
        const m = l.plan(allow) orelse return;
        params.qp_map = .{ .block = @intCast(m.block), .cols = @intCast(m.cols), .rows = @intCast(m.rows), .offsets = m.offsets };
        r.planned = true;
        r.maps += 1;
    }

    /// What the encoder made of the frame: null when it dropped it or failed. `ok`: the
    /// session's go-ahead after the encode (false: the frame was coded while the rate
    /// controller was cutting, so its blocks are redone later).
    pub fn commit(r: *Refiner, ef: ?api.EncodedFrame, ok: bool) void {
        const l = &(r.ledger orelse return);
        defer r.planned = false;
        const e = ef orelse return l.commit(.dropped);
        if (e.keyframe) return l.commit(.keyframe);
        if (e.ltr_refresh) {
            // Predicted from an LTR older than the refinement: start over.
            l.commit(.dropped);
            l.reset();
            return;
        }
        l.commit(if (ok) .coded else .constrained);
    }

    pub fn stats(r: *const Refiner) qpmap.Ledger.Stats {
        return if (r.ledger) |l| l.stats else .{};
    }
};

const testing = std.testing;

test "refiner: maps only where allowed, resets on keyframes and refreshes" {
    var r = Refiner.init(testing.allocator, .{ .refine_after = 2, .pace = 1 });
    defer r.deinit();
    var px: [64 * 32 * 4]u8 = undefined;
    const caps: api.EncoderCaps = .{ .codecs = .{ .h264 = true }, .qp_map = .{ .block = 16 } };
    var f: api.CapturedFrame = .{ .image = .{ .width = 64, .height = 32, .cpu = .{ .data = &px, .stride = 64 * 4 } }, .seq = 0, .capture_start_us = 0, .captured_us = 0, .damage = &.{} };
    const kf: api.EncodedFrame = .{ .slices = &.{}, .keyframe = true, .encode_start_us = 0, .encoded_us = 0 };
    const pf: api.EncodedFrame = .{ .slices = &.{}, .keyframe = false, .encode_start_us = 0, .encoded_us = 0 };
    for (0..3) |_| r.observe(caps, &f);
    // Forced and idle-refine frames get none.
    var p: api.EncodeParams = .{ .force = .idr };
    r.plan(&p, true);
    try testing.expect(p.qp_map == null);
    r.commit(kf, true);
    p = .{ .refine_qp = 16 };
    r.plan(&p, true);
    try testing.expect(p.qp_map == null);
    p = .{};
    r.plan(&p, false);
    try testing.expect(p.qp_map == null);
    r.commit(pf, true);
    for (0..2) |_| r.observe(caps, &f);
    p = .{};
    r.plan(&p, true);
    const m = p.qp_map.?;
    try testing.expectEqual(@as(u16, 4), m.cols);
    try testing.expectEqual(@as(u16, 2), m.rows);
    r.commit(pf, true);
    // A refresh against an old LTR undoes the refinement.
    r.observe(caps, &f);
    p = .{};
    r.plan(&p, true);
    r.commit(.{ .slices = &.{}, .keyframe = false, .ltr_refresh = true, .encode_start_us = 0, .encoded_us = 0 }, true);
    try testing.expectEqual(@as(usize, 0), r.ledger.?.cleanCount());
    // An encoder without maps: nothing kept.
    r.observe(.{ .codecs = .{ .h264 = true } }, &f);
    try testing.expect(r.ledger == null);
    p = .{};
    r.plan(&p, true);
    try testing.expect(p.qp_map == null);
    // A repeat counts as no damage even if a backend left damage null.
    f.damage = null;
    f.repeat = true;
    r.observe(caps, &f); // new ledger: everything coarse
    for (0..3) |_| r.observe(caps, &f);
    p = .{};
    r.plan(&p, true);
    try testing.expect(p.qp_map != null);
}
