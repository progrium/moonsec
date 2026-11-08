//! Build steps for the Linux host backend, kept out of the root build.zig (like
//! platform/client/build.zig). The root calls `add` (the pure tests, part of
//! `zig build test` on Linux) and `addTests` (`test-linux-host`).

const std = @import("std");

pub const Modules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    synthetic: *std.Build.Module,
    linux_uinput: *std.Build.Module,
};

/// The Linux host backend ("host_linux", platform/host/linux/host.zig). Pure Zig and
/// libc-free so far: 7A (PipeWire) and 7B (VAAPI, NVENC) add their C files and system
/// libraries here.
pub fn hostModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("platform/host/linux/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = m.platform },
            .{ .name = "core", .module = m.core },
            .{ .name = "synthetic", .module = m.synthetic },
            .{ .name = "linux_uinput", .module = m.linux_uinput },
        },
    });
}

/// The injector's translation (devices are pipes) and the bundle's fallbacks; no
/// /dev/uinput needed.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, test_step: *std.Build.Step) void {
    if (target.result.os.tag != .linux) return;
    const t = b.addTest(.{ .name = "host-linux-test", .root_module = hostModule(b, target, optimize, m) });
    test_step.dependOn(&b.addRunArtifact(t).step);
}

/// `test-linux-host`: the injector on real uinput devices, read back from evdev.
pub fn addTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) void {
    const step = b.step("test-linux-host", "Run the Linux host backend tests on real uinput devices (skip without /dev/uinput)");
    if (target.result.os.tag != .linux) {
        step.dependOn(&b.addFail("test-linux-host needs a Linux host").step);
        return;
    }
    const tm = b.createModule(.{
        .root_source_file = b.path("platform/host/linux/test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "host_linux", .module = hostModule(b, target, optimize, m) },
            .{ .name = "linux_uinput", .module = m.linux_uinput },
        },
    });
    const run = b.addRunArtifact(b.addTest(.{ .name = "host-linux-uinput-test", .root_module = tm }));
    run.has_side_effects = true; // depends on /dev/uinput
    step.dependOn(&run.step);
}
