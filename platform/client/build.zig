//! Build steps for the client platform backends, kept out of the root
//! build.zig so the per-OS threads don't collide there. The root calls `add`
//! (portable tests, part of `zig build test`), `addWindowsTests` (part of
//! `check-win` and `test-win`) and `addLinuxTests` (`test-linux`).

const std = @import("std");
const root = @import("../../build.zig");

pub const Modules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    /// platform/linux/uinput.zig: event codes, key table, uinput devices (Linux only).
    linux_uinput: ?*std.Build.Module = null,
};

fn overlayModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("platform/client/common/overlay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "core", .module = m.core }, .{ .name = "platform", .module = m.platform } },
    });
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, test_step: *std.Build.Step) void {
    const overlay_mod = overlayModule(b, target, optimize, m);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "client-overlay-test", .root_module = overlay_mod })).step);

    const rawinput_mod = b.createModule(.{
        .root_source_file = b.path("platform/client/windows/rawinput.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "platform", .module = m.platform }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "client-rawinput-test", .root_module = rawinput_mod })).step);

    // The evdev translation is pure; its device code needs Linux.
    if (target.result.os.tag == .linux) {
        const evdev_mod = b.createModule(.{
            .root_source_file = b.path("platform/client/linux/evdev.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "platform", .module = m.platform }, .{ .name = "linux_uinput", .module = m.linux_uinput.? } },
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "client-evdev-test", .root_module = evdev_mod })).step);
    }
}

/// System libraries the Linux client links (found with pkg-config): libavcodec and libva
/// (decode), Wayland, EGL and GLES (present), PipeWire (audio). On Ubuntu 24.04:
///   libavcodec-dev libva-dev libwayland-dev libegl-dev libgles-dev libpipewire-0.3-dev
pub const linux_client_libs: []const []const u8 = &.{ "libavcodec", "libavutil", "libva", "wayland-client", "wayland-egl", "egl", "glesv2", "libpipewire-0.3" };

pub const LinuxModules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    synthetic: *std.Build.Module,
    linux_uinput: *std.Build.Module,
};

/// The Linux client backend ("client_linux", platform/client/linux/backend.zig) with its
/// C files and system libraries. Pass the app's own core/platform/synthetic modules so
/// the bundle's types are the app's.
pub fn linuxClientModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: LinuxModules) *std.Build.Module {
    const tc = b.addTranslateC(.{ .root_source_file = b.path("platform/client/linux/mlc.h"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("platform/client/linux/backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "platform", .module = m.platform },
            .{ .name = "core", .module = m.core },
            .{ .name = "synthetic", .module = m.synthetic },
            .{ .name = "linux_uinput", .module = m.linux_uinput },
            .{ .name = "client_overlay", .module = overlayModule(b, target, optimize, .{ .core = m.core, .platform = m.platform }) },
            .{ .name = "mlc_c", .module = tc.createModule() },
        },
    });
    mod.addIncludePath(b.path("platform/client/linux"));
    mod.addCSourceFiles(.{
        .root = b.path("platform/client/linux"),
        .files = &.{ "mlc_window.c", "mlc_decode.c", "mlc_audio.c", "protocol/xdg-shell-protocol.c", "protocol/tearing-control-v1-protocol.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fno-sanitize=undefined" },
    });
    for (linux_client_libs) |lib| mod.linkSystemLibrary(lib, .{});
    return mod;
}

/// `test-linux`: the Linux client tests (Linux host with the libraries above; see
/// platform/client/linux/test.zig for what they need at run time).
pub fn addLinuxTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: LinuxModules) void {
    const step = b.step("test-linux", "Run the Linux client backend tests (Linux host; Wayland, PipeWire and uinput tests skip without them)");
    if (target.result.os.tag != .linux) {
        step.dependOn(&b.addFail("test-linux needs a Linux host").step);
        return;
    }
    const client = linuxClientModule(b, target, optimize, m);
    const tm = b.createModule(.{
        .root_source_file = b.path("platform/client/linux/test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "client_linux", .module = client },
            .{ .name = "platform", .module = m.platform },
            .{ .name = "core", .module = m.core },
            .{ .name = "synthetic", .module = m.synthetic },
        },
    });
    const t = b.addTest(.{ .name = "client-linux-test", .root_module = tm });
    const run = b.addRunArtifact(t);
    run.has_side_effects = true; // depends on the display, PipeWire and /dev/uinput
    step.dependOn(&run.step);
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
