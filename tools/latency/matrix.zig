//! The Phase 4 gate (docs/design.md): every host/client pair in the target table streams
//! with the Phase 2 latency bar, glass-to-glass within 5 ms of Moonlight at 1080p60.
//!
//! A manifest lists the measurements, one per line; paths are relative to it:
//!
//!   # comment
//!   bar margin_ms=5 min_edges=10 min_frames=100 [max_ms=N]
//!   target HOST CLIENT                      (repeat; default: the design's target table)
//!   run host=H client=C stack=moonsec|reference method=photodiode|camera|screenshot
//!       file=PATH [name="Moonlight 6.1"] [mode=1080p60] [host_crop=X,Y,W,H]
//!       [client_crop=X,Y,W,H] [max_latency_ms=500]
//!
//! (a `run` is one line). Each moonsec run is held to the reference run for the same pair
//! and method: its latency at most the reference's plus `margin_ms`. Photodiode runs
//! compare medians of the edges; camera and screenshot runs compare means of the frames
//! (a frame's sample is quantized to the screens' refresh, so only the mean is unbiased).
//! With no reference for a method, `max_ms` (if set) is the bar instead. A pair passes when
//! it has at least one moonsec run and every one passes; the gate passes when every target
//! pair does.
const std = @import("std");
const analyze = @import("analyze.zig");

const Io = std.Io;
const Micros = i64;

pub const Stack = enum { moonsec, reference };
pub const Method = enum {
    photodiode,
    camera,
    screenshot,

    pub fn statName(m: Method) []const u8 {
        return if (m == .photodiode) "median" else "mean";
    }
};

pub const Bar = struct {
    margin_ms: f64 = 5,
    min_edges: usize = 10,
    min_frames: usize = 100,
    /// Absolute bar for a method with no reference run (null: such a run fails).
    max_ms: ?f64 = null,
};

pub const Pair = struct {
    host: []const u8,
    client: []const u8,

    fn eql(a: Pair, b: Pair) bool {
        return std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.client, b.client);
    }
};

/// The target table in docs/design.md: hosts Windows and macOS, clients Windows, macOS
/// and Linux (the browser is Phase 6, the Linux host Phase 7).
pub const default_hosts = [_][]const u8{ "windows", "macos" };
pub const default_clients = [_][]const u8{ "windows", "macos", "linux" };

