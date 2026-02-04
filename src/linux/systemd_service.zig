const std = @import("std");
const builtin = @import("builtin");

const win_service = @import("../windows/service.zig");

pub const ServiceError = error{
    Unsupported,
    InvalidArguments,
    AccessDenied,
    ExecFailed,
};

pub const InstallMode = win_service.InstallMode;

const Scope = enum { user, system };

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
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

    if (child.stdout) |out| stdout_buf = out.readToEndAlloc(allocator, 64 * 1024) catch &.{};
    if (child.stderr) |err| stderr_buf = err.readToEndAlloc(allocator, 64 * 1024) catch &.{};

    const term = try child.wait();

    if (stdout_buf.len != 0) _ = std.fs.File.stdout().write(stdout_buf) catch {};
    if (stderr_buf.len != 0) _ = std.fs.File.stderr().write(stderr_buf) catch {};

    switch (term) {
        .Exited => |code| if (code != 0) return ServiceError.ExecFailed,
        else => return ServiceError.ExecFailed,
    }
}

fn scopeFromMode(mode: InstallMode) Scope {
    // onlogon -> user service (starts when user session starts)
    // onstart -> system service (starts at boot)
    return switch (mode) {
        .onlogon => .user,
        .onstart => .system,
    };
}

fn sanitizeUnitBaseName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (name) |c| {
        const lc: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const ok = (lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9') or lc == '-' or lc == '_' or lc == '.';
        if (ok) {
            try out.append(allocator, lc);
        } else if (lc == ' ' or lc == '/' or lc == '\\' or lc == ':') {
            try out.append(allocator, '-');
        } else {
            // replace anything else with '-'
            try out.append(allocator, '-');
        }
    }

    if (out.items.len == 0) return allocator.dupe(u8, "ziggystarclaw-node");

    // trim leading/trailing '-'
    var start: usize = 0;
    while (start < out.items.len and out.items[start] == '-') start += 1;
    var end: usize = out.items.len;
    while (end > start and out.items[end - 1] == '-') end -= 1;

    const trimmed = out.items[start..end];
    if (trimmed.len == 0) return allocator.dupe(u8, "ziggystarclaw-node");
    return allocator.dupe(u8, trimmed);
}

fn unitFilePath(allocator: std.mem.Allocator, scope: Scope, unit_filename: []const u8) ![]u8 {
    switch (scope) {
        .user => {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
            if (home == null) return ServiceError.InvalidArguments;
            defer allocator.free(home.?);
            return std.fs.path.join(allocator, &.{ home.?, ".config", "systemd", "user", unit_filename });
        },
        .system => return std.fs.path.join(allocator, &.{ "/etc/systemd/system", unit_filename }),
    }
}

fn unitDirPath(allocator: std.mem.Allocator, scope: Scope) ![]u8 {
    switch (scope) {
        .user => {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
            if (home == null) return ServiceError.InvalidArguments;
            defer allocator.free(home.?);
            return std.fs.path.join(allocator, &.{ home.?, ".config", "systemd", "user" });
        },
        .system => return allocator.dupe(u8, "/etc/systemd/system"),
    }
}

fn writeUnitFile(allocator: std.mem.Allocator, scope: Scope, unit_path: []const u8, unit_text: []const u8) !void {
    _ = allocator;
    // Ensure parent dir exists.
    const dir = std.fs.path.dirname(unit_path) orelse ".";
    std.fs.cwd().makePath(dir) catch {};

    const f = try std.fs.cwd().createFile(unit_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(unit_text);

    if (scope == .system) {
        // best effort: chmod 0644
        std.posix.fchmod(f.handle, 0o644) catch {};
    }
}

fn systemctl(allocator: std.mem.Allocator, scope: Scope, args: []const []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "systemctl");
    if (scope == .user) try argv.append(allocator, "--user");
    for (args) |a| try argv.append(allocator, a);
    try runCommand(allocator, argv.items);
}

