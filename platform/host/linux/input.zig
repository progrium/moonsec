//! Input injection for the Linux host through /dev/uinput: what `core.input.Receiver`
//! decoded, as evdev events from virtual devices the compositor and games read like
//! real ones.
//!
//!   keyboard  every KEY_* the HID usage table maps to (platform/linux/uinput.zig).
//!   mouse     BTN_LEFT/RIGHT/MIDDLE/SIDE/EXTRA (buttons 1..5), REL_X/Y, and the wheels
//!             as REL_WHEEL_HI_RES/REL_HWHEEL_HI_RES (120 per notch) with REL_WHEEL/
//!             REL_HWHEEL notches accumulated from them, as the kernel's HID driver does.
//!   tablet    absolute positioning: ABS_X/Y over the captured output's pixels, with
//!             INPUT_PROP_DIRECT and mouse buttons so udev tags it an absolute mouse
//!             (like a VM's USB tablet). Created at the first `abs` action, and again
//!             when the output size changes.
//!   pads      one per connected client pad, Xbox 360 layout as the kernel's xpad driver
//!             reports it (vendor 045e, product 028e), so SDL and Steam map it without a
//!             custom mapping. Created on connect, removed on disconnect.
//!
//! Every action is one report (its events, then SYN_REPORT) in one write. The kernel
//! releases a device's held keys and buttons when the device is destroyed, so `deinit`
//! never leaves anything stuck.
//!
//! Rumble: the client pad protocol (#25) carries no force feedback yet, so the pads do
//! not advertise EV_FF (a game then knows not to try).
const std = @import("std");
const api = @import("platform");
const core = @import("core");
const ui = @import("linux_uinput");

const log = std.log.scoped(.linux_host);
const Gamepad = core.input.Gamepad;

/// Bits of `Gamepad.buttons`: `core.input.Gamepad.Button` (XInput order plus guide).
/// The same values are spelled out here until that declaration (client gamepads) lands.
pub const PadButton = if (@hasDecl(Gamepad, "Button")) Gamepad.Button else struct {
    pub const dpad_up: u32 = 0x0001;
    pub const dpad_down: u32 = 0x0002;
    pub const dpad_left: u32 = 0x0004;
    pub const dpad_right: u32 = 0x0008;
    pub const start: u32 = 0x0010;
    pub const back: u32 = 0x0020;
    pub const left_thumb: u32 = 0x0040;
    pub const right_thumb: u32 = 0x0080;
    pub const left_shoulder: u32 = 0x0100;
    pub const right_shoulder: u32 = 0x0200;
    pub const guide: u32 = 0x0400;
    pub const a: u32 = 0x1000;
    pub const b: u32 = 0x2000;
    pub const x: u32 = 0x4000;
    pub const y: u32 = 0x8000;
};

/// xpad's names for the face buttons: X and Y are BTN_X (= BTN_NORTH) and BTN_Y
/// (= BTN_WEST), which is what SDL's mapping for an Xbox 360 pad expects.
const BTN_X = ui.BTN_NORTH;
const BTN_Y = ui.BTN_WEST;

/// Mouse buttons 1..5 (left, right, middle, back, forward) as BTN_* codes.
pub fn buttonCode(button: u16) u16 {
    return switch (button) {
        1 => ui.BTN_LEFT,
        2 => ui.BTN_RIGHT,
        3 => ui.BTN_MIDDLE,
        4 => ui.BTN_SIDE,
        5 => ui.BTN_EXTRA,
        else => 0,
    };
}

pub const Kind = enum { keyboard, mouse, tablet, pad };

const mouse_buttons = [_]u16{ ui.BTN_LEFT, ui.BTN_RIGHT, ui.BTN_MIDDLE, ui.BTN_SIDE, ui.BTN_EXTRA };
const pad_buttons = [_]u16{ ui.BTN_SOUTH, ui.BTN_EAST, BTN_X, BTN_Y, ui.BTN_TL, ui.BTN_TR, ui.BTN_SELECT, ui.BTN_START, ui.BTN_MODE, ui.BTN_THUMBL, ui.BTN_THUMBR };
const stick = struct {
    fn axis(code: u16) ui.Axis {
        return .{ .code = code, .min = -32768, .max = 32767, .fuzz = 16, .flat = 128 };
    }
};
/// Trigger range: xpad's Xbox One range (the 360's is 0..255).
pub const trigger_max = 1023;
const pad_axes = [_]ui.Axis{
    stick.axis(ui.ABS_X),                                stick.axis(ui.ABS_Y),
    stick.axis(ui.ABS_RX),                               stick.axis(ui.ABS_RY),
    .{ .code = ui.ABS_Z, .min = 0, .max = trigger_max }, .{ .code = ui.ABS_RZ, .min = 0, .max = trigger_max },
    .{ .code = ui.ABS_HAT0X, .min = -1, .max = 1 },      .{ .code = ui.ABS_HAT0Y, .min = -1, .max = 1 },
};

