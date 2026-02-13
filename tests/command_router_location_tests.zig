const std = @import("std");
const zsc = @import("ziggystarclaw");

const command_router = zsc.node.command_router;
const node_context = zsc.node.node_context;
const NodeContext = node_context.NodeContext;

test "command router: location.get registration matches advertised command surface" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerLocationCapabilities();

    const requested = [_]node_context.Command{.location_get};
    if (ctx.supportsCommand("location.get")) {
        var router = try command_router.initRouterWithCommands(std.testing.allocator, &requested);
        defer router.deinit();
        try std.testing.expect(router.isRegistered("location.get"));
    } else {
        try std.testing.expectError(
            error.CommandNotSupported,
            command_router.initRouterWithCommands(std.testing.allocator, &requested),
        );
    }
}
