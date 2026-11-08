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

    // Platform interface (platform/api.zig): what each OS backend implements for the
    // host and client apps. Pure Zig; backends live under platform/<os>/.
    const platform_mod = b.addModule("platform", .{
        .root_source_file = b.path("platform/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core_mod }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = platform_mod })).step);
    // Synthetic backend (platform/synthetic): test pattern, passthrough codec, scripted input.
    const synthetic_mod = b.addModule("synthetic", .{
        .root_source_file = b.path("platform/synthetic/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "core", .module = core_mod }, .{ .name = "platform", .module = platform_mod } },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = synthetic_mod })).step);

    // Client platform backends (platform/client/build.zig).
    @import("platform/client/build.zig").add(b, target, optimize, .{ .core = core_mod, .platform = platform_mod }, test_step);

    // PacketPipe (transport/pipe.zig): the core's view of a transport, shared by the
    // sim (transport/sim.zig) and iroh (transport/iroh_pipe.zig) implementations.
    const pipe_mod = b.addModule("pipe", .{ .root_source_file = b.path("transport/pipe.zig"), .target = target, .optimize = optimize });

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

    // libopus from source (codec/opus/libopus.zig) and its Zig binding, for every target.
    const opus = addOpus(b, target, optimize);
    const opus_tests = b.addTest(.{ .name = "opus-test", .root_module = opus.module });
    const run_opus_tests = b.addRunArtifact(opus_tests);
    b.step("test-opus", "Run the libopus binding tests").dependOn(&run_opus_tests.step);
    test_step.dependOn(&run_opus_tests.step);
    // Browser client: libopus and the binding must build for wasm32-wasi (design, "Web").
    const wasm_wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    wasm_step.dependOn(&b.addTest(.{ .root_module = addOpus(b, wasm_wasi, optimize).module }).step);
    // `zig build check-opus`: cross-compile libopus for every shipping target from one host.
    const check_opus = b.step("check-opus", "Cross-compile libopus and its binding for every target");
    for (opus_targets) |q| {
        const t = b.resolveTargetQuery(q);
        check_opus.dependOn(&b.addTest(.{ .root_module = addOpus(b, t, .ReleaseSafe).module }).step);
    }

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

    // Reed-Solomon FEC (core/media/fec.zig): pure Zig, no shim needed.
    const fec_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("core/media/fec.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("fec-test", "Run the Reed-Solomon FEC tests").dependOn(&b.addRunArtifact(fec_tests).step);
    test_step.dependOn(&b.addRunArtifact(fec_tests).step);
    wasm_step.dependOn(&b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("core/media/fec.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
        .optimize = optimize,
    }) }).step);
    const fec_bench = b.addExecutable(.{ .name = "fec-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("core/media/fec_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    b.step("fec-bench", "Benchmark the Reed-Solomon FEC codec (ReleaseFast)").dependOn(&b.addRunArtifact(fec_bench).step);
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

    // Shim ABI tests over loopback (transport/iroh_test.zig); part of test-shim.
    const iroh_tests = b.addTest(.{
        .name = "iroh-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("transport/iroh_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "iroh", .module = iroh_mod }},
        }),
    });
    const run_iroh_tests = b.addRunArtifact(iroh_tests);
    b.top_level_steps.get("test-shim").?.step.dependOn(&run_iroh_tests.step);

    // Linux netns tests (root): `zig build netns-test` installs zig-out/bin/iroh-netns-test,
    // run it with sudo. It drives zig-out/bin/shim-echo as the peer in another namespace.
    const netns_tests = b.addTest(.{
        .name = "iroh-netns-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("transport/iroh_netns_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "iroh", .module = iroh_mod }},
        }),
    });
    const netns_step = b.step("netns-test", "Install the Linux netns shim tests (run zig-out/bin/iroh-netns-test as root)");
    // The netns lab (tools/netlab): a userspace delay line for kernels without netem.
    const delayline = b.addExecutable(.{ .name = "delayline", .root_module = b.createModule(.{ .root_source_file = b.path("tools/netlab/delayline.zig"), .target = target, .optimize = optimize }) });
    b.step("delayline", "Install zig-out/bin/delayline (Linux; the netns lab's delay line)").dependOn(&b.addInstallArtifact(delayline, .{}).step);
    netns_step.dependOn(&b.addInstallArtifact(netns_tests, .{}).step);
    netns_step.dependOn(b.getInstallStep());

    // Simulated network behind PacketPipe (transport/sim.zig) and its scenario harness (sim/).
    // Pure Zig: none of these steps build the shim.
    const simnet_mod = b.addModule("simnet", .{ .root_source_file = b.path("transport/sim.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "pipe", .module = pipe_mod }} });
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
    test_sim.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pipe_mod })).step);
    test_sim.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("sim/test.zig"), .target = target, .optimize = optimize, .imports = sim_imports }) })).step);
    test_step.dependOn(test_sim);

    // Phase 1 gate (tools/gate): two processes exchange stream-tagged datagrams through
    // the core, over iroh and over the simulated network. `gate-sim` is built without the
    // shim so the sim half runs without Rust; `gate` (part of test-shim) runs both.
    const simlink_mod = b.addModule("simlink", .{ .root_source_file = b.path("transport/simlink.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "simnet", .module = simnet_mod }, .{ .name = "pipe", .module = pipe_mod } } });
    const iroh_pipe_mod = b.addModule("iroh_pipe", .{ .root_source_file = b.path("transport/iroh_pipe.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "iroh", .module = iroh_mod }, .{ .name = "pipe", .module = pipe_mod } } });
    const gate_imports = [_]std.Build.Module.Import{
        .{ .name = "core", .module = core_mod },
        .{ .name = "pipe", .module = pipe_mod },
        .{ .name = "simnet", .module = simnet_mod },
        .{ .name = "simlink", .module = simlink_mod },
    };
    const gate_args: []const []const u8 = if (b.args) |a| a else &.{ "run", "all" };
    for ([_]bool{ false, true }) |with_iroh| {
        const opts = b.addOptions();
        opts.addOption(bool, "iroh", with_iroh);
        const m = b.createModule(.{ .root_source_file = b.path("tools/gate/main.zig"), .target = target, .optimize = optimize, .imports = &gate_imports });
        m.addOptions("gate_options", opts);
        if (with_iroh) {
            m.addImport("iroh", iroh_mod);
            m.addImport("iroh_pipe", iroh_pipe_mod);
        }
        if (target.result.os.tag == .windows) m.linkSystemLibrary("winmm", .{});
        const exe = b.addExecutable(.{ .name = if (with_iroh) "gate" else "gate-sim", .root_module = m });
        const run = b.addRunArtifact(exe);
        if (with_iroh) {
            run.addArgs(gate_args);
            b.step("gate", "Run the Phase 1 gate over iroh and the sim (builds the shim; args: see tools/gate/main.zig)").dependOn(&run.step);
            const run_all = b.addRunArtifact(exe);
            run_all.addArgs(&.{ "run", "all" });
            b.top_level_steps.get("test-shim").?.step.dependOn(&run_all.step);
        } else {
            run.addArgs(if (b.args) |a| a else &.{ "run", "sim" });
            b.step("gate-sim", "Run the Phase 1 gate over the simulated network only (no Rust needed)").dependOn(&run.step);
        }
    }
    const gate_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/gate/test.zig"), .target = target, .optimize = optimize, .imports = &gate_imports }) });
    test_sim.dependOn(&b.addRunArtifact(gate_tests).step);
    test_sim.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = simlink_mod })).step);

    // The audio stream with real libopus over the simulated network (sim/audio.zig).
    // codec/opus/stage.zig: Opus plus core/audio, the host and client ends of the audio stage.
    const audio_stage_mod = b.addModule("audio_stage", .{ .root_source_file = b.path("codec/opus/stage.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "core", .module = core_mod }, .{ .name = "opus", .module = opus.module } } });
    const audio_imports: []const std.Build.Module.Import = &.{ .{ .name = "simnet", .module = simnet_mod }, .{ .name = "core", .module = core_mod }, .{ .name = "opus", .module = opus.module }, .{ .name = "audio_stage", .module = audio_stage_mod } };
    const audio_sim = b.addExecutable(.{ .name = "audio-sim", .root_module = b.createModule(.{ .root_source_file = b.path("sim/audio_main.zig"), .target = target, .optimize = optimize, .imports = audio_imports }) });
    const run_audio_sim = b.addRunArtifact(audio_sim);
    if (b.args) |a| run_audio_sim.addArgs(a);
    b.step("audio-sim", "Run the audio scenarios with libopus over the sim and print a table").dependOn(&run_audio_sim.step);
    const audio_tests = b.addRunArtifact(b.addTest(.{ .name = "audio-sim-test", .root_module = b.createModule(.{ .root_source_file = b.path("sim/audio.zig"), .target = target, .optimize = optimize, .imports = audio_imports }) }));
    b.step("test-audio", "Run the libopus binding tests and the audio sim scenarios").dependOn(&audio_tests.step);
    b.top_level_steps.get("test-audio").?.step.dependOn(&run_opus_tests.step);
    const stage_tests = b.addRunArtifact(b.addTest(.{ .name = "audio-stage-test", .root_module = audio_stage_mod }));
    b.top_level_steps.get("test-audio").?.step.dependOn(&stage_tests.step);
    test_sim.dependOn(&stage_tests.step);
    test_sim.dependOn(&audio_tests.step);

    // Phase 2 session spine (app/): host and client sessions, the apps over any
    // platform backend, and the `moonsec` tool (sim runs, soak, iroh, test pattern).
    const app_imports = [_]std.Build.Module.Import{
        .{ .name = "core", .module = core_mod },
        .{ .name = "pipe", .module = pipe_mod },
        .{ .name = "platform", .module = platform_mod },
        .{ .name = "synthetic", .module = synthetic_mod },
        .{ .name = "simnet", .module = simnet_mod },
        .{ .name = "simlink", .module = simlink_mod },
        .{ .name = "audio_stage", .module = audio_stage_mod },
    };
    const app_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("app/test.zig"), .target = target, .optimize = optimize, .imports = &app_imports }) });
    const test_app = b.step("test-app", "Host and client apps end to end over the in-process sim");
    test_app.dependOn(&b.addRunArtifact(app_tests).step);
    test_step.dependOn(test_app);
    for ([_]bool{ false, true }) |with_iroh| {
        const opts = b.addOptions();
        opts.addOption(bool, "iroh", with_iroh);
        const m = b.createModule(.{ .root_source_file = b.path("app/main.zig"), .target = target, .optimize = optimize, .imports = &app_imports });
        m.addOptions("app_options", opts);
        if (with_iroh) {
            m.addImport("iroh", iroh_mod);
            m.addImport("iroh_pipe", iroh_pipe_mod);
        }
        if (target.result.os.tag == .windows) m.linkSystemLibrary("winmm", .{});
        const exe = b.addExecutable(.{ .name = if (with_iroh) "moonsec" else "moonsec-sim", .root_module = m });
        const run = b.addRunArtifact(exe);
        if (b.args) |a| run.addArgs(a);
        if (with_iroh) {
            if (b.args == null) run.addArgs(&.{ "run", "all" });
            b.step("moonsec", "Run the moonsec tool with the iroh shim (default: `run all`; args: see app/main.zig)").dependOn(&run.step);
            const install = b.addInstallArtifact(exe, .{});
            b.step("install-moonsec", "Install zig-out/bin/moonsec (builds the shim)").dependOn(&install.step);
            const run_all = b.addRunArtifact(exe);
            run_all.addArgs(&.{ "run", "all", "--seconds", "8" });
            b.top_level_steps.get("test-shim").?.step.dependOn(&run_all.step);
            // Pairing (QR ticket, PIN) and session admission, end to end over iroh.
            const run_pair = b.addRunArtifact(exe);
            run_pair.addArgs(&.{ "run", "pair", "--seconds", "3" });
            run_pair.step.dependOn(&run_all.step); // one loopback run at a time
            b.top_level_steps.get("test-shim").?.step.dependOn(&run_pair.step);
            const run_pair_only = b.addRunArtifact(exe);
            run_pair_only.addArgs(&.{ "run", "pair", "--seconds", "3" });
            b.step("test-pair", "Pairing and admission end to end over iroh on loopback (builds the shim)").dependOn(&run_pair_only.step);
        } else {
            if (b.args == null) run.addArgs(&.{ "sim", "--seconds", "10" });
            b.step("moonsec-sim", "Run the moonsec tool without the shim (sim, soak, run sim, pattern)").dependOn(&run.step);
            b.installArtifact(exe);
            const soak = b.addRunArtifact(exe);
            soak.addArgs(if (b.args) |a| a else &.{ "soak", "--seconds", "3600" });
            b.step("soak", "One hour of streaming over the simulated LAN in virtual time (args override)").dependOn(&soak.step);
        }
    }

    // core/rate driving the simulated network with S11's metrics (sim/rate.zig).
    const sim_rate = b.addExecutable(.{ .name = "sim-rate", .root_module = b.createModule(.{ .root_source_file = b.path("sim/rate.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "simnet", .module = simnet_mod }, .{ .name = "core", .module = core_mod } } }) });
    b.installArtifact(sim_rate);
    const run_sim_rate = b.addRunArtifact(sim_rate);
    if (b.args) |a| run_sim_rate.addArgs(a);
    b.step("sim-rate", "Run core/rate over the S11 scenarios and print S11's metrics").dependOn(&run_sim_rate.step);

    // Windows platform (platform/windows): COM/D3D11/DXGI code in small C files compiled
    // by zig cc against Zig's bundled mingw-w64 headers; Zig sees only msw.h's C ABI.
    // `check-win` cross-compiles the Windows tests from any host; `test-win` runs them
    // and needs a Windows host.
    const check_win = b.step("check-win", "Cross-compile the Windows platform tests for x86_64 and aarch64 Windows");
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const wt = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .windows, .abi = .gnu });
        const t = b.addTest(.{ .name = b.fmt("win-test-{s}", .{@tagName(arch)}), .root_module = windowsTestModule(b, wt, optimize) });
        // Install (not just compile) so the link step runs and catches missing import libs/IIDs.
        check_win.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "win-test" } } }).step);
    }
    const test_win = b.step("test-win", "Run the Windows platform tests (Windows host; WARP and software paths run without a GPU)");
    if (target.result.os.tag == .windows) {
        const t = b.addTest(.{ .name = "win-test", .root_module = windowsTestModule(b, target, optimize) });
        test_win.dependOn(&b.addRunArtifact(t).step);
    } else {
        test_win.dependOn(&b.addFail("test-win needs a Windows host; use check-win to cross-compile").step);
    }
    // Windows client backend tests join both steps (platform/client/build.zig).
    @import("platform/client/build.zig").addWindowsTests(b, target, optimize, check_win, test_win);
}

