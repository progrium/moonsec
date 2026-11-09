//! Build steps for the client platform backends, kept out of the root
//! build.zig so the per-OS threads don't collide there. The root calls `add`
//! (portable tests, part of `zig build test`), `addWindowsTests` (part of
//! `check-win` and `test-win`), `addMacosTests` (`test-mac`) and `addLinuxTests`
//! (`test-linux`).

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

    const nsinput_mod = b.createModule(.{
        .root_source_file = b.path("platform/client/macos/nsinput.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "platform", .module = m.platform }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "client-nsinput-test", .root_module = nsinput_mod })).step);

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
        "platform/client/windows/mswc_formats.c",
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

/// Flags for the macOS client's Objective-C files (ARC, warnings as errors).
pub const macos_objc_flags: []const []const u8 = &.{
    "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
};

/// The macOS client backend ("client_macos", platform/client/macos/backend.zig) for a
/// macOS target. With `native`, its Objective-C files are compiled and the frameworks
/// linked, which needs the macOS SDK and so a macOS host; without, the Zig side only
/// (type-checking from any host).
pub fn macosClientModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native: bool) *std.Build.Module {
    const core = b.createModule(.{ .root_source_file = b.path("core/root.zig"), .target = target, .optimize = optimize });
    const platform = b.createModule(.{
        .root_source_file = b.path("platform/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });
    const tc = b.addTranslateC(.{ .root_source_file = b.path("platform/client/macos/macc.h"), .target = target, .optimize = optimize });
    const m = b.createModule(.{
        .root_source_file = b.path("platform/client/macos/backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "platform", .module = platform },
            .{ .name = "core", .module = core },
            .{ .name = "client_overlay", .module = overlayModule(b, target, optimize, .{ .core = core, .platform = platform }) },
            .{ .name = "macc_c", .module = tc.createModule() },
            .{ .name = "client_gamepad", .module = if (native) gamepadModule(b, target, optimize, .{ .core = core, .platform = platform }) else gamepadCheckModule(b, target, optimize, .{ .core = core, .platform = platform }) },
        },
    });
    if (native) {
        root.addMacosSdkPaths(b, m, target);
        m.addIncludePath(b.path("platform/client/macos"));
        m.addCSourceFiles(.{
            .root = b.path("platform/client/macos"),
            .files = &.{ "macc_window.m", "macc_decode.m", "macc_present.m", "macc_audio.m" },
            .flags = macos_objc_flags,
        });
        for ([_][]const u8{
            "Foundation",   "AppKit",       "QuartzCore", "Metal",        "CoreVideo", "CoreMedia",
            "VideoToolbox", "AudioToolbox", "CoreAudio",  "CoreGraphics", "IOSurface",
        }) |f| m.linkFramework(f, .{});
    }
    return m;
}

/// The gamepad module's Zig side only (gc.m is not compiled, nothing is linked), for
/// type-checking the macOS client from hosts without the SDK.
fn gamepadCheckModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption(bool, "require_uinput", false);
    return b.createModule(.{
        .root_source_file = b.path("platform/client/gamepad/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = m.core },
            .{ .name = "platform", .module = m.platform },
            .{ .name = "gamepad_options", .module = opts.createModule() },
        },
    });
}

/// `test-mac-client` runs the macOS client tests (macOS host); they also join `test-mac`.
/// `check-mac` type-checks them for aarch64 and x86_64 macOS from any host.
pub fn addMacosTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_mac: *std.Build.Step, check_mac: *std.Build.Step) void {
    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |arch| {
        const mt = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .macos });
        const t = b.addTest(.{ .name = b.fmt("client-mac-check-{s}", .{@tagName(arch)}), .root_module = macosTestModule(b, mt, optimize, false) });
        // Compile only: nothing asks for the binary, so it is analyzed but not linked.
        check_mac.dependOn(&t.step);
    }
    const step = b.step("test-mac-client", "Run the macOS client backend tests (macOS host; window and audio tests skip without a window server or output device)");
    if (target.result.os.tag != .macos) {
        step.dependOn(&b.addFail("test-mac-client needs a macOS host; use check-mac to type-check").step);
        return;
    }
    const t = b.addTest(.{ .name = "client-mac-test", .root_module = macosTestModule(b, target, optimize, true) });
    const run = b.addRunArtifact(t);
    run.has_side_effects = true; // depends on the GPU, window server and audio device
    step.dependOn(&run.step);
    test_mac.dependOn(&run.step);
}

fn macosTestModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native: bool) *std.Build.Module {
    const client = macosClientModule(b, target, optimize, native);
    return b.createModule(.{
        .root_source_file = b.path("platform/client/macos/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "client_macos", .module = client },
            .{ .name = "platform", .module = client.import_table.get("platform").? },
            .{ .name = "core", .module = client.import_table.get("core").? },
        },
    });
}
