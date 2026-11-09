//! fuzz-repro: runs one harness on saved inputs (a crash from the fuzzer, or a corpus
//! file), outside the fuzzer, so a failure can be debugged or minimized.
//!
//!   fuzz-repro <harness> <input>...   exit 0: every input passes; 1: an input failed
//!                                     with an error; a panic aborts the process.
//!   fuzz-repro --list                 print the harness names
const std = @import("std");
const root = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--list")) {
        inline for (root.harnesses) |h| std.debug.print("{s}\n", .{h[0]});
        return;
    }
    if (args.len < 3) {
        std.debug.print("usage: fuzz-repro <harness> <input>... | --list\n", .{});
        std.process.exit(2);
    }
    inline for (root.harnesses) |h| if (std.mem.eql(u8, args[1], h[0])) {
        var failed = false;
        for (args[2..]) |path| {
            const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(16 << 20));
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var smith: std.testing.Smith = .{ .in = data };
            h[1](dbg.allocator(), &smith) catch |e| {
                std.debug.print("{s}: {s}: error.{t}\n", .{ h[0], path, e });
                if (@errorReturnTrace()) |t| std.debug.dumpErrorReturnTrace(t);
                failed = true;
            };
            if (dbg.deinit() == .leak) {
                std.debug.print("{s}: {s}: leaked memory\n", .{ h[0], path });
                failed = true;
            }
        }
        std.process.exit(if (failed) 1 else 0);
    };
    std.debug.print("fuzz-repro: no harness named '{s}' (try --list)\n", .{args[1]});
    std.process.exit(2);
}
