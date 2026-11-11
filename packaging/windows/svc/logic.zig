//! The platform-free parts of moonsec-svc: the agent command line and the restart backoff.
const std = @import("std");

/// What the agent runs in the user's session when the registry doesn't say otherwise.
/// `{dir}` is the service's own directory (the install directory); `%VAR%` is expanded
/// with the logged-on user's environment, so the state lands in their profile.
pub const default_agent_cmdline =
    \\"{dir}\moonsec.exe" peer iroh host --relay --state-dir "%APPDATA%\moonsec" --ticket-file "%APPDATA%\moonsec\host-ticket"
;

/// Replaces every `{dir}` in `template` with `dir`.
pub fn substituteDir(gpa: std.mem.Allocator, template: []const u8, dir: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, template, "{dir}", dir);
}

/// Restart delay after the agent exits: quick when it ran a while (a session ended or the
/// client said bye), backing off to a minute when it keeps failing at start.
pub const Backoff = struct {
    failures: u32 = 0,

    /// `ran_ms`: how long the agent ran before it exited.
    pub fn next(self: *Backoff, ran_ms: u64) u32 {
        if (ran_ms >= 30_000) {
            self.failures = 0;
            return 500;
        }
        self.failures +|= 1;
        const shift: u5 = @intCast(@min(self.failures, 7));
        return @min(@as(u32, 500) << shift, 60_000);
    }
};

test "dir substitution" {
    const gpa = std.testing.allocator;
    const s = try substituteDir(gpa, default_agent_cmdline, "C:\\Program Files\\moonsec");
    defer gpa.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "\"C:\\Program Files\\moonsec\\moonsec.exe\" peer iroh host"));
    try std.testing.expect(std.mem.indexOf(u8, s, "{dir}") == null);
}

test "backoff" {
    var b: Backoff = .{};
    try std.testing.expectEqual(@as(u32, 1000), b.next(10));
    try std.testing.expectEqual(@as(u32, 2000), b.next(10));
    for (0..10) |_| _ = b.next(10);
    try std.testing.expectEqual(@as(u32, 60_000), b.next(10));
    try std.testing.expectEqual(@as(u32, 500), b.next(60_000));
    try std.testing.expectEqual(@as(u32, 1000), b.next(10));
}
