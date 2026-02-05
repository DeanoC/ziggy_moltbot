const std = @import("std");
const node_context = @import("node/node_context.zig");
const NodeContext = node_context.NodeContext;
const unified_config = @import("unified_config.zig");
const UnifiedConfig = unified_config.UnifiedConfig;
const command_router = @import("node/command_router.zig");
const CommandRouter = command_router.CommandRouter;
const canvas = @import("node/canvas.zig");
const websocket_client = @import("client/websocket_client.zig");
const node_platform = @import("node/node_platform.zig");
const SingleThreadConnectionManager = @import("node/connection_manager_singlethread.zig").SingleThreadConnectionManager;
const event_handler = @import("client/event_handler.zig");
const requests = @import("protocol/requests.zig");
const messages = @import("protocol/messages.zig");
const gateway = @import("protocol/gateway.zig");
const health_reporter = @import("node/health_reporter.zig");
const HealthReporter = health_reporter.HealthReporter;
const logger = @import("utils/logger.zig");

fn expandUserPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len >= 2 and path[0] == '~' and (path[1] == '/' or path[1] == '\\')) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (home) |value| {
            defer allocator.free(value);
            return std.fs.path.join(allocator, &.{ value, path[2..] });
        }
        const userprofile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (userprofile) |value| {
            defer allocator.free(value);
            return std.fs.path.join(allocator, &.{ value, path[2..] });
        }
    }
    return allocator.dupe(u8, path);
}

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
    \\Config:
    \\  Uses a single config file (no legacy fallbacks):
    \\    %APPDATA%\\ZiggyStarClaw\\config.json
    \\
    \\Options:
    \\  --config <path>            Path to config.json (default: %APPDATA%\\ZiggyStarClaw\\config.json)
    \\  --url <url>                Override gateway URL (ws/wss/http/https; with or without /ws)
    \\  --gateway-token <token>    Override gateway auth token (handshake + connect auth)
    \\  --node-token <token>       Override node device token (role=node)
    \\  --display-name <name>      Override node display name shown in gateway UI
    \\  --as-node / --no-node      Enable/disable node connection (default: from config)
    \\  --as-operator / --no-operator  Enable/disable operator connection (default: from config)
    \\  --auto-approve-pairing    Auto-approve pairing requests (node-mode only)
    \\  --pairing-timeout <sec>   Pairing approval timeout in seconds (default: 120)
    \\  --insecure-tls             Disable TLS verification
    \\  --log-level <level>        Log level (debug|info|warn|error)
    \\  -h, --help                 Show help
    \\
;

pub const NodeCliOptions = struct {
    gateway_url: ?[]const u8 = null,
    // Token for the initial websocket handshake (gateway auth).
    gateway_token: ?[]const u8 = null,
    // Token for the node connect auth (role=node). Required when the gateway enforces node auth.
    node_token: ?[]const u8 = null,
    // Token for the operator connect auth (role=operator) when --as-operator is enabled.
    operator_token: ?[]const u8 = null,

    // IMPORTANT: these are optional so we can distinguish "flag not provided" from
    // "use defaults". Otherwise we clobber values loaded from node.json.
    gateway_host: ?[]const u8 = null,
    gateway_port: ?u16 = null,
    tls: ?bool = null,

    display_name: ?[]const u8 = null,
    node_id: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    save_config: bool = false,

    // Connect role toggles (checkboxes)
    as_node: ?bool = null,
    as_operator: ?bool = null,

    auto_approve_pairing: bool = false,
    pairing_timeout_seconds: u32 = 120,

    insecure_tls: bool = false,
    log_level: logger.Level = .info,
};

