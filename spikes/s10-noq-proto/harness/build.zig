const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shim = b.option([]const u8, "shim", "path to libs10noq.a") orelse
        "../shim/target/release/libs10noq.a";
    const rv = b.option(bool, "rv", "include the iroh rendezvous punch demo (shim built with --features rv)") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "rv", rv);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", opts);
    mod.addObjectFile(.{ .cwd_relative = shim });
    for ([_][]const u8{ "pthread", "dl", "m", "rt", "util", "gcc_s" }) |l| mod.linkSystemLibrary(l, .{});
    const exe = b.addExecutable(.{ .name = "s10", .root_module = mod });
    b.installArtifact(exe);
}
