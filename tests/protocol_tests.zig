const std = @import("std");
const moltbot = @import("moltbot");

const messages = moltbot.protocol.messages;
const types = moltbot.protocol.types;

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
