//! The simulated path the gate runs over: 10 ms each way, 3 ms of jitter, 2% of
//! datagrams held back 5 ms (reordering), a 50 Mbit/s bottleneck, and 2% random
//! loss in each direction once the session has warmed up.
//!
//! Loss starts after `warmup_us` so the first frame's first shard arrives: the
//! NACK tracker starts from the first media_seq it sees, and the recovery module
//! (not part of this gate) is what handles joining mid-stream.
const simnet = @import("simnet");

pub const loss = 0.02;
pub const warmup_us: i64 = 300 * simnet.MS;

pub fn link() simnet.LinkConfig {
    return .{
        .steps = &.{.{ .t_us = 0, .bps = 50e6 }},
        .delay_us = 10 * simnet.MS,
        .jitter_us = 3 * simnet.MS,
        .reorder_p = 0.02,
        .reorder_extra_us = 5 * simnet.MS,
        .overhead_bytes = 48,
    };
}

pub fn config(seed: u64) simnet.Config {
    return .{ .seed = seed, .a_to_b = link(), .b_to_a = link() };
}

/// Turn loss on (call once `warmup_us` has passed since traffic started).
pub fn startLoss(net: *simnet.Net) void {
    for (&net.links) |*l| l.cfg.loss = loss;
}
