//! Build steps for the macOS host backend, kept out of the root build.zig so the
//! per-OS threads don't collide there. The root calls `add`.
//!
//!   zig build test       the HID key map (portable)
//!   zig build check-mac  type-checks the Zig side for aarch64 and x86_64 macOS from any
//!                        host (no SDK needed: the .m files are not compiled)
//!   zig build test-mac   compiles the .m files and runs test.zig (macOS host)

const std = @import("std");

pub const Modules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
};

const objc_files: []const []const u8 = &.{
    "platform/host/macos/common.m",
    "platform/host/macos/capture.m",
    "platform/host/macos/audio.m",
    "platform/host/macos/encode.m",
    "platform/host/macos/input.m",
    "platform/host/macos/vdisplay.m",
};

/// -Dmac-virtual-display=false builds without CGVirtualDisplay (private API; see
/// vdisplay.m). Read once in `add`.
var virtual_display_enabled = true;

const objc_flags: []const []const u8 = &.{
    "-fobjc-arc",                   "-std=gnu11",              "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
    "-Wno-deprecated-declarations",
    // Zig turns on UBSan for C in Debug; SDK inline code (dispatch_once's
    // __builtin_assume) trips its builtin check, so framework code goes without it.
    "-fno-sanitize=undefined",
};

const frameworks: []const []const u8 = &.{
    "Foundation",   "AppKit",    "CoreGraphics", "CoreMedia",        "CoreVideo",
    "VideoToolbox", "IOSurface", "CoreAudio",    "ScreenCaptureKit", "ApplicationServices",
};

/// The macOS host backend ("mac_host", platform/host/macos/host.zig). With `native`, the
/// Objective-C files are compiled and the frameworks linked (macOS SDK required).
pub fn macosHostModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, native: bool) *std.Build.Module {
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
    if (native) {
        mod.addIncludePath(b.path("platform/host/macos"));
        const flags: []const []const u8 = if (virtual_display_enabled) objc_flags else objc_flags ++ &[_][]const u8{"-DMH_NO_CGVIRTUALDISPLAY"};
        mod.addCSourceFiles(.{ .root = b.path("."), .files = objc_files, .flags = flags });
        for (frameworks) |f| mod.linkFramework(f, .{});
    }
    return mod;
}

fn testModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, native: bool) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("platform/host/macos/test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "platform", .module = m.platform },
            .{ .name = "core", .module = m.core },
            .{ .name = "host", .module = macosHostModule(b, target, optimize, m, native) },
        },
    });
}

/// Core and platform modules for another target.
fn modulesFor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const core = b.createModule(.{ .root_source_file = b.path("core/root.zig"), .target = target, .optimize = optimize });
    const platform = b.createModule(.{
        .root_source_file = b.path("platform/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });
    return .{ .core = core, .platform = platform };
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, test_step: *std.Build.Step) void {
    virtual_display_enabled = b.option(bool, "mac-virtual-display", "macOS host: CGVirtualDisplay virtual displays (private API; default true)") orelse true;
    const keymap = b.createModule(.{ .root_source_file = b.path("platform/host/macos/keymap.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "mac-keymap-test", .root_module = keymap })).step);

    const check_mac = b.step("check-mac", "Type-check the macOS host backend for aarch64 and x86_64 macOS (any host; the .m files need test-mac)");
    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |arch| {
        const mt = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .macos });
        const t = b.addTest(.{ .name = b.fmt("mac-host-check-{s}", .{@tagName(arch)}), .root_module = testModule(b, mt, optimize, modulesFor(b, mt, optimize), false) });
        // Compile only: nothing asks for the binary, so it is analyzed but not linked.
        check_mac.dependOn(&t.step);
    }

    const test_mac = b.step("test-mac", "Run the macOS host backend tests (macOS host; capture, audio and input skip without permission)");
    if (target.result.os.tag == .macos) {
        const t = b.addTest(.{ .name = "mac-host-test", .root_module = testModule(b, target, optimize, m, true) });
        const run = b.addRunArtifact(t);
        run.has_side_effects = true;
        test_mac.dependOn(&run.step);
        // The binary itself, for running with its output in full (CI's encoder report).
        const install = b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "mac-test" } } });
        b.step("build-test-mac", "Install the macOS host test binary to zig-out/mac-test").dependOn(&install.step);
    } else {
        test_mac.dependOn(&b.addFail("test-mac needs a macOS host; use check-mac to type-check").step);
    }
}