pub const Run = struct {
    pair: Pair,
    stack: Stack,
    method: Method,
    file: []const u8,
    name: []const u8 = "",
    mode: []const u8 = "",
    host_crop: ?analyze.Rect = null,
    client_crop: ?analyze.Rect = null,
    max_latency_us: Micros = 500_000,
    line: usize = 0,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    bar: Bar = .{},
    targets: []Pair = &.{},
    runs: []Run = &.{},

    pub fn deinit(m: *Manifest) void {
        m.arena.deinit();
    }

    /// Parse manifest text. On error, `err_line` is the line at fault.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8, err_line: *usize) !Manifest {
        var m: Manifest = .{ .arena = .init(gpa) };
        errdefer m.arena.deinit();
        const a = m.arena.allocator();
        var targets: std.ArrayList(Pair) = .empty;
        var runs: std.ArrayList(Run) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var ln: usize = 0;
        while (lines.next()) |raw| {
            ln += 1;
            err_line.* = ln;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var toks: Tokens = .{ .s = line };
            const kw = toks.next() orelse continue;
            if (std.mem.eql(u8, kw, "target")) {
                const h = toks.next() orelse return error.BadManifest;
                const c = toks.next() orelse return error.BadManifest;
                if (toks.next() != null) return error.BadManifest;
                try targets.append(a, .{ .host = try a.dupe(u8, h), .client = try a.dupe(u8, c) });
            } else if (std.mem.eql(u8, kw, "bar")) {
                while (toks.next()) |kv| {
                    const k, const v = try splitKv(kv);
                    if (std.mem.eql(u8, k, "margin_ms")) {
                        m.bar.margin_ms = try std.fmt.parseFloat(f64, v);
                    } else if (std.mem.eql(u8, k, "min_edges")) {
                        m.bar.min_edges = try std.fmt.parseInt(usize, v, 10);
                    } else if (std.mem.eql(u8, k, "min_frames")) {
                        m.bar.min_frames = try std.fmt.parseInt(usize, v, 10);
                    } else if (std.mem.eql(u8, k, "max_ms")) {
                        m.bar.max_ms = try std.fmt.parseFloat(f64, v);
                    } else return error.BadManifest;
                }
            } else if (std.mem.eql(u8, kw, "run")) {
                var host: ?[]const u8 = null;
                var client: ?[]const u8 = null;
                var stack: ?Stack = null;
                var method: ?Method = null;
                var r: Run = .{ .pair = undefined, .stack = undefined, .method = undefined, .file = "", .line = ln };
                while (toks.next()) |kv| {
                    const k, const v = try splitKv(kv);
                    const eq = std.mem.eql;
                    if (eq(u8, k, "host")) {
                        host = try a.dupe(u8, v);
                    } else if (eq(u8, k, "client")) {
                        client = try a.dupe(u8, v);
                    } else if (eq(u8, k, "stack")) {
                        stack = std.meta.stringToEnum(Stack, v) orelse return error.BadManifest;
                    } else if (eq(u8, k, "method")) {
                        method = std.meta.stringToEnum(Method, v) orelse return error.BadManifest;
                    } else if (eq(u8, k, "file")) {
                        r.file = try a.dupe(u8, v);
                    } else if (eq(u8, k, "name")) {
                        r.name = try a.dupe(u8, v);
                    } else if (eq(u8, k, "mode")) {
                        r.mode = try a.dupe(u8, v);
                    } else if (eq(u8, k, "host_crop")) {
                        r.host_crop = try analyze.Rect.parse(v);
                    } else if (eq(u8, k, "client_crop")) {
                        r.client_crop = try analyze.Rect.parse(v);
                    } else if (eq(u8, k, "max_latency_ms")) {
                        r.max_latency_us = 1000 * try std.fmt.parseInt(Micros, v, 10);
                    } else return error.BadManifest;
                }
                r.pair = .{ .host = host orelse return error.BadManifest, .client = client orelse return error.BadManifest };
                r.stack = stack orelse return error.BadManifest;
                r.method = method orelse return error.BadManifest;
                if (r.file.len == 0) return error.BadManifest;
                try runs.append(a, r);
            } else return error.BadManifest;
        }
        if (targets.items.len == 0) {
            for (default_hosts) |h| for (default_clients) |c| try targets.append(a, .{ .host = h, .client = c });
        }
        m.targets = targets.items;
        m.runs = runs.items;
        return m;
    }
};

/// Space-separated tokens; a value may be double-quoted (`name="Moonlight 6.1"`).
const Tokens = struct {
    s: []const u8,
    i: usize = 0,

    fn next(t: *Tokens) ?[]const u8 {
        while (t.i < t.s.len and (t.s[t.i] == ' ' or t.s[t.i] == '\t')) t.i += 1;
        if (t.i == t.s.len) return null;
        const start = t.i;
        var quoted = false;
        while (t.i < t.s.len) : (t.i += 1) {
            const c = t.s[t.i];
            if (c == '"') quoted = !quoted;
            if (!quoted and (c == ' ' or c == '\t')) break;
        }
        return t.s[start..t.i];
    }
};

fn splitKv(kv: []const u8) !struct { []const u8, []const u8 } {
    const i = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadManifest;
    var v = kv[i + 1 ..];
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
    return .{ kv[0..i], v };
}

// ---------------------------------------------------------------------------
// Measuring

