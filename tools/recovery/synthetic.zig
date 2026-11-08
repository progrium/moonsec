//! The synthetic backend for the recovery gate: the passthrough encoder with its own
//! LTR bookkeeping, fed the test pattern, and the synthetic decoder, which fails a frame
//! whose reference the client never got (a P frame after a gap, a refresh against a
//! missing LTR). Frame sizes are the synthetic encoder's model (an IDR is 2x a P frame,
//! a refresh 1.5x), not a codec's, so runs on it check the protocol, not the sizes.
const std = @import("std");
const api = @import("platform");
const synthetic = @import("synthetic");
const run = @import("recovery_run");

pub const Backend = struct {
    gpa: std.mem.Allocator,
    host: *synthetic.Host,
    client: *synthetic.Client,
    hb: api.HostBackend,
    cb: api.ClientBackend,
    buf: []u8,
    frame: api.CapturedFrame = undefined,
    w: u32,
    h: u32,
    now_us: api.Micros = 0,

    fn now(p: ?*anyopaque) api.Micros {
        const self: *Backend = @ptrCast(@alignCast(p.?));
        return self.now_us;
    }

    pub fn open(gpa: std.mem.Allocator, w: u32, h: u32) !*Backend {
        const self = try gpa.create(Backend);
        errdefer gpa.destroy(self);
        const clock: api.Clock = .{ .ptr = self, .nowFn = now };
        const host = try synthetic.openHost(gpa, .{ .clock = clock, .width = w, .height = h, .audio = false });
        const client = try synthetic.openClient(gpa, .{ .clock = clock, .width = w, .height = h, .audio = false, .input_interval_us = 0 });
        self.* = .{
            .gpa = gpa,
            .host = host,
            .client = client,
            .hb = host.backend(),
            .cb = client.backend(),
            .buf = try gpa.alloc(u8, @as(usize, w) * h * 4),
            .w = w,
            .h = h,
        };
        return self;
    }

    fn frameFn(p: *anyopaque, i: u32, t: api.Micros) anyerror!*const api.CapturedFrame {
        const self: *Backend = @ptrCast(@alignCast(p));
        self.now_us = t;
        api.pattern.render(self.buf, self.w, self.h, self.w * 4, .{ .time_us = @bitCast(t), .frame = i });
        self.frame = .{
            .image = .{ .width = self.w, .height = self.h, .cpu = .{ .data = self.buf, .stride = self.w * 4 } },
            .seq = i,
            .capture_start_us = t,
            .captured_us = t,
        };
        return &self.frame;
    }

    pub fn source(self: *Backend) run.Source {
        return .{ .ptr = self, .frameFn = frameFn };
    }

    pub fn close(self: *Backend) void {
        self.hb.deinit();
        self.cb.deinit();
        self.gpa.free(self.buf);
        self.gpa.destroy(self);
    }
};
