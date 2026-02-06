const std = @import("std");
const builtin = @import("builtin");
const node_context = @import("node_context.zig");
const NodeContext = node_context.NodeContext;
const Command = node_context.Command;
const websocket_client = @import("../client/websocket_client.zig");
const requests = @import("../protocol/requests.zig");
const messages = @import("../protocol/messages.zig");
const logger = @import("../utils/logger.zig");
const node_platform = @import("node_platform.zig");

/// Command handler function signature
pub const CommandHandler = *const fn (
    allocator: std.mem.Allocator,
    ctx: *NodeContext,
    params: std.json.Value,
) CommandError!std.json.Value;

/// Command errors
pub const CommandError = error{
    CommandNotSupported,
    InvalidParams,
    ExecutionFailed,
    NotAllowed,
    Timeout,
    BackgroundNotAvailable,
    PermissionRequired,
    OutOfMemory,
    SystemResources,
    Unexpected,
    LockedMemoryLimitExceeded,
    ThreadQuotaExceeded,
};

/// Command router - maps command strings to handlers
pub const CommandRouter = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(CommandHandler),

    pub fn init(allocator: std.mem.Allocator) CommandRouter {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(CommandHandler).init(allocator),
        };
    }

    pub fn deinit(self: *CommandRouter) void {
        var iter = self.handlers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.handlers.deinit();
    }

    /// Register a command handler
    pub fn register(self: *CommandRouter, cmd: Command, handler: CommandHandler) !void {
        const cmd_str = try self.allocator.dupe(u8, cmd.toString());
        try self.handlers.put(cmd_str, handler);
    }

    /// Route a command to its handler
    pub fn route(
        self: *CommandRouter,
        allocator: std.mem.Allocator,
        ctx: *NodeContext,
        command: []const u8,
        params: std.json.Value,
    ) CommandError!std.json.Value {
        const handler = self.handlers.get(command) orelse {
            logger.warn("Command not registered: {s}", .{command});
            return CommandError.CommandNotSupported;
        };

        // IMPORTANT: handlers may allocate large payloads (e.g. screenshots).
        // We accept an allocator per invocation so callers can use a per-message
        // arena and avoid unbounded leaks.
        return handler(allocator, ctx, params);
    }

    /// Check if command is registered
    pub fn isRegistered(self: *CommandRouter, command: []const u8) bool {
        return self.handlers.contains(command);
    }
};

/// Initialize router with standard handlers
pub fn initStandardRouter(allocator: std.mem.Allocator) !CommandRouter {
    var router = CommandRouter.init(allocator);

    // System commands
    try router.register(.system_run, systemRunHandler);
    try router.register(.system_which, systemWhichHandler);
    try router.register(.system_notify, systemNotifyHandler);
    try router.register(.system_exec_approvals_get, systemExecApprovalsGetHandler);
    try router.register(.system_exec_approvals_set, systemExecApprovalsSetHandler);

    // Process commands
    try router.register(.process_spawn, processSpawnHandler);
    try router.register(.process_poll, processPollHandler);
    try router.register(.process_stop, processStopHandler);
    try router.register(.process_list, processListHandler);

    // Canvas commands
    try router.register(.canvas_present, canvasPresentHandler);
    try router.register(.canvas_hide, canvasHideHandler);
    try router.register(.canvas_navigate, canvasNavigateHandler);
    try router.register(.canvas_eval, canvasEvalHandler);
    try router.register(.canvas_snapshot, canvasSnapshotHandler);
    try router.register(.canvas_a2ui_push_jsonl, canvasA2uiPushJsonlHandler);
    try router.register(.canvas_a2ui_reset, canvasA2uiResetHandler);

    return router;
}

