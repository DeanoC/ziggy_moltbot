const std = @import("std");
const unified_config = @import("unified_config.zig");
const websocket_client = @import("client/websocket_client.zig");
const logger = @import("utils/logger.zig");
const secret_prompt = @import("utils/secret_prompt.zig");

fn ensureParentDir(path: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
}

pub fn run(allocator: std.mem.Allocator, config_path: ?[]const u8, insecure_tls: bool) !void {
    const cfg_path = config_path orelse try unified_config.defaultConfigPath(allocator);
    defer if (config_path == null) allocator.free(cfg_path);

    logger.info("node-register using config: {s}", .{cfg_path});

    var cfg = try unified_config.load(allocator, cfg_path);
    defer cfg.deinit(allocator);

    // Ensure directories exist for stable paths.
    ensureParentDir(cfg.node.deviceIdentityPath);
    ensureParentDir(cfg.node.execApprovalsPath);
    if (cfg.logging.file) |p| ensureParentDir(p);

    const ws_url = try unified_config.normalizeGatewayWsUrl(allocator, cfg.gateway.url);
    defer allocator.free(ws_url);

    // Attempt connect as node. If it fails due to signature invalid, prompt for node token.
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        logger.info("node-register connect attempt {d}/10", .{attempt + 1});

        var ws = websocket_client.WebSocketClient.init(
            allocator,
            ws_url,
            cfg.gateway.authToken,
            insecure_tls,
            null,
        );
        defer ws.deinit();

        ws.setConnectAuthToken(cfg.gateway.authToken);
        ws.setDeviceAuthToken(cfg.node.deviceToken);
        ws.setConnectProfile(.{
            .role = "node",
            .scopes = &.{},
            .client_id = "node-host",
            .client_mode = "node",
        });
        ws.setConnectNodeMetadata(.{
            .caps = &.{"system"},
            .commands = &.{
                "system.run",
                "system.which",
                "system.notify",
                "system.execApprovals.get",
                "system.execApprovals.set",
            },
        });
        ws.setDeviceIdentityPath(cfg.node.deviceIdentityPath);
        ws.setReadTimeout(250);

        ws.connect() catch |err| {
            logger.err("connect() failed: {s}", .{@errorName(err)});
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };

        // Poll for a short time to see if we immediately get closed with an auth error.
        const start = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start < 3000) {
            _ = ws.receive() catch {};
            if (!ws.is_connected) break;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }

        if (ws.is_connected) {
            logger.info("node-register: connected successfully.", .{});
            return;
        }

        const reason = ws.last_close_reason orelse "";
        if (std.mem.indexOf(u8, reason, "pairing required") != null) {
            logger.err("Pairing required. Approve the device in Control UI, then re-run node-register.", .{});
            return error.PairingRequired;
        }
        if (std.mem.indexOf(u8, reason, "device signature invalid") != null or
            std.mem.indexOf(u8, reason, "unauthorized role") != null)
        {
            logger.err("Node token rejected ({s}).", .{reason});
            // Ask user for node token
            const tok = try secret_prompt.readSecretAlloc(allocator, "Paste ROLE=node device token (will be stored in config.json):");
            defer allocator.free(tok);

            // Replace in-memory token
            allocator.free(cfg.node.deviceToken);
            cfg.node.deviceToken = try allocator.dupe(u8, tok);

            // Write back config (minimal rewrite)
            try saveUpdatedNodeToken(allocator, cfg_path, cfg.node.deviceToken);

            logger.info("Updated node.deviceToken in config. Retrying...", .{});
            continue;
        }

        logger.err("Disconnected: {s}", .{reason});
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    return error.ConnectionFailed;
}

fn saveUpdatedNodeToken(allocator: std.mem.Allocator, path: []const u8, token: []const u8) !void {
    // NOTE: This is a deliberately tiny write-back: we parse the JSON as Value and update node.deviceToken,
    // preserving unknown fields if any (but unified config parser rejects unknown fields).
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
    try node_val.object.put("deviceToken", std.json.Value{ .string = token });

    const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(out);

    // Ensure parent dir exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const wf = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer wf.close();
    try wf.writeAll(out);
}
