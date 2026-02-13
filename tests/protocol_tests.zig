const std = @import("std");
const moltbot = @import("ziggystarclaw");

const messages = moltbot.protocol.messages;
const types = moltbot.protocol.types;
const requests = moltbot.protocol.requests;
const chat = moltbot.protocol.chat;
const ws_auth_pairing = moltbot.protocol.ws_auth_pairing;

test "serialize/deserialize chat message" {
    const allocator = std.testing.allocator;
    const msg = types.ChatMessage{
        .id = "m1",
        .role = "user",
        .content = "hello",
        .timestamp = 1,
        .attachments = null,
    };

    const json = try messages.serializeMessage(allocator, msg);
    defer allocator.free(json);

    var parsed = try messages.deserializeMessage(allocator, json, types.ChatMessage);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(msg.id, parsed.value.id);
    try std.testing.expectEqualStrings(msg.role, parsed.value.role);
    try std.testing.expectEqualStrings(msg.content, parsed.value.content);
    try std.testing.expectEqual(msg.timestamp, parsed.value.timestamp);
}

test "parse message envelope payload" {
    const allocator = std.testing.allocator;
    const json =
        \\{"kind":"message_new","payload":{"id":"m1","role":"user","content":"hello","timestamp":1}}
    ;

    var envelope = try messages.deserializeMessage(allocator, json, types.MessageEnvelope);
    defer envelope.deinit();

    try std.testing.expectEqualStrings("message_new", envelope.value.kind);

    var payload = try messages.parsePayload(allocator, envelope.value.payload, types.ChatMessage);
    defer payload.deinit();

    try std.testing.expectEqualStrings("m1", payload.value.id);
    try std.testing.expectEqualStrings("user", payload.value.role);
    try std.testing.expectEqualStrings("hello", payload.value.content);
    try std.testing.expectEqual(@as(i64, 1), payload.value.timestamp);
}

test "build request payload" {
    const allocator = std.testing.allocator;
    const params = chat.ChatHistoryParams{
        .sessionKey = "main",
        .limit = 2,
    };
    const req = try requests.buildRequestPayload(allocator, "chat.history", params);
    defer allocator.free(req.payload);
    defer allocator.free(req.id);

    var parsed = try messages.deserializeMessage(allocator, req.payload, std.json.Value);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("req", obj.get("type").?.string);
    try std.testing.expectEqualStrings("chat.history", obj.get("method").?.string);
}

test "parse chat history payload" {
    const allocator = std.testing.allocator;
    const json =
        \\{"messages":[{"role":"user","content":[{"type":"text","text":"hi"}],"timestamp":1}]}
    ;
    var value = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer value.deinit();

    var parsed = try messages.parsePayload(allocator, value.value, chat.ChatHistoryResult);
    defer parsed.deinit();

    const msg = parsed.value.messages.?[0];
    try std.testing.expectEqualStrings("user", msg.role);
}

test "ws auth payload builder matches gateway v2 shape" {
    const allocator = std.testing.allocator;

    const payload = try ws_auth_pairing.buildDeviceAuthPayload(allocator, .{
        .device_id = "device-1",
        .client_id = "zsc-cli",
        .client_mode = "cli",
        .role = "operator",
        .scopes = &.{ "operator.read", "operator.write" },
        .signed_at_ms = 1737264000000,
        .token = "gateway-token",
        .nonce = "nonce-123",
    });
    defer allocator.free(payload);

    try std.testing.expectEqualStrings(
        "v2|device-1|zsc-cli|cli|operator|operator.read,operator.write|1737264000000|gateway-token|nonce-123",
        payload,
    );
}

test "ws auth + pairing example payload bundle builds valid frames" {
    const allocator = std.testing.allocator;

    var bundle = try ws_auth_pairing.buildExamplePayloadBundle(allocator);
    defer bundle.deinit(allocator);

    var connect = try std.json.parseFromSlice(std.json.Value, allocator, bundle.connect, .{});
    defer connect.deinit();
    try std.testing.expectEqualStrings("req", connect.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("connect", connect.value.object.get("method").?.string);

    var node_pair = try std.json.parseFromSlice(std.json.Value, allocator, bundle.node_pair_request, .{});
    defer node_pair.deinit();
    try std.testing.expectEqualStrings("node.pair.request", node_pair.value.object.get("method").?.string);

    var approve = try std.json.parseFromSlice(std.json.Value, allocator, bundle.device_pair_approve, .{});
    defer approve.deinit();
    try std.testing.expectEqualStrings("device.pair.approve", approve.value.object.get("method").?.string);

    var reject = try std.json.parseFromSlice(std.json.Value, allocator, bundle.device_pair_reject, .{});
    defer reject.deinit();
    try std.testing.expectEqualStrings("device.pair.reject", reject.value.object.get("method").?.string);
}
