const std = @import("std");
const zsc = @import("ziggystarclaw");

const node_context = zsc.node.node_context;
const NodeContext = node_context.NodeContext;

test "node context: location support registers location.get" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerLocationCapabilitiesForSupport(.{ .get = true });

    try std.testing.expect(ctx.supportsCommand("location.get"));
    try std.testing.expectEqual(@as(usize, 1), ctx.capabilities.items.len);
    try std.testing.expect(ctx.capabilities.items[0] == .location);
}

test "node context: no location support keeps capability surface unchanged" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerLocationCapabilitiesForSupport(.{ .get = false });

    try std.testing.expectEqual(@as(usize, 0), ctx.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.commands.items.len);
}
