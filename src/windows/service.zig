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
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                // schtasks returns common Windows error codes.
                // 5 = ACCESS_DENIED
                if (code == 5) return ServiceError.AccessDenied;
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

    const task_name = task_name_opt orelse defaultTaskName();

    const exe_path = try selfExePath(allocator);
    defer allocator.free(exe_path);

    // Quote exe and config path for schtasks.
    const task_run = try std.fmt.allocPrint(
        allocator,
        "\"{s}\" --node-mode --config \"{s}\" --as-node --no-operator",
        .{ exe_path, config_path },
    );
    defer allocator.free(task_run);

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