pub const Measured = struct {
    run: Run,
    stats: analyze.Stats = .{},
    /// Photodiode: host and client edges, unmatched client edges. Frames: frames,
    /// barcode reads, digit reads, unreadable, rejected.
    counts: [5]usize = @splat(0),
    /// Why the input could not be measured.
    err: ?[]const u8 = null,

    /// The number held to the bar: median for photodiode, mean for frames.
    pub fn value_us(m: Measured) f64 {
        return if (m.run.method == .photodiode) @floatFromInt(m.stats.p50_us) else m.stats.mean_us;
    }

    pub fn enough(m: Measured, bar: Bar) bool {
        return m.err == null and m.stats.n >= (if (m.run.method == .photodiode) bar.min_edges else bar.min_frames);
    }
};

/// Analyze one run's input file, relative to `dir`.
pub fn measure(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, r: Run) Measured {
    var out: Measured = .{ .run = r };
    measureInner(gpa, io, dir, &out) catch |e| {
        out.err = @errorName(e);
    };
    return out;
}

fn measureInner(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, out: *Measured) !void {
    const r = out.run;
    switch (r.method) {
        .photodiode => {
            const text = try dir.readFileAlloc(io, r.file, gpa, .limited(1 << 30));
            defer gpa.free(text);
            var res = try analyze.photodiode(gpa, text, .{ .max_latency_us = r.max_latency_us });
            defer res.deinit(gpa);
            out.stats = try analyze.Stats.of(gpa, res.samples);
            out.counts = .{ res.host_edges, res.client_edges, res.unmatched, 0, 0 };
        },
        .camera, .screenshot => {
            var f: analyze.Frames = .{ .o = .{ .host = r.host_crop, .client = r.client_crop, .max_latency_us = r.max_latency_us } };
            defer f.deinit(gpa);
            try f.addPath(gpa, io, dir, r.file);
            out.stats = try analyze.Stats.of(gpa, f.samples.items);
            out.counts = .{ f.frames, f.barcode, f.digits, f.unreadable, f.rejected };
        },
    }
}

pub const Verdict = enum { pass, fail, no_reference, too_few, unreadable, not_measured };

pub const Check = struct {
    moonsec: *const Measured,
    reference: ?*const Measured,
    verdict: Verdict,
    /// Moonsec minus reference, when there is one.
    delta_us: ?f64 = null,
};

