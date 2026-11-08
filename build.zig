const std = @import("std");

pub const ShimSource = enum {
    /// Run cargo on ./shim for the selected target (needs Rust; for people changing the shim).
    source,
    /// Use a prebuilt shim directory given with -Dshim-dir (contains lib/ and include/).
    dir,
    /// Use the hash-pinned CI release artifact from build.zig.zon (no Rust needed).
    prebuilt,
};

pub const ShimLink = enum { static, dynamic };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shim_source = b.option(ShimSource, "shim", "Where the iroh shim comes from (default: source)") orelse .source;
    const shim_link = b.option(ShimLink, "shim-link", "Link the shim statically or as a shared library (default: static)") orelse .static;
    const shim_dir_opt = b.option([]const u8, "shim-dir", "Prebuilt shim directory for -Dshim=dir");

    // Core: pure Zig, no shim, no libc. Other modules import it as "core".
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run the core unit tests (no Rust needed)");
    const core_tests = b.addTest(.{ .root_module = core_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // The core must build for the browser unchanged: compile it (and its tests) for wasm32.
    const wasm_step = b.step("check-wasm", "Compile the core for wasm32-freestanding and its tests for wasm32-wasi");
    const wasm_lib = b.addLibrary(.{
        .name = "moonsec-core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_step.dependOn(&wasm_lib.step);
    const wasm_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("core/root.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
        .optimize = optimize,
    }) });
    wasm_step.dependOn(&wasm_tests.step);

    const shim = resolveShim(b, target, shim_source, shim_link, shim_dir_opt);

    // C header -> Zig module (the shim's ABI as Zig sees it).
    const translate = b.addTranslateC(.{
        .root_source_file = shim.include_dir.path(b, "iroh_shim.h"),
        .target = target,
        .optimize = optimize,
    });

    const iroh_mod = b.addModule("iroh", .{
        .root_source_file = b.path("transport/iroh.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "iroh_shim_c", .module = translate.createModule() }},
    });
    linkShim(b, iroh_mod, target, shim, shim_link);

    const echo = b.addExecutable(.{
        .name = "shim-echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shim-echo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "iroh", .module = iroh_mod }},
        }),
    });
    b.installArtifact(echo);
    if (shim_link == .dynamic) {
        // Ship the shared shim next to the executable.
        const ext = sharedName(target.result);
        b.getInstallStep().dependOn(&b.addInstallBinFile(shim.lib_dir.path(b, ext), ext).step);
    }

    const run_echo = b.addRunArtifact(echo);
    run_echo.addArgs(if (b.args) |a| a else &.{"selftest"});
    b.step("echo", "Run the S1 datagram echo (default: selftest over loopback)").dependOn(&run_echo.step);

    const run_test = b.addRunArtifact(echo);
    run_test.addArg("selftest");
    b.step("test-shim", "Run the shim echo selftest (builds the shim)").dependOn(&run_test.step);

    // Simulated network behind PacketPipe (transport/sim.zig) and its scenario harness (sim/).
    // Pure Zig: none of these steps build the shim.
    const simnet_mod = b.addModule("simnet", .{ .root_source_file = b.path("transport/sim.zig"), .target = target, .optimize = optimize });
    const sim_imports: []const std.Build.Module.Import = &.{.{ .name = "simnet", .module = simnet_mod }};
    const sim_exe = b.addExecutable(.{ .name = "sim", .root_module = b.createModule(.{ .root_source_file = b.path("sim/main.zig"), .target = target, .optimize = optimize, .imports = sim_imports }) });
    const run_sim = b.addRunArtifact(sim_exe);
    if (b.args) |a| run_sim.addArgs(a);
    b.step("sim", "Run the simulated-network scenarios (options: see sim/main.zig)").dependOn(&run_sim.step);
    const check_sim = b.addRunArtifact(sim_exe);
    check_sim.addArg("--check");
    check_sim.addFileArg(b.path("sim/golden.txt"));
    b.step("sim-check", "Run every scenario and compare digests with sim/golden.txt").dependOn(&check_sim.step);
    const test_sim = b.step("test-sim", "Unit tests for PacketPipe, the sim network and the scenarios");
    test_sim.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = simnet_mod })).step);
    test_sim.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("sim/test.zig"), .target = target, .optimize = optimize, .imports = sim_imports }) })).step);
    test_step.dependOn(test_sim);
}

const Shim = struct {
    lib_dir: std.Build.LazyPath,
    include_dir: std.Build.LazyPath,
};

