const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shim = b.option([]const u8, "shim", "path to libs4shim.a") orelse
        "../shim/target/release/libs4shim.a";

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addObjectFile(.{ .cwd_relative = shim });
    if (target.result.os.tag == .macos) {
        // from `cargo rustc --release -- --print native-static-libs`
        for ([_][]const u8{ "SystemConfiguration", "Security", "CoreFoundation", "Foundation" }) |f| mod.linkFramework(f, .{});
        for ([_][]const u8{ "objc", "iconv" }) |l| mod.linkSystemLibrary(l, .{});
    } else {
        for ([_][]const u8{ "pthread", "dl", "m", "rt", "util", "gcc_s" }) |l| mod.linkSystemLibrary(l, .{});
    }

    const exe = b.addExecutable(.{ .name = "s4", .root_module = mod });
    b.installArtifact(exe);
}
