const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// Windows tray app MVP: status + start/stop/restart + open logs.
//
// NOTE: This is intentionally minimal and Windows-only.
// - Uses Task Scheduler helper task "ZiggyStarClaw Node" (same default as ziggystarclaw-cli node service ...)
// - Spawns ziggystarclaw-cli where available; falls back to schtasks.
// - Logs basic tray actions to %APPDATA%\\ZiggyStarClaw\\tray.log for troubleshooting.

pub fn main() !void {
    if (builtin.os.tag != .windows) {
        @compileError("ziggystarclaw-tray is Windows-only");
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try trayMain(allocator);
}

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

const WM_TRAYICON: u32 = win.WM_APP + 1;
const TIMER_STATUS: usize = 1;

const NODE_CONTROL_PIPE: []const u8 = "\\\\.\\pipe\\ZiggyStarClaw.NodeControl";

const IDM_COPY_VERSION: u16 = 998;
const IDM_VERSION: u16 = 999;
const IDM_STATUS: u16 = 1000;
const IDM_START: u16 = 1001;
const IDM_STOP: u16 = 1002;
const IDM_RESTART: u16 = 1003;
const IDM_OPEN_LOGS: u16 = 1004;
const IDM_OPEN_CONFIG: u16 = 1005;
const IDM_EXIT: u16 = 1099;

const ServiceState = enum {
    unknown,
    not_installed,
    running,
    stopped,
};

var g_allocator: std.mem.Allocator = undefined;
var g_hwnd: win.HWND = null;
var g_nid: win.NOTIFYICONDATAW = undefined;
var g_state: ServiceState = .unknown;
var g_tip_buf: [128]u16 = undefined;

fn trayMain(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;

    // Single instance (best-effort)
    const mutex_name = try utf16Z(allocator, "ZiggyStarClaw.Tray.Singleton");
    defer allocator.free(mutex_name);
    const hMutex = win.CreateMutexW(null, win.TRUE, mutex_name.ptr);
    if (hMutex != null) {
        // ERROR_ALREADY_EXISTS = 183
        if (win.GetLastError() == 183) {
            // Another instance is running.
            _ = win.CloseHandle(hMutex);
            return;
        }
    }

    const hInstance = win.GetModuleHandleW(null);

    const class_name = try utf16Z(allocator, "ZiggyStarClawTrayWnd");
    defer allocator.free(class_name);

    var wc: win.WNDCLASSEXW = std.mem.zeroes(win.WNDCLASSEXW);
    wc.cbSize = @sizeOf(win.WNDCLASSEXW);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = class_name.ptr;

    if (win.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    g_hwnd = win.CreateWindowExW(
        0,
        class_name.ptr,
        class_name.ptr,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        hInstance,
        null,
    );
    if (g_hwnd == null) return error.CreateWindowFailed;

    // Add tray icon
    const icon_name = utf16Z(allocator, "ZSC_ICON") catch null;
    defer if (icon_name) |v| allocator.free(v);

    const icon = (if (icon_name) |v|
        win.LoadIconW(hInstance, @ptrCast(v.ptr))
    else
        null) orelse return error.IconLoadFailed;

    g_nid = std.mem.zeroes(win.NOTIFYICONDATAW);
    g_nid.cbSize = @sizeOf(win.NOTIFYICONDATAW);
    g_nid.hWnd = g_hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAYICON;
    g_nid.hIcon = icon;

    updateTipText(.unknown);
    @memcpy(g_nid.szTip[0..g_tip_buf.len], g_tip_buf[0..g_tip_buf.len]);

    if (win.Shell_NotifyIconW(win.NIM_ADD, &g_nid) == 0) return error.NotifyIconAddFailed;
    // (No NIM_SETVERSION on some header versions; keep MVP simple.)

    // Poll status every 5s.
    _ = win.SetTimer(g_hwnd, TIMER_STATUS, 5000, null);
    // Initial status update.
    refreshStatus();

    var msg: win.MSG = undefined;
    while (win.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }

    if (hMutex != null) _ = win.CloseHandle(hMutex);
}

fn refreshStatus() void {
    const new_state = queryServiceState(g_allocator) catch .unknown;
    if (new_state != g_state) {
        g_state = new_state;
        updateTipText(g_state);
        g_nid.uFlags = win.NIF_TIP;
        @memcpy(g_nid.szTip[0..g_tip_buf.len], g_tip_buf[0..g_tip_buf.len]);
        _ = win.Shell_NotifyIconW(win.NIM_MODIFY, &g_nid);
    }
}

fn updateTipText(state: ServiceState) void {
    const txt = switch (state) {
        .unknown => std.fmt.comptimePrint("ZSC {s}+{s}: status unknown", .{ build_options.app_version, build_options.git_rev }),
        .not_installed => std.fmt.comptimePrint("ZSC {s}+{s}: not installed", .{ build_options.app_version, build_options.git_rev }),
        .running => std.fmt.comptimePrint("ZSC {s}+{s}: running", .{ build_options.app_version, build_options.git_rev }),
        .stopped => std.fmt.comptimePrint("ZSC {s}+{s}: stopped", .{ build_options.app_version, build_options.git_rev }),
    };
    // Clear buffer
    @memset(&g_tip_buf, 0);
    const tip16 = std.unicode.utf8ToUtf16LeAlloc(g_allocator, txt) catch return;
    defer g_allocator.free(tip16);
    const n = @min(g_tip_buf.len - 1, tip16.len);
    std.mem.copyForwards(u16, g_tip_buf[0..n], tip16[0..n]);
    g_tip_buf[n] = 0;
}

fn showContextMenu() void {
    const hMenu = win.CreatePopupMenu();
    if (hMenu == null) return;
    defer _ = win.DestroyMenu(hMenu);

    const status_label = switch (g_state) {
        .running => "Status: Running",
        .stopped => "Status: Stopped",
        .not_installed => "Status: Not installed",
        .unknown => "Status: Unknown",
    };

    const version_label = std.fmt.comptimePrint("ZSC Tray {s}+{s}", .{ build_options.app_version, build_options.git_rev });
    appendMenuItem(hMenu, IDM_VERSION, version_label, true);
    appendMenuItem(hMenu, IDM_COPY_VERSION, "Copy Version", false);
    appendMenuItem(hMenu, IDM_STATUS, status_label, true);
    _ = win.AppendMenuW(hMenu, win.MF_SEPARATOR, 0, null);

    // Be permissive: if status is unknown (common when task query is restricted/localized),
    // still allow Start/Stop so the user can try the action and see any error message.
    const can_start = g_state != .running;
    const can_stop = g_state == .running or g_state == .unknown;

    appendMenuItem(hMenu, IDM_START, "Start Node", !can_start);
    appendMenuItem(hMenu, IDM_STOP, "Stop Node", !can_stop);
    appendMenuItem(hMenu, IDM_RESTART, "Restart Node", g_state == .not_installed);

    _ = win.AppendMenuW(hMenu, win.MF_SEPARATOR, 0, null);
    appendMenuItem(hMenu, IDM_OPEN_LOGS, "Open Logs", false);
    appendMenuItem(hMenu, IDM_OPEN_CONFIG, "Open Config Folder", false);

    _ = win.AppendMenuW(hMenu, win.MF_SEPARATOR, 0, null);
    appendMenuItem(hMenu, IDM_EXIT, "Exit", false);

    var pt: win.POINT = undefined;
    _ = win.GetCursorPos(&pt);

    // Required so the menu dismisses correctly.
    _ = win.SetForegroundWindow(g_hwnd);

    _ = win.TrackPopupMenu(
        hMenu,
        win.TPM_RIGHTBUTTON | win.TPM_NONOTIFY,
        pt.x,
        pt.y,
        0,
        g_hwnd,
        null,
    );
}

fn appendMenuItem(hMenu: win.HMENU, id: u16, label_utf8: []const u8, disabled: bool) void {
    const wlabel = utf16Z(g_allocator, label_utf8) catch return;
    defer g_allocator.free(wlabel);

    var flags: u32 = win.MF_STRING;
    if (disabled) flags |= win.MF_GRAYED | win.MF_DISABLED;
    _ = win.AppendMenuW(hMenu, flags, id, wlabel.ptr);
}

fn WndProc(hwnd: win.HWND, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.c) win.LRESULT {
    switch (msg) {
        WM_TRAYICON => {
            // lParam contains the mouse message.
            const mouse_msg: u32 = @truncate(@as(usize, @bitCast(lparam)));
            if (mouse_msg == win.WM_RBUTTONUP or mouse_msg == win.WM_CONTEXTMENU or mouse_msg == win.WM_LBUTTONUP) {
                refreshStatus();
                showContextMenu();
            }
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == TIMER_STATUS) {
                refreshStatus();
            }
            return 0;
        },
        win.WM_COMMAND => {
            const cmd_id: u16 = @intCast(@as(usize, wparam) & 0xffff);
            handleCommand(cmd_id);
            return 0;
        },
        win.WM_DESTROY => {
            _ = win.KillTimer(hwnd, TIMER_STATUS);
            _ = win.Shell_NotifyIconW(win.NIM_DELETE, &g_nid);
            win.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return win.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn handleCommand(cmd_id: u16) void {
    switch (cmd_id) {
        IDM_START => {
            logLine("start requested");
            runServiceAction(g_allocator, .start) catch |err| {
                showError(g_allocator, "Start failed", err);
            };
            refreshStatus();
        },
        IDM_STOP => {
            logLine("stop requested");
            runServiceAction(g_allocator, .stop) catch |err| {
                showError(g_allocator, "Stop failed", err);
            };
            refreshStatus();
        },
        IDM_RESTART => {
            logLine("restart requested");
            // Best-effort: stop then start.
            _ = runServiceAction(g_allocator, .stop) catch {};
            std.Thread.sleep(250 * std.time.ns_per_ms);
            runServiceAction(g_allocator, .start) catch |err| {
                showError(g_allocator, "Restart failed", err);
            };
            refreshStatus();
        },
        IDM_OPEN_LOGS => {
            logLine("open logs requested");
            openLogs(g_allocator) catch |err| {
                showError(g_allocator, "Open logs failed", err);
            };
        },
        IDM_COPY_VERSION => {
            logLine("copy version requested");
            const v = std.fmt.comptimePrint("{s}+{s}", .{ build_options.app_version, build_options.git_rev });
            copyUtf8ToClipboard(g_allocator, v) catch |err| {
                showError(g_allocator, "Copy version failed", err);
                return;
            };
            showInfoBalloon(g_allocator, "ZiggyStarClaw", "Copied version to clipboard");
        },
        IDM_OPEN_CONFIG => {
            logLine("open config folder requested");
            openConfigFolder(g_allocator) catch |err| {
                showError(g_allocator, "Open config folder failed", err);
            };
        },
        IDM_EXIT => {
            logLine("exit requested");
            _ = win.DestroyWindow(g_hwnd);
        },
        else => {},
    }
}

const Action = enum { start, stop, status };

fn runServiceAction(allocator: std.mem.Allocator, action: Action) !void {
    // Prefer the supervisor control pipe if available.
    if (try tryRunPipeServiceAction(allocator, action)) |ok| {
        if (ok) return;
    }

    // Next: invoke ziggystarclaw-cli if present.
    if (try tryRunCliServiceAction(allocator, action)) |ok| {
        if (ok) return;
    }

    // Fallback to schtasks.
    const task_name = "ZiggyStarClaw Node";

    const res = switch (action) {
        .start => try runCapture(allocator, &.{ "schtasks", "/Run", "/TN", task_name }),
        .stop => try runCapture(allocator, &.{ "schtasks", "/End", "/TN", task_name }),
        .status => try runCapture(allocator, &.{ "schtasks", "/Query", "/TN", task_name, "/V", "/FO", "LIST" }),
    };
    defer res.deinit(allocator);

    if (res.exit_code != 0) {
        if (isAccessDenied(res.stdout) or isAccessDenied(res.stderr)) return error.AccessDenied;
        return error.CommandFailed;
    }
}

fn queryServiceState(allocator: std.mem.Allocator) !ServiceState {
    // Prefer the supervisor control pipe if available (works without Task Scheduler permissions).
    if (try queryServiceStatePipe(allocator)) |st| return st;

    // NOTE: Avoid parsing `schtasks /Query` stdout for status.
    // That output is localized (non-English Windows), which would keep the tray
    // state stuck at `.unknown` and disable Start/Stop/Restart.
    if (try queryServiceStatePowerShell(allocator)) |st| return st;

    // Fallback: schtasks (best-effort; may be localized).
    const task_name = "ZiggyStarClaw Node";
    const argv = &.{ "schtasks", "/Query", "/TN", task_name, "/FO", "LIST" };
    const res = try runCapture(allocator, argv);
    defer res.deinit(allocator);

    if (res.exit_code != 0) {
        if (looksLikeNotInstalled(res.stdout) or looksLikeNotInstalled(res.stderr)) return .not_installed;
        return .unknown;
    }

    if (res.stdout.len != 0) {
        // Best-effort parse (English-only).
        if (std.mem.indexOf(u8, res.stdout, "Status:") != null) {
            if (std.mem.indexOf(u8, res.stdout, "Running") != null) return .running;
            return .stopped;
        }
        if (std.mem.indexOf(u8, res.stdout, "Running") != null) return .running;
        if (std.mem.indexOf(u8, res.stdout, "Ready") != null) return .stopped;
    }

    return .unknown;
}

fn queryServiceStatePowerShell(allocator: std.mem.Allocator) !?ServiceState {
    // `Get-ScheduledTask` exposes `State` as an enum; `[int]$t.State` is stable and
    // not localized, unlike `schtasks /Query` output.
    const task_name = "ZiggyStarClaw Node";
    const script = try std.fmt.allocPrint(
        allocator,
        "$t=Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $t) {{ 'NOTFOUND' }} else {{ [int]$t.State }}",
        .{task_name},
    );
    defer allocator.free(script);

    const candidates = [_][]const u8{ "powershell", "powershell.exe" };

    for (candidates) |exe| {
        const argv = &.{ exe, "-NoProfile", "-NonInteractive", "-Command", script };
        const res = runCapture(allocator, argv) catch continue;
        defer res.deinit(allocator);

        if (res.exit_code != 0) continue;

        const out = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (out.len == 0) continue;
        if (std.mem.eql(u8, out, "NOTFOUND")) return .not_installed;

        const state_num = std.fmt.parseInt(i32, out, 10) catch continue;
        // ScheduledTaskState: Unknown=0, Disabled=1, Queued=2, Ready=3, Running=4
        if (state_num == 4) return .running;
        return .stopped;
    }

    // PowerShell not available (or missing Get-ScheduledTask).
    return null;
}

fn pipeRequest(allocator: std.mem.Allocator, cmd: []const u8) !?[]u8 {
    // Returns null when the supervisor pipe isn't available.
    const wpipe = utf16Z(allocator, NODE_CONTROL_PIPE) catch return null;
    defer allocator.free(wpipe);

    const h = win.CreateFileW(
        wpipe.ptr,
        win.GENERIC_READ | win.GENERIC_WRITE,
        0,
        null,
        win.OPEN_EXISTING,
        0,
        null,
    );
    if (h == win.INVALID_HANDLE_VALUE) return null;
    defer _ = win.CloseHandle(h);

    // Write command line.
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s}\n", .{cmd});
    var written: u32 = 0;
    if (win.WriteFile(h, line.ptr, @intCast(line.len), &written, null) == 0) return error.PipeWriteFailed;

    // Read response.
    var out_buf: [256]u8 = undefined;
    var read_n: u32 = 0;
    if (win.ReadFile(h, &out_buf, out_buf.len, &read_n, null) == 0) return error.PipeReadFailed;
    if (read_n == 0) return error.PipeReadFailed;

    return allocator.dupe(u8, out_buf[0..read_n]);
}

fn queryServiceStatePipe(allocator: std.mem.Allocator) !?ServiceState {
    const resp = (try pipeRequest(allocator, "status")) orelse return null;
    defer allocator.free(resp);

    const s = std.mem.trim(u8, resp, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "ok")) return null;
    if (std.mem.indexOf(u8, s, "status=running") != null) return .running;
    if (std.mem.indexOf(u8, s, "status=stopped") != null) return .stopped;
    return .unknown;
}

fn tryRunPipeServiceAction(allocator: std.mem.Allocator, action: Action) !?bool {
    const cmd = switch (action) {
        .start => "start",
        .stop => "stop",
        // Query is not an action here.
        .status => "status",
    };

    const resp = (try pipeRequest(allocator, cmd)) orelse return null;
    defer allocator.free(resp);
    const s = std.mem.trim(u8, resp, " \t\r\n");
    return std.mem.startsWith(u8, s, "ok");
}

fn tryRunCliServiceAction(allocator: std.mem.Allocator, action: Action) !?bool {
    // Return null if CLI not found.
    const exe_dir = try selfExeDir(allocator);
    defer allocator.free(exe_dir);

    const candidates = [_][]const u8{ "ziggystarclaw-cli.exe", "ziggystarclaw-cli" };

    for (candidates) |name| {
        const full = try std.fs.path.join(allocator, &.{ exe_dir, name });
        defer allocator.free(full);

        if (pathExists(full)) {
            const verb = switch (action) {
                .start => "start",
                .stop => "stop",
                .status => "status",
            };
            const argv = &.{ full, "node", "service", verb };
            const res = try runCapture(allocator, argv);
            defer res.deinit(allocator);
            return res.exit_code == 0;
        }
    }

    // Also try PATH.
    const verb = switch (action) {
        .start => "start",
        .stop => "stop",
        .status => "status",
    };
    const argv = &.{ "ziggystarclaw-cli", "node", "service", verb };
    const res = runCapture(allocator, argv) catch return null;
    defer res.deinit(allocator);
    return res.exit_code == 0;
}

fn selfExeDir(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const dir = std.fs.path.dirname(exe_path) orelse ".";
    return allocator.dupe(u8, dir);
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn fileExists(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn dirExists(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;

    try child.spawn();

    const out = if (child.stdout) |f|
        f.readToEndAlloc(allocator, 64 * 1024) catch try allocator.dupe(u8, "")
    else
        try allocator.dupe(u8, "");

    const err = if (child.stderr) |f|
        f.readToEndAlloc(allocator, 64 * 1024) catch try allocator.dupe(u8, "")
    else
        try allocator.dupe(u8, "");

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };

    return .{ .stdout = out, .stderr = err, .exit_code = code };
}

fn openConfigFolder(allocator: std.mem.Allocator) !void {
    // Prefer the system-scope config when the node service is installed in onstart mode.
    const programdata = std.process.getEnvVarOwned(allocator, "ProgramData") catch (std.process.getEnvVarOwned(allocator, "PROGRAMDATA") catch null);
    defer if (programdata) |v| allocator.free(v);

    if (programdata) |pd| {
        const sys_folder = try std.fs.path.join(allocator, &.{ pd, "ZiggyStarClaw" });
        defer allocator.free(sys_folder);

        const sys_cfg = try std.fs.path.join(allocator, &.{ sys_folder, "config.json" });
        defer allocator.free(sys_cfg);

        if (fileExists(sys_cfg) or dirExists(sys_folder)) {
            try shellOpenPath(allocator, sys_folder);
            return;
        }
    }

    const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch null;
    defer if (appdata) |v| allocator.free(v);

    const folder = if (appdata) |v|
        try std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw" })
    else
        try allocator.dupe(u8, ".");
    defer allocator.free(folder);

    try shellOpenPath(allocator, folder);
}

fn openLogs(allocator: std.mem.Allocator) !void {
    // Common log locations:
    // - %ProgramData%\\ZiggyStarClaw\\logs\\node.log (written by node service install wrapper)
    // - %ProgramData%\\ZiggyStarClaw\\logs\\node-stdio.log (stdout/stderr capture)
    // - %ProgramData%\\ZiggyStarClaw\\logs\\wrapper.log (wrapper diagnostics)
    // - %APPDATA%\\ZiggyStarClaw\\node-service.log (older / user-scope)

    const programdata = std.process.getEnvVarOwned(allocator, "ProgramData") catch (std.process.getEnvVarOwned(allocator, "PROGRAMDATA") catch null);
    defer if (programdata) |v| allocator.free(v);

    const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch null;
    defer if (appdata) |v| allocator.free(v);

    const localapp = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch null;
    defer if (localapp) |v| allocator.free(v);

    var candidates = std.ArrayList([]u8).empty;
    defer {
        for (candidates.items) |p| allocator.free(p);
        candidates.deinit(allocator);
    }

    // System-scope logs (Task Scheduler onstart mode)
    if (programdata) |pd| {
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ pd, "ZiggyStarClaw", "logs", "node.log" }));
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ pd, "ZiggyStarClaw", "logs", "node-stdio.log" }));
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ pd, "ZiggyStarClaw", "logs", "wrapper.log" }));
    }

    // User-scope logs (manual / older)
    if (appdata) |v| {
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw", "node-service.log" }));
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw", "logs", "node.log" }));
    }
    if (localapp) |v| {
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw", "logs", "node.log" }));
        try candidates.append(allocator, try std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw", "node.log" }));
    }

    for (candidates.items) |p| {
        if (fileExists(p)) {
            try explorerSelectFile(allocator, p);
            return;
        }
    }

    // Fall back to opening a likely logs folder.
    if (programdata) |pd| {
        const sys_logs = try std.fs.path.join(allocator, &.{ pd, "ZiggyStarClaw", "logs" });
        defer allocator.free(sys_logs);
        if (dirExists(sys_logs)) {
            try shellOpenPath(allocator, sys_logs);
            return;
        }
    }

    if (localapp) |v| {
        const p = try std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw", "logs" });
        defer allocator.free(p);
        if (dirExists(p)) {
            try shellOpenPath(allocator, p);
            return;
        }
    }

    if (appdata) |v| {
        const p = try std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw", "logs" });
        defer allocator.free(p);
        if (dirExists(p)) {
            try shellOpenPath(allocator, p);
            return;
        }
    }

    // If nothing obvious, open config folder as a last resort.
    try openConfigFolder(allocator);
}

