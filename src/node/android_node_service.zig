const std = @import("std");

const websocket_client = @import("../client/websocket_client.zig");
const identity = @import("../client/device_identity.zig");
const node_context = @import("node_context.zig");
const NodeContext = node_context.NodeContext;
const Command = node_context.Command;
const command_router = @import("command_router.zig");
const CommandRouter = command_router.CommandRouter;
const SingleThreadConnectionManager = @import("connection_manager_singlethread.zig").SingleThreadConnectionManager;
const health_reporter = @import("health_reporter.zig");
const HealthReporter = health_reporter.HealthReporter;
const messages = @import("../protocol/messages.zig");
const logger = @import("../utils/logger.zig");
const node_platform = @import("node_platform.zig");

pub const NodeHostConfig = struct {
    ws_url: []const u8,
    auth_token: []const u8,
    insecure_tls: bool = false,
    connect_host_override: ?[]const u8 = null,

    display_name: ?[]const u8 = null,
    device_identity_path: []const u8 = "ziggystarclaw_node_device.json",
    exec_approvals_path: []const u8 = "exec-approvals.json",
    heartbeat_interval_ms: i64 = 10_000,
};

/// Background node host intended for the Android UI app.
///
/// This uses the same OpenClaw websocket protocol as desktop `--node-mode`, but
/// with an intentionally small initial command surface.
pub const AndroidNodeHost = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) AndroidNodeHost {
        return .{ .allocator = allocator };
    }

    pub fn start(self: *AndroidNodeHost, cfg: NodeHostConfig) !bool {
        if (self.thread != null) return false;
        if (cfg.ws_url.len == 0 or cfg.auth_token.len == 0) return false;

        self.stop_flag.store(false, .monotonic);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{ self, cfg });
        return true;
    }

    pub fn stop(self: *AndroidNodeHost) void {
        self.stop_flag.store(true, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isRunning(self: *AndroidNodeHost) bool {
        return self.running.load(.monotonic);
    }
};

fn threadMain(self: *AndroidNodeHost, cfg: NodeHostConfig) void {
    self.running.store(true, .monotonic);
    defer self.running.store(false, .monotonic);

    const allocator = self.allocator;

    // Stable node id: derive from node-specific device identity.
    var ident = identity.loadOrCreate(allocator, cfg.device_identity_path) catch |err| {
        logger.err("node-host: failed to load/create device identity: {s}", .{@errorName(err)});
        return;
    };
    defer ident.deinit(allocator);

    const display_name = cfg.display_name orelse "ZiggyStarClaw Android";

    var node_ctx = NodeContext.init(allocator, ident.device_id, display_name) catch |err| {
        logger.err("node-host: failed to init node context: {s}", .{@errorName(err)});
        return;
    };
    defer node_ctx.deinit();

    // Override exec approvals path to something sane for mobile (cwd is SDL pref path).
    const approvals_path = allocator.dupe(u8, cfg.exec_approvals_path) catch null;
    if (approvals_path) |p| {
        allocator.free(node_ctx.exec_approvals_path);
        node_ctx.exec_approvals_path = p;
    }

    // Minimal command surface for Android for now.
    // Note: we intentionally do NOT register `system.run` initially.
    node_ctx.addCapability(.system) catch {};
    node_ctx.addCommand(.system_which) catch {};
    node_ctx.addCommand(.system_notify) catch {};
    node_ctx.addCommand(.system_exec_approvals_get) catch {};
    node_ctx.addCommand(.system_exec_approvals_set) catch {};

    const supported_cmds = &[_]Command{
        .system_which,
        .system_notify,
        .system_exec_approvals_get,
        .system_exec_approvals_set,
    };

    var router = command_router.initRouterWithCommands(allocator, supported_cmds) catch |err| {
        logger.err("node-host: failed to init router: {s}", .{@errorName(err)});
        return;
    };
    defer router.deinit();

    const caps = node_ctx.getCapabilitiesArray() catch |err| {
        logger.err("node-host: failed to build caps array: {s}", .{@errorName(err)});
        return;
    };
    defer node_context.freeStringArray(allocator, caps);
    const commands = node_ctx.getCommandsArray() catch |err| {
        logger.err("node-host: failed to build commands array: {s}", .{@errorName(err)});
        return;
    };
    defer node_context.freeStringArray(allocator, commands);

    var conn = SingleThreadConnectionManager.init(
        allocator,
        cfg.ws_url,
        cfg.auth_token, // WS Authorization token
        cfg.auth_token, // connect.auth.token
        cfg.auth_token, // device-auth signed payload token
        cfg.insecure_tls,
    ) catch |err| {
        logger.err("node-host: failed to init connection manager: {s}", .{@errorName(err)});
        return;
    };
    defer conn.deinit();

    const Ctx = struct {
        cfg: NodeHostConfig,
        node_ctx: *NodeContext,
        caps: []const []const u8,
        commands: []const []const u8,
    };
    var cb_ctx = Ctx{ .cfg = cfg, .node_ctx = &node_ctx, .caps = caps, .commands = commands };
    conn.user_ctx = @ptrCast(&cb_ctx);

    conn.onConfigureClient = struct {
        fn cb(cm: *SingleThreadConnectionManager, client: *websocket_client.WebSocketClient) void {
            const ctx: *Ctx = @ptrCast(@alignCast(cm.user_ctx.?));

            client.setConnectProfile(.{
                .role = "node",
                .scopes = &.{},
                .client_id = "node-host",
                .client_mode = "node",
                .display_name = ctx.cfg.display_name orelse "ZiggyStarClaw Android",
            });
            client.setConnectNodeMetadata(.{ .caps = ctx.caps, .commands = ctx.commands });
            client.setDeviceIdentityPath(ctx.cfg.device_identity_path);
            client.setConnectAuthToken(cm.connect_auth_token);
            client.setDeviceAuthToken(cm.device_auth_token);
            client.connect_host_override = ctx.cfg.connect_host_override;

            // Keep the receive loop responsive for shutdown/reconnect.
            client.setReadTimeout(250);
        }
    }.cb;

    conn.onConnected = struct {
        fn cb(cm: *SingleThreadConnectionManager) void {
            const ctx: *Ctx = @ptrCast(@alignCast(cm.user_ctx.?));
            ctx.node_ctx.state = .connecting;
            logger.info("node-host: connected", .{});
        }
    }.cb;

    conn.onDisconnected = struct {
        fn cb(cm: *SingleThreadConnectionManager) void {
            const ctx: *Ctx = @ptrCast(@alignCast(cm.user_ctx.?));
            ctx.node_ctx.state = .disconnected;
            logger.warn("node-host: disconnected", .{});
        }
    }.cb;

    var ws_mutex: std.Thread.Mutex = .{};
    conn.ws_mutex = &ws_mutex;

    var reporter = HealthReporter.init(allocator, &node_ctx, &conn.ws_client);
    reporter.interval_ms = cfg.heartbeat_interval_ms;
    reporter.setMutex(&ws_mutex);
    reporter.start() catch |err| {
        logger.warn("node-host: failed to start health reporter: {s}", .{@errorName(err)});
    };
    defer reporter.stop();

    while (!self.stop_flag.load(.monotonic)) {
        conn.step();

        if (!conn.is_connected) {
            node_platform.sleepMs(100);
            continue;
        }

        ws_mutex.lock();
        const payload = conn.ws_client.receive() catch |err| {
            ws_mutex.unlock();
            logger.err("node-host: receive failed: {s}", .{@errorName(err)});
            conn.disconnect();
            continue;
        };
        ws_mutex.unlock();

        if (payload) |text| {
            defer allocator.free(text);
            handleNodeMessage(allocator, &conn.ws_client, &ws_mutex, &node_ctx, &router, text) catch |err| {
                logger.err("node-host: message handling failed: {s}", .{@errorName(err)});
            };
            continue;
        }

        node_platform.sleepMs(50);
    }

    // Best-effort disconnect on shutdown.
    ws_mutex.lock();
    conn.ws_client.disconnect();
    ws_mutex.unlock();
}

fn handleNodeMessage(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ws_mutex: *std.Thread.Mutex,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    text: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();

    const value = parsed.value;
    if (value != .object) return;

    const msg_type = value.object.get("type") orelse return;
    if (msg_type != .string) return;

    const frame_type = msg_type.string;

    if (std.mem.eql(u8, frame_type, "hello-ok")) {
        node_ctx.state = .idle;
        logger.info("node-host: hello-ok (registered)", .{});
        return;
    }

    if (std.mem.eql(u8, frame_type, "event")) {
        const event = value.object.get("event") orelse return;
        if (event != .string) return;
        if (std.mem.eql(u8, event.string, "node.invoke.request")) {
            try handleNodeInvokeRequestEvent(allocator, ws_client, ws_mutex, node_ctx, router, value);
        }
        return;
    }

    if (std.mem.eql(u8, frame_type, "res")) {
        const ok = value.object.get("ok") orelse return;
        if (ok != .bool or !ok.bool) return;
        if (value.object.get("payload")) |payload| {
            if (payload == .object) {
                if (payload.object.get("type")) |payload_type| {
                    if (payload_type == .string and std.mem.eql(u8, payload_type.string, "hello-ok")) {
                        node_ctx.state = .idle;
                        logger.info("node-host: registered (res hello-ok)", .{});
                    }
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, frame_type, "req")) {
        // Legacy node.invoke request form.
        const method = value.object.get("method") orelse return;
        if (method != .string) return;
        if (std.mem.eql(u8, method.string, "node.invoke")) {
            try handleNodeInvokeLegacy(allocator, ws_client, ws_mutex, node_ctx, router, value);
        }
    }
}

fn handleNodeInvokeLegacy(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ws_mutex: *std.Thread.Mutex,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    request: std.json.Value,
) !void {
    const request_id = request.object.get("id") orelse return;
    if (request_id != .string) return;
    const params = request.object.get("params") orelse return;
    if (params != .object) return;

    const command = params.object.get("command") orelse return;
    if (command != .string) return;

    const command_params = params.object.get("params") orelse std.json.Value{ .object = std.json.ObjectMap.init(allocator) };

    logger.info("node-host: node.invoke (legacy): {s}", .{command.string});

    node_ctx.state = .executing;
    defer node_ctx.state = .idle;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const result = router.route(aa, node_ctx, command.string, command_params) catch |err| {
        logger.err("node-host: command failed: {s}", .{@errorName(err)});
        const resp = try buildErrorResponse(allocator, request_id.string, err);
        defer allocator.free(resp.payload);
        try sendLocked(ws_client, ws_mutex, resp.payload);
        return;
    };

    const resp = try buildSuccessResponse(allocator, request_id.string, result);
    defer {
        allocator.free(resp.payload);
        allocator.free(resp.id);
    }
    try sendLocked(ws_client, ws_mutex, resp.payload);
}

fn handleNodeInvokeRequestEvent(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ws_mutex: *std.Thread.Mutex,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    frame: std.json.Value,
) !void {
    const payload = frame.object.get("payload") orelse return;
    if (payload != .object) return;

    const invoke_id = payload.object.get("id") orelse return;
    if (invoke_id != .string) return;

    const node_id = payload.object.get("nodeId") orelse return;
    if (node_id != .string) return;

    const command = payload.object.get("command") orelse return;
    if (command != .string) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var command_params: std.json.Value = std.json.Value{ .object = std.json.ObjectMap.init(aa) };
    var parsed_params: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_params) |*p| p.deinit();
    if (payload.object.get("paramsJSON")) |params_json| {
        if (params_json == .string and params_json.string.len > 0) {
            parsed_params = try std.json.parseFromSlice(std.json.Value, aa, params_json.string, .{});
            command_params = parsed_params.?.value;
        }
    }

    logger.info("node-host: node.invoke.request: {s}", .{command.string});

    node_ctx.state = .executing;
    defer node_ctx.state = .idle;

    const result = router.route(aa, node_ctx, command.string, command_params) catch |err| {
        logger.err("node-host: command failed: {s}", .{@errorName(err)});
        try sendNodeInvokeResultError(allocator, ws_client, ws_mutex, invoke_id.string, node_id.string, err);
        return;
    };

    try sendNodeInvokeResultOk(allocator, ws_client, ws_mutex, invoke_id.string, node_id.string, result);
}

fn sendNodeInvokeResultOk(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ws_mutex: *std.Thread.Mutex,
    invoke_id: []const u8,
    node_id: []const u8,
    payload: std.json.Value,
) !void {
    const frame = .{
        .type = "req",
        .id = invoke_id,
        .method = "node.invoke.result",
        .params = .{
            .id = invoke_id,
            .nodeId = node_id,
            .ok = true,
            .payload = payload,
        },
    };
    const json = try messages.serializeMessage(allocator, frame);
    defer allocator.free(json);
    try sendLocked(ws_client, ws_mutex, json);
}

fn sendNodeInvokeResultError(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ws_mutex: *std.Thread.Mutex,
    invoke_id: []const u8,
    node_id: []const u8,
    err: anyerror,
) !void {
    const code = switch (err) {
        error.CommandNotSupported => "COMMAND_NOT_SUPPORTED",
        error.NotAllowed => "NOT_ALLOWED",
        error.InvalidParams => "INVALID_PARAMS",
        error.Timeout => "TIMEOUT",
        error.BackgroundNotAvailable => "NODE_BACKGROUND_UNAVAILABLE",
        error.PermissionRequired => "PERMISSION_REQUIRED",
        else => "EXECUTION_FAILED",
    };

    const message = switch (err) {
        error.CommandNotSupported => "Command not supported by this node",
        error.NotAllowed => "Command not in allowlist",
        error.InvalidParams => "Invalid parameters",
        error.Timeout => "Command execution timed out",
        error.BackgroundNotAvailable => "Command requires foreground",
        error.PermissionRequired => "Required permission not granted",
        else => "Command execution failed",
    };

    const frame = .{
        .type = "req",
        .id = invoke_id,
        .method = "node.invoke.result",
        .params = .{
            .id = invoke_id,
            .nodeId = node_id,
            .ok = false,
            .@"error" = .{ .code = code, .message = message },
        },
    };
    const json = try messages.serializeMessage(allocator, frame);
    defer allocator.free(json);
    try sendLocked(ws_client, ws_mutex, json);
}

fn sendLocked(
    ws_client: *websocket_client.WebSocketClient,
    ws_mutex: *std.Thread.Mutex,
    payload: []const u8,
) !void {
    ws_mutex.lock();
    defer ws_mutex.unlock();
    try ws_client.send(payload);
}

fn buildSuccessResponse(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    payload: std.json.Value,
) !struct { id: []u8, payload: []u8 } {
    const response = .{
        .type = "res",
        .id = request_id,
        .ok = true,
        .payload = payload,
    };

    const json = try messages.serializeMessage(allocator, response);
    const id = try allocator.dupe(u8, request_id);

    return .{ .id = id, .payload = json };
}

fn buildErrorResponse(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    err: anyerror,
) !struct { payload: []u8 } {
    const code = switch (err) {
        error.CommandNotSupported => "NODE_COMMAND_NOT_SUPPORTED",
        error.NotAllowed => "SYSTEM_RUN_DENIED",
        error.InvalidParams => "INVALID_PARAMS",
        error.Timeout => "TIMEOUT",
        error.BackgroundNotAvailable => "NODE_BACKGROUND_UNAVAILABLE",
        error.PermissionRequired => "PERMISSION_REQUIRED",
        else => "EXECUTION_FAILED",
    };

    const message = switch (err) {
        error.CommandNotSupported => "Command not supported by this node",
        error.NotAllowed => "Command not in allowlist",
        error.InvalidParams => "Invalid parameters",
        error.Timeout => "Command execution timed out",
        error.BackgroundNotAvailable => "Command requires foreground",
        error.PermissionRequired => "Required permission not granted",
        else => "Command execution failed",
    };

    var response_obj = std.json.ObjectMap.init(allocator);
    try response_obj.put("type", std.json.Value{ .string = "res" });
    try response_obj.put("id", std.json.Value{ .string = try allocator.dupe(u8, request_id) });
    try response_obj.put("ok", std.json.Value{ .bool = false });

    var error_obj = std.json.ObjectMap.init(allocator);
    try error_obj.put("code", std.json.Value{ .string = try allocator.dupe(u8, code) });
    try error_obj.put("message", std.json.Value{ .string = try allocator.dupe(u8, message) });
    try response_obj.put("error", std.json.Value{ .object = error_obj });

    const response = std.json.Value{ .object = response_obj };
    const json = try messages.serializeMessage(allocator, response);
    return .{ .payload = json };
}