pub fn installService(allocator: std.mem.Allocator, config_path: []const u8, mode: InstallMode, name_opt: ?[]const u8) ![]u8 {
    if (builtin.os.tag != .linux) return ServiceError.Unsupported;

    const scope = scopeFromMode(mode);
    if (scope == .system and std.posix.geteuid() != 0) return ServiceError.AccessDenied;

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const base = try sanitizeUnitBaseName(allocator, name_opt orelse "ziggystarclaw-node");
    defer allocator.free(base);

    const unit_filename = try std.fmt.allocPrint(allocator, "{s}.service", .{base});
    defer allocator.free(unit_filename);

    const unit_path = switch (scope) {
        .user => blk: {
            const dir = try unitDirPath(allocator, .user);
            defer allocator.free(dir);
            break :blk try std.fs.path.join(allocator, &.{ dir, unit_filename });
        },
        .system => try std.fs.path.join(allocator, &.{ "/etc/systemd/system", unit_filename }),
    };
    defer allocator.free(unit_path);

    const wanted_by = switch (scope) {
        .user => "default.target",
        .system => "multi-user.target",
    };

    const user_line = if (scope == .system) blk: {
        // Prefer SUDO_USER when invoked via sudo, else USER.
        const sudo_user = std.process.getEnvVarOwned(allocator, "SUDO_USER") catch null;
        if (sudo_user) |u| {
            defer allocator.free(u);
            break :blk try std.fmt.allocPrint(allocator, "User={s}\n", .{u});
        }
        const user = std.process.getEnvVarOwned(allocator, "USER") catch null;
        if (user) |u| {
            defer allocator.free(u);
            break :blk try std.fmt.allocPrint(allocator, "User={s}\n", .{u});
        }
        break :blk try allocator.dupe(u8, "");
    } else try allocator.dupe(u8, "");
    defer allocator.free(user_line);

    const unit_text = try std.fmt.allocPrint(
        allocator,
        "[Unit]\n" ++
            "Description=ZiggyStarClaw Node\n" ++
            "Wants=network-online.target\n" ++
            "After=network-online.target\n\n" ++
            "[Service]\n" ++
            "Type=simple\n" ++
            "ExecStart={s} --node-mode --config {s} --as-node --no-operator\n" ++
            "Restart=always\n" ++
            "RestartSec=5\n" ++
            "{s}" ++
            "[Install]\n" ++
            "WantedBy={s}\n",
        .{ exe_path, config_path, user_line, wanted_by },
    );
    defer allocator.free(unit_text);

    try writeUnitFile(allocator, scope, unit_path, unit_text);

    try systemctl(allocator, scope, &.{"daemon-reload"});
    try systemctl(allocator, scope, &.{ "enable", "--now", unit_filename });

    return allocator.dupe(u8, unit_filename);
}

pub fn uninstallService(allocator: std.mem.Allocator, mode: InstallMode, name_opt: ?[]const u8) ![]u8 {
    if (builtin.os.tag != .linux) return ServiceError.Unsupported;

    const scope = scopeFromMode(mode);
    if (scope == .system and std.posix.geteuid() != 0) return ServiceError.AccessDenied;

    const base = try sanitizeUnitBaseName(allocator, name_opt orelse "ziggystarclaw-node");
    defer allocator.free(base);

    const unit_filename = try std.fmt.allocPrint(allocator, "{s}.service", .{base});
    defer allocator.free(unit_filename);

    // Stop/disable first (ignore errors by best-effort).
    systemctl(allocator, scope, &.{ "disable", "--now", unit_filename }) catch {};
    systemctl(allocator, scope, &.{"reset-failed"}) catch {};

    const unit_path = switch (scope) {
        .user => blk: {
            const dir = try unitDirPath(allocator, .user);
            defer allocator.free(dir);
            break :blk try std.fs.path.join(allocator, &.{ dir, unit_filename });
        },
        .system => try std.fs.path.join(allocator, &.{ "/etc/systemd/system", unit_filename }),
    };
    defer allocator.free(unit_path);

    std.fs.cwd().deleteFile(unit_path) catch {};
    try systemctl(allocator, scope, &.{"daemon-reload"});

    return allocator.dupe(u8, unit_filename);
}

pub fn startService(allocator: std.mem.Allocator, mode: InstallMode, name_opt: ?[]const u8) !void {
    const unit = try unitNameAlloc(allocator, name_opt);
    defer allocator.free(unit);
    const scope = scopeFromMode(mode);
    if (scope == .system and std.posix.geteuid() != 0) return ServiceError.AccessDenied;
    try systemctl(allocator, scope, &.{ "start", unit });
}

pub fn stopService(allocator: std.mem.Allocator, mode: InstallMode, name_opt: ?[]const u8) !void {
    const unit = try unitNameAlloc(allocator, name_opt);
    defer allocator.free(unit);
    const scope = scopeFromMode(mode);
    if (scope == .system and std.posix.geteuid() != 0) return ServiceError.AccessDenied;
    try systemctl(allocator, scope, &.{ "stop", unit });
}

pub fn statusService(allocator: std.mem.Allocator, mode: InstallMode, name_opt: ?[]const u8) !void {
    const unit = try unitNameAlloc(allocator, name_opt);
    defer allocator.free(unit);
    const scope = scopeFromMode(mode);
    if (scope == .system and std.posix.geteuid() != 0) return ServiceError.AccessDenied;
    try systemctl(allocator, scope, &.{ "status", "--no-pager", unit });
}

fn unitNameAlloc(allocator: std.mem.Allocator, name_opt: ?[]const u8) ![]u8 {
    const base = try sanitizeUnitBaseName(allocator, name_opt orelse "ziggystarclaw-node");
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}.service", .{base});
}
