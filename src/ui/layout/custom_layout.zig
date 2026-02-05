const std = @import("std");
const draw_context = @import("../draw_context.zig");
const workspace = @import("../workspace.zig");

pub const NodeId = u8;

pub const Axis = enum {
    vertical,
    horizontal,
};

pub const SplitNode = struct {
    axis: Axis,
    ratio: f32,
    gap: f32,
    first: NodeId,
    second: NodeId,
};

pub const TabsNode = struct {
    active: usize,
    tabs: []const NodeId,
};

pub const LeafNode = struct {
    kind: workspace.PanelKind,
};

pub const LayoutNode = union(enum) {
    Split: SplitNode,
    Tabs: TabsNode,
    Leaf: LeafNode,
};

pub const LayoutTree = struct {
    nodes: [16]LayoutNode = undefined,
    len: usize = 0,
    root: NodeId = 0,

    pub fn add(self: *LayoutTree, node: LayoutNode) NodeId {
        std.debug.assert(self.len < self.nodes.len);
        const idx: usize = self.len;
        self.nodes[idx] = node;
        self.len += 1;
        return @intCast(idx);
    }

    pub fn slice(self: *const LayoutTree) []const LayoutNode {
        return self.nodes[0..self.len];
    }
};

pub const PanelRect = struct {
    kind: workspace.PanelKind,
    rect: draw_context.Rect,
};

pub const LayoutResult = struct {
    panels: [8]PanelRect = undefined,
    len: usize = 0,

    pub fn append(self: *LayoutResult, panel: PanelRect) void {
        if (self.len >= self.panels.len) return;
        self.panels[self.len] = panel;
        self.len += 1;
    }

    pub fn slice(self: *const LayoutResult) []const PanelRect {
        return self.panels[0..self.len];
    }
};

pub fn computeRects(tree: *const LayoutTree, viewport: draw_context.Rect) LayoutResult {
    var result = LayoutResult{};
    if (tree.len == 0) return result;
    computeNode(tree, tree.root, viewport, &result);
    return result;
}

pub fn buildTwoColumnStacked(
    tree: *LayoutTree,
    left_kind: ?workspace.PanelKind,
    right_kinds: []const workspace.PanelKind,
    left_ratio: f32,
    gap: f32,
) NodeId {
    var right_node: ?NodeId = null;
    if (right_kinds.len == 1) {
        right_node = tree.add(.{ .Leaf = .{ .kind = right_kinds[0] } });
    } else if (right_kinds.len == 2) {
        const top = tree.add(.{ .Leaf = .{ .kind = right_kinds[0] } });
        const bottom = tree.add(.{ .Leaf = .{ .kind = right_kinds[1] } });
        right_node = tree.add(.{ .Split = .{ .axis = .horizontal, .ratio = 0.5, .gap = gap, .first = top, .second = bottom } });
    } else if (right_kinds.len >= 3) {
        const first = tree.add(.{ .Leaf = .{ .kind = right_kinds[0] } });
        const second = tree.add(.{ .Leaf = .{ .kind = right_kinds[1] } });
        const third = tree.add(.{ .Leaf = .{ .kind = right_kinds[2] } });
        const second_split = tree.add(.{ .Split = .{ .axis = .horizontal, .ratio = 0.5, .gap = gap, .first = second, .second = third } });
        right_node = tree.add(.{ .Split = .{ .axis = .horizontal, .ratio = 1.0 / 3.0, .gap = gap, .first = first, .second = second_split } });
    }

    if (left_kind) |kind| {
        const left_node = tree.add(.{ .Leaf = .{ .kind = kind } });
        if (right_node) |right_id| {
            return tree.add(.{ .Split = .{ .axis = .vertical, .ratio = left_ratio, .gap = gap, .first = left_node, .second = right_id } });
        }
        return left_node;
    }

    if (right_node) |right_id| return right_id;

    return tree.add(.{ .Leaf = .{ .kind = .Chat } });
}

fn computeNode(
    tree: *const LayoutTree,
    node_id: NodeId,
    rect: draw_context.Rect,
    out: *LayoutResult,
) void {
    const nodes = tree.slice();
    const node = nodes[@intCast(node_id)];
    switch (node) {
        .Leaf => |leaf| {
            out.append(.{ .kind = leaf.kind, .rect = rect });
        },
        .Split => |split| {
            const split_rect = splitRect(rect, split.axis, split.ratio, split.gap);
            computeNode(tree, split.first, split_rect.first, out);
            computeNode(tree, split.second, split_rect.second, out);
        },
        .Tabs => |tabs| {
            if (tabs.tabs.len == 0) return;
            const index = if (tabs.active < tabs.tabs.len) tabs.active else tabs.tabs.len - 1;
            computeNode(tree, tabs.tabs[index], rect, out);
        },
    }
}

const SplitRects = struct {
    first: draw_context.Rect,
    second: draw_context.Rect,
};

fn splitRect(rect: draw_context.Rect, axis: Axis, ratio: f32, gap: f32) SplitRects {
    const size = rect.size();
    const clamped_ratio = std.math.clamp(ratio, 0.0, 1.0);
    if (axis == .vertical) {
        const avail = @max(0.0, size[0] - gap);
        const first_w = avail * clamped_ratio;
        const second_w = avail - first_w;
        const first_rect = draw_context.Rect.fromMinSize(rect.min, .{ first_w, size[1] });
        const second_min = .{ rect.min[0] + first_w + gap, rect.min[1] };
        const second_rect = draw_context.Rect.fromMinSize(second_min, .{ second_w, size[1] });
        return .{ .first = first_rect, .second = second_rect };
    }

    const avail = @max(0.0, size[1] - gap);
    const first_h = avail * clamped_ratio;
    const second_h = avail - first_h;
    const first_rect = draw_context.Rect.fromMinSize(rect.min, .{ size[0], first_h });
    const second_min = .{ rect.min[0], rect.min[1] + first_h + gap };
    const second_rect = draw_context.Rect.fromMinSize(second_min, .{ size[0], second_h });
    return .{ .first = first_rect, .second = second_rect };
}
