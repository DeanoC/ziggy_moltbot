const dock_graph = @import("dock_graph.zig");
const draw_context = @import("../draw_context.zig");

pub const Side = enum {
    left,
    right,
};

pub const Item = struct {
    node_id: dock_graph.NodeId,
    side: Side,
};

pub const CollapsedSet = struct {
    items: [32]Item = undefined,
    len: usize = 0,

    pub fn isCollapsed(self: *const CollapsedSet, node_id: dock_graph.NodeId) bool {
        return self.sideForNode(node_id) != null;
    }

    pub fn sideForNode(self: *const CollapsedSet, node_id: dock_graph.NodeId) ?Side {
        for (self.items[0..self.len]) |item| {
            if (item.node_id == node_id) return item.side;
        }
        return null;
    }

    pub fn collapse(self: *CollapsedSet, node_id: dock_graph.NodeId, side: Side) void {
        for (self.items[0..self.len]) |*item| {
            if (item.node_id != node_id) continue;
            item.side = side;
            return;
        }
        if (self.len >= self.items.len) return;
        self.items[self.len] = .{ .node_id = node_id, .side = side };
        self.len += 1;
    }

    pub fn expand(self: *CollapsedSet, node_id: dock_graph.NodeId) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.items[i].node_id != node_id) continue;
            self.removeAt(i);
            return true;
        }
        return false;
    }

    pub fn countForSide(self: *const CollapsedSet, side: Side) usize {
        var n: usize = 0;
        for (self.items[0..self.len]) |item| {
            if (item.side == side) n += 1;
        }
        return n;
    }

    pub fn prune(self: *CollapsedSet, graph: *const dock_graph.Graph) void {
        var i: usize = 0;
        while (i < self.len) {
            const item = self.items[i];
            const node = graph.getNode(item.node_id) orelse {
                self.removeAt(i);
                continue;
            };
            switch (node.*) {
                .tabs => |tabs| {
                    if (tabs.tabs.items.len == 0) {
                        self.removeAt(i);
                        continue;
                    }
                },
                .split => {
                    self.removeAt(i);
                    continue;
                },
            }
            i += 1;
        }
    }

    fn removeAt(self: *CollapsedSet, index: usize) void {
        if (index >= self.len) return;
        if (index + 1 < self.len) {
            var i = index;
            while (i + 1 < self.len) : (i += 1) {
                self.items[i] = self.items[i + 1];
            }
        }
        self.len -= 1;
    }
};

pub fn sideForRect(host_rect: draw_context.Rect, group_rect: draw_context.Rect) Side {
    // Prefer the side whose edge is nearer to the group's edge. This avoids misclassifying
    // wide right-anchored groups as "left" when their center drifts past host midpoint.
    const left_gap = @abs(group_rect.min[0] - host_rect.min[0]);
    const right_gap = @abs(host_rect.max[0] - group_rect.max[0]);
    if (left_gap < right_gap) return .left;
    if (right_gap < left_gap) return .right;

    // Stable tie-breaker for centered groups.
    const host_center_x = host_rect.min[0] + host_rect.size()[0] * 0.5;
    const group_center_x = group_rect.min[0] + group_rect.size()[0] * 0.5;
    return if (group_center_x <= host_center_x) .left else .right;
}

pub fn collapsibleSideForRect(host_rect: draw_context.Rect, group_rect: draw_context.Rect) ?Side {
    const epsilon: f32 = 2.0;
    const touches_left = group_rect.min[0] <= host_rect.min[0] + epsilon;
    const touches_right = group_rect.max[0] >= host_rect.max[0] - epsilon;

    if (touches_left and !touches_right) return .left;
    if (touches_right and !touches_left) return .right;
    return null;
}