/// Compiler flags for every C file under platform/ on Windows.
pub const windows_c_flags: []const []const u8 = &.{
    "-std=c11",              "-Wall",     "-Wextra",    "-Werror",
    "-Wno-unused-parameter", "-DUNICODE", "-D_UNICODE",
};

/// Adds Windows C sources (paths relative to the repo root) to `m`, with
/// platform/windows on the include path so they can include msw_internal.h, and
/// links the given system libraries (resolved from Zig's mingw-w64 import libs).
pub fn addWindowsC(b: *std.Build, m: *std.Build.Module, files: []const []const u8, libs: []const []const u8) void {
    m.link_libc = true;
    m.addIncludePath(b.path("platform/windows"));
    m.addCSourceFiles(.{ .root = b.path("."), .files = files, .flags = windows_c_flags });
    for (libs) |l| m.linkSystemLibrary(l, .{});
}

/// Translates a Zig-facing platform header (one that does not include windows.h).
pub fn translatePlatformHeader(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, header: []const u8) *std.Build.Module {
    const tc = b.addTranslateC(.{ .root_source_file = b.path(header), .target = target, .optimize = optimize });
    tc.addIncludePath(b.path("platform/windows"));
    return tc.createModule();
}

/// The shared Windows module ("win", platform/windows/win.zig) with msw.c linked in.
/// Host and client backends import it and add their own C files with addWindowsC.
pub fn windowsModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("platform/windows/win.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "msw_c", .module = translatePlatformHeader(b, target, optimize, "platform/windows/msw.h") }},
    });
    addWindowsC(b, m, &.{"platform/windows/msw.c"}, &.{ "d3d11", "dxgi", "ole32", "uuid" });
    return m;
}

