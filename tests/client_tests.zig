const std = @import("std");
const moltbot = @import("ziggystarclaw");

const state = moltbot.client.state;
const event_handler = moltbot.client.event_handler;

test "client context init" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(state.ClientState.disconnected, ctx.state);
    try std.testing.expect(ctx.current_session == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.sessions.items.len);
}

test "hello-ok response captures gateway identity compatibility" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const raw =
        "{" ++
        "\"type\":\"res\"," ++
        "\"id\":\"req1\"," ++
        "\"ok\":true," ++
        "\"payload\":{" ++
        "\"type\":\"hello-ok\"," ++
        "\"features\":{" ++
        "\"methods\":[\"chat.send\",\"agent.control\"]" ++
        "}," ++
        "\"server\":{" ++
        "\"identity\":{" ++
        "\"kind\":\"gateway\"," ++
        "\"mode\":\"upstream\"," ++
        "\"source\":\"openclaw/openclaw\"" ++
        "}" ++
        "}," ++
        "\"auth\":{" ++
        "\"deviceToken\":\"tok\"" ++
        "}" ++
        "}" ++
        "}";

    const update = try event_handler.handleRawMessage(&ctx, raw);
    defer if (update) |u| u.deinit(allocator);

    try std.testing.expect(update != null);
    try std.testing.expectEqual(state.ClientState.connected, ctx.state);
    try std.testing.expectEqual(state.GatewayCompatibilityMode.upstream, ctx.gateway_compatibility);
    try std.testing.expect(ctx.gateway_identity.mode != null);
    try std.testing.expectEqualStrings("upstream", ctx.gateway_identity.mode.?);
    try std.testing.expect(ctx.supportsGatewayMethod("agent.control"));
    try std.testing.expect(!ctx.supportsGatewayMethod("agent.file.open"));
}

test "hello-ok response without identity keeps compatibility unknown" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const raw =
        "{" ++
        "\"type\":\"res\"," ++
        "\"id\":\"req1\"," ++
        "\"ok\":true," ++
        "\"payload\":{" ++
        "\"type\":\"hello-ok\"," ++
        "\"auth\":{" ++
        "\"deviceToken\":\"tok\"" ++
        "}" ++
        "}" ++
        "}";

    const update = try event_handler.handleRawMessage(&ctx, raw);
    defer if (update) |u| u.deinit(allocator);

    try std.testing.expect(update != null);
    try std.testing.expectEqual(state.GatewayCompatibilityMode.unknown, ctx.gateway_compatibility);
    try std.testing.expect(ctx.gateway_identity.mode == null);
}

test "client context message removal" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const session_key = "s1";
    const msg = moltbot.protocol.types.ChatMessage{
        .id = "m1",
        .role = "user",
        .content = "hello",
        .timestamp = 1,
        .attachments = null,
    };
    try ctx.upsertSessionMessage(session_key, msg);
    const state_ptr = ctx.findSessionState(session_key) orelse return error.TestExpectedSessionState;
    try std.testing.expectEqual(@as(usize, 1), state_ptr.messages.items.len);
    const removed = ctx.removeSessionMessageById(session_key, "m1");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), state_ptr.messages.items.len);
}

test "exec approval requested captures audit fields" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const raw =
        "{" ++
        "\"type\":\"event\"," ++
        "\"event\":\"exec.approval.requested\"," ++
        "\"payload\":{" ++
        "\"id\":\"a1\"," ++
        "\"createdAtMs\":1000," ++
        "\"request\":{" ++
        "\"nodeId\":\"node1\"," ++
        "\"command\":\"ls -la\"," ++
        "\"requestedBy\":\"agent:foo\"" ++
        "}" ++
        "}" ++
        "}";

    _ = try event_handler.handleRawMessage(&ctx, raw);

    try std.testing.expectEqual(@as(usize, 1), ctx.approvals.items.len);
    const approval = ctx.approvals.items[0];
    try std.testing.expect(approval.requested_by != null);
    try std.testing.expectEqualStrings("agent:foo", approval.requested_by.?);
    try std.testing.expectEqual(@as(?i64, 1000), approval.requested_at_ms);
}

