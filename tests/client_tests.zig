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

    const session_key = "s1";
    const msg = moltbot.protocol.types.ChatMessage{
        .id = "m1",
        .role = "user",
        .content = "hello",
        .timestamp = 1,
        .attachments = null,
    };

    try ctx.upsertSessionMessage(session_key, msg);
    const state_ptr = ctx.session_states.getPtr(session_key).?;
    try std.testing.expectEqual(@as(usize, 1), state_ptr.messages.items.len);

    const removed = ctx.removeSessionMessageById(session_key, "m1");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), state_ptr.messages.items.len);
}