fn windowsTestModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("platform/windows/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "win", .module = windowsModule(b, target, optimize) }},
    });
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

/// Targets `check-opus` cross-compiles libopus for. Windows MSVC needs the Windows SDK, so
/// CI builds it natively on the Windows runner instead (`-Dtarget=x86_64-windows-msvc`).
const opus_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

const Opus = struct {
    lib: *std.Build.Step.Compile,
    /// The Zig binding (codec/opus/opus.zig), linked against `lib`. Import it as "opus".
    module: *std.Build.Module,
};

fn addOpus(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Opus {
    const src = b.dependency("opus", .{});
    const lib = @import("codec/opus/libopus.zig").library(b, src, target, optimize);
    const translate = b.addTranslateC(.{ .root_source_file = b.path("codec/opus/ctl.h"), .target = target, .optimize = optimize });
    translate.addIncludePath(src.path("include"));
    const m = b.createModule(.{
        .root_source_file = b.path("codec/opus/opus.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "opus_c", .module = translate.createModule() }},
    });
    m.addIncludePath(src.path("include"));
    m.addCSourceFile(.{ .file = b.path("codec/opus/ctl.c"), .flags = &.{"-fno-sanitize=undefined"} });
    m.linkLibrary(lib);
    return .{ .lib = lib, .module = m };
}
