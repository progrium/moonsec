//! Build steps for the client platform backends, kept out of the root
//! build.zig so the per-OS threads don't collide there. The root calls `add`
//! (portable tests, part of `zig build test`) and `addWindowsTests` (part of
//! `check-win` and `test-win`).

const std = @import("std");
const root = @import("../../build.zig");

pub const Modules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
};

fn overlayModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("platform/client/common/overlay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "core", .module = m.core }, .{ .name = "platform", .module = m.platform } },
    });
}

/// Set by `add` from -Drequire-uinput; read by `gamepadModule`.
var require_uinput: bool = false;

/// Gamepad capture for every client OS (platform/client/gamepad): XInput,
/// GameController (gc.m, linked on macOS targets only) and evdev.
pub fn gamepadModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption(bool, "require_uinput", require_uinput);
    const mod = b.createModule(.{
        .root_source_file = b.path("platform/client/gamepad/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = m.core },
            .{ .name = "platform", .module = m.platform },
            .{ .name = "gamepad_options", .module = opts.createModule() },
        },
    });
    if (target.result.os.tag == .macos) {
        mod.link_libc = true;
        mod.addCSourceFile(.{ .file = b.path("platform/client/gamepad/gc.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Werror" } });
        mod.addIncludePath(b.path("platform/client/gamepad"));
        mod.linkFramework("GameController", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkSystemLibrary("objc", .{});
    }
    return mod;
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, test_step: *std.Build.Step) void {
    require_uinput = b.option(bool, "require-uinput", "Fail, not skip, the gamepad uinput tests when /dev/uinput is unavailable") orelse false;
    const gamepad_tests = b.addRunArtifact(b.addTest(.{ .name = "client-gamepad-test", .root_module = gamepadModule(b, target, optimize, m) }));
    test_step.dependOn(&gamepad_tests.step);
    const test_gamepad = b.step("test-gamepad", "Gamepad capture tests (on Linux, with a uinput virtual pad when /dev/uinput is writable)");
    test_gamepad.dependOn(&gamepad_tests.step);

    const overlay_mod = overlayModule(b, target, optimize, m);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "client-overlay-test", .root_module = overlay_mod })).step);

    const rawinput_mod = b.createModule(.{
        .root_source_file = b.path("platform/client/windows/rawinput.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "platform", .module = m.platform }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "client-rawinput-test", .root_module = rawinput_mod })).step);
}

/// The Windows client backend ("client_windows", platform/client/windows/backend.zig)
/// for a Windows target, with its C files linked in.
pub fn windowsClientModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const core = b.createModule(.{ .root_source_file = b.path("core/root.zig"), .target = target, .optimize = optimize });
    const platform = b.createModule(.{
        .root_source_file = b.path("platform/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });
    const tc = b.addTranslateC(.{ .root_source_file = b.path("platform/client/windows/mswc.h"), .target = target, .optimize = optimize });
    tc.addIncludePath(b.path("platform/windows"));
    const m = b.createModule(.{
        .root_source_file = b.path("platform/client/windows/backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = platform },
            .{ .name = "core", .module = core },
            .{ .name = "win", .module = root.windowsModule(b, target, optimize) },
            .{ .name = "client_overlay", .module = overlayModule(b, target, optimize, .{ .core = core, .platform = platform }) },
            .{ .name = "client_gamepad", .module = gamepadModule(b, target, optimize, .{ .core = core, .platform = platform }) },
            .{ .name = "mswc_c", .module = tc.createModule() },
        },
    });
    m.addIncludePath(b.path("platform/client/windows"));
    root.addWindowsC(b, m, &.{
        "platform/client/windows/mswc_window.c",
        "platform/client/windows/mswc_decode.c",
        "platform/client/windows/mswc_present.c",
        "platform/client/windows/mswc_audio.c",
    }, &.{ "d3d11", "dxgi", "ole32", "oleaut32", "uuid", "user32", "mfplat", "mfuuid", "mf", "strmiids", "avrt" });
    return m;
}

fn windowsTestModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const client = windowsClientModule(b, target, optimize);
    return b.createModule(.{
        .root_source_file = b.path("platform/client/windows/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "client_windows", .module = client },
            .{ .name = "platform", .module = client.import_table.get("platform").? },
            .{ .name = "core", .module = client.import_table.get("core").? },
            .{ .name = "win", .module = client.import_table.get("win").? },
        },
    });
}

/// Adds the Windows client tests to `check-win` (cross-compile and link for x86_64 and
/// aarch64 Windows from any host) and `test-win` (run, on a Windows host).
pub fn addWindowsTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, check_win: *std.Build.Step, test_win: *std.Build.Step) void {
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const wt = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .windows, .abi = .gnu });
        const t = b.addTest(.{ .name = b.fmt("client-win-test-{s}", .{@tagName(arch)}), .root_module = windowsTestModule(b, wt, optimize) });
        check_win.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "win-test" } } }).step);
    }
    if (target.result.os.tag == .windows) {
        const t = b.addTest(.{ .name = "client-win-test", .root_module = windowsTestModule(b, target, optimize) });
        test_win.dependOn(&b.addRunArtifact(t).step);
    }
}
