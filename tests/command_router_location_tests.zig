const std = @import("std");
const zsc = @import("ziggystarclaw");

const command_router = zsc.node.command_router;
const node_context = zsc.node.node_context;

test "command router: location.get requires an implemented backend" {
    const requested = [_]node_context.Command{.location_get};
    try std.testing.expectError(
        error.CommandNotSupported,
        command_router.initRouterWithCommands(std.testing.allocator, &requested),
    );
}