pub fn parseNodeOptions(allocator: std.mem.Allocator, args: []const []const u8) !NodeCliOptions {
    var opts = NodeCliOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.gateway_url = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--gateway-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.gateway_token = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--node-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.node_token = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--operator-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.operator_token = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--display-name")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.display_name = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "--tls") or std.mem.eql(u8, arg, "--token") or std.mem.eql(u8, arg, "--auth-token") or std.mem.eql(u8, arg, "--auth_token") or std.mem.eql(u8, arg, "--save-config") or std.mem.eql(u8, arg, "--node-id")) {
            // Clean break: legacy flags removed.
            logger.err("Unsupported legacy flag in node-mode: {s}", .{arg});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.config_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--as-node")) {
            opts.as_node = true;
        } else if (std.mem.eql(u8, arg, "--no-node")) {
            opts.as_node = false;
        } else if (std.mem.eql(u8, arg, "--as-operator")) {
            opts.as_operator = true;
        } else if (std.mem.eql(u8, arg, "--no-operator")) {
            opts.as_operator = false;
        } else if (std.mem.eql(u8, arg, "--auto-approve-pairing")) {
            opts.auto_approve_pairing = true;
        } else if (std.mem.eql(u8, arg, "--pairing-timeout")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.pairing_timeout_seconds = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArguments;
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

// (Legacy NodeConfig helpers removed; node-mode uses unified_config.json only.)

const PairingDecision = enum { approved, rejected };

const PairingPrompt = struct {
    mutex: std.Thread.Mutex = .{},
    awaiting_input: bool = false,
    decision: ?bool = null,

    fn begin(self: *PairingPrompt) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.decision = null;
        self.awaiting_input = true;
    }

    fn clear(self: *PairingPrompt) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.decision = null;
        self.awaiting_input = false;
    }

    fn popDecision(self: *PairingPrompt) ?bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.decision) |decision| {
            self.decision = null;
            return decision;
        }
        return null;
    }
};

const PairingState = struct {
    auto_approve: bool,
    timeout_ms: i64,
    interactive: bool,

    request_id: ?[]const u8 = null,
    requested_at_ms: i64 = 0,
    last_decision: ?PairingDecision = null,
    approve_method: []const u8 = "",
    reject_method: []const u8 = "",
    prompt: PairingPrompt = .{},

    fn deinit(self: *PairingState, allocator: std.mem.Allocator) void {
        if (self.request_id) |rid| {
            allocator.free(rid);
        }
    }

    fn setPending(
        self: *PairingState,
        allocator: std.mem.Allocator,
        request_id: []const u8,
        approve_method: []const u8,
        reject_method: []const u8,
    ) !void {
        if (self.request_id) |rid| {
            allocator.free(rid);
        }
        self.request_id = try allocator.dupe(u8, request_id);
        self.requested_at_ms = node_platform.nowMs();
        self.last_decision = null;
        self.approve_method = approve_method;
        self.reject_method = reject_method;
    }

    fn clear(self: *PairingState, allocator: std.mem.Allocator) void {
        if (self.request_id) |rid| {
            allocator.free(rid);
        }
        self.request_id = null;
        self.requested_at_ms = 0;
        self.approve_method = "";
        self.reject_method = "";
        self.prompt.clear();
    }

    fn isPending(self: *const PairingState) bool {
        return self.request_id != null;
    }

    fn deadlineMs(self: *const PairingState) i64 {
        return self.requested_at_ms + self.timeout_ms;
    }
};

fn isInteractive() bool {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    return stdin.isTty() and stdout.isTty();
}

fn pairingPromptThread(prompt: *PairingPrompt) void {
    var in = std.fs.File.stdin().deprecatedReader();
    var buf: [64]u8 = undefined;
    while (true) {
        const line_opt = in.readUntilDelimiterOrEof(&buf, '\n') catch return;
        const line = line_opt orelse return;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const approve = trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');

        prompt.mutex.lock();
        if (prompt.awaiting_input) {
            prompt.decision = approve;
            prompt.awaiting_input = false;
        }
        prompt.mutex.unlock();
    }
}

