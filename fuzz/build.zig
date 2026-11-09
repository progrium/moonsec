//! Build steps for the fuzz harnesses (fuzz/, docs/fuzzing.md). Called from the root
//! build.zig.
//!
//!   zig build fuzz                     replay every harness's corpus once (a plain test run)
//!   zig build fuzz --fuzz              fuzz every harness on all cores, with the web UI
//!   zig build fuzz --fuzz=1M           fuzz on one core for a million runs, then report
//!   zig build fuzz -Dfuzz-filter=pair_ticket,clock   only harnesses matching one of these
//!   zig build fuzz-repro               zig-out/bin/fuzz-repro <harness> <input>...
//!   zig build fuzz-wasm                replay the corpora on wasm32-wasi under Node
//!
//! `zig build test` also replays the corpora (fuzz/corpus/ holds saved crashes), so a fixed
//! crash stays fixed. tools/fuzz/run.sh runs long campaigns.
const std = @import("std");

pub const Modules = struct {
    core: *std.Build.Module,
    platform: *std.Build.Module,
    synthetic: *std.Build.Module,
};

pub const Opus = struct {
    opus: *std.Build.Module,
    audio_stage: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    m: Modules,
    makeOpus: *const fn (*std.Build, std.Build.ResolvedTarget, std.builtin.OptimizeMode, *std.Build.Module) Opus,
    test_step: *std.Build.Step,
    wasm_step: *std.Build.Step,
) void {
    const filter = b.option([]const u8, "fuzz-filter", "Only harnesses whose test name contains one of these (comma-separated)");
    var filters: std.ArrayList([]const u8) = .empty;
    if (filter) |f| {
        var it = std.mem.tokenizeScalar(u8, f, ',');
        while (it.next()) |one| filters.append(b.allocator, one) catch @panic("OOM");
    }
    const corpus = corpusModule(b);

    // The fuzzer needs coverage instrumentation, which Zig 0.16 only emits with
    // optimizations on; ReleaseSafe keeps every safety check, which is what we hunt.
    const fuzz_opt: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSafe else optimize;
    const fuzz_tests = b.addTest(.{
        .name = "fuzz",
        .root_module = harnessModule(b, target, fuzz_opt, m, makeOpus, corpus, "fuzz/root.zig"),
        .filters = filters.items,
        .test_runner = .{ .path = b.path("fuzz/test_runner.zig"), .mode = .server },
    });
    const fuzz_step = b.step("fuzz", "Replay the fuzz corpora; with --fuzz, fuzz every parser (see fuzz/build.zig)");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // Plain test run of the corpora in the caller's mode, as part of `zig build test`.
    const replay = b.addTest(.{
        .name = "fuzz-replay",
        .root_module = harnessModule(b, target, optimize, m, makeOpus, corpus, "fuzz/root.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(replay).step);

    const repro = b.addExecutable(.{
        .name = "fuzz-repro",
        .root_module = harnessModule(b, target, fuzz_opt, m, makeOpus, corpus, "fuzz/repro.zig"),
    });
    b.step("fuzz-repro", "Install zig-out/bin/fuzz-repro (runs one harness on saved inputs)").dependOn(&b.addInstallArtifact(repro, .{}).step);

    // The web client runs the core on wasm32: the same harnesses, corpora only.
    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasm_tests = b.addTest(.{
        .name = "fuzz-wasm",
        .root_module = harnessModule(b, wasi, .ReleaseSafe, m, makeOpus, corpus, "fuzz/root.zig"),
    });
    wasm_step.dependOn(&wasm_tests.step);
    const run_wasm = b.addSystemCommand(&.{ "node", "--no-warnings" });
    run_wasm.addFileArg(b.path("tools/fuzz/wasi.mjs"));
    run_wasm.addArtifactArg(wasm_tests);
    b.step("fuzz-wasm", "Replay the fuzz corpora on wasm32-wasi under Node (needs node)").dependOn(&run_wasm.step);
}

fn harnessModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    m: Modules,
    makeOpus: *const fn (*std.Build, std.Build.ResolvedTarget, std.builtin.OptimizeMode, *std.Build.Module) Opus,
    corpus: *std.Build.Module,
    root: []const u8,
) *std.Build.Module {
    // Rebuild core and platform for this target and mode so the harness module tree is
    // consistent (the caller's modules are for the caller's target and mode).
    const core = b.createModule(.{ .root_source_file = m.core.root_source_file, .target = target, .optimize = optimize });
    const platform = b.createModule(.{ .root_source_file = m.platform.root_source_file, .target = target, .optimize = optimize, .imports = &.{.{ .name = "core", .module = core }} });
    const synthetic = b.createModule(.{ .root_source_file = m.synthetic.root_source_file, .target = target, .optimize = optimize, .imports = &.{ .{ .name = "core", .module = core }, .{ .name = "platform", .module = platform } } });
    const app_wire = b.createModule(.{ .root_source_file = b.path("app/wire.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "core", .module = core }, .{ .name = "platform", .module = platform } } });
    const opus = makeOpus(b, target, optimize, core);
    // Zig 0.16 instruments the module's C file (codec/opus/ctl.c) for coverage without a
    // matching PC table, and the fuzzer refuses to start ("pc counters length and pcs
    // length do not match"). The binding is a thin wrapper; libopus itself is never
    // instrumented, and its crashes are still caught.
    opus.opus.fuzz = false;
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "app_wire", .module = app_wire },
            .{ .name = "platform", .module = platform },
            .{ .name = "synthetic", .module = synthetic },
            .{ .name = "opus", .module = opus.opus },
            .{ .name = "audio_stage", .module = opus.audio_stage },
            .{ .name = "fuzz_corpus", .module = corpus },
        },
    });
}

/// fuzz/corpus/<harness>/<file> -> `pub const <harness> = [_][]const u8{ @embedFile(...), ... };`
/// Read when the build graph is made, so a new file needs no build.zig change.
fn corpusModule(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    const wf = b.addWriteFiles();
    var src: std.Io.Writer.Allocating = .init(b.allocator);
    const w = &src.writer;
    w.writeAll("// Generated by fuzz/build.zig from fuzz/corpus/.\n") catch @panic("OOM");
    if (b.build_root.handle.openDir(io, "fuzz/corpus", .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |e| if (e.kind == .directory) names.append(b.allocator, b.dupe(e.name)) catch @panic("OOM");
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |name| {
            const sub = dir.openDir(io, name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            var files: std.ArrayList([]const u8) = .empty;
            var fit = sub.iterate();
            while (fit.next(io) catch null) |f| if (f.kind == .file) files.append(b.allocator, b.dupe(f.name)) catch @panic("OOM");
            std.mem.sort([]const u8, files.items, {}, lessThan);
            w.print("pub const {s} = [_][]const u8{{\n", .{name}) catch @panic("OOM");
            for (files.items) |f| {
                const rel = b.fmt("{s}/{s}", .{ name, f });
                _ = wf.addCopyFile(b.path(b.fmt("fuzz/corpus/{s}", .{rel})), rel);
                w.print("    @embedFile(\"{s}\"),\n", .{rel}) catch @panic("OOM");
            }
            w.writeAll("};\n") catch @panic("OOM");
        }
    } else |_| {}
    const root = wf.add("fuzz_corpus.zig", src.written());
    return b.createModule(.{ .root_source_file = root });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
