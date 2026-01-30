const std = @import("std");
const moltbot = @import("ziggystarclaw");

const messages = moltbot.protocol.messages;
const types = moltbot.protocol.types;
const requests = moltbot.protocol.requests;
const chat = moltbot.protocol.chat;

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
