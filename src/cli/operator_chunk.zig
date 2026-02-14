const std = @import("std");
const client_state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const event_handler = @import("../client/event_handler.zig");
const update_checker = @import("../client/update_checker.zig");
const websocket_client = @import("../openclaw_transport.zig").websocket;
const ziggy = @import("ziggy-core");
const logger = ziggy.utils.logger;
const chat = ziggy.protocol.chat;
const nodes_proto = @import("../protocol/nodes.zig");
const approvals_proto = @import("../protocol/approvals.zig");
const requests = ziggy.protocol.requests;
const ws_auth_pairing = @import("../protocol/ws_auth_pairing.zig");
const build_options = @import("build_options");
const gateway_cmd = @import("gateway.zig");

pub const Options = struct {
    config_path: []const u8,
    override_url: ?[]const u8,
    override_token: ?[]const u8,
    override_token_set: bool,
    override_update_url: ?[]const u8,
    override_insecure: ?bool,
    read_timeout_ms: u32,
    send_message: ?[]const u8,
    session_key: ?[]const u8,
    list_sessions: bool,
    use_session: ?[]const u8,
    list_nodes: bool,
    node_id: ?[]const u8,
    use_node: ?[]const u8,
    run_command: ?[]const u8,
    which_name: ?[]const u8,
    notify_title: ?[]const u8,
    ps_list: bool,
    spawn_command: ?[]const u8,
    poll_process_id: ?[]const u8,
    stop_process_id: ?[]const u8,
    canvas_present: bool,
    canvas_hide: bool,
    canvas_navigate: ?[]const u8,
    canvas_eval: ?[]const u8,
    canvas_snapshot: ?[]const u8,
    exec_approvals_get: bool,
    exec_allow_cmd: ?[]const u8,
    exec_allow_file: ?[]const u8,
    list_approvals: bool,
    approve_id: ?[]const u8,
    deny_id: ?[]const u8,
    device_pair_list: bool,
    device_pair_approve_id: ?[]const u8,
    device_pair_reject_id: ?[]const u8,
    device_pair_watch: bool,
    check_update_only: bool,
    print_update_url: bool,
    interactive: bool,
    save_config: bool,
    gateway_verb: ?[]const u8,
    gateway_url: ?[]const u8,
};