pub fn runNodeMode(allocator: std.mem.Allocator, opts: NodeCliOptions) !void {
    logger.setLevel(opts.log_level);

    // Determine config path (single unified config)
    const config_path = opts.config_path orelse try unified_config.defaultConfigPath(allocator);
    defer if (opts.config_path == null) allocator.free(config_path);

    logger.info("Using config path: {s}", .{config_path});

    var cfg = unified_config.load(allocator, config_path) catch |err| {
        logger.err("Failed to load config {s}: {s}", .{ config_path, @errorName(err) });
        return err;
    };
    defer cfg.deinit(allocator);

    // Apply explicit overrides
    if (opts.gateway_url) |u| {
        allocator.free(cfg.gateway.wsUrl);
        cfg.gateway.wsUrl = try allocator.dupe(u8, u);
    }
    if (opts.gateway_token) |t| {
        allocator.free(cfg.gateway.authToken);
        cfg.gateway.authToken = try allocator.dupe(u8, t);
    }
    if (opts.node_token) |t| {
        allocator.free(cfg.node.nodeToken);
        cfg.node.nodeToken = try allocator.dupe(u8, t);
    }
    if (opts.display_name) |n| {
        if (cfg.node.displayName) |old| allocator.free(old);
        cfg.node.displayName = try allocator.dupe(u8, n);
    }
    if (opts.as_node) |v| cfg.node.enabled = v;
    if (opts.as_operator) |v| cfg.operator.enabled = v;

    if (!cfg.node.enabled and !cfg.operator.enabled) {
        logger.err("No connections enabled (--no-node and --no-operator).", .{});
        return error.InvalidArguments;
    }

    if (cfg.gateway.wsUrl.len == 0) {
        logger.err("Config missing gateway.wsUrl", .{});
        return error.InvalidArguments;
    }

    // Token selection for node-mode:
    // - Prefer node.nodeToken (role=node) when present.
    // - Fall back to gateway.authToken for legacy configs.
    if (cfg.gateway.authToken.len == 0 and cfg.node.nodeToken.len == 0) {
        logger.err("Config missing auth token(s): need gateway.authToken and/or node.nodeToken", .{});
        return error.InvalidArguments;
    }

    const ws_url = try unified_config.normalizeGatewayWsUrl(allocator, cfg.gateway.wsUrl);
    defer allocator.free(ws_url);

    const node_id = cfg.node.nodeId;
    if (cfg.node.enabled and node_id.len == 0) {
        logger.err("Config missing node.nodeId (required for node-mode)", .{});
        return error.InvalidArguments;
    }

    const display_name = if (cfg.node.displayName) |n| n else "ZiggyStarClaw Node";

    var pairing = PairingState{
        .auto_approve = opts.auto_approve_pairing,
        .timeout_ms = @as(i64, @intCast(opts.pairing_timeout_seconds)) * std.time.ms_per_s,
        .interactive = isInteractive(),
    };
    defer pairing.deinit(allocator);

    if (pairing.interactive and !pairing.auto_approve) {
        _ = std.Thread.spawn(.{}, pairingPromptThread, .{&pairing.prompt}) catch |err| {
            logger.warn("Failed to start pairing prompt thread: {s}", .{@errorName(err)});
            pairing.interactive = false;
        };
    }

    // Initialize node context
    var node_ctx = try NodeContext.init(allocator, node_id, display_name);
    defer node_ctx.deinit();

    const approvals_path = expandUserPath(allocator, cfg.node.execApprovalsPath) catch |err| blk: {
        logger.warn("Failed to expand exec approvals path: {s}", .{@errorName(err)});
        break :blk allocator.dupe(u8, cfg.node.execApprovalsPath) catch return err;
    };
    allocator.free(node_ctx.exec_approvals_path);
    node_ctx.exec_approvals_path = approvals_path;

    // Register capabilities (currently always-on for node-mode)
    try node_ctx.registerSystemCapabilities();
    try node_ctx.registerProcessCapabilities();
    try node_ctx.registerCanvasCapabilities();

    // Initialize command router
    var router = try command_router.initStandardRouter(allocator);
    defer router.deinit();

    if (cfg.operator.enabled) {
        logger.err("operator.enabled=true is not supported in node-mode yet (clean-break config refactor in progress).", .{});
        return error.NotImplemented;
    }

    if (!cfg.node.enabled) {
        logger.err("Node connection is disabled.", .{});
        return error.InvalidArguments;
    }

    // Precompute advertised caps/commands once.
    const caps = try node_ctx.getCapabilitiesArray();
    defer node_context.freeStringArray(allocator, caps);
    const commands = try node_ctx.getCommandsArray();
    defer node_context.freeStringArray(allocator, commands);

    const handshake_token = cfg.gateway.authToken;
    // Invariant: connect.auth.token must match the WebSocket Authorization token.
    // Node-mode uses the gateway auth token for both.
    const connect_auth_token = cfg.gateway.authToken;
    // Device-auth signed payload should use the paired node token when available.
    const device_auth_token = if (cfg.node.nodeToken.len > 0) cfg.node.nodeToken else cfg.gateway.authToken;
    if (cfg.node.nodeToken.len == 0) {
        logger.warn("node.nodeToken is empty; device-auth will fall back to gateway.authToken", .{});
    }

    // Single-thread connection manager (no background threads).
    // Token design:
    // - WS Authorization + connect.auth.token use the gateway auth token (must match).
    // - device-auth payload token uses the paired node token when available.
    var conn = try SingleThreadConnectionManager.init(
        allocator,
        ws_url,
        handshake_token,
        connect_auth_token,
        device_auth_token,
        false,
    );
    defer conn.deinit();

    const Ctx = struct {
        cfg: *UnifiedConfig,
        node_ctx: *NodeContext,
        caps: []const []const u8,
        commands: []const []const u8,
    };
    var cb_ctx = Ctx{ .cfg = &cfg, .node_ctx = &node_ctx, .caps = caps, .commands = commands };
    conn.user_ctx = @ptrCast(&cb_ctx);

    conn.onConfigureClient = struct {
        fn cb(cm: *SingleThreadConnectionManager, client: *websocket_client.WebSocketClient) void {
            const ctx: *Ctx = @ptrCast(@alignCast(cm.user_ctx.?));
            client.setConnectProfile(.{
                .role = "node",
                .scopes = &.{},
                .client_id = "node-host",
                .client_mode = "node",
                .display_name = ctx.cfg.node.displayName orelse "ZiggyStarClaw",
            });
            client.setConnectNodeMetadata(.{ .caps = ctx.caps, .commands = ctx.commands });
            client.setDeviceIdentityPath(ctx.cfg.node.deviceIdentityPath);
            // Token design:
            // - WS handshake Authorization + connect.auth.token must match (gateway auth token).
            // - Device-auth signed payload should use the paired node token when available.
            client.setConnectAuthToken(cm.connect_auth_token);
            client.setDeviceAuthToken(cm.device_auth_token);
        }
    }.cb;

    conn.onConnected = struct {
        fn cb(cm: *SingleThreadConnectionManager) void {
            const ctx: *Ctx = @ptrCast(@alignCast(cm.user_ctx.?));
            ctx.node_ctx.state = .connecting;
            logger.info("Connected.", .{});
        }
    }.cb;

    conn.onDisconnected = struct {
        fn cb(cm: *SingleThreadConnectionManager) void {
            const ctx: *Ctx = @ptrCast(@alignCast(cm.user_ctx.?));
            ctx.node_ctx.state = .disconnected;
            logger.err("Disconnected from gateway.", .{});
        }
    }.cb;

    // Start health reporter (threaded, but uses per-heartbeat arena + page allocator).
    // Guard ws_client access with a mutex: reporter thread may send while we reconnect.
    var ws_mutex: std.Thread.Mutex = .{};
    conn.ws_mutex = &ws_mutex;

    var reporter = HealthReporter.init(allocator, &node_ctx, &conn.ws_client);
    reporter.interval_ms = cfg.node.healthReporterIntervalMs;
    reporter.setMutex(&ws_mutex);
    reporter.start() catch |err| {
        logger.warn("Failed to start health reporter: {s}", .{@errorName(err)});
    };
    defer reporter.stop();

    // Main event loop
    while (true) {
        conn.step();

        if (!conn.is_connected) {
            node_platform.sleepMs(100);
            continue;
        }

        ws_mutex.lock();
        const payload = conn.ws_client.receive() catch |err| {
            ws_mutex.unlock();
            logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
            conn.disconnect();
            continue;
        };
        ws_mutex.unlock();

        var got_payload = false;
        if (payload) |text| {
            got_payload = true;
            defer allocator.free(text);
            handleNodeMessage(allocator, &conn.ws_client, &conn, &pairing, &node_ctx, &router, config_path, &cfg, text) catch |err| {
                logger.err("Node message handling failed: {s}", .{@errorName(err)});
            };
        }

        if (pairing.isPending() and node_platform.nowMs() > pairing.deadlineMs()) {
            logger.err(
                "Pairing request {s} timed out after {d}s.",
                .{ pairing.request_id.?, opts.pairing_timeout_seconds },
            );
            pairing.clear(allocator);
        }

        if (pairing.isPending() and pairing.interactive) {
            if (pairing.prompt.popDecision()) |approve| {
                const request_id = pairing.request_id.?;
                if (approve) {
                    sendPairingDecision(allocator, &conn.ws_client, pairing.approve_method, request_id) catch |err| {
                        logger.err("Failed to send pairing approval: {s}", .{@errorName(err)});
                    };
                    pairing.last_decision = .approved;
                    logger.info("Approved pairing request {s}.", .{request_id});
                } else {
                    sendPairingDecision(allocator, &conn.ws_client, pairing.reject_method, request_id) catch |err| {
                        logger.err("Failed to send pairing rejection: {s}", .{@errorName(err)});
                    };
                    pairing.last_decision = .rejected;
                    logger.err("Rejected pairing request {s}.", .{request_id});
                }
            }
        } else if (!pairing.isPending()) {
            if (pairing.prompt.popDecision() != null) {
                logger.warn("Pairing input ignored (no pending request).", .{});
            }
        }

        if (!got_payload) {
            node_platform.sleepMs(50);
        }
    }
}