/// Initialize a router by registering only a specific set of commands.
///
/// This is useful for platform ports (Android/WASM) where we want a working
/// node transport but only a small/safe command surface initially.
pub fn initRouterWithCommands(allocator: std.mem.Allocator, cmds: []const Command) !CommandRouter {
    var router = CommandRouter.init(allocator);
    errdefer router.deinit();

    for (cmds) |cmd| {
        switch (cmd) {
            // System commands
            .system_run => try router.register(.system_run, systemRunHandler),
            .system_which => try router.register(.system_which, systemWhichHandler),
            .system_notify => try router.register(.system_notify, systemNotifyHandler),
            .system_exec_approvals_get => try router.register(.system_exec_approvals_get, systemExecApprovalsGetHandler),
            .system_exec_approvals_set => try router.register(.system_exec_approvals_set, systemExecApprovalsSetHandler),

            // Process commands
            .process_spawn => try router.register(.process_spawn, processSpawnHandler),
            .process_poll => try router.register(.process_poll, processPollHandler),
            .process_stop => try router.register(.process_stop, processStopHandler),
            .process_list => try router.register(.process_list, processListHandler),

            // Canvas commands
            .canvas_present => try router.register(.canvas_present, canvasPresentHandler),
            .canvas_hide => try router.register(.canvas_hide, canvasHideHandler),
            .canvas_navigate => try router.register(.canvas_navigate, canvasNavigateHandler),
            .canvas_eval => try router.register(.canvas_eval, canvasEvalHandler),
            .canvas_snapshot => try router.register(.canvas_snapshot, canvasSnapshotHandler),
            .canvas_a2ui_push_jsonl => try router.register(.canvas_a2ui_push_jsonl, canvasA2uiPushJsonlHandler),
            .canvas_a2ui_reset => try router.register(.canvas_a2ui_reset, canvasA2uiResetHandler),

            // Not implemented yet in this codebase (but present in enum)
            .screen_record,
            .camera_list,
            .camera_snap,
            .camera_clip,
            .location_get,
            => return error.CommandNotSupported,
        }
    }

    return router;
}

// ============================================================================
// System Command Handlers
// ============================================================================

