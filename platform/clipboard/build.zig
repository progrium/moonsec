//! Build wiring for platform/clipboard: the "clipboard" module with the system backend for
//! the target linked in, and its tests in `zig build test`.
const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_step: *std.Build.Step) *std.Build.Module {
    const m = b.addModule("clipboard", .{
        .root_source_file = b.path("platform/clipboard/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    return m;
}
