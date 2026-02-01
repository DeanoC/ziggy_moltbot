const std = @import("std");
const types = @import("../protocol/types.zig");
const ProcessManager = @import("process_manager.zig").ProcessManager;
const CanvasManager = @import("canvas.zig").CanvasManager;

/// Node capability categories
pub const Capability = enum {
    system,
    canvas,
    screen,
    camera,
    location,
    voice,

    pub fn toString(self: Capability) []const u8 {
        return switch (self) {
            .system => "system",
            .canvas => "canvas",
            .screen => "screen",
            .camera => "camera",
            .location => "location",
            .voice => "voice",
        };
    }
};

/// Node command strings that can be invoked
pub const Command = enum {
    // System commands
    system_run,
    system_which,
    system_notify,
    system_exec_approvals_get,
    system_exec_approvals_set,

    // Canvas commands
    canvas_present,
    canvas_hide,
    canvas_navigate,
    canvas_eval,
    canvas_snapshot,
    canvas_a2ui_push,
    canvas_a2ui_reset,

    // Screen commands
    screen_record,

    // Camera commands
    camera_list,
    camera_snap,
    camera_clip,

    // Location commands
    location_get,

    // Process commands
    process_spawn,
    process_poll,
    process_stop,
    process_list,

    pub fn toString(self: Command) []const u8 {
        return switch (self) {
            .system_run => "system.run",
            .system_which => "system.which",
            .system_notify => "system.notify",
            .system_exec_approvals_get => "system.execApprovals.get",
            .system_exec_approvals_set => "system.execApprovals.set",
            .canvas_present => "canvas.present",
            .canvas_hide => "canvas.hide",
            .canvas_navigate => "canvas.navigate",
            .canvas_eval => "canvas.eval",
            .canvas_snapshot => "canvas.snapshot",
            .canvas_a2ui_push => "canvas.a2ui.push",
            .canvas_a2ui_reset => "canvas.a2ui.reset",
            .screen_record => "screen.record",
            .camera_list => "camera.list",
            .camera_snap => "camera.snap",
            .camera_clip => "camera.clip",
            .location_get => "location.get",
            .process_spawn => "process.spawn",
            .process_poll => "process.poll",
            .process_stop => "process.stop",
            .process_list => "process.list",
        };
    }

    pub fn fromString(str: []const u8) ?Command {
        inline for (@typeInfo(Command).Enum.fields) |field| {
            const cmd = @field(Command, field.name);
            if (std.mem.eql(u8, str, cmd.toString())) {
                return cmd;
            }
        }
        return null;
    }
};

/// Node execution state
pub const NodeState = enum {
    disconnected,
    connecting,
    authenticating,
    idle,
    executing,
    error_state,
};

/// Pending command execution
pub const PendingExecution = struct {
    request_id: []const u8,
    command: Command,
    start_time_ms: i64,
    child_process: ?std.process.Child = null,
};

