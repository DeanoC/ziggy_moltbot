const std = @import("std");
const client_state = @import("client/state.zig");
const config = @import("client/config.zig");
const event_handler = @import("client/event_handler.zig");
const websocket_client = @import("openclaw_transport.zig").websocket;
const logger = @import("utils/logger.zig");
const chat = @import("protocol/chat.zig");
const requests = @import("protocol/requests.zig");
const messages = @import("protocol/messages.zig");

const usage =
    \\ZiggyStarClaw CLI (debug)
    \\
    \\Usage:
    \\  ziggystarclaw-cli [options]
    \\
    \\Options:
    \\  --url <ws/wss url>       Override server URL
    \\  --token <token>          Override auth token
    \\  --config <path>          Config file path (default: ziggystarclaw_config.json)
    \\  --insecure-tls           Disable TLS verification
    \\  --read-timeout-ms <ms>   Socket read timeout in milliseconds (default: 15000)
    \\  --send <message>         Send a chat message and exit
    \\  --session <key>          Target session for send (uses default if not set)
    \\  --list-sessions          List available sessions and exit
    \\  --use-session <key>      Set default session and exit
    \\  --save-config            Save --url, --token, --use-session to config file
    \\  -h, --help               Show help
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try initLogging(allocator);
    defer logger.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: []const u8 = "ziggystarclaw_config.json";
    var override_url: ?[]const u8 = null;
    var override_token: ?[]const u8 = null;
    var override_insecure: ?bool = null;
    var read_timeout_ms: u32 = 15_000;
    var send_message: ?[]const u8 = null;
    var session_key: ?[]const u8 = null;
    var list_sessions = false;
    var use_session: ?[]const u8 = null;
    var save_config = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            override_url = args[i];
        } else if (std.mem.eql(u8, arg, "--token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            override_token = args[i];
        } else if (std.mem.eql(u8, arg, "--insecure-tls") or std.mem.eql(u8, arg, "--insecure")) {
            override_insecure = true;
        } else if (std.mem.eql(u8, arg, "--read-timeout-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            read_timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--send")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            send_message = args[i];
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            session_key = args[i];
        } else if (std.mem.eql(u8, arg, "--list-sessions")) {
            list_sessions = true;
        } else if (std.mem.eql(u8, arg, "--use-session")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            use_session = args[i];
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            save_config = true;
        } else {
            logger.warn("Unknown argument: {s}", .{arg});
        }
    }

    var cfg = try config.loadOrDefault(allocator, config_path);
    defer cfg.deinit(allocator);

    if (override_url) |url| {
        allocator.free(cfg.server_url);
        cfg.server_url = try allocator.dupe(u8, url);
    } else {
        const env_url = std.process.getEnvVarOwned(allocator, "MOLT_URL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_url) |url| {
            allocator.free(cfg.server_url);
            cfg.server_url = url;
        }
    }
    if (override_token) |token| {
        allocator.free(cfg.token);
        cfg.token = try allocator.dupe(u8, token);
    } else {
        const env_token = std.process.getEnvVarOwned(allocator, "MOLT_TOKEN") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_token) |token| {
            allocator.free(cfg.token);
            cfg.token = token;
        }
    }
    if (override_insecure) |value| {
        cfg.insecure_tls = value;
    } else {
        const env_insecure = std.process.getEnvVarOwned(allocator, "MOLT_INSECURE_TLS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_insecure) |value| {
            defer allocator.free(value);
            cfg.insecure_tls = parseBool(value);
        }
    }
    if (use_session) |key| {
        if (cfg.default_session) |old| {
            allocator.free(old);
        }
        cfg.default_session = try allocator.dupe(u8, key);
    }

    const env_timeout = std.process.getEnvVarOwned(allocator, "MOLT_READ_TIMEOUT_MS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_timeout) |value| {
        defer allocator.free(value);
        read_timeout_ms = try std.fmt.parseInt(u32, value, 10);
    }

    if (cfg.server_url.len == 0) {
        logger.err("Server URL is empty. Use --url or set it in {s}.", .{config_path});
        return error.InvalidArguments;
    }

    // Handle --save-config without connecting
    if (save_config and !list_sessions and send_message == null) {
        try config.save(allocator, config_path, cfg);
        logger.info("Config saved to {s}", .{config_path});
        return;
    }

    var ws_client = websocket_client.WebSocketClient.init(
        allocator,
        cfg.server_url,
        cfg.token,
        cfg.insecure_tls,
        cfg.connect_host_override,
    );
    ws_client.setReadTimeout(read_timeout_ms);
    defer ws_client.deinit();

    try ws_client.connect();
    logger.info("CLI connected. Server: {s} (read timeout {}ms)", .{ cfg.server_url, read_timeout_ms });

    var ctx = try client_state.ClientContext.init(allocator);
    defer ctx.deinit();

    // Wait for connection and session list
    var connected = false;
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        if (!ws_client.is_connected) {
            logger.err("Disconnected.", .{});
            return error.NotConnected;
        }

        const payload = ws_client.receive() catch |err| {
            logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
            ws_client.disconnect();
            return err;
        };
        if (payload) |text| {
            defer allocator.free(text);
            const update = event_handler.handleRawMessage(&ctx, text) catch |err| blk: {
                logger.warn("Error handling message: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (update) |auth_update| {
                defer auth_update.deinit(allocator);
                ws_client.storeDeviceToken(
                    auth_update.device_token,
                    auth_update.role,
                    auth_update.scopes,
                    auth_update.issued_at_ms,
                ) catch |err| {
                    logger.warn("Failed to store device token: {s}", .{@errorName(err)});
                };
            }
            if (ctx.state == .connected) {
                connected = true;
            }
            // Once we have sessions, we can proceed
            if (connected and (list_sessions or send_message != null or ctx.sessions.items.len > 0)) {
                break;
            }
        } else {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    if (!connected) {
        logger.err("Failed to connect within timeout.", .{});
        return error.ConnectionTimeout;
    }

    // Handle --list-sessions
    if (list_sessions) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll("Available sessions:\n");
        if (ctx.sessions.items.len == 0) {
            try stdout.writeAll("  (no sessions available)\n");
        } else {
            for (ctx.sessions.items) |session| {
                const display = session.display_name orelse session.key;
                const label = session.label orelse "-";
                const kind = session.kind orelse "-";
                try stdout.print("  {s} | {s} | {s} | {s}\n", .{ session.key, display, label, kind });
            }
        }
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --send
    if (send_message) |message| {
        const target_session = session_key orelse cfg.default_session orelse blk: {
            if (ctx.sessions.items.len == 0) {
                logger.err("No sessions available. Use --session to specify one.", .{});
                return error.NoSessionAvailable;
            }
            break :blk ctx.sessions.items[0].key;
        };

        try sendChatMessage(allocator, &ws_client, target_session, message);
        std.Thread.sleep(500 * std.time.ns_per_ms);
        logger.info("Message sent successfully.", .{});
        
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Save config if requested
    if (save_config) {
        try config.save(allocator, config_path, cfg);
        logger.info("Config saved to {s}", .{config_path});
    }

    // Normal receive loop
    while (true) {
        if (!ws_client.is_connected) {
            logger.warn("Disconnected.", .{});
            break;
        }

        const payload = ws_client.receive() catch |err| {
            logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
            ws_client.disconnect();
            break;
        };
        if (payload) |text| {
            defer allocator.free(text);
            logger.info("recv: {s}", .{text});
            const update = event_handler.handleRawMessage(&ctx, text) catch |err| blk: {
                logger.warn("Error handling message: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (update) |auth_update| {
                defer auth_update.deinit(allocator);
                ws_client.storeDeviceToken(
                    auth_update.device_token,
                    auth_update.role,
                    auth_update.scopes,
                    auth_update.issued_at_ms,
                ) catch |err| {
                    logger.warn("Failed to store device token: {s}", .{@errorName(err)});
                };
            }
        } else {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

fn sendChatMessage(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    target_session: []const u8,
    message: []const u8,
) !void {
    const idempotency_key = try requests.makeRequestId(allocator);
    defer allocator.free(idempotency_key);

    const params = chat.ChatSendParams{
        .sessionKey = target_session,
        .message = message,
        .idempotencyKey = idempotency_key,
    };

    const request = try requests.buildRequestPayload(allocator, "chat.send", params);
    defer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    logger.info("Sending message to session {s}: {s}", .{ target_session, message });
    try ws_client.send(request.payload);
}

fn initLogging(allocator: std.mem.Allocator) !void {
    const env_level = std.process.getEnvVarOwned(allocator, "MOLT_LOG_LEVEL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_level) |value| {
        defer allocator.free(value);
        if (parseLogLevel(value)) |level| {
            logger.setLevel(level);
        }
    }

    const env_file = std.process.getEnvVarOwned(allocator, "MOLT_LOG_FILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_file) |path| {
        defer allocator.free(path);
        logger.initFile(path) catch |err| {
            logger.warn("Failed to open log file: {}", .{err});
        };
    }
}

fn parseLogLevel(value: []const u8) ?logger.Level {
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn") or std.ascii.eqlIgnoreCase(value, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "error") or std.ascii.eqlIgnoreCase(value, "err")) return .err;
    return null;
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}
