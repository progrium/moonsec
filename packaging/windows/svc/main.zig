//! `moonsec-svc.exe`: the Windows host service. Desktop Duplication, WASAPI loopback and
//! SendInput only work inside the user's interactive session, so the service (session 0,
//! LocalSystem) does no capture itself: it starts the host agent (`moonsec.exe`) in the
//! active console session as the logged-on user, restarts it when it exits, and moves it
//! when the console session changes (logon, logoff, fast user switching, RDP reconnect to
//! the console). This is how Sunshine splits its service and its per-session process.
//!
//! The agent's command line comes from `HKLM\SOFTWARE\moonsec\AgentCommandLine` (REG_SZ)
//! or `logic.default_agent_cmdline`; `{dir}` is this executable's directory and `%VAR%`
//! expands in the user's environment. The agent's stdout and stderr go to
//! `%ProgramData%\moonsec\agent.log`, the service's own lines to `service.log` there.
//!
//! The installer (packaging/windows/moonsec.wxs) registers it as the `moonsec` service
//! (automatic start). `moonsec-svc.exe --console` runs the same loop in a console for
//! debugging, as an administrator with SeTcbPrivilege (for example from `psexec -s`).
const std = @import("std");
const logic = @import("logic.zig");

const BOOL = c_int;
const DWORD = u32;
const HANDLE = *anyopaque;
const WCHAR = u16;
const LPCWSTR = [*:0]const WCHAR;
const WINAPI: std.builtin.CallingConvention = .winapi;

const SERVICE_TABLE_ENTRYW = extern struct { name: ?LPCWSTR, proc: ?*const fn (DWORD, ?[*]LPCWSTR) callconv(WINAPI) void };
const SERVICE_STATUS = extern struct {
    service_type: DWORD = 0x10, // SERVICE_WIN32_OWN_PROCESS
    current_state: DWORD,
    controls_accepted: DWORD = 0,
    win32_exit_code: DWORD = 0,
    service_specific_exit_code: DWORD = 0,
    check_point: DWORD = 0,
    wait_hint: DWORD = 0,
};
const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    reserved: ?LPCWSTR = null,
    desktop: ?LPCWSTR = null,
    title: ?LPCWSTR = null,
    x: DWORD = 0,
    y: DWORD = 0,
    x_size: DWORD = 0,
    y_size: DWORD = 0,
    x_chars: DWORD = 0,
    y_chars: DWORD = 0,
    fill_attribute: DWORD = 0,
    flags: DWORD = 0,
    show_window: u16 = 0,
    reserved2_len: u16 = 0,
    reserved2: ?*u8 = null,
    std_input: ?HANDLE = null,
    std_output: ?HANDLE = null,
    std_error: ?HANDLE = null,
};
const PROCESS_INFORMATION = extern struct { process: HANDLE, thread: HANDLE, pid: DWORD, tid: DWORD };
const SECURITY_ATTRIBUTES = extern struct { len: DWORD = @sizeOf(SECURITY_ATTRIBUTES), sd: ?*anyopaque = null, inherit: BOOL = 1 };

const SERVICE_STOPPED = 1;
const SERVICE_START_PENDING = 2;
const SERVICE_STOP_PENDING = 3;
const SERVICE_RUNNING = 4;
const SERVICE_ACCEPT_STOP = 0x1;
const SERVICE_ACCEPT_SHUTDOWN = 0x4;
const SERVICE_ACCEPT_SESSIONCHANGE = 0x80;
const SERVICE_CONTROL_STOP = 1;
const SERVICE_CONTROL_INTERROGATE = 4;
const SERVICE_CONTROL_SHUTDOWN = 5;
const SERVICE_CONTROL_SESSIONCHANGE = 14;
const NO_ERROR = 0;
const ERROR_CALL_NOT_IMPLEMENTED = 120;
const WAIT_OBJECT_0 = 0;
const WAIT_TIMEOUT = 258;
const STARTF_USESTDHANDLES = 0x100;
const CREATE_UNICODE_ENVIRONMENT = 0x400;
const CREATE_NO_WINDOW = 0x08000000;
const RRF_RT_REG_SZ = 0x2;
const HKEY_LOCAL_MACHINE: usize = 0x80000002;
const FILE_APPEND_DATA = 0x4;
const SYNCHRONIZE = 0x00100000;
const FILE_SHARE_READ = 1;
const FILE_SHARE_WRITE = 2;
const OPEN_ALWAYS = 4;
const FILE_ATTRIBUTE_NORMAL = 0x80;
const no_session: DWORD = 0xFFFFFFFF;

