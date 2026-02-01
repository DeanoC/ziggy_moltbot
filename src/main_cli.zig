const std = @import("std");
const builtin = @import("builtin");
const client_state = @import("client/state.zig");
const config = @import("client/config.zig");
const event_handler = @import("client/event_handler.zig");
const update_checker = @import("client/update_checker.zig");
const websocket_client = @import("openclaw_transport.zig").websocket;
const logger = @import("utils/logger.zig");
const chat = @import("protocol/chat.zig");
const nodes_proto = @import("protocol/nodes.zig");
const approvals_proto = @import("protocol/approvals.zig");
const requests = @import("protocol/requests.zig");
const messages = @import("protocol/messages.zig");
const main_operator = @import("main_operator.zig");
const build_options = @import("build_options");
const main_node = if (builtin.os.tag == .windows) struct {
    pub const usage =
        \\ZiggyStarClaw Node Mode
        \\
        \\Node mode is not supported on Windows.
        \\
    ;

    pub const NodeCliOptions = struct {};

    pub fn parseNodeOptions(_: std.mem.Allocator, _: []const []const u8) !NodeCliOptions {
        return error.NodeModeUnsupported;
    }

    pub fn runNodeMode(_: std.mem.Allocator, _: NodeCliOptions) !void {
        return error.NodeModeUnsupported;
    }
} else @import("main_node.zig");

pub const std_options = std.Options{
    .logFn = cliLogFn,
    .log_level = .debug,
};

var cli_log_level: std.log.Level = .warn;

const usage =
    \\ZiggyStarClaw CLI
    \\
    \\Usage:
    \\  ziggystarclaw-cli [options]
    \\
    \\Options:
    \\  --url <ws/wss url>       Override server URL
    \\  --token <token>          Override auth token
    \\  --config <path>          Config file path (default: ziggystarclaw_config.json)
    \\  --update-url <url>       Override update manifest URL
    \\  --print-update-url       Print normalized update manifest URL and exit
    \\  --insecure-tls           Disable TLS verification
    \\  --read-timeout-ms <ms>   Socket read timeout in milliseconds (default: 15000)
    \\  --send <message>         Send a chat message and exit
    \\  --session <key>          Target session for send (uses default if not set)
    \\  --list-sessions          List available sessions and exit
    \\  --use-session <key>      Set default session and exit
    \\  --list-nodes             List available nodes and exit
    \\  --node <id>              Target node for run command
    \\  --use-node <id>          Set default node and exit
    \\  --run <command>          Run a command on the target node
    \\  --list-approvals         List pending approvals and exit
    \\  --approve <id>           Approve an exec request by ID
    \\  --deny <id>              Deny an exec request by ID
    \\  --check-update-only      Fetch update manifest and exit
    \\  --interactive            Start interactive REPL mode
    \\  --node-mode              Run as a capability node (see --node-mode-help)
    \\  --operator-mode          Run as an operator client (pair/approve, list nodes, invoke)
    \\  --save-config            Save --url, --token, --update-url, --use-session, --use-node to config file
    \\  -h, --help               Show help
    \\  --node-mode-help         Show node mode help
    \\  --operator-mode-help     Show operator mode help
    \\
;