fn sendNodeConnectRequest(
    allocator: std.mem.Allocator,
    ws_client: anytype,
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
            // Must match gateway allowlist (see GATEWAY_CLIENT_IDS)
            .id = "node-host",
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
        // For token-auth gateways, this allows the node to connect without device identity.
        .auth = .{ .token = if (ws_client.token.len > 0) ws_client.token else null },
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
    ws_client: anytype,
    conn: ?*SingleThreadConnectionManager,
    pairing: *PairingState,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    cfg_path: []const u8,
    cfg: *UnifiedConfig,
    text: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();

    const value = parsed.value;
    const msg_type = value.object.get("type") orelse return;

    if (msg_type != .string) return;

    const frame_type = msg_type.string;

    // Node bridge may send direct hello-ok.
    if (std.mem.eql(u8, frame_type, "hello-ok")) {
        node_ctx.state = .idle;
        logger.info("Node registered successfully!", .{});
        return;
    }

    if (std.mem.eql(u8, frame_type, "event")) {
        const event = value.object.get("event") orelse return;
        if (event != .string) return;

        if (std.mem.eql(u8, event.string, "connect.challenge")) {
            logger.info("Received connect challenge", .{});
            // Handled by WebSocketClient
        } else if (std.mem.eql(u8, event.string, "device.pair.requested") or
            std.mem.eql(u8, event.string, "node.pair.requested"))
        {
            try handlePairingRequested(allocator, ws_client, pairing, value);
        } else if (std.mem.eql(u8, event.string, "device.pair.resolved") or
            std.mem.eql(u8, event.string, "node.pair.resolved"))
        {
            try handlePairingResolved(allocator, conn, pairing, value);
        } else if (std.mem.eql(u8, event.string, "node.invoke.request")) {
            try handleNodeInvokeRequestEvent(allocator, ws_client, node_ctx, router, value);
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

                                        // Persist device token to config.json (single source of truth).
                                        // Also refresh the connection manager token so reconnects use the updated value.
                                        if (pairing.isPending()) {
                                            logger.info("Pairing completed; clearing pending request before persisting token.", .{});
                                            pairing.clear(allocator);
                                        }

                                        if (!std.mem.eql(u8, cfg.node.nodeToken, token.string)) {
                                            allocator.free(cfg.node.nodeToken);
                                            cfg.node.nodeToken = try allocator.dupe(u8, token.string);

                                            if (conn) |cm| {
                                                cm.setDeviceAuthToken(cfg.node.nodeToken) catch |err| {
                                                    logger.warn("Failed to update device auth token: {s}", .{@errorName(err)});
                                                };
                                            }

                                            saveUpdatedNodeToken(allocator, cfg_path, token.string) catch |err| {
                                                logger.warn("Failed to persist node token to config: {s}", .{@errorName(err)});
                                            };
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            var handled_pairing = false;
            if (value.object.get("error")) |err| {
                if (err == .object) {
                    if (err.object.get("message")) |msg| {
                        if (msg == .string) {
                            if (std.mem.indexOf(u8, msg.string, "pairing required") != null or
                                std.mem.indexOf(u8, msg.string, "pairing pending") != null)
                            {
                                logger.warn(
                                    "Pairing required. Await approval or run with --auto-approve-pairing.",
                                    .{},
                                );
                                handled_pairing = true;
                            } else if (std.mem.indexOf(u8, msg.string, "pairing rejected") != null or
                                std.mem.indexOf(u8, msg.string, "pairing denied") != null)
                            {
                                logger.err("Pairing rejected by gateway.", .{});
                                pairing.last_decision = .rejected;
                                handled_pairing = true;
                            }
                            if (!handled_pairing) {
                                logger.err("Error: {s}", .{msg.string});
                            }
                        }
                    }
                }
            }
            if (!handled_pairing) {
                logger.err("Connect request failed", .{});
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

fn handlePairingRequested(
    allocator: std.mem.Allocator,
    ws_client: anytype,
    pairing: *PairingState,
    frame: std.json.Value,
) !void {
    const ev_val = frame.object.get("event") orelse return;
    if (ev_val != .string) return;
    const approve_method = if (std.mem.eql(u8, ev_val.string, "node.pair.requested"))
        "node.pair.approve"
    else
        "device.pair.approve";
    const reject_method = if (std.mem.eql(u8, ev_val.string, "node.pair.requested"))
        "node.pair.reject"
    else
        "device.pair.reject";

    const payload = frame.object.get("payload") orelse return;
    if (payload != .object) return;
    const rid_val = payload.object.get("requestId") orelse payload.object.get("id") orelse {
        logger.warn("Pairing requested but no requestId provided.", .{});
        return;
    };
    if (rid_val != .string) return;

    try pairing.setPending(allocator, rid_val.string, approve_method, reject_method);
    logger.warn("Pairing request received (requestId={s}).", .{rid_val.string});

    if (pairing.auto_approve) {
        try sendPairingDecision(allocator, ws_client, approve_method, rid_val.string);
        logger.info("Auto-approved pairing request {s}.", .{rid_val.string});
        return;
    }

    if (!pairing.interactive) {
        logger.warn(
            "Pairing pending. Re-run with --auto-approve-pairing or approve via operator CLI.",
            .{},
        );
        return;
    }

    try startPairingPrompt(pairing, rid_val.string);
}

fn handlePairingResolved(
    allocator: std.mem.Allocator,
    conn: ?*SingleThreadConnectionManager,
    pairing: *PairingState,
    frame: std.json.Value,
) !void {
    const payload = frame.object.get("payload") orelse return;
    if (payload != .object) return;
    const rid_val = payload.object.get("requestId") orelse payload.object.get("id");
    const decision_val = payload.object.get("decision") orelse payload.object.get("status");

    var decision: ?PairingDecision = null;
    if (decision_val) |dv| {
        if (dv == .string) {
            if (std.mem.eql(u8, dv.string, "approved")) decision = .approved;
            if (std.mem.eql(u8, dv.string, "rejected")) decision = .rejected;
        }
    }

    if (decision == .approved) {
        pairing.last_decision = .approved;
        if (rid_val) |rv| {
            if (rv == .string) {
                logger.info("Pairing approved (requestId={s}).", .{rv.string});
            } else {
                logger.info("Pairing approved.", .{});
            }
        } else {
            logger.info("Pairing approved.", .{});
        }
        pairing.clear(allocator);
        if (conn) |cm| {
            logger.info("Reconnecting to finalize pairing.", .{});
            cm.disconnect();
        }
        return;
    }

    if (decision == .rejected) {
        pairing.last_decision = .rejected;
        if (rid_val) |rv| {
            if (rv == .string) {
                logger.err("Pairing rejected (requestId={s}).", .{rv.string});
            } else {
                logger.err("Pairing rejected.", .{});
            }
        } else {
            logger.err("Pairing rejected.", .{});
        }
        pairing.clear(allocator);
        return;
    }
}

fn sendPairingDecision(
    allocator: std.mem.Allocator,
    ws_client: anytype,
    method: []const u8,
    request_id: []const u8,
) !void {
    const req = try requests.buildRequestPayload(allocator, method, .{ .requestId = request_id });
    defer allocator.free(req.id);
    defer allocator.free(req.payload);
    try ws_client.send(req.payload);
}

fn startPairingPrompt(pairing: *PairingState, request_id: []const u8) !void {
    pairing.prompt.begin();
    var out = std.fs.File.stderr().deprecatedWriter();
    try out.print("Approve pairing request {s}? [y/N]: ", .{request_id});
}

fn saveUpdatedNodeToken(
    allocator: std.mem.Allocator,
    path: []const u8,
    token: []const u8,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidArguments;
    var root = parsed.value.object;
    const node_val = root.getPtr("node") orelse return error.InvalidArguments;
    if (node_val.* != .object) return error.InvalidArguments;

    try node_val.object.put("nodeToken", std.json.Value{ .string = token });

    const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(out);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const wf = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer wf.close();
    try wf.writeAll(out);
}

fn handleNodeInvoke(
    allocator: std.mem.Allocator,
    ws_client: anytype,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    request: std.json.Value,
) !void {
    // Legacy request form ("req" method="node.invoke"). Keep for compatibility.
    const request_id = request.object.get("id") orelse return;
    const params = request.object.get("params") orelse return;

    if (params != .object) return;

    const command = params.object.get("command") orelse return;
    if (command != .string) return;

    const command_params = params.object.get("params") orelse std.json.Value{ .object = std.json.ObjectMap.init(allocator) };

    logger.info("Received node.invoke: {s}", .{command.string});

    node_ctx.state = .executing;
    defer node_ctx.state = .idle;

    // Use a per-invocation arena for handler allocations (screenshots, stdout/stderr, etc.)
    // to avoid unbounded leaks.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const result = router.route(aa, node_ctx, command.string, command_params) catch |err| {
        logger.err("Command execution failed: {s}", .{@errorName(err)});
        const error_response = try buildErrorResponse(allocator, request_id.string, err);
        defer allocator.free(error_response.payload);
        try ws_client.send(error_response.payload);
        return;
    };

    const response = try buildSuccessResponse(allocator, request_id.string, result);
    defer {
        allocator.free(response.payload);
        allocator.free(response.id);
    }
    try ws_client.send(response.payload);
}

fn handleNodeInvokeRequestEvent(
    allocator: std.mem.Allocator,
    ws_client: anytype,
    node_ctx: *NodeContext,
    router: *CommandRouter,
    frame: std.json.Value,
) !void {
    // Gateway sends node.invoke.request as an event, expects node.invoke.result as a request.
    const payload = frame.object.get("payload") orelse return;
    if (payload != .object) return;

    const invoke_id = payload.object.get("id") orelse return;
    if (invoke_id != .string) return;

    const node_id = payload.object.get("nodeId") orelse return;
    if (node_id != .string) return;

    const command = payload.object.get("command") orelse return;
    if (command != .string) return;

    // Use a per-invocation arena for handler allocations (screenshots, stdout/stderr, etc.)
    // to avoid unbounded leaks.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var command_params: std.json.Value = std.json.Value{ .object = std.json.ObjectMap.init(aa) };
    var parsed_params: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_params) |*parsed| parsed.deinit();
    if (payload.object.get("paramsJSON")) |params_json| {
        if (params_json == .string and params_json.string.len > 0) {
            parsed_params = try std.json.parseFromSlice(std.json.Value, aa, params_json.string, .{});
            command_params = parsed_params.?.value;
        }
    }

    logger.info("Received node.invoke.request: {s}", .{command.string});

    node_ctx.state = .executing;
    defer node_ctx.state = .idle;

    const result = router.route(aa, node_ctx, command.string, command_params) catch |err| {
        logger.err("Command execution failed: {s}", .{@errorName(err)});
        try sendNodeInvokeResultError(allocator, ws_client, invoke_id.string, node_id.string, err);
        return;
    };

    try sendNodeInvokeResultOk(allocator, ws_client, invoke_id.string, node_id.string, result);
}

fn sendNodeInvokeResultOk(
    allocator: std.mem.Allocator,
    ws_client: anytype,
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
    try ws_client.send(json);
}

fn sendNodeInvokeResultError(
    allocator: std.mem.Allocator,
    ws_client: anytype,
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
    try ws_client.send(json);
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
    var buf: [64]u8 = undefined;
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
