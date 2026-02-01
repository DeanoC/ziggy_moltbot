const std = @import("std");
const node_context = @import("node/node_context.zig");
const NodeContext = node_context.NodeContext;
const node_config = @import("node/config.zig");
const NodeConfig = node_config.NodeConfig;
const command_router = @import("node/command_router.zig");
const CommandRouter = command_router.CommandRouter;
const health_reporter = @import("node/health_reporter.zig");
const HealthReporter = health_reporter.HealthReporter;
const canvas = @import("node/canvas.zig");
const websocket_client = @import("client/websocket_client.zig");
const event_handler = @import("client/event_handler.zig");
const requests = @import("protocol/requests.zig");
const messages = @import("protocol/messages.zig");
const gateway = @import("protocol/gateway.zig");
const logger = @import("utils/logger.zig");

fn parseCanvasBackend(str: []const u8) canvas.CanvasBackend {
    if (std.mem.eql(u8, str, "webkitgtk")) {
        return .webkitgtk;
    } else if (std.mem.eql(u8, str, "chrome")) {
        return .chrome;
    } else if (std.mem.eql(u8, str, "none")) {
        return .none;
    }
    return .chrome; // Default
}

pub const usage =
    \\ZiggyStarClaw Node Mode
    \\
    \\Usage:
    \\  ziggystarclaw-cli --node-mode [options]
    \\
    \\Options:
    \\  --host <host>            Gateway host (default: 127.0.0.1)
    \\  --port <port>            Gateway port (default: 18789)
    \\  --display-name <name>    Node display name
    \\  --node-id <id>           Override node ID
    \\  --config <path>          Node config path
    \\  --save-config            Save config after successful connection
    \\  --tls                    Use TLS for connection
    \\  --insecure-tls           Disable TLS verification
    \\  --log-level <level>      Log level (debug|info|warn|error)
    \\  -h, --help               Show help
    \\
;

pub const NodeCliOptions = struct {
    gateway_host: []const u8 = "127.0.0.1",
    gateway_port: u16 = 18789,
    display_name: ?[]const u8 = null,
    node_id: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    save_config: bool = false,
    tls: bool = false,
    insecure_tls: bool = false,
    log_level: logger.Level = .info,
};

pub fn parseNodeOptions(allocator: std.mem.Allocator, args: []const []const u8) !NodeCliOptions {
    var opts = NodeCliOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.gateway_host = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.gateway_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--display-name")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.display_name = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.node_id = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.config_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            opts.save_config = true;
        } else if (std.mem.eql(u8, arg, "--tls")) {
            opts.tls = true;
        } else if (std.mem.eql(u8, arg, "--insecure-tls")) {
            opts.insecure_tls = true;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            const level_str = args[i];
            if (std.mem.eql(u8, level_str, "debug")) {
                opts.log_level = .debug;
            } else if (std.mem.eql(u8, level_str, "info")) {
                opts.log_level = .info;
            } else if (std.mem.eql(u8, level_str, "warn")) {
                opts.log_level = .warn;
            } else if (std.mem.eql(u8, level_str, "error")) {
                opts.log_level = .err;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(usage);
            return error.HelpPrinted;
        }
    }

    return opts;
}

