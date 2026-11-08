//! Windows backends for the recovery gate: the Windows host bundle (platform/host/windows)
//! with a chosen encoder, fed desktop-like content (content.zig) uploaded into a BGRA
//! texture on the bundle's own device, as Desktop Duplication would hand it over.
//!
//!   win-nvenc, win-amf, win-vpl   the vendor encoders, on hardware adapter 0
//!   win-auto                      whichever of them the adapter has, else Media Foundation
//!   win-mf                        Media Foundation's software H.264 on WARP (no LTR: the
//!                                 IDR fallback path; runs on the GPU-less CI runner)
const std = @import("std");
const api = @import("platform");
const win = @import("win");
const host = @import("win_host");
const run = @import("recovery_run");
const content = @import("content.zig");

const c = host.c;

pub const names = [_][]const u8{ "win-nvenc", "win-amf", "win-vpl", "win-auto", "win-mf" };

pub const Backend = struct {
    gpa: std.mem.Allocator,
    hb: api.HostBackend,
    tex: ?*anyopaque,
    img: []u8,
    frame: api.CapturedFrame = undefined,
    w: u32,
    h: u32,

    pub fn open(gpa: std.mem.Allocator, name: []const u8, w: u32, h: u32) !*Backend {
        const kind: host.EncoderKind, const driver: win.Driver = if (std.mem.eql(u8, name, "win-nvenc"))
            .{ .nvenc, .hardware }
        else if (std.mem.eql(u8, name, "win-amf"))
            .{ .amf, .hardware }
        else if (std.mem.eql(u8, name, "win-vpl"))
            .{ .vpl, .hardware }
        else if (std.mem.eql(u8, name, "win-auto"))
            .{ .auto, .hardware }
        else if (std.mem.eql(u8, name, "win-mf"))
            .{ .mf_software, .warp }
        else
            return error.UnknownBackend;
        const hb = try host.openHost(gpa, .{ .driver = driver, .encoder = kind, .audio = false, .input = false });
        errdefer hb.deinit();
        const bundle: *host.Host = @ptrCast(@alignCast(hb.deinit_ptr.?));
        const info = bundle.d3d.info();
        std.debug.print("device: {s}, encoder: {s}\n", .{ win.adapterName(&info), @tagName(bundle.encoder.kind) });
        var tex: ?*anyopaque = null;
        if (c.msw_texture_create(host.dev(bundle.d3d), w, h, 0xFF000000, &tex) < 0) return error.TextureCreate;
        errdefer c.msw_texture_release(tex);
        const self = try gpa.create(Backend);
        self.* = .{ .gpa = gpa, .hb = hb, .tex = tex, .img = try gpa.alloc(u8, @as(usize, w) * h * 4), .w = w, .h = h };
        return self;
    }

    fn frameFn(p: *anyopaque, i: u32, t: api.Micros) anyerror!*const api.CapturedFrame {
        const self: *Backend = @ptrCast(@alignCast(p));
        const bundle: *host.Host = @ptrCast(@alignCast(self.hb.deinit_ptr.?));
        content.render(self.img, self.w, self.h, self.w * 4, i);
        if (c.msw_texture_write(host.dev(bundle.d3d), self.tex, self.img.ptr, self.w * 4) < 0) return error.TextureWrite;
        self.frame = .{
            .image = .{ .width = self.w, .height = self.h, .format = .bgra8, .gpu = self.tex },
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
        c.msw_texture_release(self.tex);
        self.hb.deinit();
        self.gpa.free(self.img);
        self.gpa.destroy(self);
    }
};
