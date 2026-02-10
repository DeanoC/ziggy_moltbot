const std = @import("std");
const builtin = @import("builtin");

// Reuse the existing enum for CLI compatibility.
pub const InstallMode = @import("service.zig").InstallMode;

pub const ServiceError = error{
    Unsupported,
    InvalidArguments,
    AccessDenied,
    NotInstalled,
    AlreadyExists,
    ExecFailed,
} || std.mem.Allocator.Error || error{InvalidUtf8};

pub const State = enum {
    unknown,
    not_installed,
    stopped,
    start_pending,
    stop_pending,
    running,
    paused,
};

pub const Query = struct {
    state: State,
    pid: u32 = 0,
    win32_exit_code: u32 = 0,
};

pub const StartType = enum {
    unknown,
    boot,
    system,
    auto,
    demand,
    disabled,
};

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("winsvc.h");
    @cInclude("sddl.h");
});

pub fn defaultServiceName() []const u8 {
    // Keep the historical default for compatibility with the Task Scheduler MVP.
    return "ZiggyStarClaw Node";
}

fn utf16Z(allocator: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, s);
}

fn mapWinErr(err: u32) ServiceError {
    return switch (err) {
        win.ERROR_ACCESS_DENIED => ServiceError.AccessDenied,
        win.ERROR_SERVICE_DOES_NOT_EXIST => ServiceError.NotInstalled,
        win.ERROR_INVALID_NAME => ServiceError.InvalidArguments,
        else => ServiceError.ExecFailed,
    };
}

fn openSCM(desired_access: u32) ServiceError!win.SC_HANDLE {
    const h = win.OpenSCManagerW(null, null, desired_access);
    if (h == null) return mapWinErr(win.GetLastError());
    return h;
}

fn openService(h_scm: win.SC_HANDLE, name_w: [*:0]const u16, desired_access: u32) ServiceError!win.SC_HANDLE {
    const h = win.OpenServiceW(h_scm, name_w, desired_access);
    if (h == null) return mapWinErr(win.GetLastError());
    return h;
}

fn serviceStartType(mode: InstallMode) u32 {
    return switch (mode) {
        .onstart => win.SERVICE_AUTO_START,
        .onlogon => win.SERVICE_DEMAND_START,
    };
}

fn setDescription(h_svc: win.SC_HANDLE, allocator: std.mem.Allocator, desc_utf8: []const u8) void {
    const wdesc = utf16Z(allocator, desc_utf8) catch return;
    defer allocator.free(wdesc);

    var d: win.SERVICE_DESCRIPTIONW = .{ .lpDescription = @ptrCast(wdesc.ptr) };
    _ = win.ChangeServiceConfig2W(h_svc, win.SERVICE_CONFIG_DESCRIPTION, &d);
}

fn setFailureActions(h_svc: win.SC_HANDLE) void {
    // Restart on failure. (Actual retry behavior is controlled by SCM.)
    var actions = [_]win.SC_ACTION{
        .{ .Type = win.SC_ACTION_RESTART, .Delay = 5000 },
        .{ .Type = win.SC_ACTION_RESTART, .Delay = 5000 },
        .{ .Type = win.SC_ACTION_RESTART, .Delay = 5000 },
    };

    var fa: win.SERVICE_FAILURE_ACTIONSW = std.mem.zeroes(win.SERVICE_FAILURE_ACTIONSW);
    fa.dwResetPeriod = 24 * 60 * 60; // 1 day
    fa.cActions = @intCast(actions.len);
    fa.lpsaActions = &actions;
    _ = win.ChangeServiceConfig2W(h_svc, win.SERVICE_CONFIG_FAILURE_ACTIONS, &fa);

    // Also apply failure actions when the service exits with a non-crash error.
    var flag: win.SERVICE_FAILURE_ACTIONS_FLAG = .{ .fFailureActionsOnNonCrashFailures = win.TRUE };
    _ = win.ChangeServiceConfig2W(h_svc, win.SERVICE_CONFIG_FAILURE_ACTIONS_FLAG, &flag);
}