pub fn runNodeMode(allocator: std.mem.Allocator, opts: NodeCliOptions) !void {
    logger.setLevel(opts.log_level);

    // Determine config path
    const config_path = opts.config_path orelse try NodeConfig.defaultPath(allocator);
    defer if (opts.config_path == null) allocator.free(config_path);

    // Load or create config
    var config = blk: {
        if (try NodeConfig.load(allocator, config_path)) |loaded| {
            break :blk loaded;
        }
        logger.info("No existing node config, creating new one...", .{});
        const node_id = if (opts.node_id) |id|
            try allocator.dupe(u8, id)
        else
            try generateNodeIdAlloc(allocator);
        errdefer allocator.free(node_id);
        const display_name = if (opts.display_name) |name|
            try allocator.dupe(u8, name)
        else
            try allocator.dupe(u8, "ZiggyStarClaw Node");
        errdefer allocator.free(display_name);
        break :blk try NodeConfig.initDefault(allocator, node_id, display_name, opts.gateway_host);
    };

    // Override config with CLI options
    if (opts.node_id) |id| {
        allocator.free(config.node_id);
        config.node_id = try allocator.dupe(u8, id);
    }
    if (opts.display_name) |name| {
        allocator.free(config.display_name);
        config.display_name = try allocator.dupe(u8, name);
    }
    if (opts.tls) {
        config.tls = true;
    }
    config.gateway_port = opts.gateway_port;

    // Initialize node context
    var node_ctx = try NodeContext.init(allocator, config.node_id, config.display_name);
    defer node_ctx.deinit();

    // Register capabilities based on config
    if (config.system_enabled) {
        try node_ctx.registerSystemCapabilities();
        try node_ctx.registerProcessCapabilities();
    }
    if (config.canvas_enabled) {
        try node_ctx.registerCanvasCapabilities();
        
        // Initialize canvas with configured backend
        const canvas_config = canvas.CanvasConfig{
            .backend = parseCanvasBackend(config.canvas_backend),
            .width = config.canvas_width,
            .height = config.canvas_height,
            .headless = true,
            .chrome_path = config.chrome_path,
            .chrome_debug_port = config.chrome_debug_port,
        };
        
        node_ctx.canvas_manager.initialize(canvas_config) catch |err| {
            logger.warn("Failed to initialize canvas: {s}", .{@errorName(err)});
            logger.warn("Canvas commands will return errors", .{});
        };
    }

    // Initialize command router
    var router = try command_router.initStandardRouter(allocator);
    defer router.deinit();

    // Connection retry loop
    var reconnect_attempt: u32 = 0;
    const max_reconnect_attempts: u32 = 10;
    const base_delay_ms: u64 = 1000;

    while (reconnect_attempt < max_reconnect_attempts) {
        // Connect to gateway
        const ws_url = try config.getWebSocketUrl(allocator);
        defer allocator.free(ws_url);

        logger.info("Connecting to gateway at {s} (attempt {d}/{d})...", .{ ws_url, reconnect_attempt + 1, max_reconnect_attempts });

        var ws_client = websocket_client.WebSocketClient.init(
            allocator,
            ws_url,
            config.device_token orelse "",
            opts.insecure_tls,
            null,
        );
        ws_client.setReadTimeout(15000);

        ws_client.connect() catch |err| {
            logger.err("Connection failed: {s}", .{@errorName(err)});
            ws_client.deinit();
            reconnect_attempt += 1;
            if (reconnect_attempt >= max_reconnect_attempts) {
                logger.err("Max reconnection attempts reached", .{});
                return error.ConnectionFailed;
            }
            const delay_ms = base_delay_ms * std.math.pow(u64, 2, reconnect_attempt);
            logger.info("Retrying in {d}ms...", .{@min(delay_ms, 30000)});
            std.Thread.sleep(@as(u64, @min(delay_ms, 30000)) * std.time.ns_per_ms);
            continue;
        };

        node_ctx.state = .connecting;
        reconnect_attempt = 0; // Reset on successful connection

        logger.info("Connected, waiting for handshake...", .{});

        // Send connect request with node role
        try sendNodeConnectRequest(allocator, &ws_client, &node_ctx);

        // Initialize health reporter
        var health = HealthReporter.init(allocator, &node_ctx, &ws_client);
        health.start() catch |err| {
            logger.warn("Failed to start health reporter: {s}", .{@errorName(err)});
        };
        defer health.stop();

        // Main event loop
        const running = true;
        while (running) {
            if (!ws_client.is_connected) {
                logger.err("Disconnected from gateway.", .{});
                break;
            }

            const payload = ws_client.receive() catch |err| {
                logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
                break;
            };

            if (payload) |text| {
                defer allocator.free(text);
                try handleNodeMessage(allocator, &ws_client, &node_ctx, &router, text);
            } else {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }

        ws_client.deinit();

        // If we got here due to disconnect, retry
        if (reconnect_attempt < max_reconnect_attempts) {
            reconnect_attempt += 1;
            const delay_ms = base_delay_ms * std.math.pow(u64, 2, reconnect_attempt);
            logger.info("Reconnecting in {d}ms...", .{@min(delay_ms, 30000)});
            std.Thread.sleep(@as(u64, @min(delay_ms, 30000)) * std.time.ns_per_ms);
        }
    }

    // Save config if requested and we got a device token
    if (opts.save_config and node_ctx.device_token != null) {
        config.device_token = try allocator.dupe(u8, node_ctx.device_token.?);
        try config.save(allocator, config_path);
        logger.info("Config saved to {s}", .{config_path});
    }
}

fn sendNodeConnectRequest(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    node_ctx: *NodeContext,
) !void {
    const request_id = try requests.makeRequestId(allocator);
    defer allocator.free(request_id);

    // Build capabilities and commands arrays
    const caps = try node_ctx.getCapabilitiesArray();
    defer node_context.freeStringArray(allocator, caps);

    const commands = try node_ctx.getCommandsArray();
    defer node_context.freeStringArray(allocator, commands);

    // Build permissions object
    var permissions = std.json.ObjectMap.init(allocator);
    var perm_iter = node_ctx.permissions.iterator();
    while (perm_iter.next()) |entry| {
        try permissions.put(entry.key_ptr.*, std.json.Value{ .bool = entry.value_ptr.* });
    }

    // Create connect params
    const params = NodeConnectParams{
        .minProtocol = gateway.PROTOCOL_VERSION,
        .maxProtocol = gateway.PROTOCOL_VERSION,
        .client = .{
            .id = "ziggystarclaw-node",
            .displayName = node_ctx.display_name,
            .version = "0.2.0",
            .platform = @tagName(@import("builtin").target.os.tag),
            .mode = "node",
        },
        .role = "node",
        .scopes = &.{},
        .caps = caps,
        .commands = commands,
        .permissions = std.json.Value{ .object = permissions },
        .auth = .{ .token = "" }, // Will be populated from device identity
    };

    const frame = NodeConnectFrame{
        .id = request_id,
        .params = params,
    };

    const payload = try messages.serializeMessage(allocator, frame);
    defer allocator.free(payload);

    logger.info("Sending node connect request...", .{});
    try ws_client.send(payload);
}

fn handleNodeMessage(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    text: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();

    const value = parsed.value;
    const msg_type = value.object.get("type") orelse return;

    if (msg_type != .string) return;

    const frame_type = msg_type.string;

    if (std.mem.eql(u8, frame_type, "event")) {
        const event = value.object.get("event") orelse return;
        if (event != .string) return;

        if (std.mem.eql(u8, event.string, "connect.challenge")) {
            logger.info("Received connect challenge", .{});
            // Handle challenge response if needed
        } else if (std.mem.eql(u8, event.string, "device.pair.requested")) {
            logger.warn("Device pairing required. Approve via gateway UI or CLI.", .{});
        }
    } else if (std.mem.eql(u8, frame_type, "res")) {
        _ = value.object.get("id") orelse return;
        const ok = value.object.get("ok") orelse return;

        if (ok.bool) {
            if (value.object.get("payload")) |payload| {
                if (payload == .object) {
                    const payload_type = payload.object.get("type") orelse return;
                    if (payload_type == .string and std.mem.eql(u8, payload_type.string, "hello-ok")) {
                        node_ctx.state = .idle;
                        logger.info("Node registered successfully!", .{});

                        // Extract device token if present
                        if (payload.object.get("auth")) |auth| {
                            if (auth == .object) {
                                if (auth.object.get("deviceToken")) |token| {
                                    if (token == .string) {
                                        if (node_ctx.device_token) |old| {
                                            allocator.free(old);
                                        }
                                        node_ctx.device_token = try allocator.dupe(u8, token.string);
                                        logger.info("Device token received.", .{});
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            logger.err("Connect request failed", .{});
            if (value.object.get("error")) |err| {
                if (err == .object) {
                    if (err.object.get("message")) |msg| {
                        if (msg == .string) {
                            logger.err("Error: {s}", .{msg.string});
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, frame_type, "req")) {
        // This is a request to the node (node.invoke)
        const method = value.object.get("method") orelse return;
        if (method != .string) return;

        if (std.mem.eql(u8, method.string, "node.invoke")) {
            try handleNodeInvoke(allocator, ws_client, node_ctx, router, value);
        }
    }
}

fn handleNodeInvoke(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    request: std.json.Value,
) !void {
    const request_id = request.object.get("id") orelse return;
    const params = request.object.get("params") orelse return;

    if (params != .object) return;

    const command = params.object.get("command") orelse return;
    if (command != .string) return;

    const command_params = params.object.get("params") orelse std.json.Value{ .object = std.json.ObjectMap.init(allocator) };

    logger.info("Received node.invoke: {s}", .{command.string});

    node_ctx.state = .executing;
    defer node_ctx.state = .idle;

    // Execute command
    const result = router.route(node_ctx, command.string, command_params) catch |err| {
        logger.err("Command execution failed: {s}", .{@errorName(err)});

        // Send error response
        const error_response = try buildErrorResponse(allocator, request_id.string, err);
        defer allocator.free(error_response.payload);
        try ws_client.send(error_response.payload);
        return;
    };

    // Send success response
    const response = try buildSuccessResponse(allocator, request_id.string, result);
    defer {
        allocator.free(response.payload);
        allocator.free(response.id);
    }
    try ws_client.send(response.payload);
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

    // Build error response JSON manually to avoid keyword issues
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

fn generateNodeIdAlloc(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [32]u8 = undefined;
    const id = try node_context.generateNodeId(&buf);
    return try allocator.dupe(u8, id);
}

// Node-specific connect params
const NodeConnectParams = struct {
    minProtocol: u32,
    maxProtocol: u32,
    client: gateway.ConnectClient,
    role: []const u8,
    scopes: []const []const u8,
    caps: []const []const u8,
    commands: []const []const u8,
    permissions: std.json.Value,
    auth: gateway.ConnectAuth,
    locale: ?[]const u8 = null,
    userAgent: ?[]const u8 = null,
    device: ?gateway.DeviceAuth = null,
};

const NodeConnectFrame = struct {
    type: []const u8 = "req",
    id: []const u8,
    method: []const u8 = "connect",
    params: NodeConnectParams,
};

const ErrorResponse = struct {
    type: []const u8,
    id: []const u8,
    ok: bool,
    @"error": ErrorDetail,
};

const ErrorDetail = struct {
    code: []const u8,
    message: []const u8,
};