fn systemRunHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const exec_approvals = @import("config.zig").ExecApprovals;

    // Load exec approvals
    var approvals = exec_approvals.loadOrDefault(allocator, ctx.exec_approvals_path) catch |err| {
        logger.err("Failed to load exec approvals: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };
    defer approvals.deinit(allocator);

    // Extract command from params
    const cmd_array = params.object.get("command") orelse {
        logger.warn("system.run: missing 'command' param", .{});
        return CommandError.InvalidParams;
    };

    if (cmd_array != .array) {
        logger.warn("system.run: 'command' must be an array", .{});
        return CommandError.InvalidParams;
    }

    // Build command string for checking
    var cmd_buf = std.ArrayList(u8).empty;
    defer cmd_buf.deinit(allocator);

    for (cmd_array.array.items, 0..) |item, i| {
        if (item != .string) continue;
        if (i > 0) try cmd_buf.append(allocator, ' ');
        try cmd_buf.appendSlice(allocator, item.string);
    }

    const cmd_str = cmd_buf.items;

    // Check if allowed
    if (!approvals.isAllowed(cmd_str)) {
        logger.warn("system.run: command not allowed: {s}", .{cmd_str});
        return CommandError.NotAllowed;
    }

    // Get working directory (optional)
    const cwd = if (params.object.get("cwd")) |c| switch (c) {
        .string => c.string,
        else => null,
    } else null;

    // Get timeout (optional)
    const timeout_ms = if (params.object.get("timeoutMs")) |t| switch (t) {
        .integer => @as(u32, @intCast(t.integer)),
        .float => @as(u32, @intFromFloat(t.float)),
        else => 30000,
    } else 30000;

    // Convert JSON array to string array
    var cmd_strings = std.ArrayList([]const u8).empty;
    defer {
        for (cmd_strings.items) |s| {
            allocator.free(s);
        }
        cmd_strings.deinit(allocator);
    }

    for (cmd_array.array.items) |item| {
        if (item != .string) continue;
        try cmd_strings.append(allocator, try allocator.dupe(u8, item.string));
    }

    if (cmd_strings.items.len == 0) {
        logger.warn("system.run: command array is empty", .{});
        return CommandError.InvalidParams;
    }

    // Execute command
    var child = std.process.Child.init(
        cmd_strings.items,
        allocator,
    );

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    if (cwd) |dir| {
        child.cwd = dir;
    }

    // Spawn process
    child.spawn() catch |err| {
        logger.err("Failed to spawn process: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };

    // Collect output with timeout
    var stdout_buf = std.ArrayList(u8).empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf = std.ArrayList(u8).empty;
    defer stderr_buf.deinit(allocator);

    // Collect output using a simpler approach - spawn thread to read
    const stdout_reader = child.stdout.?;
    const stderr_reader = child.stderr.?;

    // Read all stdout
    var stdout_thread = try std.Thread.spawn(.{}, struct {
        fn readAll(reader: anytype, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = reader.read(&tmp) catch 0;
                if (n == 0) break;
                try buf.appendSlice(alloc, tmp[0..n]);
            }
        }
    }.readAll, .{ stdout_reader, &stdout_buf, allocator });

    // Read all stderr
    var stderr_thread = try std.Thread.spawn(.{}, struct {
        fn readAll(reader: anytype, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = reader.read(&tmp) catch 0;
                if (n == 0) break;
                try buf.appendSlice(alloc, tmp[0..n]);
            }
        }
    }.readAll, .{ stderr_reader, &stderr_buf, allocator });

    // Wait with timeout
    const start_time = node_platform.nowMs();
    var timed_out = false;
    var reaped_status: ?u32 = null;

    if (comptime builtin.os.tag == .windows) {
        // TODO: implement a non-blocking wait / poll for Windows.
        // For now, fall back to a blocking wait (no timeout).
        reaped_status = null;
    } else {
        while (true) {
            const elapsed = node_platform.nowMs() - start_time;
            if (elapsed > timeout_ms) {
                timed_out = true;
                _ = child.kill() catch {};
                break;
            }

            // Check if child exited (poll). NOTE: waitpid reaps the child; don't call child.wait() after.
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (result.pid != 0) {
                reaped_status = result.status;
                break;
            }

            node_platform.sleepMs(50);
        }
    }

    stdout_thread.join();
    stderr_thread.join();

    // Get exit status
    const term: std.process.Child.Term = if (comptime builtin.os.tag == .windows) blk: {
        break :blk child.wait() catch |err| {
            logger.err("Failed to wait for process: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
        };
    } else if (timed_out) blk: {
        break :blk std.process.Child.Term{ .Signal = 9 };
    } else if (reaped_status) |status| blk: {
        if (std.posix.W.IFEXITED(status)) {
            break :blk std.process.Child.Term{ .Exited = std.posix.W.EXITSTATUS(status) };
        }
        if (std.posix.W.IFSIGNALED(status)) {
            break :blk std.process.Child.Term{ .Signal = std.posix.W.TERMSIG(status) };
        }
        break :blk std.process.Child.Term{ .Unknown = status };
    } else blk: {
        break :blk child.wait() catch |err| {
            logger.err("Failed to wait for process: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
        };
    };

    const exit_code: i32 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| @intCast(sig),
        .Stopped => |sig| @intCast(sig),
        .Unknown => |code| @intCast(code),
    };

    // Build response
    var result = std.json.ObjectMap.init(allocator);
    try result.put("stdout", std.json.Value{ .string = try allocator.dupe(u8, stdout_buf.items) });
    try result.put("stderr", std.json.Value{ .string = try allocator.dupe(u8, stderr_buf.items) });
    try result.put("exitCode", std.json.Value{ .integer = exit_code });

    ctx.commands_executed += 1;
    if (exit_code != 0) {
        ctx.commands_failed += 1;
    }

    return std.json.Value{ .object = result };
}

fn systemNotifyHandler(allocator: std.mem.Allocator, _: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const title = params.object.get("title") orelse {
        logger.warn("system.notify: missing 'title' param", .{});
        return CommandError.InvalidParams;
    };

    if (title != .string or title.string.len == 0) {
        logger.warn("system.notify: 'title' must be a non-empty string", .{});
        return CommandError.InvalidParams;
    }

    const body: ?[]const u8 = if (params.object.get("body")) |b| switch (b) {
        .string => if (b.string.len > 0) b.string else null,
        else => null,
    } else null;

    node_platform.notify(allocator, .{ .title = title.string, .body = body }) catch |err| {
        logger.err("system.notify failed: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };

    var result = std.json.ObjectMap.init(allocator);
    try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "sent") });
    return std.json.Value{ .object = result };
}

fn systemWhichHandler(allocator: std.mem.Allocator, _: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const name = params.object.get("name") orelse {
        logger.warn("system.which: missing 'name' param", .{});
        return CommandError.InvalidParams;
    };

    if (name != .string) {
        logger.warn("system.which: 'name' must be a string", .{});
        return CommandError.InvalidParams;
    }

    // Search in PATH
    const path_var = std.process.getEnvVarOwned(allocator, "PATH") catch {
        return std.json.Value{ .null = {} };
    };
    defer allocator.free(path_var);

    const sep = if (@import("builtin").os.tag == .windows) ';' else ':';
    var iter = std.mem.splitScalar(u8, path_var, sep);

    const is_windows = @import("builtin").os.tag == .windows;
    const pathext = if (is_windows)
        (std.process.getEnvVarOwned(allocator, "PATHEXT") catch null)
    else
        null;
    defer if (pathext) |v| allocator.free(v);

    while (iter.next()) |dir| {
        if (dir.len == 0) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir, name.string }) catch continue;
        defer allocator.free(full_path);

        // Check if file exists
        if (std.fs.cwd().access(full_path, .{ .mode = .read_only })) |_| {
            var result = std.json.ObjectMap.init(allocator);
            try result.put("path", std.json.Value{ .string = try allocator.dupe(u8, full_path) });
            return std.json.Value{ .object = result };
        } else |_| {}

        // Windows: respect PATHEXT so `system.which {name:"git"}` can find git.exe, etc.
        if (is_windows and std.mem.indexOfScalar(u8, name.string, '.') == null) {
            const exts_raw = if (pathext) |v| v else ".COM;.EXE;.BAT;.CMD";
            var ext_iter = std.mem.splitScalar(u8, exts_raw, ';');
            while (ext_iter.next()) |ext| {
                if (ext.len == 0) continue;

                const name_ext = std.mem.concat(allocator, u8, &.{ name.string, ext }) catch continue;
                defer allocator.free(name_ext);

                const full_path_ext = std.fs.path.join(allocator, &.{ dir, name_ext }) catch continue;
                defer allocator.free(full_path_ext);

                if (std.fs.cwd().access(full_path_ext, .{ .mode = .read_only })) |_| {
                    var result = std.json.ObjectMap.init(allocator);
                    try result.put("path", std.json.Value{ .string = try allocator.dupe(u8, full_path_ext) });
                    return std.json.Value{ .object = result };
                } else |_| {}
            }
        }
    }

    return std.json.Value{ .null = {} };
}

