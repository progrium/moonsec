//! The scenario catalog. Each scenario is a network (`simnet.Config` without a
//! seed) plus a reference media load; the seed comes from the runner.
//!
//! The first group covers the transport cases the core must survive (loss,
//! jitter, reordering, bandwidth steps, blackouts, droptail overload). The
//! `s11-*` group reproduces S11's bottlenecks and Wi-Fi model so the rate
//! controller can be checked against S11's numbers on this harness.
const simnet = @import("simnet");

const MS = simnet.MS;
const SEC = simnet.SEC;
const M = 1_000_000.0;

/// What endpoint A sends. Without a rate controller (the core plugs in later),
/// the load is a fixed-bitrate 60 fps stream.
pub const Load = struct {
    bitrate_bps: f64,
    fps: u32 = 60,
    /// Pacing rate as a multiple of the bitrate, 0 = unpaced.
    pace_mult: f64 = 2.5,
    /// Every Nth frame is 4x larger (a scene change), 0 = never. S11 used 180.
    scene_every: u32 = 180,
};

pub const Scenario = struct {
    name: []const u8,
    about: []const u8,
    duration_us: i64,
    net: simnet.Config,
    load: Load,
};

// Reverse path: feedback only, no bottleneck.
fn back(delay_us: i64, jitter_us: i64) simnet.LinkConfig {
    return .{ .delay_us = delay_us, .jitter_us = jitter_us };
}

fn net(fwd: simnet.LinkConfig, rev: simnet.LinkConfig) simnet.Config {
    return .{ .b = .{ .clock_offset_us = 987 * SEC }, .a_to_b = fwd, .b_to_a = rev };
}

const lan100 = [_]simnet.Step{.{ .t_us = 0, .bps = 100 * M }};
const flat50 = [_]simnet.Step{.{ .t_us = 0, .bps = 50 * M }};
const flat80 = [_]simnet.Step{.{ .t_us = 0, .bps = 80 * M }};
const flat20 = [_]simnet.Step{.{ .t_us = 0, .bps = 20 * M }};
const halving = [_]simnet.Step{ .{ .t_us = 0, .bps = 40 * M }, .{ .t_us = 10 * SEC, .bps = 20 * M } };
const s11_steps = [_]simnet.Step{ .{ .t_us = 0, .bps = 50 * M }, .{ .t_us = 20 * SEC, .bps = 20 * M }, .{ .t_us = 40 * SEC, .bps = 80 * M } };
const s11_lan = [_]simnet.Step{ .{ .t_us = 0, .bps = 100 * M }, .{ .t_us = 20 * SEC, .bps = 40 * M }, .{ .t_us = 40 * SEC, .bps = 150 * M } };
const s11_fade0 = [_]simnet.Step{.{ .t_us = 0, .bps = 60 * M }};
const blackout = [_]simnet.Window{.{ .start_us = 5 * SEC, .end_us = 5 * SEC + 300 * MS }};