/// Storage a `Spec` points into; it must outlive the `openFn` call.
pub const Scratch = struct {
    name: [80]u8 = undefined,
    axes: [2]ui.Axis = undefined,
};

/// The device a `Kind` is: what `Opener` is asked to create. `size` is the tablet's
/// range; `index` the pad's.
pub fn spec(kind: Kind, size: api.Size, index: u8, scratch: *Scratch) ui.Spec {
    return switch (kind) {
        .keyboard => .{ .name = "moonsec keyboard", .product = 0x0101, .key_range = ui.max_keyboard_key },
        .mouse => .{
            .name = "moonsec mouse",
            .product = 0x0102,
            .keys = &mouse_buttons,
            .rels = &.{ ui.REL_X, ui.REL_Y, ui.REL_WHEEL, ui.REL_HWHEEL, ui.REL_WHEEL_HI_RES, ui.REL_HWHEEL_HI_RES },
        },
        .tablet => .{
            .name = "moonsec absolute pointer",
            .product = 0x0103,
            .keys = mouse_buttons[0..3],
            .abs = blk: {
                scratch.axes = tabletAxes(size);
                break :blk &scratch.axes;
            },
            .props = &.{ui.INPUT_PROP_DIRECT},
        },
        .pad => .{
            .name = std.fmt.bufPrint(&scratch.name, "moonsec pad {d} (Xbox 360 layout)", .{index + 1}) catch unreachable,
            .bustype = ui.BUS_USB,
            .vendor = 0x045e,
            .product = 0x028e,
            .version = 0x0110,
            .keys = &pad_buttons,
            .abs = &pad_axes,
        },
    };
}

fn tabletAxes(size: api.Size) [2]ui.Axis {
    return .{
        .{ .code = ui.ABS_X, .min = 0, .max = @intCast(@max(size.width, 1) - 1) },
        .{ .code = ui.ABS_Y, .min = 0, .max = @intCast(@max(size.height, 1) - 1) },
    };
}

/// Creates and destroys the devices. `uinput` makes real ones; tests pass one that hands
/// out pipes and read the events back.
pub const Opener = struct {
    ctx: ?*anyopaque = null,
    openFn: *const fn (ctx: ?*anyopaque, kind: Kind, index: u8, spec: *const ui.Spec) ui.Error!ui.Device,
    closeFn: *const fn (ctx: ?*anyopaque, dev: ui.Device) void,

    pub const uinput: Opener = .{ .openFn = openUinput, .closeFn = closeUinput };

    fn openUinput(_: ?*anyopaque, _: Kind, _: u8, s: *const ui.Spec) ui.Error!ui.Device {
        return ui.Device.create(s.*);
    }
    fn closeUinput(_: ?*anyopaque, d: ui.Device) void {
        d.destroy();
    }
};

pub const Stats = struct {
    keys: u64 = 0,
    buttons: u64 = 0,
    scrolls: u64 = 0,
    motions: u64 = 0,
    abs: u64 = 0,
    pad_reports: u64 = 0,
    pads_connected: u64 = 0,
    /// Keys and buttons with no Linux code, pads past the fourth.
    unmapped: u64 = 0,
    write_errors: u64 = 0,
    device_errors: u64 = 0,
};

