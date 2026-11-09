//! Build steps for the Linux host encoders (platform/host/linux, mlh_enc.h), kept out of
//! the root build.zig. The root calls `add`.
//!
//!   test-linux-enc     the encoder tests (Linux; see enc_test.zig for what they need)
//!   linux-enc-check    zig-out/bin/moonsec-enc-check, the hardware check (enc_check.zig)
const std = @import("std");
const client_build = @import("../../client/build.zig");

pub const Modules = client_build.LinuxModules;

/// System libraries the encoders link (pkg-config): libavcodec and libavutil for the
/// software encoder. libva is loaded at run time; only its headers are needed to build
/// (libva-dev). On Ubuntu 24.04: libavcodec-dev libavutil-dev libva-dev, and libx264 in
/// libavcodec (libavcodec60 has it).
pub const libs: []const []const u8 = &.{ "libavcodec", "libavutil" };

pub const c_flags: []const []const u8 = &.{ "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-fno-sanitize=undefined" };

pub const c_files: []const []const u8 = &.{ "enc.c", "enc_sw.c", "enc_vaapi.c", "dmabuf.c", "h26x.c", "testenc.c" };

/// The encoder module ("host_linux_enc", encoder.zig) with its C files and libraries.
pub fn encoderModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, platform: *std.Build.Module) *std.Build.Module {
    const tc = b.addTranslateC(.{ .root_source_file = b.path("platform/host/linux/mlh_enc.h"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("platform/host/linux/encoder.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "platform", .module = platform },
            .{ .name = "mlh_c", .module = tc.createModule() },
        },
    });
    mod.addIncludePath(b.path("platform/host/linux"));
    mod.addCSourceFiles(.{ .root = b.path("platform/host/linux"), .files = c_files, .flags = c_flags });
    for (libs) |lib| mod.linkSystemLibrary(lib, .{});
    return mod;
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules) void {
    const test_step = b.step("test-linux-enc", "Run the Linux host encoder tests (Linux host; VAAPI tests skip without a GPU)");
    const check_step = b.step("linux-enc-check", "Build and run zig-out/bin/moonsec-enc-check, the Linux encoder hardware check (`-- --help`)");
    if (target.result.os.tag != .linux) {
        test_step.dependOn(&b.addFail("test-linux-enc needs a Linux host").step);
        check_step.dependOn(&b.addFail("linux-enc-check needs a Linux host").step);
        return;
    }
    const enc = encoderModule(b, target, optimize, m.platform);
    const client = client_build.linuxClientModule(b, target, optimize, m);
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "host_linux_enc", .module = enc },
        .{ .name = "client_linux", .module = client },
        .{ .name = "platform", .module = m.platform },
        .{ .name = "core", .module = m.core },
    };

    const tm = b.createModule(.{
        .root_source_file = b.path("platform/host/linux/enc_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    const t = b.addTest(.{ .name = "host-linux-enc-test", .root_module = tm });
    const run = b.addRunArtifact(t);
    run.has_side_effects = true; // depends on the GPU, if any
    test_step.dependOn(&run.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "host-linux-enc-unit", .root_module = enc })).step);

    const cm = b.createModule(.{
        .root_source_file = b.path("platform/host/linux/enc_check.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    const exe = b.addExecutable(.{ .name = "moonsec-enc-check", .root_module = cm });
    const install = b.addInstallArtifact(exe, .{});
    const run_check = b.addRunArtifact(exe);
    run_check.step.dependOn(&install.step);
    if (b.args) |args| run_check.addArgs(args);
    check_step.dependOn(&run_check.step);
}
