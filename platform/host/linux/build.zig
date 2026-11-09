//! Build steps for the Linux host backend, kept out of the root build.zig so the per-OS
//! threads don't collide there. The root calls `add`.
//!
//!   zig build test-linux-host   the capture and audio tests (Linux; the portal and
//!                               PipeWire tests skip without them, see test.zig)
//!
//! `linuxHostModule` is what an app imports as "host_linux".

const std = @import("std");
const client_build = @import("../../client/build.zig");

pub const Modules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    synthetic: *std.Build.Module,
};

/// System libraries the Linux host links (found with pkg-config): libdbus (the portal)
/// and PipeWire. On Ubuntu 24.04: libdbus-1-dev libpipewire-0.3-dev.
pub const linux_host_libs: []const []const u8 = &.{ "dbus-1", "libpipewire-0.3" };

const c_flags: []const []const u8 = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fno-sanitize=undefined" };

/// The Linux host backend ("host_linux", platform/host/linux/host.zig) with its C files and
/// system libraries. Pass the app's own platform module so the types are the app's.
pub fn linuxHostModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) *std.Build.Module {
    const tc = b.addTranslateC(.{ .root_source_file = b.path("platform/host/linux/mlh.h"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("platform/host/linux/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "platform", .module = m.platform },
            .{ .name = "mlh_c", .module = tc.createModule() },
        },
    });
    mod.addIncludePath(b.path("platform/host/linux"));
    mod.addCSourceFiles(.{
        .root = b.path("platform/host/linux"),
        .files = &.{ "mlh_common.c", "mlh_portal.c", "mlh_capture.c", "mlh_audio.c" },
        .flags = c_flags,
    });
    for (linux_host_libs) |lib| mod.linkSystemLibrary(lib, .{});
    return mod;
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) void {
    const step = b.step("test-linux-host", "Run the Linux host capture and audio tests (Linux host; portal and PipeWire tests skip without them)");
    if (target.result.os.tag != .linux) {
        step.dependOn(&b.addFail("test-linux-host needs a Linux host").step);
        return;
    }
    const host = linuxHostModule(b, target, optimize, m);
    // The test window (wl_shm, xdg-shell from the client's generated protocol code), the
    // test ScreenCast portal backend (testwin/testportal.c, used under headless.sh) and the
    // client's PipeWire playback, to play a tone into the sink the host captures.
    const tw = b.addTranslateC(.{ .root_source_file = b.path("platform/host/linux/testwin/test_c.h"), .target = target, .optimize = optimize });
    const tm = b.createModule(.{
        .root_source_file = b.path("platform/host/linux/test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "host_linux", .module = host },
            .{ .name = "platform", .module = m.platform },
            .{ .name = "testwin_c", .module = tw.createModule() },
            .{ .name = "client_linux", .module = client_build.linuxClientModule(b, target, optimize, .{ .core = m.core, .platform = m.platform, .synthetic = m.synthetic }) },
        },
    });
    // xdg-shell's interface tables come with client_linux (its protocol/ code).
    tm.addCSourceFiles(.{ .root = b.path("platform/host/linux/testwin"), .files = &.{ "testwin.c", "testportal.c", "testsource.c" }, .flags = c_flags });
    tm.linkSystemLibrary("wayland-client", .{});
    tm.linkSystemLibrary("dbus-1", .{});
    tm.linkSystemLibrary("libpipewire-0.3", .{});
    const t = b.addTest(.{ .name = "host-linux-test", .root_module = tm });
    const run = b.addRunArtifact(t);
    run.has_side_effects = true; // depends on the portal, the compositor and PipeWire
    step.dependOn(&run.step);
}