/// Node context - holds all node-specific state
pub const NodeContext = struct {
    allocator: std.mem.Allocator,
    state: NodeState,

    // Identity
    node_id: []const u8,
    display_name: []const u8,
    device_token: ?[]const u8 = null,

    // Capabilities
    capabilities: std.ArrayList(Capability),
    commands: std.ArrayList(Command),
    permissions: std.StringHashMap(bool),

    // Execution
    pending_executions: std.ArrayList(PendingExecution),
    exec_approvals_path: []const u8,
    process_manager: ProcessManager,
    canvas_manager: CanvasManager,

    // Stats
    commands_executed: u64 = 0,
    commands_failed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, node_id: []const u8, display_name: []const u8) !NodeContext {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .node_id = try allocator.dupe(u8, node_id),
            .display_name = try allocator.dupe(u8, display_name),
            .capabilities = std.ArrayList(Capability).empty,
            .commands = std.ArrayList(Command).empty,
            .permissions = std.StringHashMap(bool).init(allocator),
            .pending_executions = std.ArrayList(PendingExecution).empty,
            .exec_approvals_path = try allocator.dupe(u8, "~/.openclaw/exec-approvals.json"),
            .process_manager = ProcessManager.init(allocator),
            .canvas_manager = CanvasManager.init(allocator),
        };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !NodeContext {
        var node_id_buf: [32]u8 = undefined;
        const node_id = try generateNodeId(&node_id_buf);
        return try init(allocator, node_id, "ZiggyStarClaw Node");
    }

    pub fn deinit(self: *NodeContext) void {
        self.allocator.free(self.node_id);
        self.allocator.free(self.display_name);
        if (self.device_token) |token| {
            self.allocator.free(token);
        }
        self.allocator.free(self.exec_approvals_path);

        for (self.capabilities.items) |*cap| {
            _ = cap;
        }
        self.capabilities.deinit(self.allocator);

        for (self.commands.items) |*cmd| {
            _ = cmd;
        }
        self.commands.deinit(self.allocator);

        var perm_iter = self.permissions.iterator();
        while (perm_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.permissions.deinit();

        self.process_manager.deinit();
        self.canvas_manager.deinit();

        for (self.pending_executions.items) |*exec| {
            if (exec.child_process) |*child| {
                _ = child.kill() catch {};
            }
            self.allocator.free(exec.request_id);
        }
        self.pending_executions.deinit(self.allocator);
    }

    /// Add a capability
    pub fn addCapability(self: *NodeContext, cap: Capability) !void {
        // Check if already exists
        for (self.capabilities.items) |existing| {
            if (existing == cap) return;
        }
        try self.capabilities.append(self.allocator, cap);
    }

    /// Add a command
    pub fn addCommand(self: *NodeContext, cmd: Command) !void {
        // Check if already exists
        for (self.commands.items) |existing| {
            if (existing == cmd) return;
        }
        try self.commands.append(self.allocator, cmd);
    }

    /// Set permission
    pub fn setPermission(self: *NodeContext, name: []const u8, granted: bool) !void {
        const key = try self.allocator.dupe(u8, name);
        const result = try self.permissions.getOrPut(key);
        if (result.found_existing) {
            self.allocator.free(key);
            result.value_ptr.* = granted;
        } else {
            result.value_ptr.* = granted;
        }
    }

    /// Check if command is supported
    pub fn supportsCommand(self: *NodeContext, cmd_str: []const u8) bool {
        const cmd = Command.fromString(cmd_str) orelse return false;
        for (self.commands.items) |existing| {
            if (existing == cmd) return true;
        }
        return false;
    }

    /// Get capabilities as string array (for connect params)
    pub fn getCapabilitiesArray(self: *NodeContext) ![]const []const u8 {
        const result = try self.allocator.alloc([]const u8, self.capabilities.items.len);
        for (self.capabilities.items, 0..) |cap, i| {
            result[i] = cap.toString();
        }
        return result;
    }

    /// Get commands as string array (for connect params)
    pub fn getCommandsArray(self: *NodeContext) ![]const []const u8 {
        const result = try self.allocator.alloc([]const u8, self.commands.items.len);
        for (self.commands.items, 0..) |cmd, i| {
            result[i] = cmd.toString();
        }
        return result;
    }

    /// Register standard system capabilities
    pub fn registerSystemCapabilities(self: *NodeContext) !void {
        try self.addCapability(.system);
        try self.addCommand(.system_run);
        try self.addCommand(.system_which);
        try self.addCommand(.system_exec_approvals_get);
        try self.addCommand(.system_exec_approvals_set);
        try self.setPermission("system.run", true);
    }

    /// Register canvas capabilities
    pub fn registerCanvasCapabilities(self: *NodeContext) !void {
        try self.addCapability(.canvas);
        try self.addCommand(.canvas_present);
        try self.addCommand(.canvas_hide);
        try self.addCommand(.canvas_navigate);
        try self.addCommand(.canvas_eval);
        try self.addCommand(.canvas_snapshot);
    }

    /// Register process management capabilities
    pub fn registerProcessCapabilities(self: *NodeContext) !void {
        // Process commands are part of system capability
        try self.addCommand(.process_spawn);
        try self.addCommand(.process_poll);
        try self.addCommand(.process_stop);
        try self.addCommand(.process_list);
    }
};

pub fn generateNodeId(buf: *[32]u8) ![]const u8 {
    const prefix = "zsc-node-";
    @memcpy(buf[0..prefix.len], prefix);
    
    var random_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    
    const hex_chars = "0123456789abcdef";
    var i: usize = prefix.len;
    for (random_bytes) |byte| {
        buf[i] = hex_chars[byte >> 4];
        buf[i + 1] = hex_chars[byte & 0x0f];
        i += 2;
    }
    
    return buf[0..i];
}

// Free arrays returned by getCapabilitiesArray/getCommandsArray
pub fn freeStringArray(allocator: std.mem.Allocator, arr: []const []const u8) void {
    allocator.free(arr);
}
