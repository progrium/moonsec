const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const sim_mod = b.createModule(.{ .root_source_file = b.path("src/sim.zig"), .target = target, .optimize = optimize });
    b.installArtifact(b.addExecutable(.{ .name = "s11sim", .root_module = sim_mod }));

    const net_mod = b.createModule(.{ .root_source_file = b.path("src/net.zig"), .target = target, .optimize = optimize, .link_libc = true });
    b.installArtifact(b.addExecutable(.{ .name = "s11net", .root_module = net_mod }));

    const t = b.addTest(.{ .root_module = sim_mod });
    b.step("test", "unit tests").dependOn(&b.addRunArtifact(t).step);
}
