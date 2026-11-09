//! `zig build test-nvenc-linux`: the Linux NVENC backend builds, links, and says "not
//! found" cleanly without the NVIDIA libraries or GPU (the only part that can run here; no
//! NVIDIA hardware is planned). On a machine with an NVIDIA GPU it opens a session,
//! encodes a few frames from memory and checks keyframes and long-term tokens.
const std = @import("std");
const c = @import("nvenc_c");
const testing = std.testing;

test "Linux NVENC: not found without an NVIDIA driver, or a short encode with one" {
    var e: ?*c.mlh_nvenc = null;
    const rc = c.mlh_nvenc_create(0, &e);
    if (rc != c.MLH_NV_OK) {
        try testing.expectEqual(@as(c_int, c.MLH_NV_E_NOTFOUND), rc);
        try testing.expect(e == null);
        std.debug.print("NVENC not available: {s}\n", .{c.mlh_nvenc_last_error()});
        return;
    }
    defer c.mlh_nvenc_destroy(e);
    var caps: c.mlh_nvenc_caps = undefined;
    c.mlh_nvenc_caps_get(e, &caps);
    try testing.expect(caps.h264 != 0 or caps.hevc != 0);
    const cfg: c.mlh_nvenc_config = .{ .codec = if (caps.h264 != 0) c.MLH_NV_CODEC_H264 else c.MLH_NV_CODEC_HEVC, .width = 256, .height = 128, .fps = 60, .bitrate_bps = 4_000_000, .slices = 1, .ltr = 1 };
    try testing.expectEqual(@as(c_int, 0), c.mlh_nvenc_configure(e, &cfg));
    var px: [256 * 128 * 4]u8 = undefined;
    for (0..20) |n| {
        for (&px, 0..) |*b, i| b.* = @truncate(i *% 7 +% n * 3);
        const in: c.mlh_nvenc_input = .{ .fd = -1, .fourcc = 0, .modifier = 0, .offset = 0, .pitch = 0, .data = &px, .stride = 256 * 4, .nv12 = 0, .width = 256, .height = 128 };
        const p: c.mlh_nvenc_params = .{ .force = 0, .bitrate_bps = 0, .acked_ltr_tokens = null, .acked_ltr_count = 0 };
        var out: c.mlh_nvenc_output = undefined;
        try testing.expectEqual(@as(c_int, 0), c.mlh_nvenc_encode(e, &in, n, &p, &out));
        try testing.expect(out.len > 0);
        try testing.expectEqual(n == 0, out.keyframe != 0);
        if (caps.ltr != 0 and (n == 0 or n == 15)) try testing.expect(out.has_ltr_token != 0);
    }
}