pub const all = [_]Scenario{
    // --- transport cases -------------------------------------------------
    .{
        .name = "clean",
        .about = "100 Mbit/s, 2 ms RTT, nothing wrong",
        .duration_us = 10 * SEC,
        .net = net(.{ .steps = &lan100, .delay_us = 1 * MS }, back(1 * MS, 0)),
        .load = .{ .bitrate_bps = 30 * M },
    },
    .{
        .name = "loss-5pct",
        .about = "5% independent random loss (design gate: no freeze over 500 ms)",
        .duration_us = 20 * SEC,
        .net = net(.{ .steps = &flat50, .delay_us = 10 * MS, .loss = 0.05 }, back(10 * MS, 0)),
        .load = .{ .bitrate_bps = 20 * M },
    },
    .{
        .name = "loss-bursty",
        .about = "2% loss in bursts of 4 packets on average (Gilbert-Elliott)",
        .duration_us = 20 * SEC,
        .net = net(.{ .steps = &flat50, .delay_us = 10 * MS, .loss = 0.02, .loss_burst = 4 }, back(10 * MS, 0)),
        .load = .{ .bitrate_bps = 20 * M },
    },
    .{
        .name = "jitter",
        .about = "20 ms RTT with 0-10 ms jitter, order kept",
        .duration_us = 20 * SEC,
        .net = net(.{ .steps = &flat50, .delay_us = 10 * MS, .jitter_us = 10 * MS }, back(10 * MS, 2 * MS)),
        .load = .{ .bitrate_bps = 20 * M },
    },
    .{
        .name = "reorder",
        .about = "0-4 ms independent jitter plus 2% of packets held 5 ms",
        .duration_us = 20 * SEC,
        .net = net(.{ .steps = &flat50, .delay_us = 10 * MS, .jitter_us = 4 * MS, .reorder = true, .reorder_p = 0.02, .reorder_extra_us = 5 * MS }, back(10 * MS, 0)),
        .load = .{ .bitrate_bps = 20 * M },
    },
    .{
        .name = "halving",
        .about = "40 -> 20 Mbit/s at 10 s under a fixed 15 Mbit/s load (design gate)",
        .duration_us = 20 * SEC,
        .net = net(.{ .steps = &halving, .delay_us = 10 * MS }, back(10 * MS, 0)),
        .load = .{ .bitrate_bps = 15 * M },
    },
    .{
        .name = "blackout",
        .about = "300 ms total outage at 5 s (S5b-style)",
        .duration_us = 10 * SEC,
        .net = net(.{ .steps = &flat50, .delay_us = 37 * MS, .blackouts = &blackout }, back(37 * MS, 0)),
        .load = .{ .bitrate_bps = 10 * M },
    },
    .{
        .name = "droptail-overload",
        .about = "25 Mbit/s offered into 20 Mbit/s with a 500 KB droptail buffer",
        .duration_us = 10 * SEC,
        .net = net(.{ .steps = &flat20, .delay_us = 10 * MS }, back(10 * MS, 0)),
        .load = .{ .bitrate_bps = 25 * M },
    },
    // --- S11's bottlenecks (60 s, 500 KB droptail, 20 ms RTT unless noted) --
    .{
        .name = "s11-wired-steps",
        .about = "50 -> 20 (20 s) -> 80 (40 s) Mbit/s, wired",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &s11_steps, .delay_us = 10 * MS }, back(10 * MS, 0)),
        .load = .{ .bitrate_bps = 15 * M },
    },
    .{
        .name = "s11-wired-60ms",
        .about = "same steps, 60 ms RTT",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &s11_steps, .delay_us = 30 * MS }, back(30 * MS, 0)),
        .load = .{ .bitrate_bps = 15 * M },
    },
    .{
        .name = "s11-wifi-steps",
        .about = "same steps over the Wi-Fi model",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &s11_steps, .delay_us = 10 * MS, .wifi = .{} }, back(10 * MS, 2 * MS)),
        .load = .{ .bitrate_bps = 15 * M },
    },
    .{
        .name = "s11-wifi-lan",
        .about = "100 -> 40 -> 150 Mbit/s, 2 ms RTT, Wi-Fi",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &s11_lan, .delay_us = 1 * MS, .wifi = .{} }, back(1 * MS, 2 * MS)),
        .load = .{ .bitrate_bps = 30 * M },
    },
    .{
        .name = "s11-wifi-fade",
        .about = "random 25-120 Mbit/s every 2-5 s (MCS changes), Wi-Fi",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &s11_fade0, .fade = .{ .lo_bps = 25 * M, .hi_bps = 120 * M }, .delay_us = 10 * MS, .wifi = .{} }, back(10 * MS, 2 * MS)),
        .load = .{ .bitrate_bps = 20 * M },
    },
    .{
        .name = "s11-wifi-udp-cross",
        .about = "80 Mbit/s with 40 Mbit/s on/off UDP (4 s mean periods), Wi-Fi",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &flat80, .delay_us = 10 * MS, .wifi = .{}, .cross = .{ .onoff = .{ .bps = 40 * M, .mean_on_us = 4 * SEC, .mean_off_us = 4 * SEC } } }, back(10 * MS, 2 * MS)),
        .load = .{ .bitrate_bps = 25 * M },
    },
    .{
        .name = "s11-wifi-tcp",
        .about = "50 Mbit/s with a Reno flow from 20 s to 40 s, Wi-Fi",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &flat50, .delay_us = 10 * MS, .wifi = .{}, .cross = .{ .reno = .{ .start_us = 20 * SEC, .stop_us = 40 * SEC } } }, back(10 * MS, 2 * MS)),
        .load = .{ .bitrate_bps = 15 * M },
    },
    .{
        .name = "s11-wifi-bursts",
        .about = "50 Mbit/s with 300 KB line-rate bursts every 2 s on average, Wi-Fi",
        .duration_us = 60 * SEC,
        .net = net(.{ .steps = &flat50, .delay_us = 10 * MS, .wifi = .{}, .cross = .{ .bursts = .{ .bytes = 300_000, .mean_gap_us = 2 * SEC } } }, back(10 * MS, 2 * MS)),
        .load = .{ .bitrate_bps = 20 * M },
    },
};

pub fn find(name: []const u8) ?Scenario {
    for (all) |s| if (@import("std").mem.eql(u8, s.name, name)) return s;
    return null;
}
