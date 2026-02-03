const std = @import("std");
const builtin = @import("builtin");
const unified_config = @import("unified_config.zig");
const websocket_client = @import("client/websocket_client.zig");
const logger = @import("utils/logger.zig");
// (secret_prompt unused in node-register; pairing is RPC-driven)
const requests = @import("protocol/requests.zig");

fn ensureParentDir(path: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
}

fn sendRequestAwait(
    allocator: std.mem.Allocator,
    ws: *websocket_client.WebSocketClient,
    method: []const u8,
    params: anytype,
    timeout_ms: u64,
) ![]u8 {
    const req = try requests.buildRequestPayload(allocator, method, params);
    defer allocator.free(req.id);
    defer allocator.free(req.payload);

    try ws.send(req.payload);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (ws.is_connected and std.time.milliTimestamp() < deadline) {
        const msg = ws.receive() catch |err| {
            logger.warn("recv failed while awaiting {s}: {s}", .{ method, @errorName(err) });
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
            if (t != .string) continue;

            if (std.mem.eql(u8, t.string, "res")) {
                const idv = frame.object.get("id") orelse continue;
                if (idv != .string) continue;
                if (!std.mem.eql(u8, idv.string, req.id)) continue;

                if (frame.object.get("payload")) |pv| {
                    return try std.json.Stringify.valueAlloc(allocator, pv, .{ .whitespace = .indent_2 });
                }
                return try std.json.Stringify.valueAlloc(allocator, frame, .{ .whitespace = .indent_2 });
            }
        } else {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }

    return error.Timeout;
}

fn waitForHelloOk(allocator: std.mem.Allocator, ws: *websocket_client.WebSocketClient, timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (ws.is_connected and std.time.milliTimestamp() < deadline) {
        const msg = try ws.receive();
        if (msg) |payload| {
            defer allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
                continue;
            };
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const t = parsed.value.object.get("type") orelse continue;
            if (t != .string or !std.mem.eql(u8, t.string, "res")) continue;

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
            if (ptype == .string and std.mem.eql(u8, ptype.string, "hello-ok")) {
                return;
            }
        } else {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
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
        // If rename fails (e.g., cross-device), try copy+truncate.
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
    const content = try std.fmt.allocPrint(
        allocator,
        \\
        \\{{
        \\  \"gateway\": {{
        \\    \"url\": \"{s}\",
        \\    \"authToken\": \"{s}\"
        \\  }},
        \\  \"node\": {{
        \\    \"enabled\": true,
        \\    \"id\": \"\",
        \\    \"token\": \"\",
        \\    \"displayName\": \"Deano Windows\",
        \\    \"deviceIdentityPath\": \"%APPDATA%\\\\ZiggyStarClaw\\\\node-device.json\",
        \\    \"execApprovalsPath\": \"%APPDATA%\\\\ZiggyStarClaw\\\\exec-approvals.json\"
        \\  }},
        \\  \"operator\": {{ \"enabled\": false }},
        \\  \"logging\": {{ \"level\": \"info\" }}
        \\}}\n
    ,
        .{ gateway_url, gateway_token },
    );
    defer allocator.free(content);

    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
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

        // Prompt for gateway info (required for pairing RPC).
        const url = try promptLineAlloc(allocator, "Gateway WS URL (e.g. ws://wizball.tail...:18789): ");
        defer allocator.free(url);
        if (url.len == 0) return error.InvalidArguments;

        const secret_prompt = @import("utils/secret_prompt.zig");
        const tok = try secret_prompt.readSecretAlloc(allocator, "Gateway auth token:");
        defer allocator.free(tok);
        if (tok.len == 0) return error.InvalidArguments;

        try writeDefaultConfig(allocator, cfg_path, url, tok);
        // Reload now that we have a config.
        break :blk try unified_config.load(allocator, cfg_path);
    };
    defer cfg.deinit(allocator);

    // Ensure directories exist for stable paths.
    ensureParentDir(cfg.node.deviceIdentityPath);
    ensureParentDir(cfg.node.execApprovalsPath);
    if (cfg.logging.file) |p| ensureParentDir(p);

    const ws_url = try unified_config.normalizeGatewayWsUrl(allocator, cfg.gateway.url);
    defer allocator.free(ws_url);

    // Ensure identity exists and print the device id so we can mint the correct node token.
    const identity = try @import("client/device_identity.zig").loadOrCreate(allocator, cfg.node.deviceIdentityPath);
    defer {
        var ident = identity;
        ident.deinit(allocator);
    }
    logger.info("node-register device_id={s}", .{identity.device_id});
    logger.info("node-register public_key={s}", .{identity.public_key_b64});

    // 1) If we already have a token, verify it by attempting a node connect.
    if (cfg.node.token.len > 0) {
        if (try verifyNodeToken(allocator, ws_url, &cfg, insecure_tls)) {
            logger.info("node-register: node token verified (connected as node).", .{});
            return;
        }
    }

    // 2) Start RPC-driven pairing flow.
    logger.info("node-register: requesting node pairing via RPC (node.pair.request)", .{});
    logger.info("This will create a pending request that must be approved in Control UI.", .{});

    var op_ws = websocket_client.WebSocketClient.init(
        allocator,
        ws_url,
        cfg.gateway.authToken,
        insecure_tls,
        null,
    );
    defer op_ws.deinit();

    // We *intentionally* do not require an operator device identity pairing for node-register.
    // The gateway auth token is sufficient.
    op_ws.use_device_identity = false;
    op_ws.setConnectAuthToken(cfg.gateway.authToken);
    op_ws.setConnectProfile(.{
        .role = "operator",
        .scopes = &.{ "operator.admin", "operator.approvals", "operator.pairing" },
        .client_id = "cli",
        .client_mode = "cli",
    });
    op_ws.setReadTimeout(15000);

    try op_ws.connect();
    try waitForHelloOk(allocator, &op_ws, 8000);

    const display_name = cfg.node.displayName orelse "ZiggyStarClaw Node";
    // IMPORTANT: OpenClaw's nodeId is the identifier used for node token verification.
    // Our connect/signing path uses the device identity's device_id as the device auth id,
    // so we must pair/approve using the SAME value.
    const node_id = identity.device_id;

    // If config.json contains a different node.id, we'll overwrite it after approval.
    if (cfg.node.id.len > 0 and !std.mem.eql(u8, cfg.node.id, node_id)) {
        logger.warn("config node.id differs from device identity; will overwrite: {s} -> {s}", .{ cfg.node.id, node_id });
    }

    const req_payload = try sendRequestAwait(
        allocator,
        &op_ws,
        "node.pair.request",
        .{
            // NOTE: OpenClaw gateway expects nodeId (not deviceId/publicKey).
            .nodeId = node_id,
            .displayName = display_name,
            .platform = @tagName(builtin.target.os.tag),
            // optional metadata; keep minimal and schema-safe
            .caps = &.{"system"},
            .commands = &.{
                "system.run",
                "system.which",
                "system.notify",
                "system.execApprovals.get",
                "system.execApprovals.set",
            },
            .silent = false,
        },
        8000,
    );
    defer allocator.free(req_payload);

    var request_id: ?[]u8 = null;
    defer if (request_id) |v| allocator.free(v);
    {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, req_payload, .{}) catch null;
        if (parsed) |*p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("request")) |rv| {
                    if (rv == .object) {
                        if (rv.object.get("requestId")) |ridv| {
                            if (ridv == .string and ridv.string.len > 0) {
                                request_id = try allocator.dupe(u8, ridv.string);
                            }
                        }
                    }
                }
            }
        }
    }

    if (request_id == null) {
        logger.warn("node.pair.request response did not include request.requestId. Raw payload:", .{});
        logger.warn("{s}", .{req_payload});
    }

    logger.info("", .{});
    logger.info("Next steps:", .{});
    logger.info("  1) Open Control UI on the gateway", .{});
    logger.info("  2) Go to Nodes / Pairing requests (or similar)", .{});
    logger.info("  3) Approve the pending node request for nodeId={s}", .{node_id});
    if (request_id) |rid| {
        logger.info("     (CLI: openclaw nodes approve {s})", .{rid});
    } else {
        logger.info("     (CLI: openclaw nodes pending  # then approve the requestId shown)", .{});
    }
    logger.info("  4) Leave this window open; we'll poll until the node is paired", .{});
    logger.info("", .{});

    // 3) Poll node.pair.list until the node appears in paired, then store the minted token.
    const verify_deadline_ms: i64 = std.time.milliTimestamp() + (5 * 60 * 1000);
    while (std.time.milliTimestamp() < verify_deadline_ms) {
        const list_payload = sendRequestAwait(
            allocator,
            &op_ws,
            "node.pair.list",
            .{},
            8000,
        ) catch |err| {
            if (err == error.Timeout) {
                std.Thread.sleep(1000 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        defer allocator.free(list_payload);

        const tok = extractTokenFromPairList(allocator, list_payload, node_id) catch null;
        if (tok) |t| {
            defer allocator.free(t);

            // Persist node.id + node.token.
            try saveUpdatedNodeAuth(allocator, cfg_path, node_id, t);
            logger.info("Approved! Saved node auth to config.json (node.id + node.token).", .{});

            // Update in-memory cfg for immediate verify.
            allocator.free(cfg.node.token);
            cfg.node.token = try allocator.dupe(u8, t);
            allocator.free(cfg.node.id);
            cfg.node.id = try allocator.dupe(u8, node_id);

            // Finally: verify node can connect.
            if (try verifyNodeToken(allocator, ws_url, &cfg, insecure_tls)) {
                logger.info("node-register: node token verified (connected as node).", .{});
                printTestOneLiner();
                return;
            }

            logger.err("node-register: received token, but node connect still failed. Check gateway logs.", .{});
            return error.ConnectionFailed;
        }

        // Not approved yet.
        std.Thread.sleep(1500 * std.time.ns_per_ms);
    }

    logger.err("Timed out waiting for approval.", .{});
    return error.Timeout;
}

fn extractTokenFromPairList(
    allocator: std.mem.Allocator,
    json_payload: []const u8,
    node_id: []const u8,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const pairedv = parsed.value.object.get("paired") orelse return null;
    if (pairedv != .array) return null;

    for (pairedv.array.items) |item| {
        if (item != .object) continue;
        const nidv = item.object.get("nodeId") orelse continue;
        if (nidv != .string) continue;
        if (!std.mem.eql(u8, nidv.string, node_id)) continue;

        const tokv = item.object.get("token") orelse continue;
        if (tokv != .string or tokv.string.len == 0) continue;

        return try allocator.dupe(u8, tokv.string);
    }

    return null;
}

fn verifyNodeToken(
    allocator: std.mem.Allocator,
    ws_url: []const u8,
    cfg: *unified_config.UnifiedConfig,
    insecure_tls: bool,
) !bool {
    var ws = websocket_client.WebSocketClient.init(
        allocator,
        ws_url,
        cfg.gateway.authToken,
        insecure_tls,
        null,
    );
    defer ws.deinit();

    ws.setConnectAuthToken(cfg.gateway.authToken);
    ws.setDeviceAuthToken(cfg.node.token);
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
        logger.debug("node connect failed: {s}", .{@errorName(err)});
        return false;
    };

    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 3000) {
        _ = ws.receive() catch {};
        if (!ws.is_connected) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    if (ws.is_connected) return true;

    const reason = ws.last_close_reason orelse "";
    if (reason.len > 0) logger.warn("node connect closed: {s}", .{reason});
    return false;
}

fn saveUpdatedNodeAuth(
    allocator: std.mem.Allocator,
    path: []const u8,
    node_id: ?[]const u8,
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

    try node_val.object.put("token", std.json.Value{ .string = token });
    if (node_id) |nid| {
        try node_val.object.put("id", std.json.Value{ .string = nid });
    }

    const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(out);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const wf = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer wf.close();
    try wf.writeAll(out);
}

fn printTestOneLiner() void {
    // Best-effort: this is for Windows users.
    var out = std.fs.File.stdout().deprecatedWriter();
    out.writeAll("\nPowerShell quick test (runs node-mode using unified config):\n") catch {};
    out.writeAll("  $cfg=Join-Path $env:APPDATA 'ZiggyStarClaw\\config.json'; .\\ziggystarclaw-cli.exe --node-mode --config $cfg --as-node --no-operator --log-level debug\n") catch {};
}