fn setDelayedAutoStartIfNeeded(h_svc: win.SC_HANDLE, mode: InstallMode) void {
    if (mode != .onstart) return;
    var info: win.SERVICE_DELAYED_AUTO_START_INFO = .{ .fDelayedAutostart = win.TRUE };
    _ = win.ChangeServiceConfig2W(h_svc, win.SERVICE_CONFIG_DELAYED_AUTO_START_INFO, &info);
}

fn setServiceDacl(h_svc: win.SC_HANDLE) void {
    // Allow Authenticated Users to query/start/stop the service so the tray app
    // can control it without admin.
    //
    // Rights legend (services):
    // - RP = start, WP = stop, DT = pause/continue, LO = interrogate, CR = user-defined control
    // - CC/LC/SW... = query config/status/enumerate dependents
    const sddl_utf8 =
        "D:" ++
        "(A;;CCLCSWRPWPDTLOCRRC;;;AU)" ++ // Authenticated Users: read/query + start/stop
        "(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)" ++ // Built-in Admins: full
        "(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)"; // LocalSystem: full

    const a = std.heap.page_allocator;
    const wsddl = utf16Z(a, sddl_utf8) catch return;
    defer a.free(wsddl);

    var sd: ?*anyopaque = null;
    if (win.ConvertStringSecurityDescriptorToSecurityDescriptorW(wsddl.ptr, win.SDDL_REVISION_1, @ptrCast(&sd), null) == 0) {
        sd = null;
    }
    defer if (sd) |p| {
        _ = win.LocalFree(@ptrCast(p));
    };

    if (sd == null) return;
    _ = win.SetServiceObjectSecurity(h_svc, win.DACL_SECURITY_INFORMATION, @ptrCast(sd.?));
}

pub fn installService(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    mode: InstallMode,
    name_opt: ?[]const u8,
) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;

    const service_name = name_opt orelse defaultServiceName();
    if (std.mem.indexOfScalar(u8, service_name, '\\') != null) return ServiceError.InvalidArguments;

    const exe_path = std.fs.selfExePathAlloc(allocator) catch return ServiceError.ExecFailed;
    defer allocator.free(exe_path);

    // Quote paths defensively.
    const bin_path = std.fmt.allocPrint(
        allocator,
        "\"{s}\" --windows-service --node-service-name \"{s}\" --config \"{s}\" --as-node --no-operator --log-level info",
        .{ exe_path, service_name, config_path },
    ) catch return ServiceError.ExecFailed;
    defer allocator.free(bin_path);

    const wname = utf16Z(allocator, service_name) catch return ServiceError.ExecFailed;
    defer allocator.free(wname);
    const wbin = utf16Z(allocator, bin_path) catch return ServiceError.ExecFailed;
    defer allocator.free(wbin);

    const h_scm = try openSCM(win.SC_MANAGER_CONNECT | win.SC_MANAGER_CREATE_SERVICE);
    defer _ = win.CloseServiceHandle(h_scm);

    // If it already exists, update it in place.
    const existing = win.OpenServiceW(h_scm, wname.ptr, win.SERVICE_CHANGE_CONFIG | win.READ_CONTROL | win.WRITE_DAC);
    if (existing != null) {
        defer _ = win.CloseServiceHandle(existing);

        if (win.ChangeServiceConfigW(
            existing,
            win.SERVICE_WIN32_OWN_PROCESS,
            serviceStartType(mode),
            win.SERVICE_ERROR_NORMAL,
            wbin.ptr,
            null,
            null,
            null,
            null,
            null,
            wname.ptr,
        ) == 0) {
            return mapWinErr(win.GetLastError());
        }

        setDescription(existing, allocator, "ZiggyStarClaw capability node (SCM service)");
        setFailureActions(existing);
        setDelayedAutoStartIfNeeded(existing, mode);
        setServiceDacl(existing);
        return;
    }

    // Create a new service.
    const h_svc = win.CreateServiceW(
        h_scm,
        wname.ptr,
        wname.ptr,
        win.SERVICE_ALL_ACCESS,
        win.SERVICE_WIN32_OWN_PROCESS,
        serviceStartType(mode),
        win.SERVICE_ERROR_NORMAL,
        wbin.ptr,
        null,
        null,
        null,
        null,
        null,
    );

    if (h_svc == null) {
        const err = win.GetLastError();
        if (err == win.ERROR_SERVICE_EXISTS) return ServiceError.AlreadyExists;
        return mapWinErr(err);
    }
    defer _ = win.CloseServiceHandle(h_svc);

    setDescription(h_svc, allocator, "ZiggyStarClaw capability node (SCM service)");
    setFailureActions(h_svc);
    setDelayedAutoStartIfNeeded(h_svc, mode);
    setServiceDacl(h_svc);
}

