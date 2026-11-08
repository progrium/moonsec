//! Build steps for the recovery gate (tools/recovery), kept out of the root build.zig.
//!
//!   zig build recovery -- ARGS   build and run the gate for the host OS
//!                                (synthetic, plus win-* on Windows, mac-vt on macOS)
//!   zig build test-recovery      the gate's tests on the synthetic backend (any host)
//!
//! check-win also cross-compiles the Windows build of the gate. The macOS backend needs
//! the macOS host backend (platform/host/macos); when that directory is there, this
//! file builds it the way platform/host/macos/build.zig does.
const std = @import("std");

pub const Modules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    synthetic: *std.Build.Module,
    check_win: *std.Build.Step,
    test_step: *std.Build.Step,
};

const root = @import("../../build.zig");

fn runModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("tools/recovery/run.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "core", .module = m.core }, .{ .name = "platform", .module = m.platform } },
    });
}

/// The per-OS backends module ("recovery_platform").
fn platformModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, run_mod: *std.Build.Module) *std.Build.Module {
    switch (target.result.os.tag) {
        .windows => {
            const win = root.windowsModule(b, target, optimize);
            const host = root.windowsHostModule(b, target, optimize, win);
            return b.createModule(.{
                .root_source_file = b.path("tools/recovery/windows.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "platform", .module = m.platform },
                    .{ .name = "win", .module = win },
                    .{ .name = "win_host", .module = host },
                    .{ .name = "recovery_run", .module = run_mod },
                },
            });
        },
        .macos => if (macHostModule(b, target, optimize, m)) |host| {
            return b.createModule(.{
                .root_source_file = b.path("tools/recovery/macos.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "platform", .module = m.platform },
                    .{ .name = "mac_host", .module = host },
                    .{ .name = "recovery_run", .module = run_mod },
                },
            });
        },
        else => {},
    }
    return b.createModule(.{
        .root_source_file = b.path("tools/recovery/none.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "platform", .module = m.platform }, .{ .name = "recovery_run", .module = run_mod } },
    });
}

/// The macOS host backend, when this checkout has it (it lands separately). Mirrors
/// platform/host/macos/build.zig's `macosHostModule(..., native = true)`; switch to that
/// once both are on main.
fn macHostModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) ?*std.Build.Module {
    b.build_root.handle.access(b.graph.io, "platform/host/macos/host.zig", .{}) catch return null;
    const tc = b.addTranslateC(.{ .root_source_file = b.path("platform/host/macos/mh.h"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("platform/host/macos/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "platform", .module = m.platform },
            .{ .name = "core", .module = m.core },
            .{ .name = "mh_c", .module = tc.createModule() },
        },
    });
    if (@import("builtin").os.tag == .macos) {
        mod.addIncludePath(b.path("platform/host/macos"));
        mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = &.{
                "platform/host/macos/common.m", "platform/host/macos/capture.m", "platform/host/macos/audio.m",
                "platform/host/macos/encode.m", "platform/host/macos/input.m",
            },
            .flags = &.{ "-fobjc-arc", "-std=gnu11", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-deprecated-declarations", "-fno-sanitize=undefined" },
        });
        for ([_][]const u8{ "Foundation", "AppKit", "CoreGraphics", "CoreMedia", "CoreVideo", "VideoToolbox", "IOSurface", "CoreAudio", "ScreenCaptureKit", "ApplicationServices" }) |f|
            mod.linkFramework(f, .{});
    }
    return mod;
}

fn exe(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Step.Compile {
    const run_mod = runModule(b, target, optimize, m);
    const mod = b.createModule(.{
        .root_source_file = b.path("tools/recovery/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = m.platform },
            .{ .name = "synthetic", .module = m.synthetic },
            .{ .name = "recovery_run", .module = run_mod },
            .{ .name = "recovery_platform", .module = platformModule(b, target, optimize, m, run_mod) },
        },
    });
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) void {
    const e = exe(b, "recovery-gate", target, optimize, m);
    // Not part of `zig build install`: the release builds target windows-msvc, which the
    // Windows host backend (mingw C shims) does not build for.
    const r = b.addRunArtifact(e);
    r.has_side_effects = true;
    if (b.args) |a| r.addArgs(a);
    b.step("recovery", "Run the Phase 5 recovery gate (args after --; see tools/recovery/README.md)").dependOn(&r.step);

    const t = b.addTest(.{ .name = "recovery-test", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/recovery/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = m.platform },
            .{ .name = "synthetic", .module = m.synthetic },
            .{ .name = "recovery_run", .module = runModule(b, target, optimize, m) },
        },
    }) });
    const tr = b.addRunArtifact(t);
    b.step("test-recovery", "Run the recovery gate's tests on the synthetic backend").dependOn(&tr.step);
    m.test_step.dependOn(&tr.step);

    // The Windows gate, cross-compiled and linked.
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const wt = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .windows, .abi = .gnu });
        const we = exe(b, b.fmt("recovery-gate-{s}", .{@tagName(arch)}), wt, optimize, m);
        m.check_win.dependOn(&b.addInstallArtifact(we, .{ .dest_dir = .{ .override = .{ .custom = "win-test" } } }).step);
    }
}