fn resolveShim(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    source: ShimSource,
    link: ShimLink,
    dir_opt: ?[]const u8,
) Shim {
    switch (source) {
        .source => {
            const triple = rustTriple(target.result);
            const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--locked", "--target", triple });
            cargo.addArg("--manifest-path");
            cargo.addFileArg(b.path("shim/Cargo.toml"));
            cargo.addArg("--target-dir");
            const target_dir = cargo.addOutputDirectoryArg("cargo-target");
            // cargo does its own incremental tracking; let it decide what to rebuild.
            cargo.has_side_effects = true;
            // Run inside shim/ so rustup honors shim/rust-toolchain.toml.
            cargo.setCwd(b.path("shim"));
            _ = link;
            return .{
                .lib_dir = target_dir.path(b, b.fmt("{s}/release", .{triple})),
                .include_dir = b.path("shim/include"),
            };
        },
        .dir => {
            const dir = dir_opt orelse @panic("-Dshim=dir needs -Dshim-dir=<path>");
            const root: std.Build.LazyPath = .{ .cwd_relative = dir };
            return .{ .lib_dir = root.path(b, "lib"), .include_dir = root.path(b, "include") };
        },
        .prebuilt => {
            const t = target.result;
            // Releases ship MSVC archives for Windows; Zig's *-windows-gnu needs -Dshim=source.
            if (t.os.tag == .windows and t.abi != .msvc)
                @panic("-Dshim=prebuilt has Windows archives for *-windows-msvc only; use -Dtarget=<arch>-windows-msvc or -Dshim=source");
            const dep_name = b.fmt("iroh_shim_{s}", .{artifactSuffix(t)});
            if (!hasDependency(b, dep_name)) {
                std.debug.panic("-Dshim=prebuilt: build.zig.zon has no '{s}'; pin a shim-v* release (see shim/README.md) or use -Dshim=source", .{dep_name});
            }
            const dep = b.lazyDependency(dep_name, .{}) orelse {
                // Lazy fetch pending: zig re-runs build() once it is downloaded.
                return .{ .lib_dir = b.path("shim"), .include_dir = b.path("shim/include") };
            };
            return .{ .lib_dir = dep.path("lib"), .include_dir = dep.path("include") };
        },
    }
}

fn hasDependency(b: *std.Build, name: []const u8) bool {
    for (b.available_deps) |d| {
        if (std.mem.eql(u8, d[0], name)) return true;
    }
    return false;
}

fn linkShim(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, shim: Shim, link: ShimLink) void {
    const t = target.result;
    m.link_libc = true;
    switch (link) {
        .static => {
            const name = if (t.os.tag == .windows and t.abi == .msvc) "iroh_shim.lib" else "libiroh_shim.a";
            m.addObjectFile(shim.lib_dir.path(b, name));
        },
        .dynamic => {
            if (t.os.tag == .windows) {
                // Link the DLL's import library; the .dll itself is installed next to the exe.
                m.addObjectFile(shim.lib_dir.path(b, if (t.abi == .msvc) "iroh_shim.dll.lib" else "libiroh_shim.dll.a"));
            } else {
                m.addLibraryPath(shim.lib_dir);
                m.linkSystemLibrary("iroh_shim", .{ .use_pkg_config = .no, .preferred_link_mode = .dynamic });
                m.addRPathSpecial(if (t.os.tag == .macos) "@executable_path" else "$ORIGIN");
            }
            return; // the shared library carries its own system deps
        },
    }
    // Native deps of the Rust staticlib (from `rustc --print native-static-libs`).
    switch (t.os.tag) {
        .linux => {
            // Rust's std wants libgcc_s for _Unwind_*; Zig provides LLVM libunwind instead.
            m.linkSystemLibrary("unwind", .{});
            for ([_][]const u8{ "util", "rt", "pthread", "m", "dl" }) |l| m.linkSystemLibrary(l, .{});
        },
        .macos => {
            // Zig does not search the macOS SDK on its own; point it at Xcode's SDK.
            if (b.sysroot orelse macosSdk(b, t)) |sdk| {
                m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
                m.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            }
            for ([_][]const u8{ "CoreFoundation", "Security", "SystemConfiguration" }) |f| m.linkFramework(f, .{});
            m.linkSystemLibrary("iconv", .{});
        },
        .windows => {
            if (t.abi != .msvc) m.linkSystemLibrary("unwind", .{});
            for ([_][]const u8{
                "ws2_32", "bcrypt", "ntdll", "userenv", "advapi32", "kernel32", "iphlpapi", "dbghelp", "secur32", "crypt32", "ole32", "oleaut32", "shell32", "user32", "synchronization",
            }) |l| m.linkSystemLibrary(l, .{});
        },
        else => {},
    }
}

fn macosSdk(b: *std.Build, t: std.Target) ?[]const u8 {
    if (@import("builtin").os.tag != .macos) return null;
    return std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &t);
}

fn sharedName(t: std.Target) []const u8 {
    return switch (t.os.tag) {
        .windows => "iroh_shim.dll",
        .macos => "libiroh_shim.dylib",
        else => "libiroh_shim.so",
    };
}

/// Rust target triple matching a Zig target. Windows uses the gnullvm ABI so the
/// Rust archive and Zig's MinGW/libunwind runtime agree (msvc pairs with msvc).
pub fn rustTriple(t: std.Target) []const u8 {
    const arch = t.cpu.arch;
    return switch (t.os.tag) {
        .linux => switch (arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => @panic("unsupported linux arch"),
        },
        .macos => switch (arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => @panic("unsupported macos arch"),
        },
        .windows => switch (arch) {
            .x86_64 => if (t.abi == .msvc) "x86_64-pc-windows-msvc" else "x86_64-pc-windows-gnullvm",
            .aarch64 => if (t.abi == .msvc) "aarch64-pc-windows-msvc" else "aarch64-pc-windows-gnullvm",
            else => @panic("unsupported windows arch"),
        },
        else => @panic("unsupported os for the iroh shim"),
    };
}

/// Release artifact suffix, e.g. iroh_shim_linux_x86_64. macOS ships one universal archive.
fn artifactSuffix(t: std.Target) []const u8 {
    return switch (t.os.tag) {
        .macos => "macos_universal",
        .linux => if (t.cpu.arch == .aarch64) "linux_aarch64" else "linux_x86_64",
        .windows => if (t.cpu.arch == .aarch64) "windows_aarch64" else "windows_x86_64",
        else => @panic("unsupported os for the iroh shim"),
    };
}
