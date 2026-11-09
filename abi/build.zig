//! The public C ABI (include/moonsec.h, app/abi.zig): libraries, tests and examples.
//!
//!   zig build abi             zig-out/include/moonsec.h, zig-out/lib/libmoonsec.{a,so}
//!                             (with iroh; builds the shim) and the shim archive next to it
//!   zig build abi-sim         the same without iroh (loopback only; no Rust needed)
//!   zig build test-abi        C test over the in-process sim, C++ include and signature
//!                             check, ABI dump compared with abi/abi-v1.txt (no Rust needed;
//!                             part of `zig build test`)
//!   zig build test-abi-iroh   pairing, admission and a session through the ABI over iroh
//!                             on loopback (builds the shim; part of test-shim)
//!   zig build examples        examples/host.c and examples/client.c against libmoonsec
//!   zig build abi-dump -- --write abi/abi-v1.txt     regenerate the ABI dump
const std = @import("std");

pub const Deps = struct {
    app_imports: []const std.Build.Module.Import,
    iroh: *std.Build.Module,
    iroh_pipe: *std.Build.Module,
    /// The shim's static library, installed next to libmoonsec.a (static consumers link both).
    shim_archive: ?std.Build.LazyPath,
};

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Deps, test_step: *std.Build.Step) void {
    const header = b.addTranslateC(.{ .root_source_file = b.path("include/moonsec.h"), .target = target, .optimize = optimize });
    const header_mod = header.createModule();

    const sim = libraries(b, target, optimize, deps, header_mod, false);
    const full = libraries(b, target, optimize, deps, header_mod, true);

    const install_header = b.addInstallHeaderFile(b.path("include/moonsec.h"), "moonsec.h");
    const abi_sim = b.step("abi-sim", "Install the C ABI without iroh: zig-out/lib/libmoonsec-sim.{a,so} and zig-out/include/moonsec.h");
    abi_sim.dependOn(&install_header.step);
    abi_sim.dependOn(&b.addInstallArtifact(sim.static, .{}).step);
    abi_sim.dependOn(&b.addInstallArtifact(sim.shared, .{}).step);
    const abi = b.step("abi", "Install the C ABI: zig-out/lib/libmoonsec.{a,so}, the shim archive, zig-out/include/moonsec.h (builds the shim)");
    abi.dependOn(&install_header.step);
    abi.dependOn(&b.addInstallArtifact(full.static, .{}).step);
    abi.dependOn(&b.addInstallArtifact(full.shared, .{}).step);
    if (deps.shim_archive) |a| abi.dependOn(&b.addInstallLibFile(a, "libiroh_shim.a").step);

    // --- tests (no shim) ---
    const test_abi = b.step("test-abi", "C ABI: C test over the in-process sim, C++ include check, ABI dump check (no Rust needed)");
    const loop = cProgram(b, target, optimize, "abi-test-loopback", "abi/test_loopback.c", sim.static, false);
    test_abi.dependOn(&b.addRunArtifact(loop).step);
    const cpp = cProgram(b, target, optimize, "abi-include-check", "abi/include_check.cpp", sim.static, true);
    test_abi.dependOn(&b.addRunArtifact(cpp).step);
    const dump = cProgram(b, target, optimize, "abi-dump", "abi/abi_dump.c", sim.static, false);
    const check = b.addRunArtifact(dump);
    check.addArg("--check");
    check.addFileArg(b.path("abi/abi-v1.txt"));
    test_abi.dependOn(&check.step);
    // The shared library links and exports every function (the dump takes each one's address).
    const dump_shared = cProgram(b, target, optimize, "abi-dump-shared", "abi/abi_dump.c", sim.shared, false);
    const check_shared = b.addRunArtifact(dump_shared);
    check_shared.addArg("--check");
    check_shared.addFileArg(b.path("abi/abi-v1.txt"));
    test_abi.dependOn(&check_shared.step);
    const coverage = b.createModule(.{ .root_source_file = b.path("abi/header_test.zig"), .target = target, .optimize = optimize });
    coverage.addAnonymousImport("moonsec_h_text", .{ .root_source_file = b.path("include/moonsec.h") });
    coverage.addAnonymousImport("abi_dump_c", .{ .root_source_file = b.path("abi/abi_dump.c") });
    coverage.addAnonymousImport("include_check_cpp", .{ .root_source_file = b.path("abi/include_check.cpp") });
    test_abi.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "abi-header-test", .root_module = coverage })).step);
    test_step.dependOn(test_abi);

    const run_dump = b.addRunArtifact(dump);
    if (b.args) |a| run_dump.addArgs(a);
    b.step("abi-dump", "Print the ABI dump (struct layouts, constants, functions); -- --write FILE to save it").dependOn(&run_dump.step);

    // --- over iroh (shim) ---
    const iroh_test = cProgram(b, target, optimize, "abi-test-iroh", "abi/test_iroh.c", full.static, false);
    const run_iroh = b.addRunArtifact(iroh_test);
    b.step("test-abi-iroh", "C ABI over iroh on loopback: pairing, admission, a session (builds the shim)").dependOn(&run_iroh.step);
    if (b.top_level_steps.get("test-shim")) |ts| ts.step.dependOn(&run_iroh.step);

    // --- examples ---
    const examples = b.step("examples", "Build examples/host.c and examples/client.c against libmoonsec (builds the shim)");
    inline for (.{ "host", "client" }) |name| {
        const exe = cProgram(b, target, optimize, "moonsec-example-" ++ name, "examples/" ++ name ++ ".c", full.shared, false);
        examples.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    examples.dependOn(&b.addInstallArtifact(full.shared, .{}).step);
}

const Libs = struct { static: *std.Build.Step.Compile, shared: *std.Build.Step.Compile };

fn libraries(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Deps, header_mod: *std.Build.Module, with_iroh: bool) Libs {
    const name = if (with_iroh) "moonsec" else "moonsec-sim";
    var out: Libs = undefined;
    inline for (.{ .static, .dynamic }) |linkage| {
        const opts = b.addOptions();
        opts.addOption(bool, "iroh", with_iroh);
        opts.addOption(bool, "linux_client", false);
        opts.addOption(bool, "linux_host", false);
        const m = b.createModule(.{
            .root_source_file = b.path("app/abi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = deps.app_imports,
            .link_libc = true,
            // Shared library: position-independent; static: the caller may link it into one.
            .pic = true,
        });
        m.addImport("moonsec_h", header_mod);
        m.addOptions("app_options", opts);
        if (with_iroh) {
            m.addImport("iroh", deps.iroh);
            m.addImport("iroh_pipe", deps.iroh_pipe);
        }
        if (target.result.os.tag == .windows) m.linkSystemLibrary("winmm", .{});
        const lib = b.addLibrary(.{ .name = name, .linkage = linkage, .root_module = m });
        if (linkage == .static) out.static = lib else out.shared = lib;
    }
    return out;
}

fn cProgram(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, src: []const u8, lib: *std.Build.Step.Compile, cpp: bool) *std.Build.Step.Compile {
    const m = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = if (cpp) true else null });
    m.addCSourceFile(.{ .file = b.path(src), .flags = if (cpp) &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" } else &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter" } });
    m.addIncludePath(b.path("include"));
    m.linkLibrary(lib);
    if (lib.linkage == .dynamic and target.result.os.tag != .windows) m.addRPathSpecial(if (target.result.os.tag == .macos) "@executable_path/../lib" else "$ORIGIN/../lib");
    return b.addExecutable(.{ .name = name, .root_module = m });
}