fn systemExecApprovalsGetHandler(allocator: std.mem.Allocator, ctx: *NodeContext, _: std.json.Value) CommandError!std.json.Value {
    const exec_approvals = @import("config.zig").ExecApprovals;

    var approvals = exec_approvals.loadOrDefault(allocator, ctx.exec_approvals_path) catch |err| {
        logger.err("Failed to load exec approvals: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };
    defer approvals.deinit(allocator);

    var result = std.json.ObjectMap.init(allocator);
    try result.put("mode", std.json.Value{ .string = try allocator.dupe(u8, approvals.mode) });

    var allowlist = std.json.Array.init(allocator);
    for (approvals.allowlist.items) |entry| {
        try allowlist.append(std.json.Value{ .string = try allocator.dupe(u8, entry) });
    }
    try result.put("allowlist", std.json.Value{ .array = allowlist });

    return std.json.Value{ .object = result };
}

fn systemExecApprovalsSetHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const exec_approvals = @import("config.zig").ExecApprovals;

    var approvals = exec_approvals.init(allocator);
    defer approvals.deinit(allocator);

    // Parse mode
    if (params.object.get("mode")) |m| {
        if (m == .string) {
            approvals.mode = try allocator.dupe(u8, m.string);
        }
    }

    // Parse allowlist
    if (params.object.get("allowlist")) |list| {
        if (list == .array) {
            for (list.array.items) |item| {
                if (item == .string) {
                    try approvals.allowlist.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }

    // Save
    approvals.save(allocator, ctx.exec_approvals_path) catch |err| {
        logger.err("Failed to save exec approvals: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };

    return std.json.Value{ .null = {} };
}

// ============================================================================
// Canvas Command Handlers
// ============================================================================

fn canvasPresentHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    ctx.canvas_manager.setVisible(true);

    // `openclaw nodes canvas present --target <...>` passes { url }.
    if (params.object.get("url")) |url| {
        if (url == .string and url.string.len > 0) {
            ctx.canvas_manager.setUrl(url.string) catch return CommandError.ExecutionFailed;
        }
    }

    // placement is currently ignored.

    var result = std.json.ObjectMap.init(allocator);
    try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "visible") });
    if (ctx.canvas_manager.getUrl()) |u| {
        try result.put("url", std.json.Value{ .string = try allocator.dupe(u8, u) });
    }
    return std.json.Value{ .object = result };
}

fn canvasHideHandler(allocator: std.mem.Allocator, ctx: *NodeContext, _: std.json.Value) CommandError!std.json.Value {
    ctx.canvas_manager.setVisible(false);

    var result = std.json.ObjectMap.init(allocator);
    try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "hidden") });
    return std.json.Value{ .object = result };
}

