const std = @import("std");

/// Node configuration - stored in ~/.openclaw/node.json
pub const NodeConfig = struct {
    node_id: []const u8,
    device_token: ?[]const u8 = null,
    /// Gateway auth token (OpenClaw gateway.auth.token). Required when the gateway auth mode is token.
    gateway_token: ?[]const u8 = null,
    display_name: []const u8,
    gateway_host: []const u8,
    gateway_port: u16 = 18789,
    tls: bool = false,
    tls_fingerprint: ?[]const u8 = null,

    // Capability settings
    system_enabled: bool = true,
    canvas_enabled: bool = false,
    screen_enabled: bool = false,
    camera_enabled: bool = false,
    location_enabled: bool = false,

    // Canvas backend ("webkitgtk", "chrome", "none")
    canvas_backend: []const u8 = "chrome",
    canvas_width: u32 = 1280,
    canvas_height: u32 = 720,
    chrome_path: ?[]const u8 = null,
    chrome_debug_port: u16 = 9222,

    // Connection roles
    // For "both" mode we maintain two concurrent websocket connections.
    enable_node_connection: bool = true,
    enable_operator_connection: bool = false,

    // Node connection identity
    node_device_identity_path: []const u8 = "ziggystarclaw_device.json",

    // Operator connection identity + scopes (only used when enable_operator_connection=true)
    operator_device_identity_path: []const u8 = "ziggystarclaw_operator_device.json",
    operator_scopes: []const []const u8 = &.{ "operator.admin", "operator.approvals", "operator.pairing" },
    operator_scopes_owned: bool = false,

    // Paths
    exec_approvals_path: []const u8,

    pub fn initDefault(allocator: std.mem.Allocator, node_id: []const u8, display_name: []const u8, gateway_host: []const u8) !NodeConfig {
        return .{
            .node_id = try allocator.dupe(u8, node_id),
            .display_name = try allocator.dupe(u8, display_name),
            .gateway_host = try allocator.dupe(u8, gateway_host),
            .canvas_backend = try allocator.dupe(u8, "chrome"),
            .enable_node_connection = true,
            .enable_operator_connection = false,
            .node_device_identity_path = try allocator.dupe(u8, "ziggystarclaw_device.json"),
            .operator_device_identity_path = try allocator.dupe(u8, "ziggystarclaw_operator_device.json"),
            .operator_scopes = &.{ "operator.admin", "operator.approvals", "operator.pairing" },
            .operator_scopes_owned = false,
            .exec_approvals_path = try allocator.dupe(u8, "~/.openclaw/exec-approvals.json"),
        };
    }

    pub fn deinit(self: *NodeConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        if (self.device_token) |token| {
            allocator.free(token);
        }
        if (self.gateway_token) |token| {
            allocator.free(token);
        }
        allocator.free(self.display_name);
        allocator.free(self.gateway_host);
        allocator.free(self.node_device_identity_path);
        allocator.free(self.operator_device_identity_path);
        if (self.operator_scopes_owned) {
            for (self.operator_scopes) |s| {
                allocator.free(s);
            }
            allocator.free(self.operator_scopes);
        }
        if (self.tls_fingerprint) |fp| {
            allocator.free(fp);
        }
        allocator.free(self.canvas_backend);
        if (self.chrome_path) |path| {
            allocator.free(path);
        }
        allocator.free(self.exec_approvals_path);
    }

    /// Get the default config path
    pub fn defaultPath(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (home) |value| {
            defer allocator.free(value);
            return std.fs.path.join(allocator, &.{ value, ".openclaw", "node.json" });
        }

        // Windows fallback
        // Prefer per-user roaming AppData so the config location is stable regardless
        // of current working directory and matches user expectations on Windows.
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (appdata) |value| {
            defer allocator.free(value);
            return std.fs.path.join(allocator, &.{ value, "ZiggyStarClaw", "node.json" });
        }

        const userprofile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (userprofile) |value| {
            defer allocator.free(value);
            return std.fs.path.join(allocator, &.{ value, ".openclaw", "node.json" });
        }

        // Last resort: relative path
        return allocator.dupe(u8, ".openclaw/node.json");
    }

    /// Load config from file, or return null if not found
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !?NodeConfig {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(data);

        return try parse(allocator, data);
    }

    /// Parse config from JSON string
    pub fn parse(allocator: std.mem.Allocator, json_data: []const u8) !NodeConfig {
        // Parse with our struct as the target
        var parsed = try std.json.parseFromSlice(NodeConfig, allocator, json_data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        // Deep copy all strings
        // Copy operator scopes
        var scopes_list = std.ArrayList([]const u8).empty;
        errdefer {
            for (scopes_list.items) |s| allocator.free(s);
            scopes_list.deinit(allocator);
        }
        for (parsed.value.operator_scopes) |s| {
            try scopes_list.append(allocator, try allocator.dupe(u8, s));
        }
        const operator_scopes_owned = try scopes_list.toOwnedSlice(allocator);
        scopes_list.deinit(allocator);

        return .{
            .node_id = try allocator.dupe(u8, parsed.value.node_id),
            .device_token = if (parsed.value.device_token) |token|
                try allocator.dupe(u8, token)
            else
                null,
            .gateway_token = if (parsed.value.gateway_token) |token|
                try allocator.dupe(u8, token)
            else
                null,
            .display_name = try allocator.dupe(u8, parsed.value.display_name),
            .gateway_host = try allocator.dupe(u8, parsed.value.gateway_host),
            .gateway_port = parsed.value.gateway_port,
            .tls = parsed.value.tls,
            .tls_fingerprint = if (parsed.value.tls_fingerprint) |fp|
                try allocator.dupe(u8, fp)
            else
                null,
            .system_enabled = parsed.value.system_enabled,
            .canvas_enabled = parsed.value.canvas_enabled,
            .screen_enabled = parsed.value.screen_enabled,
            .camera_enabled = parsed.value.camera_enabled,
            .location_enabled = parsed.value.location_enabled,

            .enable_node_connection = parsed.value.enable_node_connection,
            .enable_operator_connection = parsed.value.enable_operator_connection,
            .node_device_identity_path = try allocator.dupe(u8, parsed.value.node_device_identity_path),
            .operator_device_identity_path = try allocator.dupe(u8, parsed.value.operator_device_identity_path),
            .operator_scopes = operator_scopes_owned,
            .operator_scopes_owned = true,

            .exec_approvals_path = try allocator.dupe(u8, parsed.value.exec_approvals_path),
        };
    }

    /// Save config to file
    pub fn save(self: NodeConfig, allocator: std.mem.Allocator, path: []const u8) !void {
        // Ensure directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const json = try std.json.Stringify.valueAlloc(allocator, self, .{
            .emit_null_optional_fields = false,
            .whitespace = .indent_2,
        });
        defer allocator.free(json);

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        try file.writeAll(json);
    }

    /// Get the WebSocket URL
    pub fn getWebSocketUrl(self: NodeConfig, allocator: std.mem.Allocator) ![]const u8 {
        const scheme = if (self.tls) "wss" else "ws";
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}/ws", .{
            scheme,
            self.gateway_host,
            self.gateway_port,
        });
    }
};

