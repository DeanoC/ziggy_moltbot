const std = @import("std");
const builtin = @import("builtin");

pub const ServiceError = error{
    Unsupported,
    InvalidArguments,
    AccessDenied,
    NotInstalled,
    ExecFailed,
} || std.mem.Allocator.Error;

pub const InstallMode = enum {
    onlogon,
    onstart,
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn systemSchtasksPath(allocator: std.mem.Allocator) ![]u8 {
    const win_dir = std.process.getEnvVarOwned(allocator, "WINDIR") catch null;
    if (win_dir) |dir| {
        defer allocator.free(dir);
        return std.fs.path.join(allocator, &.{ dir, "System32", "schtasks.exe" });
    }
    return allocator.dupe(u8, "C:\\Windows\\System32\\schtasks.exe");
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ServiceError!RunResult {
    var effective_argv = std.ArrayList([]const u8).empty;
    defer effective_argv.deinit(allocator);

    var schtasks_abs: ?[]u8 = null;
    defer if (schtasks_abs) |p| allocator.free(p);

    if (argv.len > 0 and std.mem.eql(u8, argv[0], "schtasks")) {
        schtasks_abs = systemSchtasksPath(allocator) catch null;
    }

    if (schtasks_abs) |p| {
        effective_argv.append(allocator, p) catch return ServiceError.ExecFailed;
        if (argv.len > 1) {
            effective_argv.appendSlice(allocator, argv[1..]) catch return ServiceError.ExecFailed;
        }
    } else {
        effective_argv.appendSlice(allocator, argv) catch return ServiceError.ExecFailed;
    }

    var child = std.process.Child.init(effective_argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;

    child.spawn() catch {
        return ServiceError.ExecFailed;
    };

    const out = if (child.stdout) |f|
        f.readToEndAlloc(allocator, 64 * 1024) catch try allocator.dupe(u8, "")
    else
        try allocator.dupe(u8, "");

    const err = if (child.stderr) |f|
        f.readToEndAlloc(allocator, 64 * 1024) catch try allocator.dupe(u8, "")
    else
        try allocator.dupe(u8, "");

    const term = child.wait() catch {
        allocator.free(out);
        allocator.free(err);
        return ServiceError.ExecFailed;
    };

    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };

    return .{ .stdout = out, .stderr = err, .exit_code = code };
}

fn isAccessDenied(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "Access is denied") != null or
        std.mem.indexOf(u8, buf, "ERROR: Access is denied") != null or
        std.mem.indexOf(u8, buf, "requires elevation") != null;
}

fn looksLikeNotInstalled(buf: []const u8) bool {
    // schtasks uses a few common phrasings; keep this heuristic broad.
    return std.mem.indexOf(u8, buf, "cannot find") != null or
        std.mem.indexOf(u8, buf, "Cannot find") != null or
        std.mem.indexOf(u8, buf, "The system cannot find") != null or
        std.mem.indexOf(u8, buf, "ERROR: The system cannot find") != null or
        std.mem.indexOf(u8, buf, "ERROR: The specified task name") != null;
}

fn looksLikeAlreadyRunning(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "currently running") != null or
        std.mem.indexOf(u8, buf, "already running") != null;
}

fn looksLikeNotRunning(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "not running") != null or
        std.mem.indexOf(u8, buf, "is not running") != null;
}

fn selfExePath(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.selfExePathAlloc(allocator);
}

fn defaultTaskName() []const u8 {
    return "ZiggyStarClaw Node";
}

pub fn taskInstalled(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) ServiceError!bool {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/Query", "/TN", task_name };
    const res = try runCommandCapture(allocator, argv);
    defer res.deinit(allocator);

    if (res.exit_code == 0) return true;

    if (isAccessDenied(res.stderr) or isAccessDenied(res.stdout)) return ServiceError.AccessDenied;
    if (looksLikeNotInstalled(res.stderr) or looksLikeNotInstalled(res.stdout)) return false;

    return ServiceError.ExecFailed;
}

pub fn installTask(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    mode: InstallMode,
    task_name_opt: ?[]const u8,
) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;

    const exe_path = selfExePath(allocator) catch {
        return ServiceError.ExecFailed;
    };
    defer allocator.free(exe_path);

    // Use the node supervisor wrapper so we:
    // - write logs next to the config
    // - keep a control pipe for the tray app (start/stop)
    const task_run = try std.fmt.allocPrint(
        allocator,
        // NOTE: schtasks expects a single command line string.
        "\"{s}\" node supervise --hide-console --config \"{s}\" --as-node --no-operator --log-level info",
        .{ exe_path, config_path },
    );
    defer allocator.free(task_run);

    return installTaskCommand(allocator, task_run, mode, task_name_opt);
}