fn explorerSelectFile(allocator: std.mem.Allocator, path: []const u8) !void {
    // explorer.exe /select,"C:\\path\\to\\file"
    const arg = try std.fmt.allocPrint(allocator, "/select,\"{s}\"", .{path});
    defer allocator.free(arg);

    var child = std.process.Child.init(&.{ "explorer.exe", arg }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
    _ = try child.wait();
}

fn shellOpenPath(allocator: std.mem.Allocator, path: []const u8) !void {
    const wpath = try utf16Z(allocator, path);
    defer allocator.free(wpath);

    const op = try utf16Z(allocator, "open");
    defer allocator.free(op);

    const r = win.ShellExecuteW(null, op.ptr, wpath.ptr, null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(r) <= 32) return error.ShellExecuteFailed;
}

fn showInfoBalloon(allocator: std.mem.Allocator, title_utf8: []const u8, msg_utf8: []const u8) void {
    // Best-effort. If it fails, silently ignore (clipboard already did the job).
    var nid = g_nid;
    nid.uFlags = win.NIF_INFO;
    nid.dwInfoFlags = win.NIIF_INFO;

    @memset(&nid.szInfoTitle, 0);
    @memset(&nid.szInfo, 0);

    const title16 = std.unicode.utf8ToUtf16LeAlloc(allocator, title_utf8) catch return;
    defer allocator.free(title16);
    const msg16 = std.unicode.utf8ToUtf16LeAlloc(allocator, msg_utf8) catch return;
    defer allocator.free(msg16);

    const ntitle = @min(nid.szInfoTitle.len - 1, title16.len);
    std.mem.copyForwards(u16, nid.szInfoTitle[0..ntitle], title16[0..ntitle]);
    nid.szInfoTitle[ntitle] = 0;

    const nmsg = @min(nid.szInfo.len - 1, msg16.len);
    std.mem.copyForwards(u16, nid.szInfo[0..nmsg], msg16[0..nmsg]);
    nid.szInfo[nmsg] = 0;

    _ = win.Shell_NotifyIconW(win.NIM_MODIFY, &nid);
}

fn copyUtf8ToClipboard(allocator: std.mem.Allocator, text_utf8: []const u8) !void {
    const w = try std.unicode.utf8ToUtf16LeAlloc(allocator, text_utf8);
    defer allocator.free(w);

    // Open clipboard for our (hidden) window.
    if (win.OpenClipboard(g_hwnd) == 0) return error.OpenClipboardFailed;
    defer _ = win.CloseClipboard();

    if (win.EmptyClipboard() == 0) return error.EmptyClipboardFailed;

    // CF_UNICODETEXT expects a NUL-terminated UTF-16LE buffer.
    const bytes: usize = (w.len + 1) * @sizeOf(u16);
    const hmem = win.GlobalAlloc(win.GMEM_MOVEABLE, bytes);
    if (hmem == null) return error.GlobalAllocFailed;

    const ptr = win.GlobalLock(hmem);
    if (ptr == null) {
        _ = win.GlobalFree(hmem);
        return error.GlobalLockFailed;
    }

    const buf: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(buf[0..w.len], w);
    buf[w.len] = 0;

    _ = win.GlobalUnlock(hmem);

    if (win.SetClipboardData(win.CF_UNICODETEXT, hmem) == null) {
        _ = win.GlobalFree(hmem);
        return error.SetClipboardDataFailed;
    }
    // On success, clipboard owns hmem; do not free.
}

fn isAccessDenied(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "Access is denied") != null or std.mem.indexOf(u8, buf, "requires elevation") != null;
}