/// Exec approvals configuration
pub const ExecApprovals = struct {
    version: u32 = 1,
    mode: []const u8 = "allowlist",
    allowlist: std.ArrayList([]const u8),
    ask_patterns: std.ArrayList([]const u8),

    pub fn init(_: std.mem.Allocator) ExecApprovals {
        return .{
            .allowlist = std.ArrayList([]const u8).empty,
            .ask_patterns = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *ExecApprovals, allocator: std.mem.Allocator) void {
        for (self.allowlist.items) |entry| {
            allocator.free(entry);
        }
        self.allowlist.deinit(allocator);

        for (self.ask_patterns.items) |entry| {
            allocator.free(entry);
        }
        self.ask_patterns.deinit(allocator);
    }

    /// Load from file or create default
    pub fn loadOrDefault(allocator: std.mem.Allocator, path: []const u8) !ExecApprovals {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var default = init(allocator);
                // Add some safe defaults
                try default.allowlist.append(allocator, try allocator.dupe(u8, "/bin/ls"));
                try default.allowlist.append(allocator, try allocator.dupe(u8, "/bin/pwd"));
                try default.allowlist.append(allocator, try allocator.dupe(u8, "/usr/bin/uname"));
                return default;
            },
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(data);

        return try parse(allocator, data);
    }

    /// Parse from JSON
    pub fn parse(allocator: std.mem.Allocator, json_data: []const u8) !ExecApprovals {
        var parsed = try std.json.parseFromSlice(JsonRepr, allocator, json_data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var result = init(allocator);
        result.mode = try allocator.dupe(u8, parsed.value.mode);

        for (parsed.value.allowlist) |entry| {
            try result.allowlist.append(allocator, try allocator.dupe(u8, entry));
        }
        for (parsed.value.ask_patterns) |entry| {
            try result.ask_patterns.append(allocator, try allocator.dupe(u8, entry));
        }

        return result;
    }

    /// Save to file
    pub fn save(self: ExecApprovals, allocator: std.mem.Allocator, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const repr = JsonRepr{
            .version = self.version,
            .mode = self.mode,
            .allowlist = self.allowlist.items,
            .ask_patterns = self.ask_patterns.items,
        };

        const json = try std.json.Stringify.valueAlloc(allocator, repr, .{
            .emit_null_optional_fields = false,
            .whitespace = .indent_2,
        });
        defer allocator.free(json);

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        try file.writeAll(json);
    }

    /// Check if a command is allowed
    pub fn isAllowed(self: ExecApprovals, command: []const u8) bool {
        if (std.mem.eql(u8, self.mode, "full")) return true;
        if (std.mem.eql(u8, self.mode, "deny")) return false;

        // Allowlist mode
        for (self.allowlist.items) |allowed| {
            if (std.mem.eql(u8, command, allowed)) return true;
            // Simple glob matching for ** patterns
            if (globMatch(allowed, command)) return true;
        }

        return false;
    }

    fn globMatch(pattern: []const u8, text: []const u8) bool {
        var p: usize = 0;
        var t: usize = 0;

        while (p < pattern.len and t < text.len) {
            if (pattern[p] == '*') {
                if (p + 1 < pattern.len and pattern[p + 1] == '*') {
                    // ** matches anything
                    return true;
                }
                // * matches any sequence
                p += 1;
                if (p >= pattern.len) return true;
                while (t < text.len and text[t] != pattern[p]) {
                    t += 1;
                }
            } else if (pattern[p] == text[t]) {
                p += 1;
                t += 1;
            } else {
                return false;
            }
        }

        while (p < pattern.len and pattern[p] == '*') {
            p += 1;
        }

        return p >= pattern.len and t >= text.len;
    }

    const JsonRepr = struct {
        version: u32 = 1,
        mode: []const u8 = "allowlist",
        allowlist: [][]const u8 = &.{},
        ask_patterns: [][]const u8 = &.{},
    };
};
