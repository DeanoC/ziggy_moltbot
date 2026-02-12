const std = @import("std");
const zsc = @import("ziggystarclaw");

const node_context = zsc.node.node_context;
const NodeContext = node_context.NodeContext;

test "node context: screen support registers screen.record" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerWindowsScreenCapabilitiesForSupport(.{ .record = true });

    try std.testing.expect(ctx.supportsCommand("screen.record"));
}

test "node context: no screen support keeps capability surface unchanged" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerWindowsScreenCapabilitiesForSupport(.{ .record = false });

    try std.testing.expectEqual(@as(usize, 0), ctx.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.commands.items.len);
}