pub const Injector = struct {
    opener: Opener,
    keyboard: ui.Device,
    mouse: ui.Device,
    tablet: ?ui.Device = null,
    tablet_size: api.Size = .{ .width = 0, .height = 0 },
    /// The captured output (the host sets it when capture starts); 0 until then, and the
    /// tablet spans 0..65535.
    output: api.Size = .{ .width = 0, .height = 0 },
    pads: [core.input.max_pads]?ui.Device = @splat(null),
    /// High-resolution wheel units not yet a whole notch (x, y).
    wheel_rem: [2]i32 = .{ 0, 0 },
    stats: Stats = .{},

    /// Creates the keyboard and mouse at once, so a missing /dev/uinput shows at session
    /// start. The tablet and pads follow on first use.
    pub fn init(opener: Opener) ui.Error!Injector {
        var scratch: Scratch = .{};
        var s = spec(.keyboard, .{ .width = 0, .height = 0 }, 0, &scratch);
        const kb = try opener.openFn(opener.ctx, .keyboard, 0, &s);
        errdefer opener.closeFn(opener.ctx, kb);
        s = spec(.mouse, .{ .width = 0, .height = 0 }, 0, &scratch);
        const mouse = try opener.openFn(opener.ctx, .mouse, 0, &s);
        return .{ .opener = opener, .keyboard = kb, .mouse = mouse };
    }

    pub fn deinit(j: *Injector) void {
        for (&j.pads) |*p| if (p.*) |d| {
            j.opener.closeFn(j.opener.ctx, d);
            p.* = null;
        };
        if (j.tablet) |t| j.opener.closeFn(j.opener.ctx, t);
        j.tablet = null;
        j.opener.closeFn(j.opener.ctx, j.mouse);
        j.opener.closeFn(j.opener.ctx, j.keyboard);
    }

    /// The captured output's size: absolute positions map onto its pixels.
    pub fn setOutput(j: *Injector, size: api.Size) void {
        j.output = size;
    }

    fn send(j: *Injector, d: ui.Device, events: []const ui.Event) api.Error!void {
        if (!d.write(events)) {
            j.stats.write_errors += 1;
            return error.BackendFailed;
        }
    }

    pub fn inject(j: *Injector, a: core.input.Action) api.Error!void {
        switch (a) {
            .key => |k| {
                const code = ui.keyCode(k.code);
                if (code == 0) {
                    j.stats.unmapped += 1;
                    return;
                }
                j.stats.keys += 1;
                try j.send(j.keyboard, &.{ .{ .type = ui.EV_KEY, .code = code, .value = @intFromBool(k.down) }, ui.syn });
            },
            .button => |b| {
                const code = buttonCode(b.code);
                if (code == 0) {
                    j.stats.unmapped += 1;
                    return;
                }
                j.stats.buttons += 1;
                try j.send(j.mouse, &.{ .{ .type = ui.EV_KEY, .code = code, .value = @intFromBool(b.down) }, ui.syn });
            },
            .scroll => |s| {
                var ev: [5]ui.Event = undefined;
                var n: usize = 0;
                if (s.dy != 0) {
                    ev[n] = .{ .type = ui.EV_REL, .code = ui.REL_WHEEL_HI_RES, .value = s.dy };
                    n += 1;
                }
                if (s.dx != 0) {
                    ev[n] = .{ .type = ui.EV_REL, .code = ui.REL_HWHEEL_HI_RES, .value = s.dx };
                    n += 1;
                }
                if (notches(&j.wheel_rem[1], s.dy)) |v| {
                    ev[n] = .{ .type = ui.EV_REL, .code = ui.REL_WHEEL, .value = v };
                    n += 1;
                }
                if (notches(&j.wheel_rem[0], s.dx)) |v| {
                    ev[n] = .{ .type = ui.EV_REL, .code = ui.REL_HWHEEL, .value = v };
                    n += 1;
                }
                if (n == 0) return;
                ev[n] = ui.syn;
                j.stats.scrolls += 1;
                try j.send(j.mouse, ev[0 .. n + 1]);
            },
            .motion => |m| {
                if (m.dx == 0 and m.dy == 0) return;
                j.stats.motions += 1;
                try j.send(j.mouse, &.{ .{ .type = ui.EV_REL, .code = ui.REL_X, .value = m.dx }, .{ .type = ui.EV_REL, .code = ui.REL_Y, .value = m.dy }, ui.syn });
            },
            .abs => |p| {
                const size: api.Size = if (j.output.width > 1 and j.output.height > 1) j.output else .{ .width = 65536, .height = 65536 };
                const t = try j.tabletFor(size);
                j.stats.abs += 1;
                try j.send(t, &.{ .{ .type = ui.EV_ABS, .code = ui.ABS_X, .value = scaleAbs(p.x, size.width) }, .{ .type = ui.EV_ABS, .code = ui.ABS_Y, .value = scaleAbs(p.y, size.height) }, ui.syn });
            },
            .pad => |p| {
                if (p.index >= j.pads.len) {
                    j.stats.unmapped += 1;
                    return;
                }
                if (!p.connected) {
                    if (j.pads[p.index]) |d| {
                        j.opener.closeFn(j.opener.ctx, d);
                        j.pads[p.index] = null;
                        log.info("pad {d} disconnected", .{p.index + 1});
                    }
                    return;
                }
                const d = j.pads[p.index] orelse blk: {
                    var scratch: Scratch = .{};
                    const s = spec(.pad, .{ .width = 0, .height = 0 }, p.index, &scratch);
                    const d = j.opener.openFn(j.opener.ctx, .pad, p.index, &s) catch |e| {
                        j.stats.device_errors += 1;
                        log.warn("pad {d}: cannot create the uinput gamepad ({s})", .{ p.index + 1, @errorName(e) });
                        return error.BackendFailed;
                    };
                    j.pads[p.index] = d;
                    j.stats.pads_connected += 1;
                    log.info("pad {d} connected", .{p.index + 1});
                    break :blk d;
                };
                const ev = padReport(p.state);
                j.stats.pad_reports += 1;
                try j.send(d, &ev);
            },
        }
    }

    fn tabletFor(j: *Injector, size: api.Size) api.Error!ui.Device {
        if (j.tablet) |t| {
            if (j.tablet_size.width == size.width and j.tablet_size.height == size.height) return t;
            j.opener.closeFn(j.opener.ctx, t);
            j.tablet = null;
        }
        var scratch: Scratch = .{};
        const s = spec(.tablet, size, 0, &scratch);
        const t = j.opener.openFn(j.opener.ctx, .tablet, 0, &s) catch |e| {
            j.stats.device_errors += 1;
            log.warn("cannot create the uinput absolute pointer ({s})", .{@errorName(e)});
            return error.BackendFailed;
        };
        j.tablet = t;
        j.tablet_size = size;
        return t;
    }
};

