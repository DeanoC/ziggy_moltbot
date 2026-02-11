const std = @import("std");
const zsc = @import("ziggystarclaw");

const node_context = zsc.node.node_context;
const NodeContext = node_context.NodeContext;

test "node context: list-only camera support registers camera.list" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerWindowsCameraCapabilitiesForSupport(.{ .list = true, .snap = false });

    try std.testing.expect(ctx.supportsCommand("camera.list"));
    try std.testing.expect(!ctx.supportsCommand("camera.snap"));
}

test "node context: list+snap camera support registers both commands" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerWindowsCameraCapabilitiesForSupport(.{ .list = true, .snap = true });

    try std.testing.expect(ctx.supportsCommand("camera.list"));
    try std.testing.expect(ctx.supportsCommand("camera.snap"));
}

test "node context: no camera support keeps capability surface unchanged" {
    var ctx = try NodeContext.init(std.testing.allocator, "node-id", "Node");
    defer ctx.deinit();

    try ctx.registerWindowsCameraCapabilitiesForSupport(.{ .list = false, .snap = false });

    try std.testing.expectEqual(@as(usize, 0), ctx.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.commands.items.len);
}
