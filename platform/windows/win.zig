//! Windows platform helpers shared by the host and client backends.
//!
//! COM code is C (msw.c and friends, compiled by zig cc against the mingw-w64
//! headers bundled with Zig); this module is the Zig view of msw.h.
const std = @import("std");
pub const c = @import("msw_c");

pub const Error = error{Win32};

/// HRESULT of the most recent failed `check` on this thread.
pub threadlocal var last_hr: i32 = 0;

pub fn check(hr: i32) Error!void {
    if (hr < 0) {
        last_hr = hr;
        return error.Win32;
    }
}

pub fn hrCode(hr: anytype) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, hr))))));
}

/// System message for an HRESULT, written into `buf`.
pub fn hrMessage(hr: i32, buf: []u8) []const u8 {
    const n = c.msw_hr_message(hr, buf.ptr, buf.len);
    return buf[0..n];
}

/// "0x887A0004 (The specified device interface or feature level is not supported...)".
pub const HrFmt = struct {
    hr: i32,
    pub fn format(self: HrFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [256]u8 = undefined;
        try w.print("0x{X:0>8} ({s})", .{ @as(u32, @bitCast(self.hr)), hrMessage(self.hr, &buf) });
    }
};

pub fn fmtHr(hr: i32) HrFmt {
    return .{ .hr = hr };
}

pub const ComThread = struct {
    pub fn init() Error!ComThread {
        try check(c.msw_com_init());
        return .{};
    }
    pub fn deinit(_: ComThread) void {
        c.msw_com_uninit();
    }
};

pub fn qpcNs() u64 {
    return c.msw_qpc_ns();
}

pub const Driver = enum(c_uint) {
    hardware = c.MSW_DRIVER_HARDWARE,
    warp = c.MSW_DRIVER_WARP,
};

pub const AdapterInfo = c.msw_adapter_info;

pub fn adapterName(info: *const AdapterInfo) []const u8 {
    return std.mem.sliceTo(&info.description, 0);
}

/// DXGI adapters in enumeration order; null past the end.
pub fn adapter(index: u32) Error!?AdapterInfo {
    var info: AdapterInfo = undefined;
    const hr = c.msw_adapter_get(index, &info);
    if (hr == hrCode(c.MSW_DXGI_ERROR_NOT_FOUND)) return null;
    try check(hr);
    return info;
}

pub const D3dOptions = struct {
    driver: Driver = .hardware,
    adapter_index: u32 = 0,
    debug: bool = false,
    video: bool = false,
};

/// A D3D11 device and immediate context, multithread-protected.
pub const D3d = struct {
    handle: *c.msw_d3d,

    pub fn create(opts: D3dOptions) Error!D3d {
        var flags: u32 = 0;
        if (opts.debug) flags |= c.MSW_D3D_DEBUG;
        if (opts.video) flags |= c.MSW_D3D_VIDEO;
        var h: ?*c.msw_d3d = null;
        try check(c.msw_d3d_create(@intFromEnum(opts.driver), opts.adapter_index, flags, &h));
        return .{ .handle = h.? };
    }

    pub fn destroy(self: D3d) void {
        c.msw_d3d_destroy(self.handle);
    }

    pub fn info(self: D3d) AdapterInfo {
        var i: AdapterInfo = undefined;
        c.msw_d3d_info(self.handle, &i);
        return i;
    }

    /// Clears a w x h BGRA target to `bgra`, reads back the pixel at (x, y).
    pub fn selftest(self: D3d, w: u32, h: u32, bgra: u32, x: u32, y: u32) Error!u32 {
        var px: u32 = 0;
        try check(c.msw_d3d_selftest(self.handle, w, h, bgra, x, y, &px));
        return px;
    }
};
