const std = @import("std");
const websocket_client = @import("../openclaw_transport.zig").websocket;
const ziggy = @import("ziggy-core");
const logger = ziggy.utils.logger;

pub const GatewayVerb = enum {
    ping,
    echo,
    probe,
    unknown,
};

pub fn parseVerb(verb: []const u8) GatewayVerb {
    if (std.mem.eql(u8, verb, "ping")) return .ping;
    if (std.mem.eql(u8, verb, "echo")) return .echo;
    if (std.mem.eql(u8, verb, "probe")) return .probe;
    return .unknown;
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll("Gateway testing commands:\n" ++
        "  gateway ping <url>    Test WebSocket connectivity (handshake only)\n" ++
        "  gateway echo <url>    Full echo test: connect, send, verify response\n" ++
        "  gateway probe <url>   Probe for OpenClaw protocol compatibility\n" ++
        "\n" ++
        "Examples:\n" ++
        "  gateway ping ws://127.0.0.1:18790\n" ++
        "  gateway echo ws://127.0.0.1:18790/v1/agents/test/stream\n");
}

pub fn run(
    allocator: std.mem.Allocator,
    verb: GatewayVerb,
    url: []const u8,
    agent_id: []const u8,
    timeout_ms: u32,
    writer: anytype,
) !void {
    switch (verb) {
        .ping => try ping(allocator, url, timeout_ms, writer),
        .echo => try echo(allocator, url, agent_id, timeout_ms, writer),
        .probe => try probe(allocator, url, agent_id, timeout_ms, writer),
        .unknown => {
            try writer.writeAll("Unknown gateway verb. Use: ping, echo, or probe\n");
            return error.InvalidArguments;
        },
    }
}

fn ping(
    allocator: std.mem.Allocator,
    url: []const u8,
    timeout_ms: u32,
    writer: anytype,
) !void {
    try writer.print("Pinging {s}...\n", .{url});

    var client = websocket_client.WebSocketClient.init(
        allocator,
        url,
        "",
        true,
        null,
    );
    client.setReadTimeout(timeout_ms);
    defer client.deinit();

    const start = std.time.milliTimestamp();

    try client.connect();
    defer client.disconnect();

    // Wait for connection
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (!client.is_connected and std.time.milliTimestamp() < deadline) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const elapsed = std.time.milliTimestamp() - start;

    if (client.is_connected) {
        try writer.print("✓ Connected in {d}ms\n", .{elapsed});
        try writer.writeAll("✓ WebSocket handshake successful\n");
    } else {
        try writer.print("✗ Connection failed after {d}ms\n", .{elapsed});
        return error.ConnectionFailed;
    }
}

