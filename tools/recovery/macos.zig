//! macOS backend for the recovery gate: the macOS host bundle's VideoToolbox encoder
//! (platform/host/macos, low-latency path with long-term references), fed desktop-like
//! content (content.zig) written into an IOSurface-backed BGRA CVPixelBuffer, as
//! ScreenCaptureKit would hand it over.
//!
//!   mac-vt   VideoToolbox on the low-latency path (hardware, else software)
//!
//! Needs no Screen Recording permission: nothing is captured.
const std = @import("std");
const api = @import("platform");
const host = @import("mac_host");
const run = @import("recovery_run");
const content = @import("content.zig");

const c = host.c;

pub const names = [_][]const u8{"mac-vt"};

// CoreVideo, linked by the host backend.
extern "c" fn CVPixelBufferLockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: *anyopaque) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: *anyopaque) usize;

pub const Backend = struct {
    gpa: std.mem.Allocator,
    hb: api.HostBackend,
    pb: *anyopaque,
    img: []u8,
    frame: api.CapturedFrame = undefined,
    w: u32,
    h: u32,

    pub fn open(gpa: std.mem.Allocator, name: []const u8, w: u32, h: u32) !*Backend {
        if (!std.mem.eql(u8, name, "mac-vt")) return error.UnknownBackend;
        const hb = try host.openHost(gpa, .{ .audio = false, .input = false, .encoder = .{ .mode = .low_latency } });
        errdefer hb.deinit();
        const pb = c.mh_pixel_buffer_create(w, h, c.MH_FMT_BGRA) orelse return error.PixelBufferCreate;
        errdefer c.mh_cf_release(pb);
        const self = try gpa.create(Backend);
        self.* = .{ .gpa = gpa, .hb = hb, .pb = pb, .img = try gpa.alloc(u8, @as(usize, w) * h * 4), .w = w, .h = h };
        return self;
    }

    fn frameFn(p: *anyopaque, i: u32, t: api.Micros) anyerror!*const api.CapturedFrame {
        const self: *Backend = @ptrCast(@alignCast(p));
        content.render(self.img, self.w, self.h, self.w * 4, i);
        if (CVPixelBufferLockBaseAddress(self.pb, 0) != 0) return error.PixelBufferLock;
        defer _ = CVPixelBufferUnlockBaseAddress(self.pb, 0);
        const base = CVPixelBufferGetBaseAddress(self.pb) orelse return error.PixelBufferLock;
        const stride = CVPixelBufferGetBytesPerRow(self.pb);
        for (0..self.h) |y| @memcpy(base[y * stride ..][0 .. self.w * 4], self.img[y * self.w * 4 ..][0 .. self.w * 4]);
        self.frame = .{
            .image = .{ .width = self.w, .height = self.h, .format = .bgra8, .gpu = self.pb },
            .seq = i,
            .capture_start_us = t,
            .captured_us = t,
        };
        return &self.frame;
    }

    pub fn source(self: *Backend) run.Source {
        return .{ .ptr = self, .frameFn = frameFn };
    }

    pub fn encoder(self: *Backend) api.Encoder {
        return self.hb.encoder;
    }

    pub fn close(self: *Backend) void {
        c.mh_cf_release(self.pb);
        self.hb.deinit();
        self.gpa.free(self.img);
        self.gpa.destroy(self);
    }
};
