const std = @import("std");
const moltbot = @import("moltbot");

const state = moltbot.client.state;

test "client context init" {
    const allocator = std.testing.allocator;
    var ctx = try state.ClientContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(state.ClientState.disconnected, ctx.state);
    try std.testing.expect(ctx.current_session == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.sessions.items.len);
}
