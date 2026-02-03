const std = @import("std");
const builtin = @import("builtin");
const unified_config = @import("unified_config.zig");
const websocket_client = @import("client/websocket_client.zig");
const logger = @import("utils/logger.zig");

fn ensureParentDir(path: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
}

fn waitForHelloOkAndToken(
    allocator: std.mem.Allocator,
    ws: *websocket_client.WebSocketClient,
    timeout_ms: u64,
) !?[]u8 {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (ws.is_connected and std.time.milliTimestamp() < deadline) {
        ws.poll() catch {};

        const msg = try ws.receive();
        if (msg) |payload| {
            defer allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
                continue;
            };
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const t = parsed.value.object.get("type") orelse continue;
            if (t != .string) continue;

            if (std.mem.eql(u8, t.string, "event")) {
                const ev = parsed.value.object.get("event") orelse continue;
                if (ev == .string and std.mem.eql(u8, ev.string, "device.pair.requested")) {
                    logger.warn("Gateway requires device approval. Approve the pending request in Control UI, then re-run --node-register.", .{});
                }
                continue;
            }

            if (!std.mem.eql(u8, t.string, "res")) continue;

            const okv = parsed.value.object.get("ok") orelse continue;
            if (okv != .bool or !okv.bool) {
                if (parsed.value.object.get("error")) |errv| {
                    if (errv == .object) {
                        if (errv.object.get("message")) |mv| {
                            if (mv == .string) logger.err("connect failed: {s}", .{mv.string});
                        }
                    }
                }
                return error.ConnectionFailed;
            }

            const pv = parsed.value.object.get("payload") orelse continue;
            if (pv != .object) continue;
            const ptype = pv.object.get("type") orelse continue;
            if (!(ptype == .string and std.mem.eql(u8, ptype.string, "hello-ok"))) continue;

            // Optional auth update (device token)
            if (pv.object.get("auth")) |auth| {
                if (auth == .object) {
                    if (auth.object.get("deviceToken")) |tok| {
                        if (tok == .string and tok.string.len > 0) {
                            return try allocator.dupe(u8, tok.string);
                        }
                    }
                }
            }

            return null;
        }

        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    return error.Timeout;
}

fn promptLineAlloc(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var out = std.fs.File.stdout().deprecatedWriter();
    try out.print("{s}", .{label});

    var in = std.fs.File.stdin().deprecatedReader();
    var buf: [2048]u8 = undefined;
    const line = (try in.readUntilDelimiterOrEof(&buf, '\n')) orelse "";
    return allocator.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
}

fn backupConfigIfExists(allocator: std.mem.Allocator, path: []const u8) void {
    _ = allocator;
    // Best-effort: if file exists, rename to .bak.<unixms>
    const now_ms: i64 = std.time.milliTimestamp();
    const bak = std.fmt.allocPrint(std.heap.page_allocator, "{s}.bak.{d}", .{ path, now_ms }) catch return;
    defer std.heap.page_allocator.free(bak);

    std.fs.cwd().rename(path, bak) catch {
        // If rename fails (e.g., cross-device), try copy.
        const src = std.fs.cwd().openFile(path, .{}) catch return;
        defer src.close();
        const data = src.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return;
        defer std.heap.page_allocator.free(data);
        const dst = std.fs.cwd().createFile(bak, .{ .truncate = true }) catch return;
        defer dst.close();
        _ = dst.writeAll(data) catch {};
    };
}

fn writeDefaultConfig(allocator: std.mem.Allocator, path: []const u8, gateway_url: []const u8, gateway_token: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Keep it minimal + strict. No legacy keys.
    // IMPORTANT: build JSON via stringify to ensure proper escaping.
    const Doc = struct {
        gateway: struct { wsUrl: []const u8, authToken: []const u8 },
        node: struct {
            enabled: bool,
            nodeId: []const u8,
            nodeToken: []const u8,
            displayName: []const u8,
            deviceIdentityPath: []const u8,
            execApprovalsPath: []const u8,
        },
        operator: struct { enabled: bool },
        logging: struct { level: []const u8 },
    };

    const doc: Doc = .{
        .gateway = .{ .wsUrl = gateway_url, .authToken = gateway_token },
        .node = .{
            .enabled = true,
            .nodeId = "",
            .nodeToken = "",
            .displayName = "Deano Windows",
            .deviceIdentityPath = "%APPDATA%\\ZiggyStarClaw\\node-device.json",
            .execApprovalsPath = "%APPDATA%\\ZiggyStarClaw\\exec-approvals.json",
        },
        .operator = .{ .enabled = false },
        .logging = .{ .level = "info" },
    };

    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const writer = &out.writer;
    try std.json.Stringify.value(doc, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, writer);
    const content = try out.toOwnedSlice();
    defer allocator.free(content);

    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
    try f.writeAll("\n");
}