test "exec approval resolved moves pending to resolved list" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const requested =
        "{" ++
        "\"type\":\"event\"," ++
        "\"event\":\"exec.approval.requested\"," ++
        "\"payload\":{" ++
        "\"id\":\"a1\"," ++
        "\"createdAtMs\":1000," ++
        "\"request\":{" ++
        "\"nodeId\":\"node1\"," ++
        "\"command\":\"ls\"" ++
        "}" ++
        "}" ++
        "}";
    _ = try event_handler.handleRawMessage(&ctx, requested);

    const resolved =
        "{" ++
        "\"type\":\"event\"," ++
        "\"event\":\"exec.approval.resolved\"," ++
        "\"payload\":{" ++
        "\"id\":\"a1\"," ++
        "\"decision\":\"deny\"," ++
        "\"resolvedBy\":\"bob\"," ++
        "\"resolvedAtMs\":2000" ++
        "}" ++
        "}";
    _ = try event_handler.handleRawMessage(&ctx, resolved);

    try std.testing.expectEqual(@as(usize, 0), ctx.approvals.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.approvals_resolved.items.len);
    const entry = ctx.approvals_resolved.items[0];
    try std.testing.expect(entry.decision != null);
    try std.testing.expectEqualStrings("deny", entry.decision.?);
    try std.testing.expect(entry.resolved_by != null);
    try std.testing.expectEqualStrings("bob", entry.resolved_by.?);
    try std.testing.expectEqual(@as(?i64, 2000), entry.resolved_at_ms);
}

test "exec approval resolve response records audit trail" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const requested =
        "{" ++
        "\"type\":\"event\"," ++
        "\"event\":\"exec.approval.requested\"," ++
        "\"payload\":{" ++
        "\"id\":\"a1\"," ++
        "\"createdAtMs\":1000," ++
        "\"request\":{" ++
        "\"nodeId\":\"node1\"," ++
        "\"command\":\"ls\"" ++
        "}" ++
        "}" ++
        "}";
    _ = try event_handler.handleRawMessage(&ctx, requested);

    const req_id = try allocator.dupe(u8, "req1");
    const target_id = try allocator.dupe(u8, "a1");
    const decision = try allocator.dupe(u8, "allow-once");
    ctx.setPendingApprovalResolveRequest(req_id, target_id, decision);

    const response =
        "{" ++
        "\"type\":\"res\"," ++
        "\"id\":\"req1\"," ++
        "\"ok\":true," ++
        "\"payload\":{}" ++
        "}";
    _ = try event_handler.handleRawMessage(&ctx, response);

    try std.testing.expectEqual(@as(usize, 0), ctx.approvals.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.approvals_resolved.items.len);
    const entry = ctx.approvals_resolved.items[0];
    try std.testing.expect(entry.decision != null);
    try std.testing.expectEqualStrings("allow-once", entry.decision.?);
    try std.testing.expect(entry.resolved_by != null);
    try std.testing.expectEqualStrings("local", entry.resolved_by.?);
}

test "exec approval requested updates activity stream" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const raw =
        "{" ++
        "\"type\":\"event\"," ++
        "\"event\":\"exec.approval.requested\"," ++
        "\"payload\":{" ++
        "\"id\":\"a2\"," ++
        "\"request\":{" ++
        "\"command\":\"rm -rf /tmp/x\"" ++
        "}" ++
        "}" ++
        "}";
    _ = try event_handler.handleRawMessage(&ctx, raw);

    try std.testing.expectEqual(@as(usize, 1), ctx.activity.items.len);
    const item = ctx.activity.items[0];
    try std.testing.expectEqual(state.ActivitySource.approval, item.source);
    try std.testing.expectEqual(state.ActivityStatus.pending, item.status);
}

test "node process activity aggregates by process id" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    ctx.setPendingNodeInvokeRequest(try allocator.dupe(u8, "req-node-1"), "process.poll");
    const running =
        "{" ++
        "\"type\":\"res\"," ++
        "\"id\":\"req-node-1\"," ++
        "\"ok\":true," ++
        "\"payload\":{" ++
        "\"processId\":\"p123\"," ++
        "\"status\":\"running\"" ++
        "}" ++
        "}";
    _ = try event_handler.handleRawMessage(&ctx, running);

    ctx.setPendingNodeInvokeRequest(try allocator.dupe(u8, "req-node-2"), "process.poll");
    const done =
        "{" ++
        "\"type\":\"res\"," ++
        "\"id\":\"req-node-2\"," ++
        "\"ok\":true," ++
        "\"payload\":{" ++
        "\"processId\":\"p123\"," ++
        "\"status\":\"succeeded\"" ++
        "}" ++
        "}";
    _ = try event_handler.handleRawMessage(&ctx, done);

    try std.testing.expectEqual(@as(usize, 1), ctx.activity.items.len);
    try std.testing.expectEqual(state.ActivitySource.process, ctx.activity.items[0].source);
    try std.testing.expectEqual(state.ActivityStatus.succeeded, ctx.activity.items[0].status);
}