pub fn uninstallService(allocator: std.mem.Allocator, name_opt: ?[]const u8) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const service_name = name_opt orelse defaultServiceName();

    const wname = try utf16Z(allocator, service_name);
    defer allocator.free(wname);

    const h_scm = try openSCM(win.SC_MANAGER_CONNECT);
    defer _ = win.CloseServiceHandle(h_scm);

    const h_svc = openService(h_scm, wname.ptr, win.DELETE | win.SERVICE_STOP | win.SERVICE_QUERY_STATUS) catch |err| switch (err) {
        ServiceError.NotInstalled => return,
        else => return err,
    };
    defer _ = win.CloseServiceHandle(h_svc);

    // Best-effort stop.
    _ = stopService(allocator, name_opt) catch {};

    if (win.DeleteService(h_svc) == 0) return mapWinErr(win.GetLastError());
}

pub fn startService(allocator: std.mem.Allocator, name_opt: ?[]const u8) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const service_name = name_opt orelse defaultServiceName();

    const wname = try utf16Z(allocator, service_name);
    defer allocator.free(wname);

    const h_scm = try openSCM(win.SC_MANAGER_CONNECT);
    defer _ = win.CloseServiceHandle(h_scm);

    const h_svc = try openService(h_scm, wname.ptr, win.SERVICE_START | win.SERVICE_QUERY_STATUS);
    defer _ = win.CloseServiceHandle(h_svc);

    if (win.StartServiceW(h_svc, 0, null) == 0) {
        const err = win.GetLastError();
        // If already running, treat as success.
        if (err != win.ERROR_SERVICE_ALREADY_RUNNING) return mapWinErr(err);
    }

    // Best-effort wait for running.
    _ = waitForState(h_svc, .running, 20_000) catch {};
}

pub fn stopService(allocator: std.mem.Allocator, name_opt: ?[]const u8) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const service_name = name_opt orelse defaultServiceName();

    const wname = try utf16Z(allocator, service_name);
    defer allocator.free(wname);

    const h_scm = try openSCM(win.SC_MANAGER_CONNECT);
    defer _ = win.CloseServiceHandle(h_scm);

    const h_svc = try openService(h_scm, wname.ptr, win.SERVICE_STOP | win.SERVICE_QUERY_STATUS);
    defer _ = win.CloseServiceHandle(h_svc);

    var status: win.SERVICE_STATUS = std.mem.zeroes(win.SERVICE_STATUS);
    if (win.ControlService(h_svc, win.SERVICE_CONTROL_STOP, &status) == 0) {
        const err = win.GetLastError();
        // If not running, consider it stopped.
        if (err != win.ERROR_SERVICE_NOT_ACTIVE) return mapWinErr(err);
    }

    _ = waitForState(h_svc, .stopped, 20_000) catch {};
}

