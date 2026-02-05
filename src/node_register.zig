const std = @import("std");
const builtin = @import("builtin");
const unified_config = @import("unified_config.zig");
const node_platform = @import("node/node_platform.zig");
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
    const deadline = node_platform.nowMs() + @as(i64, @intCast(timeout_ms));
    while (ws.is_connected and node_platform.nowMs() < deadline) {
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
                // Surface pairing required as a distinct error so the caller can guide UX.
                if (parsed.value.object.get("error")) |errv| {
                    if (errv == .object) {
                        if (errv.object.get("message")) |mv| {
                            if (mv == .string) {
                                if (std.mem.indexOf(u8, mv.string, "pairing required") != null) {
                                    return error.PairingRequired;
                                }
                            }
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

        node_platform.sleepMs(20);
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
    const now_ms: i64 = node_platform.nowMs();
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

fn bestEffortDefaultName(allocator: std.mem.Allocator) ![]u8 {
    const platform = @tagName(builtin.target.os.tag);

    // Prefer HOSTNAME/COMPUTERNAME env vars.
    const host = blk: {
        if (builtin.target.os.tag == .windows) {
            const v = std.process.getEnvVarOwned(allocator, "COMPUTERNAME") catch null;
            if (v) |s| break :blk s;
        }
        const v = std.process.getEnvVarOwned(allocator, "HOSTNAME") catch null;
        if (v) |s| break :blk s;

        // POSIX fallback
        if (builtin.target.os.tag != .windows) {
            var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const name = std.posix.gethostname(&buf) catch null;
            if (name) |slice| break :blk try allocator.dupe(u8, slice);
        }
        break :blk try allocator.dupe(u8, "node");
    };

    defer allocator.free(host);

    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ host, platform });
}

pub fn writeDefaultConfig(allocator: std.mem.Allocator, path: []const u8, gateway_url: []const u8, gateway_token: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const default_name = try bestEffortDefaultName(allocator);
    defer allocator.free(default_name);

    const identity_path: []const u8 = node_platform.defaultNodeDeviceIdentityPathTemplate();
    const approvals_path: []const u8 = node_platform.defaultExecApprovalsPathTemplate();

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
            .displayName = default_name,
            .deviceIdentityPath = identity_path,
            .execApprovalsPath = approvals_path,
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
    display_name: ?[]const u8,
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
    if (display_name) |name| {
        try node_val.object.put("displayName", std.json.Value{ .string = name });
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

pub fn run(allocator: std.mem.Allocator, config_path: ?[]const u8, insecure_tls: bool, wait_for_approval: bool, display_name: ?[]const u8) !void {
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
        try saveUpdatedNodeConfig(allocator, cfg_path, identity.device_id, null, display_name);
        allocator.free(cfg.node.nodeId);
        cfg.node.nodeId = try allocator.dupe(u8, identity.device_id);
    }

    // Apply display name override (optional)
    if (display_name) |name| {
        if (cfg.node.displayName) |old| allocator.free(old);
        cfg.node.displayName = try allocator.dupe(u8, name);
        // Best-effort persist so future runs show the same name.
        saveUpdatedNodeConfig(allocator, cfg_path, null, null, name) catch {};
    }

    logger.info("Connecting as node-host to obtain/verify device token...", .{});

    const max_wait_ms: i64 = if (wait_for_approval) 5 * 60 * 1000 else 0;
    const start_ms: i64 = node_platform.nowMs();
    var attempt: u32 = 0;

    while (true) {
        attempt += 1;
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
            .display_name = cfg.node.displayName,
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

        // IMPORTANT: connect.auth.token must match the websocket Authorization token.
        ws.setConnectAuthToken(cfg.gateway.authToken);
        ws.setDeviceAuthToken(cfg.gateway.authToken);

        try ws.connect();

        const token = waitForHelloOkAndToken(allocator, &ws, 10_000) catch |err| switch (err) {
            error.PairingRequired => {
                logger.err("Pairing required for this device identity.", .{});
                logger.info("Approve this device in the gateway Control UI, then re-run.", .{});
                logger.info("Device id to approve: {s}", .{identity.device_id});
                if (!wait_for_approval) return error.PairingRequired;

                const elapsed = node_platform.nowMs() - start_ms;
                if (elapsed > max_wait_ms) {
                    logger.err("Timed out waiting for approval.", .{});
                    return error.Timeout;
                }
                logger.info("Waiting for approval... (attempt {d})", .{attempt});
                node_platform.sleepMs(1500);
                continue;
            },
            else => return err,
        };
        defer if (token) |t| allocator.free(t);

        if (token) |t| {
            if (!std.mem.eql(u8, cfg.node.nodeToken, t)) {
                logger.info("Saving node.nodeToken to config.json (device token)", .{});
                try saveUpdatedNodeConfig(allocator, cfg_path, null, t, display_name);
                allocator.free(cfg.node.nodeToken);
                cfg.node.nodeToken = try allocator.dupe(u8, t);
            }
        }

        logger.info("node-register complete.", .{});
        return;
    }
}