/// Adds `v` high-resolution units to `rem`; returns the whole notches now due, if any.
/// A change of direction drops the partial notch, as the kernel's HID driver does.
fn notches(rem: *i32, v: i32) ?i32 {
    if (v == 0) return null;
    if ((rem.* < 0) != (v < 0)) rem.* = 0;
    rem.* += v;
    const n = @divTrunc(rem.*, 120);
    if (n == 0) return null;
    rem.* -= n * 120;
    return n;
}

/// XInput's stick Y (up positive) as evdev's (up negative); -32768 becomes 32767.
fn flipY(v: i16) i32 {
    return @min(-@as(i32, v), 32767);
}

/// 0..65535 across the output onto pixel 0..size-1, rounded.
pub fn scaleAbs(v: u16, size: u32) i32 {
    const max: u64 = @max(size, 1) - 1;
    return @intCast((@as(u64, v) * max + 32767) / 65535);
}

/// One pad snapshot as a full report: buttons, sticks (Y up is negative on evdev, as xpad
/// reports it, 0 at rest), triggers, d-pad as the hat, SYN_REPORT.
pub fn padReport(g: Gamepad) [pad_buttons.len + pad_axes.len + 1]ui.Event {
    const B = PadButton;
    const bits = [pad_buttons.len]u32{ B.a, B.b, B.x, B.y, B.left_shoulder, B.right_shoulder, B.back, B.start, B.guide, B.left_thumb, B.right_thumb };
    var ev: [pad_buttons.len + pad_axes.len + 1]ui.Event = undefined;
    for (pad_buttons, bits, 0..) |code, bit, i| ev[i] = .{ .type = ui.EV_KEY, .code = code, .value = @intFromBool(g.buttons & bit != 0) };
    const hat_x: i32 = @as(i32, @intFromBool(g.buttons & B.dpad_right != 0)) - @intFromBool(g.buttons & B.dpad_left != 0);
    const hat_y: i32 = @as(i32, @intFromBool(g.buttons & B.dpad_down != 0)) - @intFromBool(g.buttons & B.dpad_up != 0);
    const values = [pad_axes.len]i32{ g.lx, flipY(g.ly), g.rx, flipY(g.ry), g.lt >> 6, g.rt >> 6, hat_x, hat_y };
    for (pad_axes, values, pad_buttons.len..) |ax, v, i| ev[i] = .{ .type = ui.EV_ABS, .code = ax.code, .value = v };
    ev[ev.len - 1] = ui.syn;
    return ev;
}

