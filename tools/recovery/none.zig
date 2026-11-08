//! No platform encoders on this OS (Linux has no host backend yet): synthetic only.
const std = @import("std");
const api = @import("platform");
const run = @import("recovery_run");

pub const names = [_][]const u8{};

pub const Backend = struct {
    pub fn open(_: std.mem.Allocator, _: []const u8, _: u32, _: u32) !*Backend {
        return error.UnknownBackend;
    }
    pub fn source(_: *Backend) run.Source {
        unreachable;
    }
    pub fn encoder(_: *Backend) api.Encoder {
        unreachable;
    }
    pub fn close(_: *Backend) void {}
};