pub const Cell = struct {
    pair: Pair,
    target: bool,
    checks: []Check,

    pub fn verdict(c: Cell) Verdict {
        if (c.checks.len == 0) return .not_measured;
        for (c.checks) |k| if (k.verdict != .pass) return k.verdict;
        return .pass;
    }
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    bar: Bar,
    measured: []Measured,
    cells: []Cell,
    hosts: [][]const u8,
    clients: [][]const u8,

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
    }

    pub fn passed(r: Report) bool {
        for (r.cells) |c| if (c.target and c.verdict() != .pass) return false;
        return true;
    }

    pub fn targetsPassing(r: Report) [2]usize {
        var n: [2]usize = .{ 0, 0 };
        for (r.cells) |c| if (c.target) {
            n[1] += 1;
            if (c.verdict() == .pass) n[0] += 1;
        };
        return n;
    }

    fn cell(r: Report, host: []const u8, client: []const u8) ?Cell {
        for (r.cells) |c| if (c.pair.eql(.{ .host = host, .client = client })) return c;
        return null;
    }

    pub fn write(r: Report, w: *Io.Writer) !void {
        const n = r.targetsPassing();
        try w.print("# Glass-to-glass latency by host and client\n\n", .{});
        try w.print("**Gate: {s}** ({d} of {d} target pairs pass).\n\n", .{ if (r.passed()) "PASS" else "FAIL", n[0], n[1] });
        try w.print("Bar (Phase 2, docs/design.md): moonsec within {d:.1} ms of the reference stack on the same pair, measured the same way", .{r.bar.margin_ms});
        if (r.bar.max_ms) |m| try w.print(", or at most {d:.1} ms where a method has no reference", .{m});
        try w.print(". Photodiode runs compare the median edge delay (at least {d} edges), camera and screenshot runs the mean over frames (at least {d}).\n\n", .{ r.bar.min_edges, r.bar.min_frames });

        try w.writeAll("| host \\ client |");
        for (r.clients) |c| try w.print(" {s} |", .{c});
        try w.writeAll("\n| --- |");
        for (r.clients) |_| try w.writeAll(" --- |");
        try w.writeAll("\n");
        for (r.hosts) |h| {
            try w.print("| **{s}** |", .{h});
            for (r.clients) |c| {
                const ce = r.cell(h, c) orelse {
                    try w.writeAll(" |");
                    continue;
                };
                try w.writeAll(" ");
                try writeCell(w, ce);
                try w.writeAll(" |");
            }
            try w.writeAll("\n");
        }
        try w.writeAll("\nNot a target pair: *italic*. Each line in a cell is one method: moonsec's number, then the reference's and the difference.\n\n");

        try w.writeAll("## Runs\n\n| host | client | stack | method | mode | n | median | mean | p95 | p99 | max | notes | file |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
        for (r.measured) |m| {
            const run = m.run;
            const stack = if (run.name.len > 0) run.name else @tagName(run.stack);
            try w.print("| {s} | {s} | {s} | {s} | {s} | {d} | ", .{ run.pair.host, run.pair.client, stack, @tagName(run.method), run.mode, m.stats.n });
            if (m.stats.n > 0) {
                const s = m.stats;
                try w.print("{d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | ", .{ analyze.ms(s.p50_us), analyze.ms(s.mean_us), analyze.ms(s.p95_us), analyze.ms(s.p99_us), analyze.ms(s.max_us) });
            } else try w.writeAll("– | – | – | – | – | ");
            if (m.err) |e| {
                try w.print("error: {s}", .{e});
            } else if (run.method == .photodiode) {
                try w.print("{d} host edges, {d} client edges, {d} unmatched", .{ m.counts[0], m.counts[1], m.counts[2] });
            } else {
                try w.print("{d} frames: {d} barcode, {d} digits, {d} unreadable, {d} rejected", .{ m.counts[0], m.counts[1], m.counts[2], m.counts[3], m.counts[4] });
            }
            try w.print(" | `{s}` |\n", .{run.file});
        }
    }

    fn writeCell(w: *Io.Writer, c: Cell) !void {
        const v = c.verdict();
        const it = if (c.target) "" else "*";
        if (v == .not_measured) return w.print("{s}not measured{s}", .{ it, it });
        try w.print("{s}**{s}**{s}", .{ it, verdictName(v), it });
        for (c.checks) |k| {
            const m = k.moonsec;
            try w.print("<br>{s} {s}: ", .{ @tagName(m.run.method), m.run.method.statName() });
            if (m.err) |e| {
                try w.print("error ({s})", .{e});
                continue;
            }
            try w.print("{d:.1} ms", .{analyze.ms(m.value_us())});
            if (k.reference) |ref| {
                if (ref.err != null or ref.stats.n == 0) {
                    try w.writeAll(" (reference unreadable)");
                } else try w.print(" (ref {d:.1}, {s}{d:.1})", .{ analyze.ms(ref.value_us()), if (k.delta_us.? >= 0) "+" else "", analyze.ms(k.delta_us.?) });
            } else if (k.verdict == .no_reference) {
                try w.writeAll(" (no reference)");
            }
            if (k.verdict == .too_few) try w.print(" (only {d} samples)", .{m.stats.n});
        }
    }
};

pub fn verdictName(v: Verdict) []const u8 {
    return switch (v) {
        .pass => "PASS",
        .fail => "FAIL",
        .no_reference => "NO REFERENCE",
        .too_few => "TOO FEW SAMPLES",
        .unreadable => "UNREADABLE",
        .not_measured => "NOT MEASURED",
    };
}

