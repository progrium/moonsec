//! Build wiring for platform/clipboard: the "clipboard" module with the system backend for
//! the target compiled in, its unit tests in `zig build test`, and `zig build test-clipboard`
//! for the backend on a real clipboard.
//!
//! Linux: the Wayland/X11 backend needs libwayland-client, libX11 and libXfixes (headers and
//! libraries), so it is built only with `-Dlinux-clipboard`; without it `System.open()`
//! returns null on Linux. macOS links AppKit; Windows needs nothing beyond user32.
const std = @import("std");

const linux_c_flags: []const []const u8 = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-Wno-cast-function-type" };

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_step: *std.Build.Step) *std.Build.Module {
    const linux_opt = b.option(bool, "linux-clipboard", "Build the Linux system clipboard (needs libwayland-client, libX11, libXfixes; default: off)") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "linux", linux_opt and target.result.os.tag == .linux);
    const m = b.addModule("clipboard", .{
        .root_source_file = b.path("platform/clipboard/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    m.addOptions("clipboard_options", opts);
    switch (target.result.os.tag) {
        .macos => {
            m.link_libc = true;
            m.addCSourceFile(.{ .file = b.path("platform/clipboard/pasteboard.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Werror" } });
            m.linkFramework("AppKit", .{});
            m.linkFramework("Foundation", .{});
        },
        .windows => m.linkSystemLibrary("user32", .{}),
        .linux => if (linux_opt) {
            m.link_libc = true;
            m.addIncludePath(b.path("platform/clipboard"));
            m.addCSourceFiles(.{ .root = b.path("platform/clipboard"), .files = &.{
                "linux_common.c",
                "linux_wayland.c",
                "linux_x11.c",
                "protocols/ext-data-control-v1.c",
                "protocols/wlr-data-control-unstable-v1.c",
            }, .flags = linux_c_flags });
            for ([_][]const u8{ "wayland-client", "X11", "Xfixes", "pthread" }) |l| m.linkSystemLibrary(l, .{});
        },
        else => {},
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);

    const sys_tests = b.addTest(.{ .name = "clipboard-test", .root_module = b.createModule(.{
        .root_source_file = b.path("platform/clipboard/system_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
        .imports = &.{.{ .name = "clipboard", .module = m }},
    }) });
    b.step("test-clipboard", "Run the system clipboard backend on a real clipboard (skips without a display)").dependOn(&b.addRunArtifact(sys_tests).step);
    return m;
}