extern "advapi32" fn StartServiceCtrlDispatcherW(table: [*]const SERVICE_TABLE_ENTRYW) callconv(WINAPI) BOOL;
extern "advapi32" fn RegisterServiceCtrlHandlerExW(name: LPCWSTR, handler: *const fn (DWORD, DWORD, ?*anyopaque, ?*anyopaque) callconv(WINAPI) DWORD, ctx: ?*anyopaque) callconv(WINAPI) ?HANDLE;
extern "advapi32" fn SetServiceStatus(h: HANDLE, status: *const SERVICE_STATUS) callconv(WINAPI) BOOL;
extern "advapi32" fn CreateProcessAsUserW(token: HANDLE, app: ?LPCWSTR, cmd: [*:0]WCHAR, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?LPCWSTR, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(WINAPI) BOOL;
extern "advapi32" fn RegGetValueW(key: usize, sub: LPCWSTR, value: LPCWSTR, flags: DWORD, typ: ?*DWORD, data: ?*anyopaque, len: *DWORD) callconv(WINAPI) i32;
extern "wtsapi32" fn WTSQueryUserToken(session: DWORD, token: *HANDLE) callconv(WINAPI) BOOL;
extern "userenv" fn CreateEnvironmentBlock(env: *?*anyopaque, token: HANDLE, inherit: BOOL) callconv(WINAPI) BOOL;
extern "userenv" fn DestroyEnvironmentBlock(env: *anyopaque) callconv(WINAPI) BOOL;
extern "userenv" fn ExpandEnvironmentStringsForUserW(token: HANDLE, src: LPCWSTR, dst: [*]WCHAR, size: DWORD) callconv(WINAPI) BOOL;
extern "kernel32" fn WTSGetActiveConsoleSessionId() callconv(WINAPI) DWORD;
extern "kernel32" fn CreateEventW(sa: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?LPCWSTR) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn ResetEvent(h: HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn WaitForMultipleObjects(n: DWORD, handles: [*]const HANDLE, all: BOOL, ms: DWORD) callconv(WINAPI) DWORD;
extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(WINAPI) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(WINAPI) DWORD;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;
extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, buf: [*]WCHAR, size: DWORD) callconv(WINAPI) DWORD;
extern "kernel32" fn GetCommandLineW() callconv(WINAPI) LPCWSTR;
extern "kernel32" fn GetTickCount64() callconv(WINAPI) u64;
extern "kernel32" fn ExpandEnvironmentStringsW(src: LPCWSTR, dst: [*]WCHAR, size: DWORD) callconv(WINAPI) DWORD;
extern "kernel32" fn CreateDirectoryW(path: LPCWSTR, sa: ?*anyopaque) callconv(WINAPI) BOOL;
extern "kernel32" fn CreateFileW(path: LPCWSTR, access: DWORD, share: DWORD, sa: ?*SECURITY_ATTRIBUTES, disp: DWORD, attrs: DWORD, template: ?HANDLE) callconv(WINAPI) HANDLE;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(WINAPI) BOOL;

const W = std.unicode.utf8ToUtf16LeStringLiteral;
const service_name = W("moonsec");
const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));

var gpa_state: std.heap.DebugAllocator(.{}) = .init;
var status_handle: ?HANDLE = null;
var stop_event: HANDLE = undefined;
var session_event: HANDLE = undefined;
var log_file: ?HANDLE = null;

