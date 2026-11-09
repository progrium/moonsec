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
//!   zig build test-abi-system  a host and a client on MOONSEC_BACKEND_SYSTEM over iroh
//!                             (Linux: run under platform/host/linux/headless.sh)
//!
//! `-Dabi-system=true|false` puts the OS backends (MOONSEC_BACKEND_SYSTEM) into the
//! libraries: the screen capture, encoders, audio and input injection of the host, and the
//! decoder, window, audio and input of the client. On by default for Windows targets and
//! on macOS hosts; off by default on Linux, where it needs the libraries listed in
//! platform/client/build.zig and platform/host/linux/build.zig.
const std = @import("std");
const root = @import("../build.zig");
const client_build = @import("../platform/client/build.zig");
const host_linux_build = @import("../platform/host/linux/build.zig");
const host_macos_build = @import("../platform/host/macos/build.zig");

pub const Deps = struct {
    app_imports: []const std.Build.Module.Import,
    iroh: *std.Build.Module,
    iroh_pipe: *std.Build.Module,
    /// The shim's static library, installed next to libmoonsec.a (static consumers link both).
    shim_archive: ?std.Build.LazyPath,
    /// platform/linux/uinput.zig (the Linux backends share it).
    linux_uinput: *std.Build.Module,
};

fn appModule(deps: Deps, name: []const u8) *std.Build.Module {
    for (deps.app_imports) |i| if (std.mem.eql(u8, i.name, name)) return i.module;
    @panic(name);
}

/// Whether the libraries get the OS backends (see the top of this file).
fn systemDefault(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    return switch (target.result.os.tag) {
        .windows => true,
        .macos => b.graph.host.result.os.tag == .macos,
        else => false,
    };
}

/// Adds the OS backends for `target` to the library module `m` as "system_host" and
/// "system_client" (app/system.zig picks them up).
fn addSystem(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Deps, m: *std.Build.Module) void {
    const core = appModule(deps, "core");
    const platform = appModule(deps, "platform");
    const synthetic = appModule(deps, "synthetic");
    switch (target.result.os.tag) {
        .linux => {
            const lm: client_build.LinuxModules = .{ .core = core, .platform = platform, .synthetic = synthetic, .linux_uinput = deps.linux_uinput };
            m.addImport("system_host", host_linux_build.linuxHostModule(b, target, optimize, .{ .core = core, .platform = platform, .synthetic = synthetic, .linux_uinput = deps.linux_uinput }));
            m.addImport("system_client", client_build.linuxClientModule(b, target, optimize, lm));
        },
        .windows => {
            const win = root.windowsModule(b, target, optimize);
            m.addImport("system_host", root.windowsHostModule(b, target, optimize, win));
            m.addImport("system_client", client_build.windowsClientModuleWith(b, target, optimize, .{ .core = core, .platform = platform, .win = win }));
        },
        .macos => {
            const native = b.graph.host.result.os.tag == .macos;
            m.addImport("system_host", host_macos_build.macosHostModule(b, target, optimize, .{ .core = core, .platform = platform }, native));
            m.addImport("system_client", client_build.macosClientModuleWith(b, target, optimize, native, .{ .core = core, .platform = platform }));
        },
        else => @panic("-Dabi-system: no OS backends for this target"),
    }
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Deps, test_step: *std.Build.Step) void {
    const header = b.addTranslateC(.{ .root_source_file = b.path("include/moonsec.h"), .target = target, .optimize = optimize });
    const header_mod = header.createModule();

    const system = b.option(bool, "abi-system", "Put the OS backends (MOONSEC_BACKEND_SYSTEM) into libmoonsec (default: on for Windows and macOS)") orelse systemDefault(b, target);
    const sim = libraries(b, target, optimize, deps, header_mod, false, system);
    const full = libraries(b, target, optimize, deps, header_mod, true, system);

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
    const multi_test = cProgram(b, target, optimize, "abi-test-multi", "abi/test_multi.c", full.static, false);
    const run_multi = b.addRunArtifact(multi_test);
    run_multi.step.dependOn(&run_iroh.step); // one loopback run at a time
    const reconnect_test = cProgram(b, target, optimize, "abi-test-reconnect", "abi/test_reconnect.c", full.static, false);
    const run_reconnect = b.addRunArtifact(reconnect_test);
    run_reconnect.step.dependOn(&run_multi.step);
    const iroh_step = b.step("test-abi-iroh", "C ABI over iroh on loopback: pairing, admission, a session, a multi-user host, reconnects (builds the shim)");
    iroh_step.dependOn(&run_iroh.step);
    iroh_step.dependOn(&run_multi.step);
    iroh_step.dependOn(&run_reconnect.step);
    if (b.top_level_steps.get("test-shim")) |ts| ts.step.dependOn(iroh_step);

    // --- the OS backends over iroh ---
    const test_system = b.step("test-abi-system", "C ABI: a host and a client on MOONSEC_BACKEND_SYSTEM over iroh (-Dabi-system; Linux: under platform/host/linux/headless.sh)");
    if (system) {
        const sys_test = cProgram(b, target, optimize, "abi-test-system", "abi/test_system.c", full.static, false);
        if (target.result.os.tag == .linux) {
            // The host tests' ScreenCast portal backend, served when MOONSEC_TEST_PORTAL is set.
            const m = sys_test.root_module;
            m.addCMacro("MOONSEC_TEST_PORTAL_BACKEND", "1");
            m.addIncludePath(b.path("platform/host/linux/testwin"));
            m.addCSourceFile(.{ .file = b.path("platform/host/linux/testwin/testportal.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fno-sanitize=undefined" } });
            m.linkSystemLibrary("dbus-1", .{});
        }
        // `-- multi` runs it on a multi-user host. On Linux each mode needs its own
        // headless.sh: its Weston does not survive a capture after a finished session.
        const run_sys = b.addRunArtifact(sys_test);
        run_sys.has_side_effects = true;
        if (b.args) |args| run_sys.addArgs(args);
        test_system.dependOn(&run_sys.step);
    } else test_system.dependOn(&b.addFail("test-abi-system needs -Dabi-system=true").step);

    // --- examples ---
    const examples = b.step("examples", "Build examples/host.c and examples/client.c against libmoonsec (builds the shim)");
    inline for (.{ "host", "client" }) |name| {
        const exe = cProgram(b, target, optimize, "moonsec-example-" ++ name, "examples/" ++ name ++ ".c", full.shared, false);
        examples.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    examples.dependOn(&b.addInstallArtifact(full.shared, .{}).step);
}

const Libs = struct { static: *std.Build.Step.Compile, shared: *std.Build.Step.Compile };

fn libraries(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Deps, header_mod: *std.Build.Module, with_iroh: bool, system: bool) Libs {
    const name = if (with_iroh) "moonsec" else "moonsec-sim";
    var out: Libs = undefined;
    inline for (.{ .static, .dynamic }) |linkage| {
        const opts = b.addOptions();
        opts.addOption(bool, "iroh", with_iroh);
        opts.addOption(bool, "linux_client", false);
        opts.addOption(bool, "linux_host", false);
        opts.addOption(bool, "system_backend", system);
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
        if (system) addSystem(b, target, optimize, deps, m);
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
