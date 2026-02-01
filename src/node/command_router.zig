const std = @import("std");
const node_context = @import("node_context.zig");
const NodeContext = node_context.NodeContext;
const Command = node_context.Command;
const websocket_client = @import("../client/websocket_client.zig");
const requests = @import("../protocol/requests.zig");
const messages = @import("../protocol/messages.zig");
const logger = @import("../utils/logger.zig");

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
        ctx: *NodeContext,
        command: []const u8,
        params: std.json.Value,
    ) CommandError!std.json.Value {
        const handler = self.handlers.get(command) orelse {
            logger.warn("Command not registered: {s}", .{command});
            return CommandError.CommandNotSupported;
        };

        return handler(self.allocator, ctx, params);
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
    try router.register(.system_exec_approvals_get, systemExecApprovalsGetHandler);
    try router.register(.system_exec_approvals_set, systemExecApprovalsSetHandler);

    // Process commands
    try router.register(.process_spawn, processSpawnHandler);
    try router.register(.process_poll, processPollHandler);
    try router.register(.process_stop, processStopHandler);
    try router.register(.process_list, processListHandler);

    // Canvas commands (stubs for now)
    try router.register(.canvas_present, canvasPresentHandler);
    try router.register(.canvas_hide, canvasHideHandler);
    try router.register(.canvas_navigate, canvasNavigateHandler);
    try router.register(.canvas_eval, canvasEvalHandler);
    try router.register(.canvas_snapshot, canvasSnapshotHandler);

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
    const start_time = std.time.milliTimestamp();
    var timed_out = false;

    while (true) {
        const elapsed = std.time.milliTimestamp() - start_time;
        if (elapsed > timeout_ms) {
            timed_out = true;
            _ = child.kill() catch {};
            break;
        }
        
        // Check if child exited (poll)
        const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (result.pid != 0) {
            break; // Process exited
        }
        
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    stdout_thread.join();
    stderr_thread.join();

    // Get exit status
    const term = if (timed_out) 
        std.process.Child.Term{ .Signal = 9 }
    else 
        child.wait() catch |err| {
            logger.err("Failed to wait for process: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
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

    while (iter.next()) |dir| {
        if (dir.len == 0) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir, name.string }) catch continue;
        defer allocator.free(full_path);

        // Check if file exists and is executable
        std.fs.cwd().access(full_path, .{ .mode = .read_only }) catch continue;

        var result = std.json.ObjectMap.init(allocator);
        try result.put("path", std.json.Value{ .string = try allocator.dupe(u8, full_path) });
        return std.json.Value{ .object = result };
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
// Canvas Command Handlers (Stubs)
// ============================================================================

fn canvasPresentHandler(allocator: std.mem.Allocator, ctx: *NodeContext, _: std.json.Value) CommandError!std.json.Value {
    if (ctx.canvas_manager.getCanvas()) |canvas| {
        canvas.present() catch |err| {
            logger.err("canvas.present failed: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
        };
        
        var result = std.json.ObjectMap.init(allocator);
        try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "visible") });
        try result.put("backend", std.json.Value{ .string = try allocator.dupe(u8, @tagName(canvas.config.backend)) });
        return std.json.Value{ .object = result };
    }
    
    return CommandError.NotAllowed;
}

fn canvasHideHandler(allocator: std.mem.Allocator, ctx: *NodeContext, _: std.json.Value) CommandError!std.json.Value {
    if (ctx.canvas_manager.getCanvas()) |canvas| {
        canvas.hide() catch |err| {
            logger.err("canvas.hide failed: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
        };
        
        var result = std.json.ObjectMap.init(allocator);
        try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "hidden") });
        return std.json.Value{ .object = result };
    }
    
    return CommandError.NotAllowed;
}

fn canvasNavigateHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const url_param = params.object.get("url") orelse {
        return CommandError.InvalidParams;
    };
    if (url_param != .string) {
        return CommandError.InvalidParams;
    }
    
    if (ctx.canvas_manager.getCanvas()) |canvas| {
        canvas.navigate(url_param.string) catch |err| {
            logger.err("canvas.navigate failed: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
        };
        
        var result = std.json.ObjectMap.init(allocator);
        try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "navigated") });
        try result.put("url", std.json.Value{ .string = try allocator.dupe(u8, url_param.string) });
        return std.json.Value{ .object = result };
    }
    
    return CommandError.NotAllowed;
}

fn canvasEvalHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const js_param = params.object.get("js") orelse {
        return CommandError.InvalidParams;
    };
    if (js_param != .string) {
        return CommandError.InvalidParams;
    }
    
    if (ctx.canvas_manager.getCanvas()) |canvas| {
        const result_str = canvas.eval(js_param.string) catch |err| {
            logger.err("canvas.eval failed: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
        };
        defer allocator.free(result_str);
        
        var result = std.json.ObjectMap.init(allocator);
        try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "success") });
        try result.put("result", std.json.Value{ .string = try allocator.dupe(u8, result_str) });
        return std.json.Value{ .object = result };
    }
    
    return CommandError.NotAllowed;
}

fn canvasSnapshotHandler(allocator: std.mem.Allocator, ctx: *NodeContext, params: std.json.Value) CommandError!std.json.Value {
    const path_param = params.object.get("path") orelse {
        return CommandError.InvalidParams;
    };
    if (path_param != .string) {
        return CommandError.InvalidParams;
    }
    
    if (ctx.canvas_manager.getCanvas()) |canvas| {
        canvas.snapshot(path_param.string) catch |err| {
            logger.err("canvas.snapshot failed: {s}", .{@errorName(err)});
            return CommandError.ExecutionFailed;
        };
        
        var result = std.json.ObjectMap.init(allocator);
        try result.put("status", std.json.Value{ .string = try allocator.dupe(u8, "saved") });
        try result.put("path", std.json.Value{ .string = try allocator.dupe(u8, path_param.string) });
        return std.json.Value{ .object = result };
    }
    
    return CommandError.NotAllowed;
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
