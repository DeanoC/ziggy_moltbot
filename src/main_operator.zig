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
    \\This mode will connect to the gateway as an operator (role=operator)
    \\and is intended for pairing approvals and node administration.
    \\
;

pub const OperatorCliOptions = struct {
    url: []const u8 = "ws://127.0.0.1:18789/ws",
    token: ?[]const u8 = null,
    insecure_tls: bool = false,
    log_level: logger.Level = .info,
    // Separate operator identity file
    device_identity_path: []const u8 = "ziggystarclaw_operator_device.json",
};

pub fn parseOperatorOptions(allocator: std.mem.Allocator, args: []const []const u8) !OperatorCliOptions {
    var opts = OperatorCliOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.url = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.token = try allocator.dupe(u8, args[i]);
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

pub fn runOperatorMode(allocator: std.mem.Allocator, opts: OperatorCliOptions) !void {
    logger.setLevel(opts.log_level);

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
    logger.info("Operator connected to {s}", .{opts.url});

    // For now, just sit connected; operator functionality can be layered in.
    // (pair list/approve, node list/invoke etc.)
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