fn canvasNavigateHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const url_param = params.object.get("url") orelse return CommandError.InvalidParams;
    if (url_param != .string or url_param.string.len == 0) return CommandError.InvalidParams;

    ctx.canvas_manager.setUrl(url_param.string) catch return CommandError.ExecutionFailed;
    ctx.canvas_manager.setVisible(true);

    var result = std.json.ObjectMap.init(allocator);
    try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "navigated") });
    try result.put("url", std.json.Value{ .string = try allocator.dupe(u8, url_param.string) });
    return std.json.Value{ .object = result };
}

fn canvasEvalHandler(allocator: std.mem.Allocator, _: *NodeContext, _: std.json.Value) CommandError!std.json.Value {
    // TODO: implement CDP/WebKit-based evaluation.
    var result = std.json.ObjectMap.init(allocator);
    try result.put("result", std.json.Value{ .string = try allocator.dupe(u8, "(canvas.eval not implemented yet)") });
    return std.json.Value{ .object = result };
}

fn canvasSnapshotHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    // Expected params (from OpenClaw canvas tool): { format: "png"|"jpeg", maxWidth?: number, quality?: number }
    _ = params;

    const url = ctx.canvas_manager.getUrl() orelse "about:blank";

    const png_bytes = chromeScreenshotPngAlloc(allocator, url) catch |err| {
        logger.err("canvas.snapshot failed: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };
    defer allocator.free(png_bytes);

    const b64_len = std.base64.standard.Encoder.calcSize(png_bytes.len);
    const b64_buf = try allocator.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(b64_buf, png_bytes);

    var out = std.json.ObjectMap.init(allocator);
    try out.put("format", std.json.Value{ .string = try allocator.dupe(u8, "png") });
    // b64_buf is owned by the per-invocation arena allocator (see main_node.zig).
    try out.put("base64", std.json.Value{ .string = b64_buf });
    return std.json.Value{ .object = out };
}

fn canvasA2uiPushJsonlHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const jsonl = params.object.get("jsonl") orelse return CommandError.InvalidParams;
    if (jsonl != .string) return CommandError.InvalidParams;

    ctx.canvas_manager.setA2uiJsonl(jsonl.string) catch return CommandError.ExecutionFailed;
    ctx.canvas_manager.setVisible(true);

    var result = std.json.ObjectMap.init(allocator);
    try result.put("ok", std.json.Value{ .bool = true });
    return std.json.Value{ .object = result };
}

