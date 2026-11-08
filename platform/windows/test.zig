//! Windows platform tests (zig build test-win, on Windows). Every test here must
//! pass on a GPU-less windows-2022 CI runner: hardware paths skip when absent.
const std = @import("std");
const win = @import("win");

test "HRESULT messages" {
    var buf: [256]u8 = undefined;
    const msg = win.hrMessage(win.hrCode(win.c.MSW_E_INVALIDARG), &buf);
    try std.testing.expect(msg.len > 0);
    const unknown = win.hrMessage(@bitCast(@as(u32, 0xA0BADBAD)), &buf);
    try std.testing.expectEqualStrings("HRESULT 0xa0badbad", unknown);
}

test "QPC clock is monotonic and in nanoseconds" {
    const a = win.qpcNs();
    try std.testing.io.sleep(.fromMilliseconds(2), .awake);
    const b = win.qpcNs();
    try std.testing.expect(b > a);
    try std.testing.expect(b - a >= 1 * std.time.ns_per_ms);
    try std.testing.expect(b - a < 2 * std.time.ns_per_s);
}

test "enumerate DXGI adapters" {
    const com = try win.ComThread.init();
    defer com.deinit();
    var i: u32 = 0;
    while (try win.adapter(i)) |info| : (i += 1) {
        std.debug.print("adapter {d}: {s} vendor=0x{X:0>4} device=0x{X:0>4} vram={d} MiB software={d}\n", .{
            i, win.adapterName(&info), info.vendor_id, info.device_id, info.dedicated_video_memory >> 20, info.is_software,
        });
    }
    // Every Windows install has at least the Microsoft Basic Render Driver.
    try std.testing.expect(i >= 1);
}

test "WARP device clears and reads back a texture" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d = try win.D3d.create(.{ .driver = .warp });
    defer d.destroy();
    const info = d.info();
    std.debug.print("WARP: {s} feature level 0x{X}\n", .{ win.adapterName(&info), info.feature_level });
    try std.testing.expectEqual(@as(u32, 0x1414), info.vendor_id);
    try std.testing.expect(info.feature_level >= 0xb000);
    try std.testing.expectEqual(@as(u32, 0xFF336699), try d.selftest(64, 32, 0xFF336699, 63, 31));
}

test "primary adapter device (hardware or Basic Render Driver)" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d = win.D3d.create(.{ .driver = .hardware, .adapter_index = 0 }) catch |e| {
        std.debug.print("hardware device: {f}, skipping\n", .{win.fmtHr(win.last_hr)});
        return e;
    };
    defer d.destroy();
    const info = d.info();
    std.debug.print("adapter 0 device: {s} feature level 0x{X}\n", .{ win.adapterName(&info), info.feature_level });
    try std.testing.expectEqual(@as(u32, 0xFF102030), try d.selftest(16, 16, 0xFF102030, 0, 0));
}

test "invalid D3D11 call surfaces its HRESULT" {
    const com = try win.ComThread.init();
    defer com.deinit();
    const d = try win.D3d.create(.{ .driver = .warp });
    defer d.destroy();
    try std.testing.expectError(error.Win32, d.selftest(8, 8, 0, 8, 0));
    try std.testing.expectEqual(win.hrCode(win.c.MSW_E_INVALIDARG), win.last_hr);
}