pub fn queryService(allocator: std.mem.Allocator, name_opt: ?[]const u8) ServiceError!Query {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const service_name = name_opt orelse defaultServiceName();

    const wname = try utf16Z(allocator, service_name);
    defer allocator.free(wname);

    const h_scm = try openSCM(win.SC_MANAGER_CONNECT);
    defer _ = win.CloseServiceHandle(h_scm);

    const h_svc = openService(h_scm, wname.ptr, win.SERVICE_QUERY_STATUS) catch |err| switch (err) {
        ServiceError.NotInstalled => return .{ .state = .not_installed },
        else => return err,
    };
    defer _ = win.CloseServiceHandle(h_svc);

    var ssp: win.SERVICE_STATUS_PROCESS = std.mem.zeroes(win.SERVICE_STATUS_PROCESS);
    var needed: u32 = 0;
    if (win.QueryServiceStatusEx(
        h_svc,
        win.SC_STATUS_PROCESS_INFO,
        @ptrCast(&ssp),
        @sizeOf(win.SERVICE_STATUS_PROCESS),
        &needed,
    ) == 0) {
        return mapWinErr(win.GetLastError());
    }

    return .{
        .state = stateFromWin(ssp.dwCurrentState),
        .pid = @intCast(ssp.dwProcessId),
        .win32_exit_code = @intCast(ssp.dwWin32ExitCode),
    };
}

pub fn queryStartType(allocator: std.mem.Allocator, name_opt: ?[]const u8) ServiceError!StartType {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const service_name = name_opt orelse defaultServiceName();

    const wname = try utf16Z(allocator, service_name);
    defer allocator.free(wname);

    const h_scm = try openSCM(win.SC_MANAGER_CONNECT);
    defer _ = win.CloseServiceHandle(h_scm);

    const h_svc = try openService(h_scm, wname.ptr, win.SERVICE_QUERY_CONFIG);
    defer _ = win.CloseServiceHandle(h_svc);

    var needed: u32 = 0;
    _ = win.QueryServiceConfigW(h_svc, null, 0, &needed);
    const e = win.GetLastError();
    if (e != win.ERROR_INSUFFICIENT_BUFFER) return mapWinErr(e);

    const buf = try allocator.alloc(u8, needed);
    defer allocator.free(buf);

    const cfg: *win.QUERY_SERVICE_CONFIGW = @ptrCast(@alignCast(buf.ptr));
    if (win.QueryServiceConfigW(h_svc, cfg, needed, &needed) == 0) {
        return mapWinErr(win.GetLastError());
    }

    return startTypeFromWin(cfg.dwStartType);
}

fn stateFromWin(s: u32) State {
    return switch (s) {
        win.SERVICE_STOPPED => .stopped,
        win.SERVICE_START_PENDING => .start_pending,
        win.SERVICE_STOP_PENDING => .stop_pending,
        win.SERVICE_RUNNING => .running,
        win.SERVICE_PAUSED => .paused,
        else => .unknown,
    };
}

fn startTypeFromWin(s: u32) StartType {
    return switch (s) {
        win.SERVICE_BOOT_START => .boot,
        win.SERVICE_SYSTEM_START => .system,
        win.SERVICE_AUTO_START => .auto,
        win.SERVICE_DEMAND_START => .demand,
        win.SERVICE_DISABLED => .disabled,
        else => .unknown,
    };
}

pub fn stateLabel(state: State) []const u8 {
    return switch (state) {
        .unknown => "unknown",
        .not_installed => "not installed",
        .stopped => "stopped",
        .start_pending => "start pending",
        .stop_pending => "stop pending",
        .running => "running",
        .paused => "paused",
    };
}

fn waitForState(h_svc: win.SC_HANDLE, desired: State, timeout_ms: u32) ServiceError!void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        var ssp: win.SERVICE_STATUS_PROCESS = std.mem.zeroes(win.SERVICE_STATUS_PROCESS);
        var needed: u32 = 0;
        if (win.QueryServiceStatusEx(
            h_svc,
            win.SC_STATUS_PROCESS_INFO,
            @ptrCast(&ssp),
            @sizeOf(win.SERVICE_STATUS_PROCESS),
            &needed,
        ) == 0) {
            return mapWinErr(win.GetLastError());
        }
        if (stateFromWin(ssp.dwCurrentState) == desired) return;
        std.Thread.sleep(150 * std.time.ns_per_ms);
    }
    // timeout is not fatal for our CLI UX.
}
