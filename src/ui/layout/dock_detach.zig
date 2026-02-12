const dock_graph = @import("dock_graph.zig");

pub const GroupDetachPlan = union(enum) {
    node_not_found,
    split_node,
    empty_tabs,
    tabs: []const dock_graph.PanelId,
};

pub fn shouldTryCrossWindowAttach(from_drag_drop: bool, src_window_id: u32, hovered_window_id: u32) bool {
    return from_drag_drop and hovered_window_id != 0 and hovered_window_id != src_window_id;
}

pub fn shouldRollbackGroupTransfer(moved_ok: bool, moved_count: usize) bool {
    return !moved_ok or moved_count == 0;
}

pub fn planGroupDetach(graph: *const dock_graph.Graph, node_id: dock_graph.NodeId) GroupDetachPlan {
    const node = graph.getNode(node_id) orelse return .node_not_found;
    return switch (node.*) {
        .split => .split_node,
        .tabs => |tabs| if (tabs.tabs.items.len == 0) .empty_tabs else .{ .tabs = tabs.tabs.items },
    };
}