fn canvasA2uiResetHandler(allocator: std.mem.Allocator, ctx: *NodeContext, _: std.json.Value) CommandError!std.json.Value {
    ctx.canvas_manager.setA2uiJsonl("") catch {};

    var result = std.json.ObjectMap.init(allocator);
    try result.put("ok", std.json.Value{ .bool = true });
    return std.json.Value{ .object = result };
}

fn discoverPlaywrightBinaryAlloc(allocator: std.mem.Allocator, prefix: []const u8, subpath: []const []const u8) !?[]u8 {
    // Best-effort scan ~/.cache/ms-playwright for the highest numeric version that matches `prefix`.
    // Example prefixes:
    // - "chromium-"
    // - "chromium_headless_shell-"

    if (builtin.os.tag == .windows) return null;

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(home);

    const base = try std.fs.path.join(allocator, &.{ home, ".cache", "ms-playwright" });
    defer allocator.free(base);

    var dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch {
        return null;
    };
    defer dir.close();

    var best_ver: i64 = -1;
    var best_name: ?[]u8 = null;
    defer if (best_name) |n| allocator.free(n);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

        const rest = entry.name[prefix.len..];
        const ver = std.fmt.parseInt(i64, rest, 10) catch continue;
        if (ver > best_ver) {
            best_ver = ver;
            if (best_name) |old| allocator.free(old);
            best_name = try allocator.dupe(u8, entry.name);
        }
    }

    if (best_name == null) return null;

    // Build candidate path and check it exists.
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    try parts.append(allocator, base);
    try parts.append(allocator, best_name.?);
    for (subpath) |p| try parts.append(allocator, p);

    const full = try std.fs.path.join(allocator, parts.items);

    // Confirm executable exists.
    const f = std.fs.openFileAbsolute(full, .{}) catch {
        allocator.free(full);
        return null;
    };
    f.close();

    return full;
}

fn chromeScreenshotPngAlloc(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    // Minimal screenshot implementation using Chromium/Chrome --headless --screenshot.
    // First preference on Linux: Playwright-managed Chromium in ~/.cache/ms-playwright.

    const tmp_dir = blk: {
        const envs = if (builtin.os.tag == .windows)
            &[_][]const u8{ "TEMP", "TMP" }
        else
            &[_][]const u8{ "TMPDIR", "TMP" };

        for (envs) |k| {
            const v = std.process.getEnvVarOwned(allocator, k) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            if (v) |val| {
                break :blk val;
            }
        }

        break :blk try allocator.dupe(u8, if (builtin.os.tag == .windows) "." else "/tmp");
    };
    defer allocator.free(tmp_dir);

    const ts = @as(u64, @intCast(node_platform.nowMs()));
    const file_name = try std.fmt.allocPrint(allocator, "zsc-canvas-{d}.png", .{ts});
    defer allocator.free(file_name);

    const out_path = try std.fs.path.join(allocator, &.{ tmp_dir, file_name });
    defer allocator.free(out_path);

    const window_size = "--window-size=1280,720";
    const screenshot_arg = try std.fmt.allocPrint(allocator, "--screenshot={s}", .{out_path});
    defer allocator.free(screenshot_arg);

    const attempt = struct {
        fn run(alloc: std.mem.Allocator, exe: []const u8, out_path_abs: []const u8, screenshot_arg_: []const u8, url_: []const u8, window_size_: []const u8) !?[]u8 {
            var child = std.process.Child.init(
                &[_][]const u8{
                    exe,
                    "--headless",
                    "--disable-gpu",
                    "--hide-scrollbars",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                    window_size_,
                    screenshot_arg_,
                    url_,
                },
                alloc,
            );
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            child.spawn() catch |err| {
                if (err == error.FileNotFound) return null;
                return err;
            };

            const term = try child.wait();
            switch (term) {
                .Exited => |code| if (code != 0) return error.Unexpected,
                else => return error.Unexpected,
            }

            const f = try std.fs.openFileAbsolute(out_path_abs, .{});
            defer f.close();
            const bytes = try f.readToEndAlloc(alloc, 20 * 1024 * 1024);
            std.fs.deleteFileAbsolute(out_path_abs) catch {};
            return bytes;
        }
    }.run;

    // Dynamic candidates (Playwright cache)
    const pw_headless = try discoverPlaywrightBinaryAlloc(
        allocator,
        "chromium_headless_shell-",
        &.{ "chrome-headless-shell-linux64", "chrome-headless-shell" },
    );
    defer if (pw_headless) |p| allocator.free(p);

    if (pw_headless) |exe| {
        if (try attempt(allocator, exe, out_path, screenshot_arg, url, window_size)) |bytes| return bytes;
    }

    const pw_chrome = try discoverPlaywrightBinaryAlloc(
        allocator,
        "chromium-",
        &.{ "chrome-linux64", "chrome" },
    );
    defer if (pw_chrome) |p| allocator.free(p);

    if (pw_chrome) |exe| {
        if (try attempt(allocator, exe, out_path, screenshot_arg, url, window_size)) |bytes| return bytes;
    }

    // Static candidates
    const candidates = if (builtin.os.tag == .windows)
        &[_][]const u8{ "chrome.exe", "chrome", "msedge.exe", "msedge" }
    else if (builtin.os.tag == .macos)
        &[_][]const u8{ "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium", "google-chrome", "chromium" }
    else
        &[_][]const u8{ "google-chrome", "google-chrome-stable", "chromium", "chromium-browser" };

    for (candidates) |exe| {
        if (try attempt(allocator, exe, out_path, screenshot_arg, url, window_size)) |bytes| return bytes;
    }

    return error.FileNotFound;
}