pub fn installTaskCommand(
    allocator: std.mem.Allocator,
    task_run: []const u8,
    mode: InstallMode,
    task_name_opt: ?[]const u8,
) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;

    const task_name = task_name_opt orelse defaultTaskName();

    // schtasks /Create /F /TN <name> /TR <cmd> /SC ONLOGON|ONSTART
    const schedule = switch (mode) {
        .onlogon => "ONLOGON",
        .onstart => "ONSTART",
    };

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "schtasks");
    try argv.append(allocator, "/Create");
    try argv.append(allocator, "/F");
    try argv.append(allocator, "/TN");
    try argv.append(allocator, task_name);
    try argv.append(allocator, "/TR");
    try argv.append(allocator, task_run);
    try argv.append(allocator, "/SC");
    try argv.append(allocator, schedule);

    // For ONLOGON tasks, ensure the task runs in the interactive session.
    if (mode == .onlogon) {
        try argv.append(allocator, "/IT");
    }

    // For ONSTART, default to SYSTEM so the node can run without a logged-in user.
    if (mode == .onstart) {
        try argv.append(allocator, "/RU");
        try argv.append(allocator, "SYSTEM");
    }

    // Run level:
    // - ONLOGON tasks should stay in user context (LIMITED) so non-admin startup installs work.
    // - ONSTART tasks run as SYSTEM and use HIGHEST.
    const run_level = switch (mode) {
        .onlogon => "LIMITED",
        .onstart => "HIGHEST",
    };
    try argv.append(allocator, "/RL");
    try argv.append(allocator, run_level);

    const res = try runCommandCapture(allocator, argv.items);
    defer res.deinit(allocator);

    if (res.exit_code == 0) return;

    if (isAccessDenied(res.stderr) or isAccessDenied(res.stdout)) return ServiceError.AccessDenied;
    return ServiceError.ExecFailed;
}

pub fn uninstallTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/Delete", "/F", "/TN", task_name };
    const res = try runCommandCapture(allocator, argv);
    defer res.deinit(allocator);

    if (res.exit_code == 0) return;
    if (isAccessDenied(res.stderr) or isAccessDenied(res.stdout)) return ServiceError.AccessDenied;
    if (looksLikeNotInstalled(res.stderr) or looksLikeNotInstalled(res.stdout)) return;

    return ServiceError.ExecFailed;
}

pub fn startTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/Run", "/TN", task_name };
    const res = try runCommandCapture(allocator, argv);
    defer res.deinit(allocator);

    if (res.exit_code == 0) return;
    if (isAccessDenied(res.stderr) or isAccessDenied(res.stdout)) return ServiceError.AccessDenied;
    if (looksLikeAlreadyRunning(res.stderr) or looksLikeAlreadyRunning(res.stdout)) return;
    if (looksLikeNotInstalled(res.stderr) or looksLikeNotInstalled(res.stdout)) return ServiceError.NotInstalled;

    return ServiceError.ExecFailed;
}

pub fn stopTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) ServiceError!void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/End", "/TN", task_name };
    const res = try runCommandCapture(allocator, argv);
    defer res.deinit(allocator);

    if (res.exit_code == 0) return;
    if (isAccessDenied(res.stderr) or isAccessDenied(res.stdout)) return ServiceError.AccessDenied;
    if (looksLikeNotRunning(res.stderr) or looksLikeNotRunning(res.stdout)) return;
    if (looksLikeNotInstalled(res.stderr) or looksLikeNotInstalled(res.stdout)) return ServiceError.NotInstalled;

    return ServiceError.ExecFailed;
}

pub fn queryTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) ServiceError!RunResult {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/Query", "/TN", task_name, "/V", "/FO", "LIST" };
    const res = try runCommandCapture(allocator, argv);

    if (res.exit_code == 0) return res;

    defer res.deinit(allocator);
    if (isAccessDenied(res.stderr) or isAccessDenied(res.stdout)) return ServiceError.AccessDenied;
    if (looksLikeNotInstalled(res.stderr) or looksLikeNotInstalled(res.stdout)) return ServiceError.NotInstalled;

    return ServiceError.ExecFailed;
}