fn dupePair(a: std.mem.Allocator, p: Pair) !Pair {
    return .{ .host = try a.dupe(u8, p.host), .client = try a.dupe(u8, p.client) };
}

fn addName(a: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, s)) return;
    try list.append(a, s);
}

/// Hold the measurements to the bar. The report copies what it keeps.
pub fn evaluate(gpa: std.mem.Allocator, m: Manifest, measured_in: []const Measured) !Report {
    var rep: Report = .{ .arena = .init(gpa), .bar = m.bar, .measured = &.{}, .cells = &.{}, .hosts = &.{}, .clients = &.{} };
    errdefer rep.arena.deinit();
    const a = rep.arena.allocator();
    rep.measured = try a.dupe(Measured, measured_in);
    // The report outlives the manifest: own every string.
    for (rep.measured) |*x| {
        x.run.pair = try dupePair(a, x.run.pair);
        x.run.file = try a.dupe(u8, x.run.file);
        x.run.name = try a.dupe(u8, x.run.name);
        x.run.mode = try a.dupe(u8, x.run.mode);
    }

    var hosts: std.ArrayList([]const u8) = .empty;
    var clients: std.ArrayList([]const u8) = .empty;
    var pairs: std.ArrayList(Pair) = .empty;
    for (m.targets) |t| {
        const p = try dupePair(a, t);
        try addName(a, &hosts, p.host);
        try addName(a, &clients, p.client);
        try pairs.append(a, p);
    }
    for (rep.measured) |x| {
        try addName(a, &hosts, x.run.pair.host);
        try addName(a, &clients, x.run.pair.client);
        for (pairs.items) |p| {
            if (p.eql(x.run.pair)) break;
        } else try pairs.append(a, x.run.pair);
    }
    rep.hosts = hosts.items;
    rep.clients = clients.items;

    var cells: std.ArrayList(Cell) = .empty;
    for (pairs.items, 0..) |p, pi| {
        var checks: std.ArrayList(Check) = .empty;
        for (rep.measured) |*x| {
            if (x.run.stack != .moonsec or !x.run.pair.eql(p)) continue;
            var ref: ?*const Measured = null;
            for (rep.measured) |*y| {
                if (y.run.stack == .reference and y.run.pair.eql(p) and y.run.method == x.run.method) ref = y;
            }
            var k: Check = .{ .moonsec = x, .reference = ref, .verdict = .pass };
            if (x.err != null) {
                k.verdict = .unreadable;
            } else if (!x.enough(m.bar)) {
                k.verdict = .too_few;
            } else if (ref) |r| {
                if (r.err != null) {
                    k.verdict = .unreadable;
                } else if (!r.enough(m.bar)) {
                    k.verdict = .too_few;
                } else {
                    k.delta_us = x.value_us() - r.value_us();
                    if (k.delta_us.? > m.bar.margin_ms * 1000) k.verdict = .fail;
                }
            } else if (m.bar.max_ms) |mx| {
                if (x.value_us() > mx * 1000) k.verdict = .fail;
            } else k.verdict = .no_reference;
            try checks.append(a, k);
        }
        try cells.append(a, .{ .pair = p, .target = pi < m.targets.len, .checks = checks.items });
    }
    rep.cells = cells.items;
    return rep;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "manifest parses, defaults to the design's target table" {
    var line: usize = 0;
    var m = try Manifest.parse(testing.allocator,
        \\# lab, Nov 2026
        \\bar margin_ms=4.5 min_edges=3
        \\run host=windows client=linux stack=moonsec method=camera file=cam/ host_crop=0,0,640,360 client_crop=640,0,640,360 mode=1080p60
        \\run host=windows client=linux stack=reference name="Moonlight 6.1" method=camera file=ml.ppm
    , &line);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 6), m.targets.len);
    try testing.expectEqual(@as(f64, 4.5), m.bar.margin_ms);
    try testing.expectEqual(@as(usize, 3), m.bar.min_edges);
    try testing.expectEqual(@as(usize, 2), m.runs.len);
    try testing.expectEqualStrings("Moonlight 6.1", m.runs[1].name);
    try testing.expectEqual(@as(u32, 640), m.runs[0].client_crop.?.x);
    try testing.expectEqual(Method.camera, m.runs[0].method);

    try testing.expectError(error.BadManifest, Manifest.parse(testing.allocator, "run host=a client=b stack=moonsec file=x\n", &line));
    try testing.expectEqual(@as(usize, 1), line);
    try testing.expectError(error.BadManifest, Manifest.parse(testing.allocator, "\nbogus\n", &line));
    try testing.expectEqual(@as(usize, 2), line);
}

