const std = @import("std");
const builtin = @import("builtin");

pub const ServiceError = error{
    Unsupported,
    InvalidArguments,
    AccessDenied,
    ExecFailed,
};

pub const InstallMode = enum {
    onlogon,
    onstart,
};

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    // We capture output so we can detect common Windows errors (e.g. schtasks access denied)
    // and provide actionable guidance.
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: []u8 = &.{};
    var stderr_buf: []u8 = &.{};
    defer {
        if (stdout_buf.len != 0) allocator.free(stdout_buf);
        if (stderr_buf.len != 0) allocator.free(stderr_buf);
    }

    if (child.stdout) |out| {
        stdout_buf = out.readToEndAlloc(allocator, 64 * 1024) catch &.{};
    }
    if (child.stderr) |err| {
        stderr_buf = err.readToEndAlloc(allocator, 64 * 1024) catch &.{};
    }

    const term = try child.wait();

    // Preserve original tool output for the user.
    if (stdout_buf.len != 0) {
        _ = std.fs.File.stdout().write(stdout_buf) catch {};
    }
    if (stderr_buf.len != 0) {
        _ = std.fs.File.stderr().write(stderr_buf) catch {};
    }

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                // schtasks often exits 1 even for specific errors; match the message too.
                if (std.mem.indexOf(u8, stderr_buf, "Access is denied") != null or
                    std.mem.indexOf(u8, stderr_buf, "ERROR: Access is denied") != null)
                {
                    return ServiceError.AccessDenied;
                }
                // Some systems emit "The requested operation requires elevation." for non-admin.
                if (std.mem.indexOf(u8, stderr_buf, "requires elevation") != null) {
                    return ServiceError.AccessDenied;
                }
                return ServiceError.ExecFailed;
            }
        },
        else => return ServiceError.ExecFailed,
    }
}

fn selfExePath(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.selfExePathAlloc(allocator);
}

fn defaultTaskName() []const u8 {
    return "ZiggyStarClaw Node";
}

pub fn installTask(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    mode: InstallMode,
    task_name_opt: ?[]const u8,
) !void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;

    const exe_path = try selfExePath(allocator);
    defer allocator.free(exe_path);

    // Quote exe and config path for schtasks.
    const task_run = try std.fmt.allocPrint(
        allocator,
        "\"{s}\" --node-mode --config \"{s}\" --as-node --no-operator",
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
) !void {
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

    // For ONSTART, default to SYSTEM so the node can run without a logged-in user.
    // (This is the closest thing to a "service" without a dedicated SCM service wrapper.)
    if (mode == .onstart) {
        try argv.append(allocator, "/RU");
        try argv.append(allocator, "SYSTEM");
    }

    // Best-effort: run at highest privileges when available.
    try argv.append(allocator, "/RL");
    try argv.append(allocator, "HIGHEST");

    try runCommand(allocator, argv.items);
}

pub fn uninstallTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) !void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/Delete", "/F", "/TN", task_name };
    try runCommand(allocator, argv);
}

pub fn startTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) !void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/Run", "/TN", task_name };
    try runCommand(allocator, argv);
}

pub fn stopTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) !void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/End", "/TN", task_name };
    try runCommand(allocator, argv);
}

pub fn queryTask(allocator: std.mem.Allocator, task_name_opt: ?[]const u8) !void {
    if (builtin.os.tag != .windows) return ServiceError.Unsupported;
    const task_name = task_name_opt orelse defaultTaskName();

    const argv = &.{ "schtasks", "/Query", "/TN", task_name, "/V", "/FO", "LIST" };
    try runCommand(allocator, argv);
}