fn saveUpdatedNodeConfig(
    allocator: std.mem.Allocator,
    path: []const u8,
    node_id: ?[]const u8,
    node_token: ?[]const u8,
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

    if (node_id) |nid| {
        try node_val.object.put("nodeId", std.json.Value{ .string = nid });
    }
    if (node_token) |tok| {
        try node_val.object.put("nodeToken", std.json.Value{ .string = tok });
    }

    const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(out);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const wf = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer wf.close();
    try wf.writeAll(out);
    try wf.writeAll("\n");
}

pub fn run(allocator: std.mem.Allocator, config_path: ?[]const u8, insecure_tls: bool) !void {
    const cfg_path = config_path orelse try unified_config.defaultConfigPath(allocator);
    defer if (config_path == null) allocator.free(cfg_path);

    logger.info("node-register using config: {s}", .{cfg_path});

    var cfg = unified_config.load(allocator, cfg_path) catch |err| blk: {
        if (err != error.ConfigNotFound and err != error.SyntaxError and err != error.UnknownField) return err;

        if (err == error.ConfigNotFound) {
            logger.info("config not found; creating {s}", .{cfg_path});
        } else {
            logger.err("config invalid ({s}); backing up and recreating {s}", .{ @errorName(err), cfg_path });
            backupConfigIfExists(allocator, cfg_path);
        }

        const url = try promptLineAlloc(allocator, "Gateway WS URL (e.g. ws://wizball.tail...:18789): ");
        defer allocator.free(url);
        if (url.len == 0) return error.InvalidArguments;

        const secret_prompt = @import("utils/secret_prompt.zig");
        const tok = try secret_prompt.readSecretAlloc(allocator, "Gateway auth token:");
        defer allocator.free(tok);
        if (tok.len == 0) return error.InvalidArguments;
        logger.info("(received {d} chars)", .{tok.len});

        try writeDefaultConfig(allocator, cfg_path, url, tok);
        break :blk try unified_config.load(allocator, cfg_path);
    };
    defer cfg.deinit(allocator);

    ensureParentDir(cfg.node.deviceIdentityPath);
    ensureParentDir(cfg.node.execApprovalsPath);
    if (cfg.logging.file) |p| ensureParentDir(p);

    if (cfg.gateway.wsUrl.len == 0 or cfg.gateway.authToken.len == 0) {
        logger.err("Config missing gateway.wsUrl and/or gateway.authToken", .{});
        return error.InvalidArguments;
    }

    const ws_url = try unified_config.normalizeGatewayWsUrl(allocator, cfg.gateway.wsUrl);
    defer allocator.free(ws_url);

    // Ensure identity exists, and use its device id as our node id (simple + stable).
    const identity = try @import("client/device_identity.zig").loadOrCreate(allocator, cfg.node.deviceIdentityPath);
    defer {
        var ident = identity;
        ident.deinit(allocator);
    }
    logger.info("node-register device_id={s}", .{identity.device_id});
    logger.info("node-register public_key={s}", .{identity.public_key_b64});

    if (cfg.node.nodeId.len == 0 or !std.mem.eql(u8, cfg.node.nodeId, identity.device_id)) {
        logger.info("Saving node.nodeId to config.json: {s}", .{identity.device_id});
        try saveUpdatedNodeConfig(allocator, cfg_path, identity.device_id, null);
        allocator.free(cfg.node.nodeId);
        cfg.node.nodeId = try allocator.dupe(u8, identity.device_id);
    }

    logger.info("Connecting once as node-host to obtain/verify device token...", .{});

    var ws = websocket_client.WebSocketClient.init(
        allocator,
        ws_url,
        // Keep websocket handshake token as the shared gateway token.
        cfg.gateway.authToken,
        insecure_tls,
        null,
    );
    defer ws.deinit();

    ws.setDeviceIdentityPath(cfg.node.deviceIdentityPath);
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

    // Prefer device token if we have one; otherwise use gateway token.
    const preferred = if (cfg.node.nodeToken.len > 0) cfg.node.nodeToken else cfg.gateway.authToken;
    ws.setConnectAuthToken(preferred);
    ws.setDeviceAuthToken(preferred);

    try ws.connect();

    const token = try waitForHelloOkAndToken(allocator, &ws, 10_000);
    defer if (token) |t| allocator.free(t);

    if (token) |t| {
        if (!std.mem.eql(u8, cfg.node.nodeToken, t)) {
            logger.info("Saving node.nodeToken to config.json (device token)", .{});
            try saveUpdatedNodeConfig(allocator, cfg_path, null, t);
            allocator.free(cfg.node.nodeToken);
            cfg.node.nodeToken = try allocator.dupe(u8, t);
        }
    }

    logger.info("node-register complete.", .{});
}
