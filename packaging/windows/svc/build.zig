//! `moonsec-svc.exe`, the Windows host service (see main.zig). Standalone so the
//! installer build doesn't touch the root build.zig:
//!
//!   cd packaging/windows/svc && zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows } });
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "moonsec-svc", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    for ([_][]const u8{ "advapi32", "wtsapi32", "userenv", "kernel32" }) |l| exe.root_module.linkSystemLibrary(l, .{});
    b.installArtifact(exe);

    // The pure parts (command-line template, backoff) as host-run tests.
    const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("logic.zig"), .target = b.graph.host, .optimize = optimize }) });
    b.step("test", "Unit tests for the service's command-line and restart logic").dependOn(&b.addRunArtifact(t).step);
}