pub fn main() void {
    stop_event = CreateEventW(null, 1, 0, null) orelse return;
    session_event = CreateEventW(null, 0, 0, null) orelse return;
    // `--console`: the same loop without the service control manager (Ctrl+C to stop).
    const cmdline = std.mem.sliceTo(GetCommandLineW(), 0);
    if (std.mem.indexOf(u16, cmdline, W("--console")) != null) {
        run();
        return;
    }
    const table = [_]SERVICE_TABLE_ENTRYW{ .{ .name = service_name, .proc = serviceMain }, .{ .name = null, .proc = null } };
    if (StartServiceCtrlDispatcherW(&table) == 0) {
        // Not started by the SCM (error 1063): say how to run it.
        std.debug.print("moonsec-svc: run as the `moonsec` service, or with --console (error {d})\n", .{GetLastError()});
    }
}

fn serviceMain(_: DWORD, _: ?[*]LPCWSTR) callconv(WINAPI) void {
    status_handle = RegisterServiceCtrlHandlerExW(service_name, handler, null) orelse return;
    report(SERVICE_START_PENDING, 0);
    run();
    report(SERVICE_STOPPED, 0);
}

fn report(state: DWORD, wait_hint: DWORD) void {
    const h = status_handle orelse return;
    const accepts: DWORD = if (state == SERVICE_RUNNING) SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_SESSIONCHANGE else 0;
    _ = SetServiceStatus(h, &.{ .current_state = state, .controls_accepted = accepts, .wait_hint = wait_hint });
}

fn handler(control: DWORD, _: DWORD, _: ?*anyopaque, _: ?*anyopaque) callconv(WINAPI) DWORD {
    switch (control) {
        SERVICE_CONTROL_STOP, SERVICE_CONTROL_SHUTDOWN => {
            report(SERVICE_STOP_PENDING, 5000);
            _ = SetEvent(stop_event);
        },
        // Any logon, logoff, lock or console change: re-check which session owns the console.
        SERVICE_CONTROL_SESSIONCHANGE => _ = SetEvent(session_event),
        SERVICE_CONTROL_INTERROGATE => {},
        else => return ERROR_CALL_NOT_IMPLEMENTED,
    }
    return NO_ERROR;
}

const Agent = struct {
    process: ?HANDLE = null,
    session: DWORD = no_session,
    started_ms: u64 = 0,

    fn stop(self: *Agent) void {
        const p = self.process orelse return;
        // The host has no shutdown request yet; ending the process drops the connection,
        // and the client sees the host go away as it would on a network loss.
        _ = TerminateProcess(p, 0);
        _ = WaitForSingleObject(p, 5000);
        _ = CloseHandle(p);
        self.process = null;
        log("agent stopped (session {d})", .{self.session});
        self.session = no_session;
    }
};

fn run() void {
    const gpa = gpa_state.allocator();
    openLog();
    report(SERVICE_RUNNING, 0);
    log("service running", .{});
    var agent: Agent = .{};
    var backoff: logic.Backoff = .{};
    var retry_at: u64 = 0;
    while (true) {
        const console = WTSGetActiveConsoleSessionId();
        // The console moved: the agent's session no longer shows the screen.
        if (agent.process != null and agent.session != console) agent.stop();
        const now = GetTickCount64();
        if (agent.process == null and console != no_session and now >= retry_at) {
            if (start(gpa, console)) |p| {
                agent = .{ .process = p, .session = console, .started_ms = now };
            } else |e| {
                // No user logged on yet (WTSQueryUserToken fails) is the common case.
                retry_at = now + backoff.next(0);
                log("agent not started in session {d}: {s} (error {d})", .{ console, @errorName(e), GetLastError() });
            }
        }
        var handles = [3]HANDLE{ stop_event, session_event, undefined };
        var n: DWORD = 2;
        if (agent.process) |p| {
            handles[2] = p;
            n = 3;
        }
        const r = WaitForMultipleObjects(n, &handles, 0, 2000);
        if (r == WAIT_OBJECT_0) break;
        if (r == WAIT_OBJECT_0 + 2) {
            const ran = GetTickCount64() - agent.started_ms;
            _ = CloseHandle(agent.process.?);
            log("agent exited after {d} ms (session {d})", .{ ran, agent.session });
            agent = .{};
            retry_at = GetTickCount64() + backoff.next(ran);
        }
    }
    agent.stop();
    log("service stopped", .{});
}