fn fake(host: []const u8, client: []const u8, stack: Stack, method: Method, value_ms: f64, n: usize) Measured {
    const us: Micros = @intFromFloat(value_ms * 1000);
    return .{
        .run = .{ .pair = .{ .host = host, .client = client }, .stack = stack, .method = method, .file = "f" },
        .stats = .{ .n = n, .mean_us = value_ms * 1000, .p50_us = us, .p95_us = us, .p99_us = us, .min_us = us, .max_us = us },
    };
}

test "evaluate: margin against the reference, per method, every target pair" {
    var line: usize = 0;
    var m = try Manifest.parse(testing.allocator,
        \\bar margin_ms=5 min_edges=10 min_frames=100
        \\target windows windows
        \\target windows linux
        \\target macos linux
    , &line);
    defer m.deinit();
    const ms = [_]Measured{
        // windows/windows: within 5 ms by photodiode, over by camera.
        fake("windows", "windows", .moonsec, .photodiode, 34, 30),
        fake("windows", "windows", .reference, .photodiode, 30, 30),
        fake("windows", "windows", .moonsec, .camera, 40, 500),
        fake("windows", "windows", .reference, .camera, 30, 500),
        // windows/linux: passes.
        fake("windows", "linux", .moonsec, .photodiode, 20, 30),
        fake("windows", "linux", .reference, .photodiode, 19, 30),
        // macos/linux: no reference.
        fake("macos", "linux", .moonsec, .photodiode, 20, 30),
        // Not a target: too few edges.
        fake("linux", "linux", .moonsec, .photodiode, 20, 3),
    };
    var r = try evaluate(testing.allocator, m, &ms);
    defer r.deinit();
    try testing.expect(!r.passed());
    try testing.expectEqual([2]usize{ 1, 3 }, r.targetsPassing());
    try testing.expectEqual(Verdict.fail, r.cell("windows", "windows").?.verdict());
    try testing.expectEqual(Verdict.pass, r.cell("windows", "linux").?.verdict());
    try testing.expectEqual(Verdict.no_reference, r.cell("macos", "linux").?.verdict());
    try testing.expectEqual(Verdict.too_few, r.cell("linux", "linux").?.verdict());
    try testing.expect(!r.cell("linux", "linux").?.target);

    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try r.write(&aw.writer);
    const md = aw.written();
    try testing.expect(std.mem.indexOf(u8, md, "**Gate: FAIL** (1 of 3 target pairs pass)") != null);
    try testing.expect(std.mem.indexOf(u8, md, "camera mean: 40.0 ms (ref 30.0, +10.0)") != null);
    try testing.expect(std.mem.indexOf(u8, md, "| **macos** | NOT MEASURED") == null);

    // An absolute bar stands in where there is no reference.
    m.bar.max_ms = 25;
    var r2 = try evaluate(testing.allocator, m, &ms);
    defer r2.deinit();
    try testing.expectEqual(Verdict.pass, r2.cell("macos", "linux").?.verdict());
}
