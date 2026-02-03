const std = @import("std");

pub const UnifiedConfig = struct {
    pub const Gateway = struct {
        /// Full ws/wss/http/https URL to the gateway (with or without /ws).
        wsUrl: []const u8,
        /// OpenClaw gateway auth token (used for operator-mode websocket and node pairing RPCs).
        authToken: []const u8,

        // (bridge removed; node-mode uses gateway websocket)
    };

    pub const Node = struct {
        enabled: bool = true,

        /// Node token (role=node). Used inside device-auth signed payload.
        /// Stored in config.json as: node.nodeToken
        nodeToken: []const u8 = "",

        /// Stable node id (what the gateway calls nodeId).
        /// Stored in config.json as: node.nodeId
        nodeId: []const u8 = "",

        // (no backward compat)

        /// Optional display name (falls back to "ZiggyStarClaw Node").
        displayName: ?[]const u8 = null,

        /// Where to store the node device identity JSON.
        deviceIdentityPath: []const u8,
        /// Exec approvals JSON path (used by system.run allowlist).
        execApprovalsPath: []const u8,
    };

    pub const Operator = struct {
        enabled: bool = false,
        /// Optional operator token (role=operator). Not used when enabled=false.
        token: ?[]const u8 = null,
        /// Where to store operator device identity JSON.
        deviceIdentityPath: ?[]const u8 = null,
        scopes: []const []const u8 = &.{ "operator.admin", "operator.approvals", "operator.pairing" },
    };

    pub const Logging = struct {
        level: ?[]const u8 = null,
        file: ?[]const u8 = null,
    };

    gateway: Gateway,
    node: Node,
    operator: Operator = .{},
    logging: Logging = .{},

    pub fn deinit(self: *UnifiedConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.gateway.wsUrl);
        allocator.free(self.gateway.authToken);
        // (no gateway.bridgeHost)

        allocator.free(self.node.nodeToken);
        allocator.free(self.node.deviceIdentityPath);
        allocator.free(self.node.execApprovalsPath);
        if (self.node.displayName) |v| allocator.free(v);
        allocator.free(self.node.nodeId);

        if (self.operator.token) |v| allocator.free(v);
        if (self.operator.deviceIdentityPath) |v| allocator.free(v);
        if (self.logging.level) |v| allocator.free(v);
        if (self.logging.file) |v| allocator.free(v);

        // scopes in Operator are borrowed; we keep defaults and ignore custom scopes for now.
    }
};

fn expandVarsAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Expand a small set of variables. This is intentionally minimal and explicit.
    // Supported:
    // - %APPDATA%, %USERPROFILE% (Windows)
    // - ~ (HOME/USERPROFILE)
    var s = try allocator.dupe(u8, raw);
    errdefer allocator.free(s);

    // Expand %APPDATA% / %USERPROFILE%
    const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch null;
    defer if (appdata) |v| allocator.free(v);
    if (appdata) |v| {
        const replaced = try std.mem.replaceOwned(u8, allocator, s, "%APPDATA%", v);
        allocator.free(s);
        s = replaced;
    }

    const userprofile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch null;
    defer if (userprofile) |v| allocator.free(v);
    if (userprofile) |v| {
        const replaced = try std.mem.replaceOwned(u8, allocator, s, "%USERPROFILE%", v);
        allocator.free(s);
        s = replaced;
    }

    // Expand ~/
    if (s.len >= 2 and s[0] == '~' and (s[1] == '/' or s[1] == '\\')) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
        if (home) |h| {
            defer allocator.free(h);
            const joined = try std.fs.path.join(allocator, &.{ h, s[2..] });
            allocator.free(s);
            s = joined;
        } else {
            // Windows fallback
            if (userprofile) |up| {
                const joined = try std.fs.path.join(allocator, &.{ up, s[2..] });
                allocator.free(s);
                s = joined;
            }
        }
    }

    return s;
}

pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch null;
    if (appdata) |v| {
        defer allocator.free(v);
        return std.fs.path.join(allocator, &.{ v, "ZiggyStarClaw", "config.json" });
    }
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home) |v| {
        defer allocator.free(v);
        return std.fs.path.join(allocator, &.{ v, ".config", "ziggystarclaw", "config.json" });
    }
    return allocator.dupe(u8, "config.json");
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !UnifiedConfig {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigNotFound,
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(UnifiedConfig, allocator, data, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // Deep-copy + env expansion
    const gw_url = try expandVarsAlloc(allocator, parsed.value.gateway.wsUrl);
    errdefer allocator.free(gw_url);
    const gw_tok = try expandVarsAlloc(allocator, parsed.value.gateway.authToken);
    errdefer allocator.free(gw_tok);

    // (bridge removed)

    // node.nodeToken (no backward compat)
    const raw_node_token = parsed.value.node.nodeToken;

    const node_tok = try expandVarsAlloc(allocator, raw_node_token);
    errdefer allocator.free(node_tok);
    const node_identity = try expandVarsAlloc(allocator, parsed.value.node.deviceIdentityPath);
    errdefer allocator.free(node_identity);
    const approvals = try expandVarsAlloc(allocator, parsed.value.node.execApprovalsPath);
    errdefer allocator.free(approvals);

    const display = if (parsed.value.node.displayName) |v|
        try expandVarsAlloc(allocator, v)
    else
        null;
    errdefer if (display) |v| allocator.free(v);

    const node_id = try expandVarsAlloc(allocator, parsed.value.node.nodeId);
    errdefer allocator.free(node_id);

    const op_token = if (parsed.value.operator.token) |v|
        try expandVarsAlloc(allocator, v)
    else
        null;
    errdefer if (op_token) |v| allocator.free(v);

    const op_ident = if (parsed.value.operator.deviceIdentityPath) |v|
        try expandVarsAlloc(allocator, v)
    else
        null;
    errdefer if (op_ident) |v| allocator.free(v);

    const log_level = if (parsed.value.logging.level) |v|
        try expandVarsAlloc(allocator, v)
    else
        null;
    errdefer if (log_level) |v| allocator.free(v);

    const log_file = if (parsed.value.logging.file) |v|
        try expandVarsAlloc(allocator, v)
    else
        null;
    errdefer if (log_file) |v| allocator.free(v);

    return .{
        .gateway = .{ .wsUrl = gw_url, .authToken = gw_tok },
        .node = .{
            .enabled = parsed.value.node.enabled,
            .nodeToken = node_tok,
            .nodeId = node_id,
            .displayName = display,
            .deviceIdentityPath = node_identity,
            .execApprovalsPath = approvals,
        },
        .operator = .{
            .enabled = parsed.value.operator.enabled,
            .token = op_token,
            .deviceIdentityPath = op_ident,
            .scopes = parsed.value.operator.scopes,
        },
        .logging = .{ .level = log_level, .file = log_file },
    };
}

pub fn normalizeGatewayWsUrl(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Ensure we have a ws:// or wss:// URL and ensure path ends with /ws.
    // Convert http(s) to ws(s)
    if (std.mem.startsWith(u8, raw, "http://")) {
        const tmp = try std.fmt.allocPrint(allocator, "ws://{s}", .{raw[7..]});
        defer allocator.free(tmp);
        return ensureWsPath(allocator, tmp);
    } else if (std.mem.startsWith(u8, raw, "https://")) {
        const tmp = try std.fmt.allocPrint(allocator, "wss://{s}", .{raw[8..]});
        defer allocator.free(tmp);
        return ensureWsPath(allocator, tmp);
    }
    return ensureWsPath(allocator, raw);
}

fn ensureWsPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // If already ends with /ws, keep. Otherwise force /ws.
    const uri = std.Uri.parse(raw) catch {
        // If it's not a full URI, assume host:port
        return std.fmt.allocPrint(allocator, "ws://{s}/ws", .{raw});
    };

    // IMPORTANT: toRawMaybeAlloc may return a borrowed slice; use an arena allocator
    // so any allocations are owned by the arena and we never free a borrowed slice.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const path_raw = try uri.path.toRawMaybeAlloc(aa);
    if (std.mem.eql(u8, path_raw, "/ws")) {
        return allocator.dupe(u8, raw);
    }

    // Rebuild with /ws
    const scheme = uri.scheme;
    // getHostAlloc may return a borrowed slice; use the arena allocator here and do not free.
    const host = try uri.getHostAlloc(aa);
    const port = uri.port;

    const base = if (port) |p|
        try std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ scheme, host, p })
    else
        try std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, host });
    defer allocator.free(base);

    return std.fmt.allocPrint(allocator, "{s}/ws", .{base});
}