fn start(gpa: std.mem.Allocator, session: DWORD) !HANDLE {
    var token: HANDLE = undefined;
    if (WTSQueryUserToken(session, &token) == 0) return error.NoUserToken;
    defer _ = CloseHandle(token);
    var env: ?*anyopaque = null;
    if (CreateEnvironmentBlock(&env, token, 0) == 0) return error.Environment;
    defer _ = DestroyEnvironmentBlock(env.?);

    const cmd = try agentCommandLine(gpa, token);
    defer gpa.free(cmd);
    var si: STARTUPINFOW = .{ .desktop = W("winsta0\\default") };
    if (log_file) |f| {
        si.flags = STARTF_USESTDHANDLES;
        si.std_output = f;
        si.std_error = f;
    }
    var pi: PROCESS_INFORMATION = undefined;
    if (CreateProcessAsUserW(token, null, cmd.ptr, null, null, @intFromBool(log_file != null), CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, env, null, &si, &pi) == 0)
        return error.CreateProcess;
    _ = CloseHandle(pi.thread);
    log("agent started (session {d}, pid {d})", .{ session, pi.pid });
    return pi.process;
}

/// The command line from the registry or the default, `{dir}` filled in, `%VAR%` expanded
/// for the user that `token` belongs to.
fn agentCommandLine(gpa: std.mem.Allocator, token: HANDLE) ![:0]u16 {
    var reg_buf: [2048]u16 = undefined;
    var reg_len: DWORD = @sizeOf(@TypeOf(reg_buf));
    const template: []const u8 = if (RegGetValueW(HKEY_LOCAL_MACHINE, W("SOFTWARE\\moonsec"), W("AgentCommandLine"), RRF_RT_REG_SZ, null, &reg_buf, &reg_len) == 0)
        try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(&reg_buf, 0))
    else
        try gpa.dupe(u8, logic.default_agent_cmdline);
    defer gpa.free(template);

    var exe_buf: [1024]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    if (exe_len == 0 or exe_len >= exe_buf.len) return error.ModulePath;
    const exe = try std.unicode.utf16LeToUtf8Alloc(gpa, exe_buf[0..exe_len]);
    defer gpa.free(exe);
    const dir = std.fs.path.dirnameWindows(exe) orelse return error.ModulePath;

    const filled = try logic.substituteDir(gpa, template, dir);
    defer gpa.free(filled);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, filled);
    defer gpa.free(wide);
    const out = try gpa.allocSentinel(u16, 4096, 0);
    errdefer gpa.free(out);
    if (ExpandEnvironmentStringsForUserW(token, wide.ptr, out.ptr, 4096) == 0) return error.Expand;
    return out;
}

/// `%ProgramData%\moonsec\agent.log` (the agent's output) and `service.log` (ours).
var service_log: ?HANDLE = null;

fn openLog() void {
    var dir: [512]u16 = undefined;
    const n = ExpandEnvironmentStringsW(W("%ProgramData%\\moonsec"), &dir, dir.len);
    if (n == 0 or n > dir.len) return;
    _ = CreateDirectoryW(@ptrCast(&dir), null);
    log_file = openAppend(dir[0 .. n - 1], "\\agent.log", true);
    service_log = openAppend(dir[0 .. n - 1], "\\service.log", false);
}

fn openAppend(dir: []const u16, comptime name: []const u8, inherit: bool) ?HANDLE {
    var path: [600]u16 = undefined;
    const tail = W(name);
    if (dir.len + tail.len + 1 > path.len) return null;
    @memcpy(path[0..dir.len], dir);
    @memcpy(path[dir.len..][0..tail.len], tail);
    path[dir.len + tail.len] = 0;
    var sa: SECURITY_ATTRIBUTES = .{ .inherit = @intFromBool(inherit) };
    const h = CreateFileW(@ptrCast(&path), FILE_APPEND_DATA | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    return if (h == invalid_handle) null else h;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] " ++ fmt ++ "\r\n", .{GetTickCount64()} ++ args) catch return;
    if (service_log) |h| _ = WriteFile(h, line.ptr, @intCast(line.len), null, null) else std.debug.print("{s}", .{line});
}

test {
    _ = logic;
}
