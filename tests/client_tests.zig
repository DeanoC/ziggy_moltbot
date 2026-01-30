const std = @import("std");
const moltbot = @import("ziggystarclaw");

const state = moltbot.client.state;

test "client context init" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(state.ClientState.disconnected, ctx.state);
    try std.testing.expect(ctx.current_session == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.sessions.items.len);
}

test "client context message removal" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    const msg = moltbot.protocol.types.ChatMessage{
        .id = "m1",
        .role = "user",
        .content = "hello",
        .timestamp = 1,
        .attachments = null,
    };
    try ctx.upsertMessage(msg);
    try std.testing.expectEqual(@as(usize, 1), ctx.messages.items.len);

    const removed = ctx.removeMessageById("m1");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), ctx.messages.items.len);
}