fn looksLikeNotInstalled(buf: []const u8) bool {
    // Best-effort heuristics; task-not-found is commonly emitted by schtasks.
    return std.mem.indexOf(u8, buf, "cannot find") != null or
        std.mem.indexOf(u8, buf, "The system cannot find") != null or
        std.mem.indexOf(u8, buf, "ERROR: The system cannot find") != null;
}

fn showError(allocator: std.mem.Allocator, title: []const u8, err: anyerror) void {
    const msg = std.fmt.allocPrint(allocator, "{s}\n\nError: {s}\n\nTip: If this is an Access Denied error, try running as Administrator or reinstall the node service using: ziggystarclaw-cli node service install", .{ title, @errorName(err) }) catch return;
    defer allocator.free(msg);

    const wtitle = utf16Z(allocator, "ZiggyStarClaw") catch return;
    defer allocator.free(wtitle);

    const wmsg = utf16Z(allocator, msg) catch return;
    defer allocator.free(wmsg);

    _ = win.MessageBoxW(null, wmsg.ptr, wtitle.ptr, win.MB_OK | win.MB_ICONERROR);
}

fn logLine(line: []const u8) void {
    // Best-effort file logging; ignore errors.
    const allocator = g_allocator;
    const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch return;
    defer allocator.free(appdata);

    const dir_path = std.fs.path.join(allocator, &.{ appdata, "ZiggyStarClaw" }) catch return;
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const file_path = std.fs.path.join(allocator, &.{ dir_path, "tray.log" }) catch return;
    defer allocator.free(file_path);

    const f = std.fs.cwd().openFile(file_path, .{ .mode = .read_write }) catch {
        // Create if missing.
        const nf = std.fs.cwd().createFile(file_path, .{ .truncate = false }) catch return;
        defer nf.close();
        nf.seekFromEnd(0) catch {};
        var w = nf.deprecatedWriter();
        w.print("{d} {s}\n", .{ std.time.timestamp(), line }) catch {};
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch {};
    var w = f.deprecatedWriter();
    w.print("{d} {s}\n", .{ std.time.timestamp(), line }) catch {};
}

fn utf16Z(allocator: std.mem.Allocator, s: []const u8) ![]u16 {
    const tmp = try std.unicode.utf8ToUtf16LeAlloc(allocator, s);
    defer allocator.free(tmp);

    var out = try allocator.alloc(u16, tmp.len + 1);
    @memcpy(out[0..tmp.len], tmp);
    out[tmp.len] = 0;
    return out;
}