// ---------------------------------------------------------------------------
// Tests: devices are pipes, and the events written to them are read back.

const testing = std.testing;
const linux = std.os.linux;

const PipeOpener = struct {
    /// Read ends by device: keyboard, mouse, tablet, pads 0..3.
    read: [7]?i32 = @splat(null),
    write: [7]?i32 = @splat(null),
    opened: [7]u32 = @splat(0),
    /// What each device was created with (the parts the tests check).
    specs: [7]?Seen = @splat(null),
    fail_pads: bool = false,

    const Seen = struct { bustype: u16, vendor: u16, product: u16, abs_max: [2]i32, prop: ?u16 };

    fn slot(kind: Kind, index: u8) usize {
        return switch (kind) {
            .keyboard => 0,
            .mouse => 1,
            .tablet => 2,
            .pad => 3 + @as(usize, index),
        };
    }

    fn open(ctx: ?*anyopaque, kind: Kind, index: u8, s: *const ui.Spec) ui.Error!ui.Device {
        const o: *PipeOpener = @ptrCast(@alignCast(ctx.?));
        if (kind == .pad and o.fail_pads) return error.AccessDenied;
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return error.SetupFailed;
        const i = slot(kind, index);
        o.read[i] = fds[0];
        o.write[i] = fds[1];
        o.opened[i] += 1;
        o.specs[i] = .{
            .bustype = s.bustype,
            .vendor = s.vendor,
            .product = s.product,
            .abs_max = if (s.abs.len >= 2) .{ s.abs[0].max, s.abs[1].max } else .{ 0, 0 },
            .prop = if (s.props.len > 0) s.props[0] else null,
        };
        return .{ .fd = fds[1] };
    }

    fn close(ctx: ?*anyopaque, d: ui.Device) void {
        const o: *PipeOpener = @ptrCast(@alignCast(ctx.?));
        for (&o.write, &o.read) |*w, *r| if (w.* == d.fd) {
            _ = linux.close(w.*.?);
            _ = linux.close(r.*.?);
            w.* = null;
            r.* = null;
        };
    }

    fn opener(o: *PipeOpener) Opener {
        return .{ .ctx = o, .openFn = open, .closeFn = close };
    }

    /// Events written to a device since the last call.
    fn drain(o: *PipeOpener, kind: Kind, index: u8, out: []ui.Event) []ui.Event {
        const fd = o.read[slot(kind, index)] orelse return out[0..0];
        const bytes = std.mem.sliceAsBytes(out);
        const rc = linux.read(fd, bytes.ptr, bytes.len);
        if (linux.errno(rc) != .SUCCESS) return out[0..0];
        return out[0 .. rc / @sizeOf(ui.Event)];
    }
};

fn expectEvents(want: []const [3]i32, got: []const ui.Event) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w[0], @as(i32, g.type));
        try testing.expectEqual(w[1], @as(i32, g.code));
        try testing.expectEqual(w[2], g.value);
    }
}

const SYN = [3]i32{ ui.EV_SYN, ui.SYN_REPORT, 0 };

test "keys, buttons and motion are one report each" {
    var po: PipeOpener = .{};
    var j = try Injector.init(po.opener());
    defer j.deinit();
    var buf: [64]ui.Event = undefined;

    try j.inject(.{ .key = .{ .code = 0x04, .down = true, .time = 0 } }); // a
    try j.inject(.{ .key = .{ .code = 0xE1, .down = false, .time = 0 } }); // left shift
    try expectEvents(&.{ .{ ui.EV_KEY, ui.KEY_A, 1 }, SYN, .{ ui.EV_KEY, 42, 0 }, SYN }, po.drain(.keyboard, 0, &buf));

    try j.inject(.{ .button = .{ .code = 1, .down = true, .time = 0 } });
    try j.inject(.{ .button = .{ .code = 5, .down = false, .time = 0 } });
    try j.inject(.{ .motion = .{ .dx = 7, .dy = -3 } });
    try j.inject(.{ .motion = .{ .dx = 0, .dy = 0 } }); // nothing
    try expectEvents(&.{
        .{ ui.EV_KEY, ui.BTN_LEFT, 1 },  SYN,
        .{ ui.EV_KEY, ui.BTN_EXTRA, 0 }, SYN,
        .{ ui.EV_REL, ui.REL_X, 7 },     .{ ui.EV_REL, ui.REL_Y, -3 },
        SYN,
    }, po.drain(.mouse, 0, &buf));

    // No Linux code: counted, nothing written.
    try j.inject(.{ .key = .{ .code = 0x300, .down = true, .time = 0 } });
    try j.inject(.{ .button = .{ .code = 9, .down = true, .time = 0 } });
    try testing.expectEqual(@as(usize, 0), po.drain(.keyboard, 0, &buf).len);
    try testing.expectEqual(@as(usize, 0), po.drain(.mouse, 0, &buf).len);
    try testing.expectEqual(@as(u64, 2), j.stats.unmapped);
    try testing.expectEqual(@as(u64, 2), j.stats.keys);
}

