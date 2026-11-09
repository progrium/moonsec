//! Keeps the ABI checks complete: every struct, field, constant and function in
//! include/moonsec.h must be listed in abi/abi_dump.c (so the frozen dump covers it), and
//! every function in abi/include_check.cpp (so its signature is frozen).
const std = @import("std");

const header = @embedFile("moonsec_h_text");
const dump = @embedFile("abi_dump_c");
const cpp = @embedFile("include_check_cpp");

/// The header without comments.
fn stripComments(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "/*")) {
            const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse src.len;
            i = end + 2;
            try out.append(gpa, ' ');
        } else {
            try out.append(gpa, src[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn expectListed(haystack: []const u8, comptime fmt: []const u8, args: anytype, where: []const u8) !void {
    var buf: [256]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, fmt, args);
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("{s} does not list `{s}`\n", .{ where, needle });
        return error.Incomplete;
    }
}

test "the ABI dump and the C++ signature check cover the whole header" {
    const gpa = std.testing.allocator;
    const h = try stripComments(gpa, header);
    defer gpa.free(h);
    var structs: usize = 0;
    var fields: usize = 0;
    var consts: usize = 0;
    var funcs: usize = 0;

    // Structs and their fields.
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, h, pos, "typedef struct ")) |at| {
        const name_start = at + "typedef struct ".len;
        var name_end = name_start;
        while (isIdent(h[name_end])) name_end += 1;
        const name = h[name_start..name_end];
        const brace = std.mem.indexOfScalarPos(u8, h, name_end, '{') orelse break;
        const semi = std.mem.indexOfScalarPos(u8, h, name_end, ';').?;
        pos = name_end;
        if (semi < brace) continue; // an opaque handle
        const close = std.mem.indexOfScalarPos(u8, h, brace, '}').?;
        try expectListed(dump, "S({s})", .{name}, "abi/abi_dump.c");
        structs += 1;
        var decls = std.mem.tokenizeScalar(u8, h[brace + 1 .. close], ';');
        while (decls.next()) |decl_| {
            const decl = std.mem.trim(u8, decl_, " \t\r\n");
            if (decl.len == 0) continue;
            if (std.mem.indexOf(u8, decl, "(*")) |fp| {
                // A function pointer: the name is inside "(*name)".
                const end = std.mem.indexOfScalarPos(u8, decl, fp, ')').?;
                try expectListed(dump, "F({s}, {s})", .{ name, decl[fp + 2 .. end] }, "abi/abi_dump.c");
                fields += 1;
                continue;
            }
            var parts = std.mem.tokenizeScalar(u8, decl, ',');
            while (parts.next()) |part_| {
                var part = std.mem.trim(u8, part_, " \t\r\n");
                if (std.mem.indexOfScalar(u8, part, '[')) |b| part = std.mem.trimEnd(u8, part[0..b], " ");
                var s = part.len;
                while (s > 0 and isIdent(part[s - 1])) s -= 1;
                try expectListed(dump, "F({s}, {s})", .{ name, part[s..] }, "abi/abi_dump.c");
                fields += 1;
            }
        }
    }

    // Constants: `#define MOONSEC_X value`.
    var lines = std.mem.tokenizeScalar(u8, h, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "#define MOONSEC_")) continue;
        const rest = line["#define ".len..];
        var e: usize = 0;
        while (e < rest.len and isIdent(rest[e])) e += 1;
        const name = rest[0..e];
        if (std.mem.trim(u8, rest[e..], " \t\r").len == 0) continue; // include guard
        if (std.mem.eql(u8, name, "MOONSEC_API")) continue;
        try expectListed(dump, "K({s})", .{name}, "abi/abi_dump.c");
        consts += 1;
    }

    // Functions: `MOONSEC_API <type> moonsec_x(`.
    pos = 0;
    while (std.mem.indexOfPos(u8, h, pos, "MOONSEC_API ")) |at| {
        pos = at + 1;
        const paren = std.mem.indexOfScalarPos(u8, h, at, '(') orelse break;
        var s = paren;
        while (s > 0 and isIdent(h[s - 1])) s -= 1;
        const name = h[s..paren];
        if (!std.mem.startsWith(u8, name, "moonsec_")) continue;
        try expectListed(dump, "FN({s})", .{name}, "abi/abi_dump.c");
        try expectListed(cpp, "SIG({s},", .{name}, "abi/include_check.cpp");
        funcs += 1;
    }
    try std.testing.expect(structs >= 12 and fields > 100 and consts > 90 and funcs >= 36);
}
