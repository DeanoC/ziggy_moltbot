const draw_context = @import("../draw_context.zig");
const dock_graph = @import("dock_graph.zig");

pub const edge_band_ratio: f32 = 0.22;

pub const DropTarget = struct {
    node_id: dock_graph.NodeId,
    location: dock_graph.DropLocation,
};

pub fn classifyDropLocation(rect: draw_context.Rect, pos: [2]f32) dock_graph.DropLocation {
    const size = rect.size();
    if (size[0] <= 0.0 or size[1] <= 0.0) return .center;

    const left_band = rect.min[0] + size[0] * edge_band_ratio;
    const right_band = rect.max[0] - size[0] * edge_band_ratio;
    const top_band = rect.min[1] + size[1] * edge_band_ratio;
    const bottom_band = rect.max[1] - size[1] * edge_band_ratio;

    // Keep horizontal precedence for corners (top-left => left, top-right => right)
    // to match existing window docking feel.
    if (pos[0] < left_band) return .left;
    if (pos[0] > right_band) return .right;
    if (pos[1] < top_band) return .top;
    if (pos[1] > bottom_band) return .bottom;
    return .center;
}

pub fn pickDropTarget(
    graph: *const dock_graph.Graph,
    viewport: draw_context.Rect,
    pos: [2]f32,
) ?DropTarget {
    const layout = graph.computeLayout(viewport);
    for (layout.slice()) |group| {
        if (group.rect.contains(pos)) {
            return .{
                .node_id = group.node_id,
                .location = classifyDropLocation(group.rect, pos),
            };
        }
    }

    const fallback_node = graph.firstTabsNode() orelse return null;
    return .{ .node_id = fallback_node, .location = .center };
}
