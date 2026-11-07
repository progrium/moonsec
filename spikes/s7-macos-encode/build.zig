const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFile(.{ .file = b.path("src/probe.m"), .flags = &.{ "-fobjc-arc", "-O2" } });
    for ([_][]const u8{ "Foundation", "AppKit", "ScreenCaptureKit", "VideoToolbox", "CoreMedia", "CoreVideo", "CoreGraphics", "IOSurface" }) |fw|
        mod.linkFramework(fw, .{});
    const exe = b.addExecutable(.{ .name = "s7probe", .root_module = mod });
    b.installArtifact(exe);
}
