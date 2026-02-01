const std = @import("std");
const logger = @import("utils/logger.zig");
const websocket_client = @import("client/websocket_client.zig");
const requests = @import("protocol/requests.zig");

pub const usage =
    \\ZiggyStarClaw Operator Mode
    \\
    \\Usage:
    \\  ziggystarclaw-cli --operator-mode [options]
    \\
    \\Actions:
    \\  --pair-list                 List pending/paired devices
    \\  --pair-approve <requestId>  Approve a pairing request
    \\  --nodes                      List connected nodes
    \\  --watch-pairing              Watch for device.pair.* events
    \\
;

pub const OperatorCliOptions = struct {
    url: []const u8 = "ws://127.0.0.1:18789/ws",
    token: ?[]const u8 = null,
    insecure_tls: bool = false,
    log_level: logger.Level = .info,
    // Separate operator identity file
    device_identity_path: []const u8 = "ziggystarclaw_operator_device.json",

    // Actions
    pair_list: bool = false,
    pair_approve_request_id: ?[]const u8 = null,
    list_nodes: bool = false,
    watch_pairing: bool = false,
};

pub fn parseOperatorOptions(_: std.mem.Allocator, args: []const []const u8) !OperatorCliOptions {
    var opts = OperatorCliOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.url = args[i];
        } else if (std.mem.eql(u8, arg, "--token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.token = args[i];
        } else if (std.mem.eql(u8, arg, "--pair-list")) {
            opts.pair_list = true;
        } else if (std.mem.eql(u8, arg, "--pair-approve")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.pair_approve_request_id = args[i];
        } else if (std.mem.eql(u8, arg, "--nodes")) {
            opts.list_nodes = true;
        } else if (std.mem.eql(u8, arg, "--watch-pairing")) {
            opts.watch_pairing = true;
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
        const msg = try ws.receive();
        if (msg) |payload| {
            defer allocator.free(payload);

            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
            defer parsed.deinit();

            const frame = parsed.value;
            if (frame != .object) continue;
            const t = frame.object.get("type") orelse continue;
            if (t != .string) continue;

            if (std.mem.eql(u8, t.string, "res")) {
                const idv = frame.object.get("id") orelse continue;
                if (idv != .string) continue;
                if (!std.mem.eql(u8, idv.string, req.id)) continue;

                // Return payload as JSON text.
                if (frame.object.get("payload")) |pv| {
                    return try std.json.Stringify.valueAlloc(allocator, pv, .{ .whitespace = .indent_2 });
                }
                return try std.json.Stringify.valueAlloc(allocator, frame, .{ .whitespace = .indent_2 });
            }

            // Ignore events/other frames for now.
        } else {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }

    return error.Timeout;
}

fn printJsonText(s: []const u8) void {
    var out = std.fs.File.stdout().deprecatedWriter();
    out.writeAll(s) catch {};
    if (s.len == 0 or s[s.len - 1] != '\n') {
        out.writeAll("\n") catch {};
    }
}

fn waitForHelloOk(allocator: std.mem.Allocator, ws: *websocket_client.WebSocketClient, timeout_ms: u64) !?[]u8 {
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
            if (t != .string) continue;
            if (!std.mem.eql(u8, t.string, "res")) continue;
            const okv = parsed.value.object.get("ok") orelse continue;
            if (okv == .bool and okv.bool == true) {
                const pv = parsed.value.object.get("payload") orelse continue;
                if (pv != .object) continue;
                const ptype = pv.object.get("type") orelse continue;
                if (ptype == .string and std.mem.eql(u8, ptype.string, "hello-ok")) {
                    return null;
                }
            } else {
                // Failed connect; try to extract pairing request id.
                const errv = parsed.value.object.get("error") orelse continue;
                if (errv != .object) continue;
                if (errv.object.get("code")) |codev| {
                    if (codev == .string and std.mem.eql(u8, codev.string, "NOT_PAIRED")) {
                        if (errv.object.get("details")) |dv| {
                            if (dv == .object) {
                                if (dv.object.get("requestId")) |ridv| {
                                    if (ridv == .string and ridv.string.len > 0) {
                                        return try allocator.dupe(u8, ridv.string);
                                    }
                                }
                            }
                        }
                        return try allocator.dupe(u8, "");
                    }
                }
            }
        } else {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }
    return error.Timeout;
}

pub fn runOperatorMode(allocator: std.mem.Allocator, opts: OperatorCliOptions) !void {
    logger.setLevel(opts.log_level);

    const Empty = struct {};

    const token = opts.token orelse std.process.getEnvVarOwned(allocator, "GATEWAY_TOKEN") catch null orelse "";
    defer if (opts.token == null and token.len > 0) allocator.free(token);

    var ws_client = websocket_client.WebSocketClient.init(
        allocator,
        opts.url,
        token,
        opts.insecure_tls,
        null,
    );
    defer ws_client.deinit();

    ws_client.setConnectProfile(.{
        .role = "operator",
        .scopes = &.{ "operator.admin", "operator.approvals", "operator.pairing" },
        .client_id = "cli",
        .client_mode = "cli",
    });
    ws_client.setDeviceIdentityPath(opts.device_identity_path);
    ws_client.setReadTimeout(15000);

    try ws_client.connect();
    // Important: WebSocketClient sends connect only after we receive connect.challenge,
    // so we must drain until we get hello-ok before issuing any other requests.
    const pairing_req = try waitForHelloOk(allocator, &ws_client, 5000);
    if (pairing_req) |rid| {
        defer allocator.free(rid);
        if (rid.len > 0) {
            logger.err("Operator device not paired. Approve pairing requestId={s}", .{rid});
        } else {
            logger.err("Operator device not paired (no requestId found).", .{});
        }
        return error.NotPaired;
    }
    logger.info("Operator connected (hello-ok) to {s}", .{opts.url});

    // Actions
    if (opts.pair_list) {
        const payload = try sendRequestAwait(allocator, &ws_client, "device.pair.list", Empty{}, 5000);
        defer allocator.free(payload);
        printJsonText(payload);
        return;
    }

    if (opts.pair_approve_request_id) |rid| {
        const payload = try sendRequestAwait(
            allocator,
            &ws_client,
            "device.pair.approve",
            .{ .requestId = rid },
            5000,
        );
        defer allocator.free(payload);
        printJsonText(payload);
        return;
    }

    if (opts.list_nodes) {
        const payload = try sendRequestAwait(allocator, &ws_client, "node.list", Empty{}, 5000);
        defer allocator.free(payload);
        printJsonText(payload);
        return;
    }

    if (opts.watch_pairing) {
        while (ws_client.is_connected) {
            const msg = ws_client.receive() catch |err| {
                logger.warn("operator recv failed: {s}", .{@errorName(err)});
                break;
            };
            if (msg) |payload| {
                defer allocator.free(payload);
                // Print only pairing-related events to stdout.
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
                    var out = std.fs.File.stdout().deprecatedWriter();
                    out.writeAll(payload) catch {};
                    out.writeAll("\n") catch {};
                }
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
        return;
    }

    // Default: stay connected and print inbound frames at debug.
    while (ws_client.is_connected) {
        const msg = ws_client.receive() catch |err| {
            logger.warn("operator recv failed: {s}", .{@errorName(err)});
            break;
        };
        if (msg) |payload| {
            defer allocator.free(payload);
            logger.debug("operator recv: {s}", .{payload});
        } else {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}