const ReplCommand = enum {
    help,
    send,
    session,
    sessions,
    node,
    nodes,
    run,
    approvals,
    approve,
    deny,
    quit,
    exit,
    save,
    unknown,
};

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
    var override_update_url: ?[]const u8 = null;
    var override_insecure: ?bool = null;
    var read_timeout_ms: u32 = 15_000;
    var send_message: ?[]const u8 = null;
    var session_key: ?[]const u8 = null;
    var list_sessions = false;
    var use_session: ?[]const u8 = null;
    var list_nodes = false;
    var node_id: ?[]const u8 = null;
    var use_node: ?[]const u8 = null;
    var run_command: ?[]const u8 = null;
    var list_approvals = false;
    var approve_id: ?[]const u8 = null;
    var deny_id: ?[]const u8 = null;
    var check_update_only = false;
    var print_update_url = false;
    var interactive = false;
    // Pre-scan for mode flags so we can delegate argument parsing cleanly.
    var node_mode = false;
    var operator_mode = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--node-mode")) node_mode = true;
        if (std.mem.eql(u8, a, "--operator-mode")) operator_mode = true;
    }
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
        } else if (std.mem.eql(u8, arg, "--update-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            override_update_url = args[i];
        } else if (std.mem.eql(u8, arg, "--print-update-url")) {
            print_update_url = true;
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
        } else if (std.mem.eql(u8, arg, "--list-nodes")) {
            list_nodes = true;
        } else if (std.mem.eql(u8, arg, "--node")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_id = args[i];
        } else if (std.mem.eql(u8, arg, "--use-node")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            use_node = args[i];
        } else if (std.mem.eql(u8, arg, "--run")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            run_command = args[i];
        } else if (std.mem.eql(u8, arg, "--list-approvals")) {
            list_approvals = true;
        } else if (std.mem.eql(u8, arg, "--approve")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            approve_id = args[i];
        } else if (std.mem.eql(u8, arg, "--deny")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            deny_id = args[i];
        } else if (std.mem.eql(u8, arg, "--check-update-only")) {
            check_update_only = true;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--node-mode")) {
            // handled by pre-scan
        } else if (std.mem.eql(u8, arg, "--operator-mode")) {
            // handled by pre-scan
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            save_config = true;
        } else if (std.mem.eql(u8, arg, "--node-mode-help")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(main_node.usage);
            return;
        } else if (std.mem.eql(u8, arg, "--operator-mode-help")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(main_operator.usage);
            return;
        } else {
            // When running a specialized mode, allow that mode to parse its own flags.
            if (!(node_mode or operator_mode)) {
                logger.warn("Unknown argument: {s}", .{arg});
            }
        }
    }

    const has_action = list_sessions or list_nodes or list_approvals or send_message != null or
        run_command != null or approve_id != null or deny_id != null or use_session != null or
        use_node != null or check_update_only or print_update_url or interactive or node_mode or save_config;
    if (!has_action) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(usage);
        return;
    }

    // Handle node mode
    if (node_mode) {
        if (builtin.os.tag == .windows) {
            logger.err("Node mode is not supported on Windows.", .{});
            return error.NodeModeUnsupported;
        }
        const node_opts = try main_node.parseNodeOptions(allocator, args[1..]);
        try main_node.runNodeMode(allocator, node_opts);
        return;
    }

    // Handle operator mode
    if (operator_mode) {
        const op_opts = try main_operator.parseOperatorOptions(allocator, args[1..]);
        try main_operator.runOperatorMode(allocator, op_opts);
        return;
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
    if (override_update_url) |url| {
        if (cfg.update_manifest_url) |old| {
            allocator.free(old);
        }
        cfg.update_manifest_url = try allocator.dupe(u8, url);
    }
    if (use_session) |key| {
        if (cfg.default_session) |old| {
            allocator.free(old);
        }
        cfg.default_session = try allocator.dupe(u8, key);
    }
    if (use_node) |id| {
        if (cfg.default_node) |old| {
            allocator.free(old);
        }
        cfg.default_node = try allocator.dupe(u8, id);
    }

    const env_timeout = std.process.getEnvVarOwned(allocator, "MOLT_READ_TIMEOUT_MS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_timeout) |value| {
        defer allocator.free(value);
        read_timeout_ms = try std.fmt.parseInt(u32, value, 10);
    }

    const requires_connection = list_sessions or list_nodes or list_approvals or send_message != null or
        run_command != null or approve_id != null or deny_id != null or interactive;
    if (requires_connection and cfg.server_url.len == 0) {
        logger.err("Server URL is empty. Use --url or set it in {s}.", .{config_path});
        return error.InvalidArguments;
    }

    // Allow --run with default node; only error if neither is provided.
    if (run_command != null and node_id == null and cfg.default_node == null) {
        logger.err("No node specified. Use --node or --use-node to set a default.", .{});
        return error.InvalidArguments;
    }

    if (print_update_url) {
        const manifest_url = cfg.update_manifest_url orelse "";
        if (manifest_url.len == 0) {
            logger.err("Update manifest URL is empty. Use --update-url or set it in {s}.", .{config_path});
            return error.InvalidArguments;
        }
        var normalized = try update_checker.sanitizeUrl(allocator, manifest_url);
        defer allocator.free(normalized);
        _ = try update_checker.normalizeUrlForParse(allocator, &normalized);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Manifest URL: {s}\n", .{manifest_url});
        try stdout.print("Normalized URL: {s}\n", .{normalized});
        if (!check_update_only and !requires_connection and !save_config) {
            return;
        }
    }

    // Handle --save-config without connecting
    if (save_config and !check_update_only and !list_sessions and !list_nodes and !list_approvals and send_message == null and run_command == null and approve_id == null and deny_id == null and !interactive) {
        try config.save(allocator, config_path, cfg);
        logger.info("Config saved to {s}", .{config_path});
        return;
    }

    if (check_update_only) {
        const manifest_url = cfg.update_manifest_url orelse "";
        if (manifest_url.len == 0) {
            logger.err("Update manifest URL is empty. Use --update-url or set it in {s}.", .{config_path});
            return error.InvalidArguments;
        }
        var info = try update_checker.checkOnce(allocator, manifest_url, build_options.app_version);
        defer info.deinit(allocator);

        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Manifest URL: {s}\n", .{manifest_url});
        try stdout.print("Current version: {s}\n", .{build_options.app_version});
        try stdout.print("Latest version: {s}\n", .{info.version});
        const newer = update_checker.isNewerVersion(info.version, build_options.app_version);
        try stdout.print("Status: {s}\n", .{if (newer) "update available" else "up to date"});
        try stdout.print("Release URL: {s}\n", .{info.release_url orelse "-"});
        try stdout.print("Download URL: {s}\n", .{info.download_url orelse "-"});
        try stdout.print("Download file: {s}\n", .{info.download_file orelse "-"});
        try stdout.print("SHA256: {s}\n", .{info.download_sha256 orelse "-"});

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    var ws_client = websocket_client.WebSocketClient.init(
        allocator,
        cfg.server_url,
        cfg.token,
        cfg.insecure_tls,
        cfg.connect_host_override,
    );
    // Explicitly set CLI connect profile (operator)
    ws_client.setConnectProfile(.{
        .role = "operator",
        .scopes = &.{ "operator.admin", "operator.approvals", "operator.pairing" },
        .client_id = "cli",
        .client_mode = "cli",
    });
    ws_client.setReadTimeout(read_timeout_ms);
    defer ws_client.deinit();

    try ws_client.connect();
    logger.info("CLI connected. Server: {s} (read timeout {}ms)", .{ cfg.server_url, read_timeout_ms });

    var ctx = try client_state.ClientContext.init(allocator);
    defer ctx.deinit();

    // Wait for connection and data
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
            // Once we have data we need, proceed
            const have_sessions = ctx.sessions.items.len > 0;
            const have_nodes = ctx.nodes.items.len > 0;
            if (connected) {
                if (list_sessions and have_sessions) break;
                if (list_nodes and have_nodes) break;
                if (list_approvals) break;
                if (send_message != null and have_sessions) break;
                if (run_command != null and have_nodes) break;
                if (approve_id != null) break;
                if (deny_id != null) break;
                if (interactive) break;
                if (!list_sessions and !list_nodes and !list_approvals and send_message == null and run_command == null and approve_id == null and deny_id == null and !interactive) break;
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

    // Handle --list-nodes
    if (list_nodes) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll("Available nodes:\n");
        if (ctx.nodes.items.len == 0) {
            try stdout.writeAll("  (no nodes available)\n");
        } else {
            for (ctx.nodes.items) |node| {
                const display = node.display_name orelse node.id;
                const platform = node.platform orelse "-";
                const status = if (node.connected orelse false) "connected" else "disconnected";
                try stdout.print("  {s} | {s} | {s} | {s}\n", .{ node.id, display, platform, status });
            }
        }
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --list-approvals
    if (list_approvals) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll("Pending approvals:\n");
        if (ctx.approvals.items.len == 0) {
            try stdout.writeAll("  (no pending approvals)\n");
        } else {
            for (ctx.approvals.items) |approval| {
                const summary = approval.summary orelse "(no summary)";
                const can_resolve = if (approval.can_resolve) "Y" else "N";
                try stdout.print("  {s} | {s} | resolve={s}\n", .{ approval.id, summary, can_resolve });
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

    // Handle --run
    if (run_command) |command| {
        const target_node = node_id orelse cfg.default_node orelse {
            logger.err("No node specified. Use --node or --use-node to set a default.", .{});
            return error.NoNodeSpecified;
        };

        // Verify node exists
        var node_exists = false;
        for (ctx.nodes.items) |node| {
            if (std.mem.eql(u8, node.id, target_node)) {
                node_exists = true;
                break;
            }
        }
        if (!node_exists) {
            logger.err("Node '{s}' not found. Use --list-nodes to see available nodes.", .{target_node});
            return error.NodeNotFound;
        }

        try runNodeCommand(allocator, &ws_client, target_node, command);

        // Wait for result
        var wait_attempts: u32 = 0;
        while (wait_attempts < 100 and ctx.node_result == null) : (wait_attempts += 1) {
            const payload = ws_client.receive() catch |err| {
                logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
                break;
            };
            if (payload) |text| {
                defer allocator.free(text);
                _ = event_handler.handleRawMessage(&ctx, text) catch |err| blk: {
                    logger.warn("Error handling message: {s}", .{@errorName(err)});
                    break :blk null;
                };
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        if (ctx.node_result) |result| {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.print("Result: {s}\n", .{result});
        } else {
            logger.info("Command sent. Waiting for result timed out.", .{});
        }

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --approve
    if (approve_id) |id| {
        try resolveApproval(allocator, &ws_client, id, "approve");
        std.Thread.sleep(500 * std.time.ns_per_ms);
        logger.info("Approval {s} approved.", .{id});

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --deny
    if (deny_id) |id| {
        try resolveApproval(allocator, &ws_client, id, "deny");
        std.Thread.sleep(500 * std.time.ns_per_ms);
        logger.info("Approval {s} denied.", .{id});

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --interactive
    if (interactive) {
        try runRepl(allocator, &ws_client, &ctx, &cfg, config_path);
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

fn runRepl(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    cfg: *config.Config,
    config_path: []const u8,
) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    var stdin = std.fs.File.stdin().deprecatedReader();

    try stdout.writeAll("\nZiggyStarClaw Interactive Mode\n");
    try stdout.writeAll("Type 'help' for commands, 'quit' to exit.\n\n");

    var current_session = cfg.default_session;
    var current_node = cfg.default_node;

    while (true) {
        const session_name = if (current_session) |s| s[0..@min(s.len, 8)] else "none";
        const node_name = if (current_node) |n| n[0..@min(n.len, 8)] else "none";
        try stdout.print("[session:{s} node:{s}]> ", .{ session_name, node_name });

        var input_buffer: [1024]u8 = undefined;
        const line_opt = try stdin.readUntilDelimiterOrEof(&input_buffer, '\n');
        if (line_opt == null) break;

        const input = std.mem.trim(u8, line_opt.?, " \t\r\n");
        if (input.len == 0) continue;

        var parts = std.mem.splitScalar(u8, input, ' ');
        const cmd_str = parts.next() orelse continue;
        const cmd = parseReplCommand(cmd_str);

        switch (cmd) {
            .help => {
                try stdout.writeAll(
                    "Commands:\n" ++
                    "  help                    Show this help\n" ++
                    "  send <message>          Send message to current session\n" ++
                    "  session [key]           Show or set current session\n" ++
                    "  sessions                List available sessions\n" ++
                    "  node [id]               Show or set current node\n" ++
                    "  nodes                   List available nodes\n" ++
                    "  run <command>           Run command on current node\n" ++
                    "  approvals               List pending approvals\n" ++
                    "  approve <id>            Approve request by ID\n" ++
                    "  deny <id>               Deny request by ID\n" ++
                    "  save                    Save current session/node to config\n" ++
                    "  quit/exit               Exit interactive mode\n"
                );
            },
            .send => {
                const message = parts.rest();
                if (message.len == 0) {
                    try stdout.writeAll("Usage: send <message>\n");
                    continue;
                }
                const target_session = current_session orelse blk: {
                    if (ctx.sessions.items.len == 0) {
                        try stdout.writeAll("No sessions available. Use 'sessions' to list.\n");
                        continue;
                    }
                    break :blk ctx.sessions.items[0].key;
                };
                try sendChatMessage(allocator, ws_client, target_session, message);
                try stdout.writeAll("Message sent.\n");
            },
            .session => {
                const new_session = parts.rest();
                if (new_session.len == 0) {
                    if (current_session) |s| {
                        try stdout.print("Current session: {s}\n", .{s});
                    } else {
                        try stdout.writeAll("No current session. Use 'session <key>' to set.\n");
                    }
                } else {
                    current_session = try allocator.dupe(u8, new_session);
                    try stdout.print("Session set to: {s}\n", .{current_session.?});
                }
            },
            .sessions => {
                try stdout.writeAll("Available sessions:\n");
                if (ctx.sessions.items.len == 0) {
                    try stdout.writeAll("  (no sessions available)\n");
                } else {
                    for (ctx.sessions.items) |session| {
                        const display = session.display_name orelse session.key;
                        const label = session.label orelse "-";
                        try stdout.print("  {s} | {s} | {s}\n", .{ session.key, display, label });
                    }
                }
            },
            .node => {
                const new_node = parts.rest();
                if (new_node.len == 0) {
                    if (current_node) |n| {
                        try stdout.print("Current node: {s}\n", .{n});
                    } else {
                        try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    }
                } else {
                    current_node = try allocator.dupe(u8, new_node);
                    try stdout.print("Node set to: {s}\n", .{current_node.?});
                }
            },
            .nodes => {
                try stdout.writeAll("Available nodes:\n");
                if (ctx.nodes.items.len == 0) {
                    try stdout.writeAll("  (no nodes available)\n");
                } else {
                    for (ctx.nodes.items) |node| {
                        const display = node.display_name orelse node.id;
                        const platform = node.platform orelse "-";
                        const status = if (node.connected orelse false) "connected" else "disconnected";
                        try stdout.print("  {s} | {s} | {s} | {s}\n", .{ node.id, display, platform, status });
                    }
                }
            },
            .run => {
                const command = parts.rest();
                if (command.len == 0) {
                    try stdout.writeAll("Usage: run <command>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                try runNodeCommand(allocator, ws_client, target_node, command);
                try stdout.writeAll("Command sent.\n");
            },
            .approvals => {
                try stdout.writeAll("Pending approvals:\n");
                if (ctx.approvals.items.len == 0) {
                    try stdout.writeAll("  (no pending approvals)\n");
                } else {
                    for (ctx.approvals.items) |approval| {
                        const summary = approval.summary orelse "(no summary)";
                        try stdout.print("  {s} | {s}\n", .{ approval.id, summary });
                    }
                }
            },
            .approve => {
                const id = parts.rest();
                if (id.len == 0) {
                    try stdout.writeAll("Usage: approve <id>\n");
                    continue;
                }
                try resolveApproval(allocator, ws_client, id, "approve");
                try stdout.writeAll("Approval sent.\n");
            },
            .deny => {
                const id = parts.rest();
                if (id.len == 0) {
                    try stdout.writeAll("Usage: deny <id>\n");
                    continue;
                }
                try resolveApproval(allocator, ws_client, id, "deny");
                try stdout.writeAll("Denial sent.\n");
            },
            .quit, .exit => {
                try stdout.writeAll("Goodbye!\n");
                break;
            },
            .save => {
                if (current_session) |s| {
                    if (cfg.default_session) |old| {
                        if (!(old.ptr == s.ptr and old.len == s.len)) {
                            allocator.free(old);
                            cfg.default_session = try allocator.dupe(u8, s);
                        }
                    } else {
                        cfg.default_session = try allocator.dupe(u8, s);
                    }
                }
                if (current_node) |n| {
                    if (cfg.default_node) |old| {
                        if (!(old.ptr == n.ptr and old.len == n.len)) {
                            allocator.free(old);
                            cfg.default_node = try allocator.dupe(u8, n);
                        }
                    } else {
                        cfg.default_node = try allocator.dupe(u8, n);
                    }
                }
                try config.save(allocator, config_path, cfg.*);
                try stdout.writeAll("Config saved.\n");
            },
            .unknown => {
                try stdout.print("Unknown command: {s}. Type 'help' for available commands.\n", .{cmd_str});
            },
        }

        var processed = false;
        while (!processed) {
            const payload = ws_client.receive() catch |err| {
                logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
                break;
            };
            if (payload) |text| {
                defer allocator.free(text);
                _ = event_handler.handleRawMessage(ctx, text) catch |err| blk: {
                    logger.warn("Error handling message: {s}", .{@errorName(err)});
                    break :blk null;
                };
            } else {
                processed = true;
            }
        }
    }
}

fn parseReplCommand(cmd: []const u8) ReplCommand {
    if (std.mem.eql(u8, cmd, "help")) return .help;
    if (std.mem.eql(u8, cmd, "send")) return .send;
    if (std.mem.eql(u8, cmd, "session")) return .session;
    if (std.mem.eql(u8, cmd, "sessions")) return .sessions;
    if (std.mem.eql(u8, cmd, "node")) return .node;
    if (std.mem.eql(u8, cmd, "nodes")) return .nodes;
    if (std.mem.eql(u8, cmd, "run")) return .run;
    if (std.mem.eql(u8, cmd, "approvals")) return .approvals;
    if (std.mem.eql(u8, cmd, "approve")) return .approve;
    if (std.mem.eql(u8, cmd, "deny")) return .deny;
    if (std.mem.eql(u8, cmd, "quit")) return .quit;
    if (std.mem.eql(u8, cmd, "exit")) return .exit;
    if (std.mem.eql(u8, cmd, "save")) return .save;
    return .unknown;
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

fn runNodeCommand(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    target_node: []const u8,
    command: []const u8,
) !void {
    const idempotency_key = try requests.makeRequestId(allocator);
    defer allocator.free(idempotency_key);

    var params_json = std.json.ObjectMap.init(allocator);
    defer params_json.deinit();

    var command_arr = std.json.Array.init(allocator);
    defer command_arr.deinit();

    var it = std.mem.splitScalar(u8, command, ' ');
    while (it.next()) |part| {
        if (part.len > 0) {
            try command_arr.append(std.json.Value{ .string = try allocator.dupe(u8, part) });
        }
    }

    try params_json.put("command", std.json.Value{ .array = command_arr });

    const params = nodes_proto.NodeInvokeParams{
        .nodeId = target_node,
        .command = "system.run",
        .params = std.json.Value{ .object = params_json },
        .idempotencyKey = idempotency_key,
    };

    const request = try requests.buildRequestPayload(allocator, "node.invoke", params);
    defer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    logger.info("Running command on node {s}: {s}", .{ target_node, command });
    try ws_client.send(request.payload);
}

fn resolveApproval(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    approval_id: []const u8,
    decision: []const u8,
) !void {
    const params = approvals_proto.ExecApprovalResolveParams{
        .id = approval_id,
        .decision = decision,
    };

    const request = try requests.buildRequestPayload(allocator, "exec.approval.resolve", params);
    defer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    logger.info("Resolving approval {s} with decision: {s}", .{ approval_id, decision });
    try ws_client.send(request.payload);
}

fn cliLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (stdLogRank(level) < stdLogRank(cli_log_level)) return;
    var stderr = std.fs.File.stderr().deprecatedWriter();
    if (scope == .default) {
        stderr.print("{s}: ", .{@tagName(level)}) catch return;
    } else {
        stderr.print("{s}({s}): ", .{ @tagName(level), @tagName(scope) }) catch return;
    }
    stderr.print(format, args) catch return;
    stderr.writeByte('\n') catch return;
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
            cli_log_level = toStdLogLevel(level);
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

fn toStdLogLevel(level: logger.Level) std.log.Level {
    return switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
}

fn stdLogRank(level: std.log.Level) u8 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}