test "the wheels: high resolution, and notches accumulated from it" {
    var po: PipeOpener = .{};
    var j = try Injector.init(po.opener());
    defer j.deinit();
    var buf: [64]ui.Event = undefined;

    // One notch away from the user.
    try j.inject(.{ .scroll = .{ .dx = 0, .dy = 120, .time = 0 } });
    try expectEvents(&.{ .{ ui.EV_REL, ui.REL_WHEEL_HI_RES, 120 }, .{ ui.EV_REL, ui.REL_WHEEL, 1 }, SYN }, po.drain(.mouse, 0, &buf));
    // Half notches: the second completes one.
    try j.inject(.{ .scroll = .{ .dx = 0, .dy = 60, .time = 0 } });
    try j.inject(.{ .scroll = .{ .dx = 0, .dy = 60, .time = 0 } });
    try expectEvents(&.{
        .{ ui.EV_REL, ui.REL_WHEEL_HI_RES, 60 }, SYN,
        .{ ui.EV_REL, ui.REL_WHEEL_HI_RES, 60 }, .{ ui.EV_REL, ui.REL_WHEEL, 1 },
        SYN,
    }, po.drain(.mouse, 0, &buf));
    // A partial notch is dropped when the direction changes.
    try j.inject(.{ .scroll = .{ .dx = 0, .dy = 90, .time = 0 } });
    try j.inject(.{ .scroll = .{ .dx = -240, .dy = -60, .time = 0 } });
    try expectEvents(&.{
        .{ ui.EV_REL, ui.REL_WHEEL_HI_RES, 90 },  SYN,
        .{ ui.EV_REL, ui.REL_WHEEL_HI_RES, -60 }, .{ ui.EV_REL, ui.REL_HWHEEL_HI_RES, -240 },
        .{ ui.EV_REL, ui.REL_HWHEEL, -2 },        SYN,
    }, po.drain(.mouse, 0, &buf));
}

test "absolute positions map onto the output's pixels through a tablet" {
    var po: PipeOpener = .{};
    var j = try Injector.init(po.opener());
    defer j.deinit();
    var buf: [64]ui.Event = undefined;
    try testing.expectEqual(@as(?i32, null), po.read[2]); // not until the first abs

    j.setOutput(.{ .width = 1920, .height = 1080 });
    try j.inject(.{ .abs = .{ .x = 0, .y = 65535 } });
    try j.inject(.{ .abs = .{ .x = 32768, .y = 32768 } });
    try expectEvents(&.{
        .{ ui.EV_ABS, ui.ABS_X, 0 },   .{ ui.EV_ABS, ui.ABS_Y, 1079 }, SYN,
        .{ ui.EV_ABS, ui.ABS_X, 960 }, .{ ui.EV_ABS, ui.ABS_Y, 540 },  SYN,
    }, po.drain(.tablet, 0, &buf));
    const s = po.specs[2].?;
    try testing.expectEqual(@as(i32, 1919), s.abs_max[0]);
    try testing.expectEqual(@as(i32, 1079), s.abs_max[1]);
    try testing.expectEqual(@as(?u16, ui.INPUT_PROP_DIRECT), s.prop);

    // A new output size makes a new tablet with the new range.
    j.setOutput(.{ .width = 1280, .height = 720 });
    try j.inject(.{ .abs = .{ .x = 65535, .y = 0 } });
    try testing.expectEqual(@as(u32, 2), po.opened[2]);
    try expectEvents(&.{ .{ ui.EV_ABS, ui.ABS_X, 1279 }, .{ ui.EV_ABS, ui.ABS_Y, 0 }, SYN }, po.drain(.tablet, 0, &buf));
    try testing.expectEqual(@as(i32, 1279), po.specs[2].?.abs_max[0]);
}