const ReplCommand = enum {
    help,
    send,
    session,
    sessions,
    node,
    nodes,
    run,
    which,
    notify,
    ps,
    spawn,
    poll,
    stop,
    canvas,
    approvals,
    approve,
    deny,
    gateway,
    quit,
    exit,
    save,
    unknown,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    const config_path = options.config_path;
    const override_url = options.override_url;
    const override_token = options.override_token;
    const override_token_set = options.override_token_set;
    const override_update_url = options.override_update_url;
    const override_insecure = options.override_insecure;
    var read_timeout_ms = options.read_timeout_ms;
    const send_message = options.send_message;
    const session_key = options.session_key;
    const list_sessions = options.list_sessions;
    const use_session = options.use_session;
    const list_nodes = options.list_nodes;
    const node_id = options.node_id;
    const use_node = options.use_node;
    const run_command = options.run_command;
    const which_name = options.which_name;
    const notify_title = options.notify_title;
    const ps_list = options.ps_list;
    const spawn_command = options.spawn_command;
    const poll_process_id = options.poll_process_id;
    const stop_process_id = options.stop_process_id;
    const canvas_present = options.canvas_present;
    const canvas_hide = options.canvas_hide;
    const canvas_navigate = options.canvas_navigate;
    const canvas_eval = options.canvas_eval;
    const canvas_snapshot = options.canvas_snapshot;
    const exec_approvals_get = options.exec_approvals_get;
    const exec_allow_cmd = options.exec_allow_cmd;
    const exec_allow_file = options.exec_allow_file;
    const list_approvals = options.list_approvals;
    const approve_id = options.approve_id;
    const deny_id = options.deny_id;
    const device_pair_list = options.device_pair_list;
    const device_pair_approve_id = options.device_pair_approve_id;
    const device_pair_reject_id = options.device_pair_reject_id;
    const device_pair_watch = options.device_pair_watch;
    const check_update_only = options.check_update_only;
    const print_update_url = options.print_update_url;
    const interactive = options.interactive;
    const save_config = options.save_config;
    const gateway_verb = options.gateway_verb;
    const gateway_url = options.gateway_url;

    // Handle standalone gateway test (no main connection needed)
    if (gateway_verb) |verb_str| {
        const url = gateway_url orelse {
            logger.err("Usage: --gateway-test <verb> <url>", .{});
            return error.InvalidArguments;
        };

        const verb = gateway_cmd.parseVerb(verb_str);
        if (verb == .unknown) {
            logger.err("Unknown gateway verb: {s}. Use: ping, echo, or probe", .{verb_str});
            const stdout = std.fs.File.stdout().deprecatedWriter();
            try gateway_cmd.printHelp(stdout);
            return error.InvalidArguments;
        }

        // Parse agent_id from URL path (e.g., /v1/agents/test/stream -> test)
        var agent_id: []const u8 = "test";
        if (std.mem.indexOf(u8, url, "/agents/")) |start| {
            const after_agent = start + 8; // "/agents/" len
            if (std.mem.indexOfPos(u8, url, after_agent, "/")) |end| {
                agent_id = url[after_agent..end];
            }
        }

        var standalone_cfg = try config.loadOrDefault(allocator, config_path);
        defer standalone_cfg.deinit(allocator);

        var env_token_to_free: ?[]u8 = null;
        defer if (env_token_to_free) |value| allocator.free(value);

        const standalone_token: []const u8 = blk: {
            if (override_token_set) break :blk (override_token orelse "");

            const env_token = std.process.getEnvVarOwned(allocator, "MOLT_TOKEN") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            if (env_token) |token| {
                env_token_to_free = token;
                break :blk token;
            }

            break :blk standalone_cfg.token;
        };

        const standalone_insecure_tls = blk: {
            if (override_insecure) |value| break :blk value;

            const env_insecure = std.process.getEnvVarOwned(allocator, "MOLT_INSECURE_TLS") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            if (env_insecure) |value| {
                defer allocator.free(value);
                break :blk parseBool(value);
            }

            break :blk standalone_cfg.insecure_tls;
        };

        var stdout = std.fs.File.stdout().deprecatedWriter();
        gateway_cmd.run(allocator, verb, url, standalone_token, agent_id, read_timeout_ms, standalone_insecure_tls, &stdout) catch |err| {
            logger.err("Gateway test failed: {s}", .{@errorName(err)});
            return err;
        };
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
    if (override_token_set) {
        const token = override_token orelse "";
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
        run_command != null or which_name != null or notify_title != null or ps_list or spawn_command != null or
        poll_process_id != null or stop_process_id != null or canvas_present or canvas_hide or
        canvas_navigate != null or canvas_eval != null or canvas_snapshot != null or exec_approvals_get or
        exec_allow_cmd != null or exec_allow_file != null or approve_id != null or deny_id != null or
        device_pair_list or device_pair_approve_id != null or device_pair_reject_id != null or device_pair_watch or interactive;
    if (requires_connection and cfg.server_url.len == 0) {
        logger.err("Server URL is empty. Use --url or set it in {s}.", .{config_path});
        return error.InvalidArguments;
    }

    const needs_node = run_command != null or which_name != null or notify_title != null or ps_list or
        spawn_command != null or poll_process_id != null or stop_process_id != null or canvas_present or
        canvas_hide or canvas_navigate != null or canvas_eval != null or canvas_snapshot != null or
        exec_approvals_get or exec_allow_cmd != null or exec_allow_file != null;

    // Allow node commands with default node; only error if neither is provided.
    if (needs_node and node_id == null and cfg.default_node == null) {
        logger.err("No node specified. Use --node or set a default via `nodes use <id> --save-config`.", .{});
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
    if (save_config and !check_update_only and !list_sessions and !list_nodes and !list_approvals and send_message == null and run_command == null and approve_id == null and deny_id == null and !device_pair_list and device_pair_approve_id == null and device_pair_reject_id == null and !device_pair_watch and !interactive) {
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

            const needs_sessions = list_sessions or send_message != null or interactive;
            const needs_nodes = list_nodes or run_command != null or which_name != null or notify_title != null or ps_list or spawn_command != null or
                poll_process_id != null or stop_process_id != null or canvas_present or canvas_hide or canvas_navigate != null or canvas_eval != null or canvas_snapshot != null;

            if (connected) {
                // Actively request state instead of waiting for the gateway to push it.
                if (needs_sessions and !have_sessions and ctx.pending_sessions_request_id == null) {
                    requestSessionsList(allocator, &ws_client, &ctx) catch |err| {
                        logger.warn("sessions.list request failed: {s}", .{@errorName(err)});
                    };
                }
                if (needs_nodes and !have_nodes and ctx.pending_nodes_request_id == null) {
                    requestNodesList(allocator, &ws_client, &ctx) catch |err| {
                        logger.warn("node.list request failed: {s}", .{@errorName(err)});
                    };
                }

                if (list_sessions and have_sessions) break;
                if (list_nodes and have_nodes) break;
                if (list_approvals) break;
                if (send_message != null and have_sessions) break;
                if (needs_nodes and have_nodes) break;
                if (approve_id != null) break;
                if (deny_id != null) break;
                if (device_pair_list) break;
                if (device_pair_approve_id != null) break;
                if (device_pair_reject_id != null) break;
                if (device_pair_watch) break;
                if (interactive) break;
                if (!list_sessions and !list_nodes and !list_approvals and send_message == null and run_command == null and which_name == null and notify_title == null and !ps_list and spawn_command == null and poll_process_id == null and stop_process_id == null and !canvas_present and !canvas_hide and canvas_navigate == null and canvas_eval == null and canvas_snapshot == null and approve_id == null and deny_id == null and !device_pair_list and device_pair_approve_id == null and device_pair_reject_id == null and !device_pair_watch and !interactive) break;
            }
        } else {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    if (!connected) {
        logger.err("Failed to connect within timeout.", .{});
        return error.ConnectionTimeout;
    }

    if (device_pair_watch) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        while (ws_client.is_connected) {
            const msg = ws_client.receive() catch |err| {
                logger.warn("pairing watch recv failed: {s}", .{@errorName(err)});
                break;
            };
            if (msg) |payload| {
                defer allocator.free(payload);

                var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
                    continue;
                };
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const t = parsed.value.object.get("type") orelse continue;
                if (t != .string or !std.mem.eql(u8, t.string, "event")) continue;
                const ev = parsed.value.object.get("event") orelse continue;
                if (ev != .string) continue;
                if (std.mem.startsWith(u8, ev.string, "device.pair.")) {
                    try stdout.writeAll(payload);
                    try stdout.writeByte('\n');
                }
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
        return;
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

    if (device_pair_list) {
        const payload = try requestAndAwaitJsonPayloadText(allocator, &ws_client, "device.pair.list", .{}, 5000);
        defer allocator.free(payload);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(payload);
        try stdout.writeByte('\n');
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    if (device_pair_approve_id) |request_id| {
        const payload = try requestAndAwaitJsonPayloadText(allocator, &ws_client, "device.pair.approve", ws_auth_pairing.PairingRequestIdParams{ .requestId = request_id }, 5000);
        defer allocator.free(payload);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(payload);
        try stdout.writeByte('\n');
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    if (device_pair_reject_id) |request_id| {
        const payload = try requestAndAwaitJsonPayloadText(allocator, &ws_client, "device.pair.reject", ws_auth_pairing.PairingRequestIdParams{ .requestId = request_id }, 5000);
        defer allocator.free(payload);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(payload);
        try stdout.writeByte('\n');
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

    const target_node = node_id orelse cfg.default_node;

    if (needs_node and ctx.nodes.items.len == 0) {
        // Ensure we have a node list before validating ids.
        if (ctx.pending_nodes_request_id == null) {
            requestNodesList(allocator, &ws_client, &ctx) catch |err| {
                logger.warn("node.list request failed: {s}", .{@errorName(err)});
            };
        }
        var wait_attempts: u32 = 0;
        while (wait_attempts < 150 and ctx.nodes.items.len == 0) : (wait_attempts += 1) {
            const payload = ws_client.receive() catch |err| {
                logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
                break;
            };
            if (payload) |text| {
                defer allocator.free(text);
                _ = event_handler.handleRawMessage(&ctx, text) catch {};
            } else {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
    }

    if (target_node != null) {
        // Verify node exists for any node action.
        var node_exists = false;
        for (ctx.nodes.items) |node| {
            if (std.mem.eql(u8, node.id, target_node.?)) {
                node_exists = true;
                break;
            }
        }
        if (!node_exists) {
            logger.err("Node '{s}' not found. Use --list-nodes to see available nodes.", .{target_node.?});
            return error.NodeNotFound;
        }
    }

    // Handle --run (system.run)
    if (run_command) |command| {
        try runNodeCommand(allocator, &ws_client, &ctx, target_node.?, command);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --which (system.which)
    if (which_name) |name| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("name", std.json.Value{ .string = name });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "system.which", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --notify (system.notify)
    if (notify_title) |title| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("title", std.json.Value{ .string = title });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "system.notify", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --ps (process.list)
    if (ps_list) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.list", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --spawn (process.spawn)
    if (spawn_command) |cmdline| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        var cmd_arr = try buildJsonCommandArray(allocator, cmdline);
        defer freeJsonStringArray(allocator, &cmd_arr);
        try params_obj.put("command", std.json.Value{ .array = cmd_arr });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.spawn", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --poll (process.poll)
    if (poll_process_id) |pid| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("processId", std.json.Value{ .string = pid });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.poll", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --stop (process.stop)
    if (stop_process_id) |pid| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("processId", std.json.Value{ .string = pid });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.stop", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle canvas
    if (canvas_present) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.present", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_hide) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.hide", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_navigate) |url| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("url", std.json.Value{ .string = url });
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.navigate", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_eval) |js| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("js", std.json.Value{ .string = js });
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.eval", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_snapshot) |path| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("path", std.json.Value{ .string = path });
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.snapshot", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle exec approvals
    if (exec_approvals_get) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "system.execApprovals.get", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    if (exec_allow_cmd) |entry| {
        const added = try addExecAllowlistEntries(allocator, &ws_client, &ctx, target_node.?, &.{entry});
        var stdout = std.fs.File.stdout().deprecatedWriter();
        if (added == 1) {
            try stdout.writeAll("Added 1 allowlist entry.\n");
        } else {
            try stdout.print("Added {d} allowlist entries.\n", .{added});
        }
        return;
    }

    if (exec_allow_file) |path| {
        const entries = try readAllowlistFile(allocator, path);
        defer {
            for (entries) |s| allocator.free(s);
            allocator.free(entries);
        }

        const added = try addExecAllowlistEntries(allocator, &ws_client, &ctx, target_node.?, entries);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        if (added == 1) {
            try stdout.print("Added 1 allowlist entry from {s}.\n", .{path});
        } else {
            try stdout.print("Added {d} allowlist entries from {s}.\n", .{ added, path });
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
        try runRepl(allocator, &ws_client, &ctx, &cfg, config_path, read_timeout_ms);
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
    read_timeout_ms: u32,
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
                try stdout.writeAll("Commands:\n" ++
                    "  help                    Show this help\n" ++
                    "  send <message>          Send message to current session\n" ++
                    "  session [key]           Show or set current session\n" ++
                    "  sessions                List available sessions\n" ++
                    "  node [id]               Show or set current node\n" ++
                    "  nodes                   List available nodes\n" ++
                    "  run <command>           Run command on current node (system.run)\n" ++
                    "  which <name>            Locate executable on node PATH (system.which)\n" ++
                    "  notify <title>          Show node notification (system.notify)\n" ++
                    "  ps                      List node background processes (process.list)\n" ++
                    "  spawn <command>         Spawn background process (process.spawn)\n" ++
                    "  poll <processId>        Poll process status (process.poll)\n" ++
                    "  stop <processId>        Stop process (process.stop)\n" ++
                    "  canvas <op> [args...]   Canvas ops: present|hide|navigate <url>|eval <js>|snapshot <path>\n" ++
                    "  approvals               List pending approvals\n" ++
                    "  approve <id>            Approve request by ID\n" ++
                    "  deny <id>               Deny request by ID\n" ++
                    "  gateway <verb> [url]   Gateway test: ping|echo|probe ws://host:port\n" ++
                    "  save                    Save current session/node to config\n" ++
                    "  quit/exit               Exit interactive mode\n");
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
                try runNodeCommand(allocator, ws_client, ctx, target_node, command);
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .which => {
                const name = parts.rest();
                if (name.len == 0) {
                    try stdout.writeAll("Usage: which <name>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("name", std.json.Value{ .string = name });
                try invokeNode(allocator, ws_client, ctx, target_node, "system.which", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .notify => {
                const title = parts.rest();
                if (title.len == 0) {
                    try stdout.writeAll("Usage: notify <title>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("title", std.json.Value{ .string = title });
                try invokeNode(allocator, ws_client, ctx, target_node, "system.notify", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .ps => {
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                try invokeNode(allocator, ws_client, ctx, target_node, "process.list", null);
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .spawn => {
                const command = parts.rest();
                if (command.len == 0) {
                    try stdout.writeAll("Usage: spawn <command>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                var cmd_arr = try buildJsonCommandArray(allocator, command);
                defer freeJsonStringArray(allocator, &cmd_arr);
                try params_obj.put("command", std.json.Value{ .array = cmd_arr });
                try invokeNode(allocator, ws_client, ctx, target_node, "process.spawn", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .poll => {
                const pid = parts.rest();
                if (pid.len == 0) {
                    try stdout.writeAll("Usage: poll <processId>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("processId", std.json.Value{ .string = pid });
                try invokeNode(allocator, ws_client, ctx, target_node, "process.poll", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .stop => {
                const pid = parts.rest();
                if (pid.len == 0) {
                    try stdout.writeAll("Usage: stop <processId>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("processId", std.json.Value{ .string = pid });
                try invokeNode(allocator, ws_client, ctx, target_node, "process.stop", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .canvas => {
                const rest = parts.rest();
                if (rest.len == 0) {
                    try stdout.writeAll("Usage: canvas <present|hide|navigate|eval|snapshot> [args...]\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var subparts = std.mem.splitScalar(u8, rest, ' ');
                const op = subparts.next() orelse continue;
                const arg = std.mem.trim(u8, subparts.rest(), " \t\r\n");

                if (std.mem.eql(u8, op, "present")) {
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.present", null);
                } else if (std.mem.eql(u8, op, "hide")) {
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.hide", null);
                } else if (std.mem.eql(u8, op, "navigate")) {
                    if (arg.len == 0) {
                        try stdout.writeAll("Usage: canvas navigate <url>\n");
                        continue;
                    }
                    var params_obj = std.json.ObjectMap.init(allocator);
                    defer params_obj.deinit();
                    try params_obj.put("url", std.json.Value{ .string = arg });
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.navigate", std.json.Value{ .object = params_obj });
                } else if (std.mem.eql(u8, op, "eval")) {
                    if (arg.len == 0) {
                        try stdout.writeAll("Usage: canvas eval <js>\n");
                        continue;
                    }
                    var params_obj = std.json.ObjectMap.init(allocator);
                    defer params_obj.deinit();
                    try params_obj.put("js", std.json.Value{ .string = arg });
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.eval", std.json.Value{ .object = params_obj });
                } else if (std.mem.eql(u8, op, "snapshot")) {
                    if (arg.len == 0) {
                        try stdout.writeAll("Usage: canvas snapshot <path>\n");
                        continue;
                    }
                    var params_obj = std.json.ObjectMap.init(allocator);
                    defer params_obj.deinit();
                    try params_obj.put("path", std.json.Value{ .string = arg });
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.snapshot", std.json.Value{ .object = params_obj });
                } else {
                    try stdout.print("Unknown canvas op: {s}\n", .{op});
                    continue;
                }

                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
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
            .gateway => {
                const verb_str = parts.next() orelse "";
                const url = parts.rest();

                if (verb_str.len == 0) {
                    try gateway_cmd.printHelp(stdout);
                    continue;
                }

                const verb = gateway_cmd.parseVerb(verb_str);
                if (verb == .unknown) {
                    try stdout.print("Unknown verb: {s}\n", .{verb_str});
                    try gateway_cmd.printHelp(stdout);
                    continue;
                }

                if (url.len == 0) {
                    try stdout.writeAll("Usage: gateway <verb> <url>\n");
                    try gateway_cmd.printHelp(stdout);
                    continue;
                }

                // Parse agent_id from URL path (e.g., /v1/agents/test/stream -> test)
                var agent_id: []const u8 = "test";
                if (std.mem.indexOf(u8, url, "/agents/")) |start| {
                    const after_agent = start + 8; // "/agents/" len
                    if (std.mem.indexOfPos(u8, url, after_agent, "/")) |end| {
                        agent_id = url[after_agent..end];
                    }
                }

                gateway_cmd.run(allocator, verb, url, cfg.token, agent_id, read_timeout_ms, cfg.insecure_tls, stdout) catch |err| {
                    try stdout.print("Gateway test failed: {s}\n", .{@errorName(err)});
                    continue;
                };
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
    if (std.mem.eql(u8, cmd, "which")) return .which;
    if (std.mem.eql(u8, cmd, "notify")) return .notify;
    if (std.mem.eql(u8, cmd, "ps")) return .ps;
    if (std.mem.eql(u8, cmd, "spawn")) return .spawn;
    if (std.mem.eql(u8, cmd, "poll")) return .poll;
    if (std.mem.eql(u8, cmd, "stop")) return .stop;
    if (std.mem.eql(u8, cmd, "canvas")) return .canvas;
    if (std.mem.eql(u8, cmd, "approvals")) return .approvals;
    if (std.mem.eql(u8, cmd, "approve")) return .approve;
    if (std.mem.eql(u8, cmd, "deny")) return .deny;
    if (std.mem.eql(u8, cmd, "gateway")) return .gateway;
    if (std.mem.eql(u8, cmd, "quit")) return .quit;
    if (std.mem.eql(u8, cmd, "exit")) return .exit;
    if (std.mem.eql(u8, cmd, "save")) return .save;
    return .unknown;
}

fn requestAndAwaitJsonPayloadText(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    method: []const u8,
    params: anytype,
    timeout_ms: u64,
) ![]u8 {
    const request = try requests.buildRequestPayload(allocator, method, params);
    defer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    try ws_client.send(request.payload);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (ws_client.is_connected and std.time.milliTimestamp() < deadline) {
        const msg = ws_client.receive() catch |err| {
            logger.err("WebSocket receive failed while waiting for {s}: {s}", .{ method, @errorName(err) });
            return err;
        };
        if (msg) |payload| {
            defer allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
                continue;
            };
            defer parsed.deinit();

            const frame = parsed.value;
            if (frame != .object) continue;
            const t = frame.object.get("type") orelse continue;
            if (t != .string or !std.mem.eql(u8, t.string, "res")) continue;

            const idv = frame.object.get("id") orelse continue;
            if (idv != .string or !std.mem.eql(u8, idv.string, request.id)) continue;

            if (frame.object.get("payload")) |pv| {
                return std.json.Stringify.valueAlloc(allocator, pv, .{ .whitespace = .indent_2 });
            }
            return std.json.Stringify.valueAlloc(allocator, frame, .{ .whitespace = .indent_2 });
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    return error.Timeout;
}

fn requestSessionsList(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !void {
    const sessions_proto = @import("../protocol/sessions.zig");
    const params = sessions_proto.SessionsListParams{
        .includeGlobal = true,
        .includeUnknown = true,
    };
    const request = try requests.buildRequestPayload(allocator, "sessions.list", params);
    defer allocator.free(request.payload);

    // Only mark pending if send succeeds.
    logger.info("Requesting sessions.list", .{});
    try ws_client.send(request.payload);
    ctx.setPendingSessionsRequest(request.id);
}

fn requestNodesList(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !void {
    const params = nodes_proto.NodeListParams{};
    const request = try requests.buildRequestPayload(allocator, "node.list", params);
    defer allocator.free(request.payload);

    // Only mark pending if send succeeds.
    logger.info("Requesting node.list", .{});
    try ws_client.send(request.payload);
    ctx.setPendingNodesRequest(request.id);
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

fn parseCommandLineArgs(allocator: std.mem.Allocator, cmdline: []const u8) !std.ArrayList([]u8) {
    // Very small shell-ish tokenizer:
    // - splits on whitespace
    // - supports single and double quotes
    // - supports backslash escaping outside quotes and inside double quotes
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var cur = std.ArrayList(u8).empty;
    defer cur.deinit(allocator);

    const State = enum { none, single, double };
    var state: State = .none;

    var i: usize = 0;
    while (i < cmdline.len) : (i += 1) {
        const c = cmdline[i];

        // Whitespace ends token (only when not in quotes)
        if (state == .none and (c == ' ' or c == '\t' or c == '\n' or c == '\r')) {
            if (cur.items.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, cur.items));
                cur.clearRetainingCapacity();
            }
            continue;
        }

        // Quote handling
        if (state == .none and c == '\'') {
            state = .single;
            continue;
        }
        if (state == .none and c == '"') {
            state = .double;
            continue;
        }
        if (state == .single and c == '\'') {
            state = .none;
            continue;
        }
        if (state == .double and c == '"') {
            state = .none;
            continue;
        }

        // Backslash escaping
        if ((state == .none or state == .double) and c == '\\' and i + 1 < cmdline.len) {
            i += 1;
            try cur.append(allocator, cmdline[i]);
            continue;
        }

        try cur.append(allocator, c);
    }

    if (cur.items.len > 0) {
        try out.append(allocator, try allocator.dupe(u8, cur.items));
    }

    return out;
}

fn buildJsonCommandArray(allocator: std.mem.Allocator, cmdline: []const u8) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    errdefer arr.deinit();

    var argv = try parseCommandLineArgs(allocator, cmdline);
    defer {
        for (argv.items) |s| allocator.free(s);
        argv.deinit(allocator);
    }

    for (argv.items) |part| {
        if (part.len == 0) continue;
        try arr.append(std.json.Value{ .string = try allocator.dupe(u8, part) });
    }

    return arr;
}

fn freeJsonStringArray(allocator: std.mem.Allocator, arr: *std.json.Array) void {
    for (arr.items) |item| {
        if (item == .string) allocator.free(item.string);
    }
    arr.deinit();
}

fn invokeNode(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    target_node: []const u8,
    command: []const u8,
    params_value: ?std.json.Value,
) !void {
    const idempotency_key = try requests.makeRequestId(allocator);
    defer allocator.free(idempotency_key);

    const params = nodes_proto.NodeInvokeParams{
        .nodeId = target_node,
        .command = command,
        .params = params_value,
        .idempotencyKey = idempotency_key,
    };

    const request = try requests.buildRequestPayload(allocator, "node.invoke", params);
    defer allocator.free(request.payload);

    // Mark as pending so response routing can populate ctx.node_result.
    ctx.setPendingNodeInvokeRequest(request.id);

    logger.info("Invoking node {s}: {s}", .{ target_node, command });
    try ws_client.send(request.payload);
}

fn awaitNodeResultOwned(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !?[]u8 {
    // Wait for result
    var wait_attempts: u32 = 0;
    while (wait_attempts < 150 and ctx.node_result == null) : (wait_attempts += 1) {
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
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    if (ctx.node_result) |result| {
        const owned = try allocator.dupe(u8, result);
        ctx.clearNodeResult();
        return owned;
    }

    return null;
}

fn awaitAndPrintNodeResult(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !void {
    const res = try awaitNodeResultOwned(allocator, ws_client, ctx);
    if (res) |owned| {
        defer allocator.free(owned);
        try printNodeResult(allocator, owned);
    } else {
        logger.info("Command sent. Waiting for result timed out.", .{});
    }
}

fn readAllowlistFile(allocator: std.mem.Allocator, path: []const u8) ![]const []u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    // Supported formats:
    // 1) ["cmd1", "cmd2"]
    // 2) {"allowlist": ["cmd1", ...]}
    var arr_val: ?std.json.Value = null;
    if (parsed.value == .array) {
        arr_val = parsed.value;
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("allowlist")) |v| {
            if (v == .array) arr_val = v;
        }
    }

    const arr = arr_val orelse return error.InvalidArguments;

    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    for (arr.array.items) |it| {
        if (it == .string and it.string.len > 0) {
            try out.append(allocator, try allocator.dupe(u8, it.string));
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn parseAllowlistFromInvokeResult(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayList([]u8) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var allow = std.ArrayList([]u8).empty;
    errdefer {
        for (allow.items) |s| allocator.free(s);
        allow.deinit(allocator);
    }

    if (parsed.value == .object) {
        const obj = parsed.value.object;

        // Accept both shapes:
        // 1) node.invoke response: { ok, nodeId, command, payload: { allowlist: [...] } }
        // 2) raw handler payload (future-proof): { allowlist: [...] }
        var alist_opt: ?std.json.Value = null;

        if (obj.get("payload")) |payload| {
            if (payload == .object) {
                if (payload.object.get("allowlist")) |alist| alist_opt = alist;
            }
        }
        if (alist_opt == null) {
            if (obj.get("allowlist")) |alist| alist_opt = alist;
        }

        if (alist_opt) |alist| {
            if (alist == .array) {
                for (alist.array.items) |it| {
                    if (it == .string) try allow.append(allocator, try allocator.dupe(u8, it.string));
                }
            }
        }
    }

    return allow;
}

fn addExecAllowlistEntries(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    target_node: []const u8,
    new_entries: []const []const u8,
) !u32 {
    // 1) Get current approvals
    try invokeNode(allocator, ws_client, ctx, target_node, "system.execApprovals.get", null);
    const raw_owned = (try awaitNodeResultOwned(allocator, ws_client, ctx)) orelse {
        return error.Unexpected;
    };
    defer allocator.free(raw_owned);

    var allow = try parseAllowlistFromInvokeResult(allocator, raw_owned);
    defer {
        for (allow.items) |s| allocator.free(s);
        allow.deinit(allocator);
    }

    var added: u32 = 0;
    for (new_entries) |entry| {
        if (entry.len == 0) continue;
        var exists = false;
        for (allow.items) |s| {
            if (std.mem.eql(u8, s, entry)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try allow.append(allocator, try allocator.dupe(u8, entry));
            added += 1;
        }
    }

    if (added == 0) return 0;

    // 2) Set approvals (mode=allowlist)
    var params_obj = std.json.ObjectMap.init(allocator);
    defer params_obj.deinit();
    try params_obj.put("mode", std.json.Value{ .string = "allowlist" });

    var allow_arr = std.json.Array.init(allocator);
    defer {
        for (allow_arr.items) |it| if (it == .string) allocator.free(it.string);
        allow_arr.deinit();
    }

    for (allow.items) |s| {
        try allow_arr.append(std.json.Value{ .string = try allocator.dupe(u8, s) });
    }
    try params_obj.put("allowlist", std.json.Value{ .array = allow_arr });

    try invokeNode(allocator, ws_client, ctx, target_node, "system.execApprovals.set", std.json.Value{ .object = params_obj });
    _ = try awaitNodeResultOwned(allocator, ws_client, ctx);

    return added;
}

fn printNodeResult(allocator: std.mem.Allocator, result: []const u8) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();

    // Try parse JSON for nicer output.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch null;
    if (parsed) |tree| {
        defer tree.deinit();

        if (tree.value == .object) {
            const obj = tree.value.object;
            // Common shape for system.run in this repo: { stdout, stderr, exitCode }
            if (obj.get("stdout") != null or obj.get("stderr") != null or obj.get("exitCode") != null) {
                const exit_code = obj.get("exitCode");
                if (exit_code) |ec| {
                    switch (ec) {
                        .integer => try stdout.print("exitCode: {d}\n", .{ec.integer}),
                        .float => try stdout.print("exitCode: {d}\n", .{@as(i64, @intFromFloat(ec.float))}),
                        else => {},
                    }
                }

                if (obj.get("stdout")) |outv| {
                    if (outv == .string and outv.string.len > 0) {
                        try stdout.writeAll("stdout:\n");
                        try stdout.writeAll(outv.string);
                        if (!std.mem.endsWith(u8, outv.string, "\n")) try stdout.writeByte('\n');
                    }
                }
                if (obj.get("stderr")) |errv| {
                    if (errv == .string and errv.string.len > 0) {
                        try stdout.writeAll("stderr:\n");
                        try stdout.writeAll(errv.string);
                        if (!std.mem.endsWith(u8, errv.string, "\n")) try stdout.writeByte('\n');
                    }
                }
                return;
            }
        }

        // Generic JSON pretty print.
        try stdout.print("{f}\n", .{std.json.fmt(tree.value, .{ .whitespace = .indent_2 })});
        return;
    }

    try stdout.print("Result: {s}\n", .{result});
}

fn runNodeCommand(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    target_node: []const u8,
    command: []const u8,
) !void {
    var params_json = std.json.ObjectMap.init(allocator);
    defer params_json.deinit();

    var command_arr = try buildJsonCommandArray(allocator, command);
    defer freeJsonStringArray(allocator, &command_arr);

    try params_json.put("command", std.json.Value{ .array = command_arr });

    try invokeNode(allocator, ws_client, ctx, target_node, "system.run", std.json.Value{ .object = params_json });
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

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}