fn echo(
    allocator: std.mem.Allocator,
    url: []const u8,
    _agent_id: []const u8,
    timeout_ms: u32,
    writer: anytype,
) !void {
    _ = _agent_id;
    try writer.print("Echo test to {s}...\n", .{url});

    var client = websocket_client.WebSocketClient.init(
        allocator,
        url,
        "",
        true,
        null,
    );
    client.setReadTimeout(timeout_ms);
    defer client.deinit();

    const start = std.time.milliTimestamp();

    try client.connect();
    defer client.disconnect();

    // Wait for session.ack
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var got_ack = false;
    var session_key: ?[]u8 = null;
    defer if (session_key) |s| allocator.free(s);

    while (std.time.milliTimestamp() < deadline) {
        const msg = client.receive() catch |err| {
            logger.err("Receive error: {s}", .{@errorName(err)});
            break;
        };

        if (msg) |payload| {
            defer allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
            defer parsed.deinit();

            const frame = parsed.value;
            if (frame != .object) continue;

            const msg_type = frame.object.get("type") orelse continue;
            if (msg_type != .string) continue;

            if (std.mem.eql(u8, msg_type.string, "session.ack")) {
                got_ack = true;
                if (frame.object.get("sessionKey")) |sk| {
                    if (sk == .string) {
                        session_key = try allocator.dupe(u8, sk.string);
                        try writer.print("✓ Session established: {s}\n", .{sk.string});
                    }
                }
                break;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (!got_ack) {
        try writer.writeAll("✗ No session.ack received\n");
        return error.NoSessionAck;
    }

    // Send echo message
    const test_payload = "{\"type\":\"session.send\",\"id\":\"test1\",\"content\":\"Hello from ZiggyStarClaw\"}";
    try client.send(test_payload);
    try writer.writeAll("✓ Sent test message\n");

    // Wait for echo response
    const echo_deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var got_echo = false;

    while (std.time.milliTimestamp() < echo_deadline) {
        const msg = client.receive() catch |err| {
            logger.err("Receive error: {s}", .{@errorName(err)});
            break;
        };

        if (msg) |payload| {
            defer allocator.free(payload);

            if (std.mem.containsAtLeast(u8, payload, 1, "Echo:")) {
                got_echo = true;
                try writer.print("✓ Received echo: {s}\n", .{payload});
                break;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const elapsed = std.time.milliTimestamp() - start;

    if (got_echo) {
        try writer.print("✓ Echo test passed in {d}ms\n", .{elapsed});
    } else {
        try writer.writeAll("✗ No echo response received\n");
        return error.NoEcho;
    }
}

fn probe(
    allocator: std.mem.Allocator,
    url: []const u8,
    _agent_id: []const u8,
    timeout_ms: u32,
    writer: anytype,
) !void {
    _ = _agent_id;
    try writer.print("Probing {s} for OpenClaw compatibility...\n\n", .{url});

    var client = websocket_client.WebSocketClient.init(
        allocator,
        url,
        "",
        true,
        null,
    );
    client.setReadTimeout(timeout_ms);
    defer client.deinit();

    const start = std.time.milliTimestamp();

    try client.connect();
    defer client.disconnect();

    // Check protocol version (look for session.ack structure)
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    const checks = [_]struct {
        name: []const u8,
        check: enum { websocket, session_ack, agent_id, json_rpc },
    }{
        .{ .name = "WebSocket handshake", .check = .websocket },
        .{ .name = "Session ACK", .check = .session_ack },
        .{ .name = "Agent ID in ACK", .check = .agent_id },
        .{ .name = "JSON-RPC framing", .check = .json_rpc },
    };

    const checks_total: u32 = @intCast(checks.len);
    var websocket_ok = false;
    var session_ack_ok = false;
    var agent_id_ok = false;
    var json_rpc_ok = false;

    // WebSocket check
    if (client.is_connected) {
        websocket_ok = true;
        try writer.print("[✓] {s}\n", .{checks[0].name});
    } else {
        try writer.print("[✗] {s}\n", .{checks[0].name});
    }

    // Protocol checks
    while (std.time.milliTimestamp() < deadline and !session_ack_ok) {
        const msg = client.receive() catch continue;

        if (msg) |payload| {
            defer allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
            defer parsed.deinit();

            const frame = parsed.value;
            if (frame != .object) continue;

            const msg_type = frame.object.get("type") orelse continue;
            if (msg_type != .string) continue;

            if (std.mem.eql(u8, msg_type.string, "session.ack")) {
                session_ack_ok = true;
                try writer.print("[✓] {s}\n", .{checks[1].name});

                if (frame.object.get("agentId")) |aid| {
                    if (aid == .string and aid.string.len > 0) {
                        agent_id_ok = true;
                        try writer.print("[✓] {s} (found: {s})\n", .{ checks[2].name, aid.string });
                    } else {
                        try writer.print("[✗] {s} (empty or invalid)\n", .{checks[2].name});
                    }
                } else {
                    try writer.print("[✗] {s} (missing)\n", .{checks[2].name});
                }

                // Check JSON-RPC structure
                if (frame.object.get("sessionKey")) |sk| {
                    if (sk == .string and sk.string.len > 0) {
                        json_rpc_ok = true;
                        try writer.print("[✓] {s}\n", .{checks[3].name});
                    } else {
                        try writer.print("[✗] {s} (invalid sessionKey)\n", .{checks[3].name});
                    }
                } else {
                    try writer.print("[✗] {s} (missing sessionKey)\n", .{checks[3].name});
                }

                break;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (!session_ack_ok) {
        try writer.print("[✗] {s} (not received before timeout)\n", .{checks[1].name});
        try writer.print("[✗] {s} (no session.ack payload)\n", .{checks[2].name});
        try writer.print("[✗] {s} (no session.ack payload)\n", .{checks[3].name});
    }

    var checks_passed: u32 = 0;
    if (websocket_ok) checks_passed += 1;
    if (session_ack_ok) checks_passed += 1;
    if (agent_id_ok) checks_passed += 1;
    if (json_rpc_ok) checks_passed += 1;

    const elapsed = std.time.milliTimestamp() - start;

    try writer.print("\n{d}/{d} checks passed in {d}ms\n", .{ checks_passed, checks_total, elapsed });

    if (checks_passed == checks_total) {
        try writer.writeAll("\n✓ OpenClaw protocol compatible\n");
    } else {
        try writer.writeAll("\n✗ Not fully compatible (may be a custom gateway or old version)\n");
    }
}
