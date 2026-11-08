//! The gate end to end on the synthetic pair: record it under the simulated photodiode
//! and camera, write the files, measure them through the manifest, and check the numbers
//! against the session's own glass-to-glass telemetry.
const std = @import("std");
const main = @import("main.zig");
const matrix = @import("matrix.zig");
const synth = @import("synth.zig");

const testing = std.testing;
const io = testing.io;

const quick: synth.Options = .{
    .sim = .{ .width = 256, .height = 144, .seconds = 6 },
    .camera_seconds = 3,
};

fn find(rep: matrix.Report, stack: matrix.Stack, method: matrix.Method) matrix.Measured {
    for (rep.measured) |m| if (m.run.stack == stack and m.run.method == method) return m;
    unreachable;
}

test "synthetic pair: photodiode and camera agree with the session, gate passes on LAN" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try main.writeSynthetic(gpa, io, tmp.dir, quick, .clean, null);
    var rep = try main.runManifest(gpa, io, tmp.dir, "manifest.txt");
    defer rep.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try rep.write(&aw.writer);
    if (!rep.passed()) {
        std.debug.print("{s}\n", .{aw.written()});
        return error.GateFailed;
    }
    try testing.expectEqual([2]usize{ 1, 1 }, rep.targetsPassing());

    // What the session measured for itself, from the manifest's comment.
    const text = try tmp.dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16));
    defer gpa.free(text);
    const key = "# moonsec: the session's own telemetry says glass-to-glass p50 ";
    const at = std.mem.indexOf(u8, text, key).? + key.len;
    const sp = std.mem.indexOfScalarPos(u8, text, at, ' ').?;
    const session_ms = try std.fmt.parseFloat(f64, text[at..sp]);

    const pd = find(rep, .moonsec, .photodiode);
    const cam = find(rep, .moonsec, .camera);
    // 6 s: a rising and a falling edge a second, less the first second.
    try testing.expect(pd.stats.n >= 9);
    try testing.expectEqual(@as(usize, 0), pd.counts[2]);
    // Edges are interpolated between 250 µs samples, both diodes lag alike.
    try testing.expectApproxEqAbs(session_ms, pd.value_us() / 1000, 1.0);
    // 3 s at 125 fps; glare on every seventh frame sends those to the digits.
    try testing.expectEqual(@as(usize, 375), cam.counts[0]);
    try testing.expect(cam.counts[2] >= 50);
    try testing.expectEqual(@as(usize, 0), cam.counts[3] + cam.counts[4]);
    // Frame samples are 0 or one frame, so the mean is the estimate.
    try testing.expectApproxEqAbs(session_ms, cam.value_us() / 1000, 2.0);
}

test "synthetic pair: the gate fails when moonsec is 9 ms slower than the reference" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var o = quick;
    o.sim.profile = .wan; // 10 ms each way vs 1 ms on the reference's clean link
    try main.writeSynthetic(gpa, io, tmp.dir, o, .clean, null);
    var rep = try main.runManifest(gpa, io, tmp.dir, "manifest.txt");
    defer rep.deinit();
    try testing.expect(!rep.passed());
    for (rep.cells[0].checks) |k| {
        try testing.expectEqual(matrix.Verdict.fail, k.verdict);
        try testing.expect(k.delta_us.? > 5_000);
    }
}