// ============================================================================
// Process Management Command Handlers
// ============================================================================

fn processSpawnHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const command_arr = params.object.get("command") orelse {
        return CommandError.InvalidParams;
    };
    if (command_arr != .array or command_arr.array.items.len == 0) {
        return CommandError.InvalidParams;
    }

    // Convert JSON array to string array
    var cmd_parts = std.ArrayList([]const u8).empty;
    defer {
        for (cmd_parts.items) |s| allocator.free(s);
        cmd_parts.deinit(allocator);
    }

    for (command_arr.array.items) |item| {
        if (item != .string) continue;
        try cmd_parts.append(allocator, try allocator.dupe(u8, item.string));
    }

    if (cmd_parts.items.len == 0) {
        return CommandError.InvalidParams;
    }

    // Get optional cwd
    const cwd = if (params.object.get("cwd")) |c| switch (c) {
        .string => c.string,
        else => null,
    } else null;

    // Spawn the process
    const proc_id = ctx.process_manager.spawn(cmd_parts.items, cwd) catch |err| {
        logger.err("Failed to spawn process: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };
    defer allocator.free(proc_id);

    var result = std.json.ObjectMap.init(allocator);
    try result.put("processId", std.json.Value{ .string = try allocator.dupe(u8, proc_id) });
    try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "running") });
    return std.json.Value{ .object = result };
}

fn processPollHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const proc_id = params.object.get("processId") orelse {
        return CommandError.InvalidParams;
    };
    if (proc_id != .string) {
        return CommandError.InvalidParams;
    }

    const status = ctx.process_manager.getProcessStatus(allocator, proc_id.string) catch |err| {
        logger.err("Failed to get process status: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    } orelse {
        return CommandError.InvalidParams;
    };

    return status;
}

fn processStopHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const proc_id = params.object.get("processId") orelse {
        return CommandError.InvalidParams;
    };
    if (proc_id != .string) {
        return CommandError.InvalidParams;
    }

    const killed = ctx.process_manager.killProcess(proc_id.string) catch |err| {
        logger.err("Failed to kill process: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };

    var result = std.json.ObjectMap.init(allocator);
    try result.put("killed", std.json.Value{ .bool = killed });
    return std.json.Value{ .object = result };
}

fn processListHandler(allocator: std.mem.Allocator, ctx: *NodeContext, _: std.json.Value) CommandError!std.json.Value {
    return ctx.process_manager.listProcesses(allocator) catch |err| {
        logger.err("Failed to list processes: {s}", .{@errorName(err)});
        return CommandError.ExecutionFailed;
    };
}