test "pads: created on connect with the Xbox 360 layout, removed on disconnect" {
    var po: PipeOpener = .{};
    var j = try Injector.init(po.opener());
    defer j.deinit();
    var buf: [64]ui.Event = undefined;
    const B = PadButton;

    const g: Gamepad = .{ .buttons = B.a | B.y | B.left_shoulder | B.guide | B.dpad_up | B.dpad_right, .lx = 32767, .ly = 32767, .rx = -32768, .ry = -32768, .lt = 65535, .rt = 64 };
    try j.inject(.{ .pad = .{ .index = 1, .connected = true, .state = g } });
    try testing.expect(po.read[3] == null and po.read[4] != null);
    const s = po.specs[4].?;
    try testing.expectEqual(@as(u16, 0x045e), s.vendor);
    try testing.expectEqual(@as(u16, 0x028e), s.product);
    try testing.expectEqual(@as(u16, ui.BUS_USB), s.bustype);
    try expectEvents(&.{
        .{ ui.EV_KEY, ui.BTN_SOUTH, 1 },  .{ ui.EV_KEY, ui.BTN_EAST, 0 },    .{ ui.EV_KEY, ui.BTN_NORTH, 0 },  .{ ui.EV_KEY, ui.BTN_WEST, 1 },
        .{ ui.EV_KEY, ui.BTN_TL, 1 },     .{ ui.EV_KEY, ui.BTN_TR, 0 },      .{ ui.EV_KEY, ui.BTN_SELECT, 0 }, .{ ui.EV_KEY, ui.BTN_START, 0 },
        .{ ui.EV_KEY, ui.BTN_MODE, 1 },   .{ ui.EV_KEY, ui.BTN_THUMBL, 0 },  .{ ui.EV_KEY, ui.BTN_THUMBR, 0 },
        // Stick Y is flipped: XInput up (+32767) is evdev's -32767.
        .{ ui.EV_ABS, ui.ABS_X, 32767 },
        .{ ui.EV_ABS, ui.ABS_Y, -32767 }, .{ ui.EV_ABS, ui.ABS_RX, -32768 }, .{ ui.EV_ABS, ui.ABS_RY, 32767 }, .{ ui.EV_ABS, ui.ABS_Z, 1023 },
        .{ ui.EV_ABS, ui.ABS_RZ, 1 },     .{ ui.EV_ABS, ui.ABS_HAT0X, 1 },   .{ ui.EV_ABS, ui.ABS_HAT0Y, -1 }, SYN,
    }, po.drain(.pad, 1, &buf));

    // A second snapshot reuses the device.
    try j.inject(.{ .pad = .{ .index = 1, .connected = true, .state = .{} } });
    try testing.expectEqual(@as(u32, 1), po.opened[4]);
    try testing.expectEqual(@as(usize, 20), po.drain(.pad, 1, &buf).len);

    try j.inject(.{ .pad = .{ .index = 1, .connected = false, .state = .{} } });
    try testing.expectEqual(@as(?i32, null), po.read[4]);
    try testing.expectEqual(@as(?ui.Device, null), j.pads[1]);
    // Past the last pad: dropped.
    try j.inject(.{ .pad = .{ .index = 4, .connected = true, .state = .{} } });
    try testing.expectEqual(@as(u64, 1), j.stats.unmapped);
}

test "a pad that cannot be created is an error, and the next snapshot tries again" {
    var po: PipeOpener = .{ .fail_pads = true };
    testing.log_level = .err; // the warning about the pad is expected here
    defer testing.log_level = .warn;
    var j = try Injector.init(po.opener());
    defer j.deinit();
    try testing.expectError(error.BackendFailed, j.inject(.{ .pad = .{ .index = 0, .connected = true, .state = .{} } }));
    po.fail_pads = false;
    try j.inject(.{ .pad = .{ .index = 0, .connected = true, .state = .{} } });
    try testing.expect(j.pads[0] != null);
    try testing.expectEqual(@as(u64, 1), j.stats.device_errors);
}

test "scaleAbs" {
    try testing.expectEqual(@as(i32, 0), scaleAbs(0, 1920));
    try testing.expectEqual(@as(i32, 1919), scaleAbs(65535, 1920));
    try testing.expectEqual(@as(i32, 65535), scaleAbs(65535, 65536));
    try testing.expectEqual(@as(i32, 0), scaleAbs(65535, 1));
}
