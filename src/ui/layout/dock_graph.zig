const std = @import("std");
const draw_context = @import("../draw_context.zig");

pub const PanelId = u64;
pub const NodeId = u32;

pub const Axis = enum {
    vertical,
    horizontal,
};

pub const DropLocation = enum {
    left,
    right,
    top,
    bottom,
    center,
};

pub const SplitNode = struct {
    axis: Axis,
    ratio: f32,
    first: NodeId,
    second: NodeId,
};

pub const TabsNode = struct {
    active: usize = 0,
    tabs: std.ArrayList(PanelId),

    pub fn deinit(self: *TabsNode, allocator: std.mem.Allocator) void {
        self.tabs.deinit(allocator);
    }
};

pub const Node = union(enum) {
    split: SplitNode,
    tabs: TabsNode,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .split => {},
            .tabs => |*tabs| tabs.deinit(allocator),
        }
    }
};

pub const SplitSnapshot = struct {
    axis: Axis,
    ratio: f32,
    first: NodeId,
    second: NodeId,
};

pub const TabsSnapshot = struct {
    active: usize = 0,
    tabs: ?[]PanelId = null,

    pub fn deinit(self: *TabsSnapshot, allocator: std.mem.Allocator) void {
        if (self.tabs) |tabs| allocator.free(tabs);
        self.* = undefined;
    }
};

pub const NodeSnapshot = struct {
    id: NodeId,
    split: ?SplitSnapshot = null,
    tabs: ?TabsSnapshot = null,

    pub fn deinit(self: *NodeSnapshot, allocator: std.mem.Allocator) void {
        if (self.tabs) |*tabs| {
            tabs.deinit(allocator);
        }
        self.* = undefined;
    }
};

pub const GraphSnapshot = struct {
    layout_version: u32 = 2,
    root: ?NodeId = null,
    nodes: ?[]NodeSnapshot = null,

    pub fn deinit(self: *GraphSnapshot, allocator: std.mem.Allocator) void {
        if (self.nodes) |nodes| {
            for (nodes) |*n| n.deinit(allocator);
            allocator.free(nodes);
        }
        self.* = undefined;
    }
};

pub const LayoutGroup = struct {
    node_id: NodeId,
    rect: draw_context.Rect,
};

pub const Splitter = struct {
    node_id: NodeId,
    axis: Axis,
    handle_rect: draw_context.Rect,
    container_rect: draw_context.Rect,
};

pub const LayoutResult = struct {
    groups: [32]LayoutGroup = undefined,
    len: usize = 0,

    pub fn append(self: *LayoutResult, g: LayoutGroup) void {
        if (self.len >= self.groups.len) return;
        self.groups[self.len] = g;
        self.len += 1;
    }

    pub fn slice(self: *const LayoutResult) []const LayoutGroup {
        return self.groups[0..self.len];
    }
};

pub const SplitterResult = struct {
    splitters: [32]Splitter = undefined,
    len: usize = 0,

    pub fn append(self: *SplitterResult, s: Splitter) void {
        if (self.len >= self.splitters.len) return;
        self.splitters[self.len] = s;
        self.len += 1;
    }

    pub fn slice(self: *const SplitterResult) []const Splitter {
        return self.splitters[0..self.len];
    }
};

pub const Graph = struct {
    const PanelLoc = struct {
        node_id: NodeId,
        tab_index: usize,
    };

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(?Node),
    root: ?NodeId = null,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .root = null,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node_opt| {
            if (node_opt.*) |*node| node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Graph) void {
        for (self.nodes.items) |*node_opt| {
            if (node_opt.*) |*node| node.deinit(self.allocator);
            node_opt.* = null;
        }
        self.nodes.clearRetainingCapacity();
        self.root = null;
    }

    pub fn cloneFrom(self: *Graph, src: *const Graph) !void {
        self.clear();
        try self.nodes.ensureTotalCapacity(self.allocator, src.nodes.items.len);
        for (src.nodes.items) |node_opt| {
            if (node_opt) |node| {
                switch (node) {
                    .split => |s| try self.nodes.append(self.allocator, .{ .split = s }),
                    .tabs => |tabs| {
                        var new_tabs = std.ArrayList(PanelId).empty;
                        try new_tabs.ensureTotalCapacity(self.allocator, tabs.tabs.items.len);
                        try new_tabs.appendSlice(self.allocator, tabs.tabs.items);
                        try self.nodes.append(self.allocator, .{ .tabs = .{ .active = tabs.active, .tabs = new_tabs } });
                    },
                }
            } else {
                try self.nodes.append(self.allocator, null);
            }
        }
        self.root = src.root;
    }

    pub fn fromSnapshot(allocator: std.mem.Allocator, snap_opt: ?GraphSnapshot) !Graph {
        var g = Graph.init(allocator);
        const snap = snap_opt orelse return g;
        const nodes = snap.nodes orelse {
            g.root = snap.root;
            return g;
        };

        var max_id: NodeId = 0;
        for (nodes) |n| {
            if (n.id > max_id) max_id = n.id;
        }
        const cap: usize = @as(usize, @intCast(max_id)) + 1;
        try g.nodes.resize(allocator, cap);
        for (g.nodes.items) |*slot| slot.* = null;

        for (nodes) |n| {
            const idx: usize = @intCast(n.id);
            if (n.tabs) |tabs_snap| {
                var tabs = std.ArrayList(PanelId).empty;
                const src_tabs = tabs_snap.tabs orelse &[_]PanelId{};
                try tabs.ensureTotalCapacity(allocator, src_tabs.len);
                try tabs.appendSlice(allocator, src_tabs);
                g.nodes.items[idx] = .{ .tabs = .{ .active = tabs_snap.active, .tabs = tabs } };
            } else if (n.split) |split| {
                g.nodes.items[idx] = .{ .split = .{
                    .axis = split.axis,
                    .ratio = split.ratio,
                    .first = split.first,
                    .second = split.second,
                } };
            } else {
                // Unknown/empty node entry.
                g.nodes.items[idx] = null;
            }
        }

        if (snap.root) |rid| {
            if (rid < g.nodes.items.len and g.nodes.items[@intCast(rid)] != null) {
                g.root = rid;
            }
        }

        g.normalize();
        return g;
    }

    pub fn toSnapshot(self: *const Graph, allocator: std.mem.Allocator) !GraphSnapshot {
        var snap = GraphSnapshot{ .layout_version = 2, .root = self.root, .nodes = null };
        errdefer snap.deinit(allocator);

        if (self.root == null) return snap;

        var seen = std.AutoHashMap(NodeId, void).init(allocator);
        defer seen.deinit();

        var stack = std.ArrayList(NodeId).empty;
        defer stack.deinit(allocator);

        try stack.append(allocator, self.root.?);
        while (stack.pop()) |nid| {
            if (seen.contains(nid)) continue;
            const node = self.getNode(nid) orelse continue;
            try seen.put(nid, {});
            switch (node.*) {
                .split => |s| {
                    try stack.append(allocator, s.first);
                    try stack.append(allocator, s.second);
                },
                .tabs => {},
            }
        }

        const count = seen.count();
        if (count == 0) {
            snap.root = null;
            return snap;
        }

        var ids = try allocator.alloc(NodeId, count);
        defer allocator.free(ids);
        var i: usize = 0;
        var it = seen.iterator();
        while (it.next()) |entry| : (i += 1) {
            ids[i] = entry.key_ptr.*;
        }
        std.mem.sortUnstable(NodeId, ids, {}, struct {
            fn lessThan(_: void, a: NodeId, b: NodeId) bool {
                return a < b;
            }
        }.lessThan);

        var out = try allocator.alloc(NodeSnapshot, ids.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |*n| n.deinit(allocator);
            allocator.free(out);
        }

        for (ids) |id| {
            const node = self.getNode(id) orelse continue;
            var ns = NodeSnapshot{ .id = id };
            switch (node.*) {
                .split => |s| {
                    ns.split = .{ .axis = s.axis, .ratio = s.ratio, .first = s.first, .second = s.second };
                },
                .tabs => |tabs| {
                    const list = try allocator.alloc(PanelId, tabs.tabs.items.len);
                    @memcpy(list, tabs.tabs.items);
                    ns.tabs = .{ .active = tabs.active, .tabs = list };
                },
            }
            out[filled] = ns;
            filled += 1;
        }

        snap.nodes = out;
        return snap;
    }

    pub fn addTabsNode(self: *Graph, panel_ids: []const PanelId, active: usize) !NodeId {
        var tabs = std.ArrayList(PanelId).empty;
        try tabs.ensureTotalCapacity(self.allocator, panel_ids.len);
        try tabs.appendSlice(self.allocator, panel_ids);

        const clamped_active = if (tabs.items.len == 0) 0 else @min(active, tabs.items.len - 1);
        const id = try self.appendNode(.{ .tabs = .{ .active = clamped_active, .tabs = tabs } });
        return id;
    }

    pub fn addSplitNode(self: *Graph, axis: Axis, ratio: f32, first: NodeId, second: NodeId) !NodeId {
        const id = try self.appendNode(.{ .split = .{
            .axis = axis,
            .ratio = std.math.clamp(ratio, 0.1, 0.9),
            .first = first,
            .second = second,
        } });
        return id;
    }

    pub fn getNode(self: *const Graph, id: NodeId) ?*const Node {
        if (id >= self.nodes.items.len) return null;
        const node_opt = self.nodes.items[@intCast(id)];
        if (node_opt) |*n| return n;
        return null;
    }

    pub fn getNodeMut(self: *Graph, id: NodeId) ?*Node {
        if (id >= self.nodes.items.len) return null;
        if (self.nodes.items[@intCast(id)]) |*n| return n;
        return null;
    }

    pub fn firstTabsNode(self: *const Graph) ?NodeId {
        const root = self.root orelse return null;
        return self.firstTabsNodeFrom(root);
    }

    pub fn firstTabsNodeFrom(self: *const Graph, start: NodeId) ?NodeId {
        const node = self.getNode(start) orelse return null;
        switch (node.*) {
            .tabs => return start,
            .split => |s| {
                if (self.firstTabsNodeFrom(s.first)) |id| return id;
                return self.firstTabsNodeFrom(s.second);
            },
        }
    }

    pub fn containsPanel(self: *const Graph, panel_id: PanelId) bool {
        return self.findPanel(panel_id) != null;
    }

    pub fn findPanel(self: *const Graph, panel_id: PanelId) ?PanelLoc {
        var idx: usize = 0;
        while (idx < self.nodes.items.len) : (idx += 1) {
            const node_opt = self.nodes.items[idx];
            const node = node_opt orelse continue;
            switch (node) {
                .tabs => |tabs| {
                    for (tabs.tabs.items, 0..) |tab, tab_idx| {
                        if (tab == panel_id) return .{ .node_id = @intCast(idx), .tab_index = tab_idx };
                    }
                },
                .split => {},
            }
        }
        return null;
    }

    pub fn setActiveTab(self: *Graph, node_id: NodeId, tab_index: usize) bool {
        const node = self.getNodeMut(node_id) orelse return false;
        switch (node.*) {
            .tabs => |*tabs| {
                if (tabs.tabs.items.len == 0) return false;
                tabs.active = @min(tab_index, tabs.tabs.items.len - 1);
                return true;
            },
            .split => return false,
        }
    }

    pub fn setSplitRatio(self: *Graph, node_id: NodeId, ratio: f32) bool {
        const node = self.getNodeMut(node_id) orelse return false;
        switch (node.*) {
            .split => |*split| {
                const clamped = std.math.clamp(ratio, 0.1, 0.9);
                if (@abs(split.ratio - clamped) < 0.0001) return false;
                split.ratio = clamped;
                return true;
            },
            .tabs => return false,
        }
    }

    pub fn syncPanels(self: *Graph, panel_ids: []const PanelId) !bool {
        var changed = false;

        var keep = std.AutoHashMap(PanelId, void).init(self.allocator);
        defer keep.deinit();
        for (panel_ids) |id| {
            try keep.put(id, {});
        }

        var idx: usize = 0;
        while (idx < self.nodes.items.len) : (idx += 1) {
            var node = self.nodes.items[idx] orelse continue;
            switch (node) {
                .tabs => |*tabs| {
                    var i: usize = 0;
                    while (i < tabs.tabs.items.len) {
                        const pid = tabs.tabs.items[i];
                        if (!keep.contains(pid)) {
                            _ = tabs.tabs.orderedRemove(i);
                            changed = true;
                            continue;
                        }
                        i += 1;
                    }
                    if (tabs.tabs.items.len == 0) {
                        tabs.active = 0;
                    } else if (tabs.active >= tabs.tabs.items.len) {
                        tabs.active = tabs.tabs.items.len - 1;
                    }
                    self.nodes.items[idx] = node;
                },
                .split => {},
            }
        }

        self.normalize();
        if (self.pruneUnreachableNodes()) {
            changed = true;
        }

        for (panel_ids) |pid| {
            if (self.findPanelReachable(pid) != null) continue;
            try self.appendPanelToBestTabs(pid);
            changed = true;
        }

        if (self.root == null and panel_ids.len > 0) {
            const root_tabs = try self.addTabsNode(panel_ids, 0);
            self.root = root_tabs;
            changed = true;
        }

        return changed;
    }

    fn findPanelReachable(self: *const Graph, panel_id: PanelId) ?PanelLoc {
        const root = self.root orelse return null;
        return self.findPanelFromSubtree(root, panel_id);
    }

    fn findPanelFromSubtree(self: *const Graph, node_id: NodeId, panel_id: PanelId) ?PanelLoc {
        const node = self.getNode(node_id) orelse return null;
        return switch (node.*) {
            .tabs => |tabs| blk: {
                for (tabs.tabs.items, 0..) |tab, tab_idx| {
                    if (tab == panel_id) {
                        break :blk .{ .node_id = node_id, .tab_index = tab_idx };
                    }
                }
                break :blk null;
            },
            .split => |split| self.findPanelFromSubtree(split.first, panel_id) orelse self.findPanelFromSubtree(split.second, panel_id),
        };
    }

    fn pruneUnreachableNodes(self: *Graph) bool {
        if (self.nodes.items.len == 0) return false;

        var reachable = std.ArrayList(bool).empty;
        defer reachable.deinit(self.allocator);
        reachable.resize(self.allocator, self.nodes.items.len) catch return false;
        @memset(reachable.items, false);

        if (self.root) |root_id| {
            self.markReachable(root_id, reachable.items);
        }

        var changed = false;
        var idx: usize = 0;
        while (idx < self.nodes.items.len) : (idx += 1) {
            if (reachable.items[idx]) continue;
            if (self.nodes.items[idx]) |*node| {
                node.deinit(self.allocator);
                self.nodes.items[idx] = null;
                changed = true;
            }
        }
        return changed;
    }

    fn markReachable(self: *const Graph, node_id: NodeId, reachable: []bool) void {
        if (node_id >= reachable.len) return;
        const idx: usize = @intCast(node_id);
        if (reachable[idx]) return;

        const node = self.getNode(node_id) orelse return;
        reachable[idx] = true;
        switch (node.*) {
            .tabs => {},
            .split => |split| {
                self.markReachable(split.first, reachable);
                self.markReachable(split.second, reachable);
            },
        }
    }

    pub fn movePanelToTabs(self: *Graph, panel_id: PanelId, target_tabs_node: NodeId, insert_index_opt: ?usize) !bool {
        const src = self.findPanel(panel_id) orelse return false;
        const dst_node = self.getNodeMut(target_tabs_node) orelse return false;
        var dst_tabs_ptr: *TabsNode = switch (dst_node.*) {
            .tabs => |*tabs| tabs,
            .split => return false,
        };

        // Same tabs node: reorder only.
        if (src.node_id == target_tabs_node) {
            if (dst_tabs_ptr.tabs.items.len <= 1) return false;
            const src_idx = src.tab_index;
            var dst_idx = insert_index_opt orelse dst_tabs_ptr.tabs.items.len;
            if (dst_idx > dst_tabs_ptr.tabs.items.len) dst_idx = dst_tabs_ptr.tabs.items.len;
            if (dst_idx > src_idx) dst_idx -= 1;
            if (dst_idx == src_idx) {
                dst_tabs_ptr.active = src_idx;
                return true;
            }
            const pid = dst_tabs_ptr.tabs.orderedRemove(src_idx);
            try dst_tabs_ptr.tabs.insert(self.allocator, dst_idx, pid);
            dst_tabs_ptr.active = dst_idx;
            return true;
        }

        const src_node = self.getNodeMut(src.node_id) orelse return false;
        var src_tabs_ptr: *TabsNode = switch (src_node.*) {
            .tabs => |*tabs| tabs,
            .split => return false,
        };

        const pid = src_tabs_ptr.tabs.orderedRemove(src.tab_index);
        if (src_tabs_ptr.tabs.items.len == 0) {
            src_tabs_ptr.active = 0;
        } else if (src_tabs_ptr.active >= src_tabs_ptr.tabs.items.len) {
            src_tabs_ptr.active = src_tabs_ptr.tabs.items.len - 1;
        }

        var dst_idx = insert_index_opt orelse dst_tabs_ptr.tabs.items.len;
        if (dst_idx > dst_tabs_ptr.tabs.items.len) dst_idx = dst_tabs_ptr.tabs.items.len;
        try dst_tabs_ptr.tabs.insert(self.allocator, dst_idx, pid);
        dst_tabs_ptr.active = dst_idx;

        self.normalize();
        return true;
    }

    pub fn splitNodeWithPanel(self: *Graph, target_node: NodeId, panel_id: PanelId, location: DropLocation) !bool {
        if (location == .center) {
            return self.movePanelToTabs(panel_id, target_node, null);
        }

        const src = self.findPanel(panel_id) orelse return false;
        // Capture the target parent before introducing a new split node. Looking it up
        // afterwards can return the freshly created split and orphan the drop when the
        // target was the root.
        const target_parent = self.findParent(target_node);
        if (src.node_id == target_node) {
            const src_node = self.getNode(src.node_id) orelse return false;
            const src_tabs = switch (src_node.*) {
                .tabs => |tabs| tabs,
                .split => return false,
            };
            // Need at least one remaining tab in the source group.
            if (src_tabs.tabs.items.len <= 1) return false;
        }

        const new_tabs = try self.addTabsNode(&[_]PanelId{panel_id}, 0);

        // Remove from previous location.
        {
            const src_node = self.getNodeMut(src.node_id) orelse return false;
            switch (src_node.*) {
                .tabs => |*tabs| {
                    _ = tabs.tabs.orderedRemove(src.tab_index);
                    if (tabs.tabs.items.len == 0) {
                        tabs.active = 0;
                    } else if (tabs.active >= tabs.tabs.items.len) {
                        tabs.active = tabs.tabs.items.len - 1;
                    }
                },
                .split => return false,
            }
        }

        const axis: Axis = switch (location) {
            .left, .right => .vertical,
            .top, .bottom => .horizontal,
            .center => .vertical,
        };

        const split_id = switch (location) {
            .left, .top => try self.addSplitNode(axis, 0.5, new_tabs, target_node),
            .right, .bottom => try self.addSplitNode(axis, 0.5, target_node, new_tabs),
            .center => unreachable,
        };

        if (target_parent) |parent| {
            if (self.getNodeMut(parent.parent_id)) |parent_node| {
                switch (parent_node.*) {
                    .split => |*split| {
                        if (parent.is_first) {
                            split.first = split_id;
                        } else {
                            split.second = split_id;
                        }
                    },
                    .tabs => {},
                }
            }
        } else {
            self.root = split_id;
        }

        self.normalize();
        if (self.findPanel(panel_id)) |dst| {
            _ = self.setActiveTab(dst.node_id, dst.tab_index);
        }
        return true;
    }

    pub fn removePanel(self: *Graph, panel_id: PanelId) bool {
        const found = self.findPanel(panel_id) orelse return false;
        const node = self.getNodeMut(found.node_id) orelse return false;
        switch (node.*) {
            .tabs => |*tabs| {
                _ = tabs.tabs.orderedRemove(found.tab_index);
                if (tabs.tabs.items.len == 0) {
                    tabs.active = 0;
                } else if (tabs.active >= tabs.tabs.items.len) {
                    tabs.active = tabs.tabs.items.len - 1;
                }
            },
            .split => return false,
        }
        self.normalize();
        return true;
    }

    pub fn computeLayout(self: *const Graph, viewport: draw_context.Rect) LayoutResult {
        var out = LayoutResult{};
        const root = self.root orelse return out;
        self.computeNodeLayout(root, viewport, &out);
        return out;
    }

    pub fn computeSplitters(self: *const Graph, viewport: draw_context.Rect) SplitterResult {
        var out = SplitterResult{};
        const root = self.root orelse return out;
        self.computeNodeSplitters(root, viewport, &out);
        return out;
    }

    pub fn normalize(self: *Graph) void {
        const root = self.root orelse return;
        self.root = self.normalizeNode(root);
    }

    fn normalizeNode(self: *Graph, id: NodeId) ?NodeId {
        const node = self.getNodeMut(id) orelse return null;
        switch (node.*) {
            .tabs => |*tabs| {
                if (tabs.tabs.items.len == 0) return null;
                if (tabs.active >= tabs.tabs.items.len) tabs.active = tabs.tabs.items.len - 1;
                return id;
            },
            .split => |*split| {
                split.ratio = std.math.clamp(split.ratio, 0.1, 0.9);
                const left = self.normalizeNode(split.first);
                const right = self.normalizeNode(split.second);
                if (left == null and right == null) return null;
                if (left == null) return right;
                if (right == null) return left;
                split.first = left.?;
                split.second = right.?;
                return id;
            },
        }
    }

    fn appendNode(self: *Graph, node: Node) !NodeId {
        try self.nodes.append(self.allocator, node);
        return @intCast(self.nodes.items.len - 1);
    }

    fn findParent(self: *const Graph, child: NodeId) ?struct { parent_id: NodeId, is_first: bool } {
        var idx: usize = 0;
        while (idx < self.nodes.items.len) : (idx += 1) {
            const node = self.nodes.items[idx] orelse continue;
            switch (node) {
                .split => |s| {
                    if (s.first == child) return .{ .parent_id = @intCast(idx), .is_first = true };
                    if (s.second == child) return .{ .parent_id = @intCast(idx), .is_first = false };
                },
                .tabs => {},
            }
        }
        return null;
    }

    fn appendPanelToBestTabs(self: *Graph, panel_id: PanelId) !void {
        if (self.root == null) {
            const tabs = try self.addTabsNode(&[_]PanelId{panel_id}, 0);
            self.root = tabs;
            return;
        }

        if (self.firstTabsNode()) |tabs_id| {
            if (self.getNodeMut(tabs_id)) |node| {
                switch (node.*) {
                    .tabs => |*tabs| {
                        try tabs.tabs.append(self.allocator, panel_id);
                        tabs.active = tabs.tabs.items.len - 1;
                    },
                    .split => unreachable,
                }
            }
            return;
        }

        const tabs = try self.addTabsNode(&[_]PanelId{panel_id}, 0);
        if (self.root) |root_id| {
            const new_root = try self.addSplitNode(.vertical, 0.5, root_id, tabs);
            self.root = new_root;
        } else {
            self.root = tabs;
        }
    }

    fn computeNodeLayout(
        self: *const Graph,
        node_id: NodeId,
        rect: draw_context.Rect,
        out: *LayoutResult,
    ) void {
        const node = self.getNode(node_id) orelse return;
        switch (node.*) {
            .tabs => {
                out.append(.{ .node_id = node_id, .rect = rect });
            },
            .split => |split| {
                const split_rect = splitRect(rect, split.axis, split.ratio, 6.0);
                self.computeNodeLayout(split.first, split_rect.first, out);
                self.computeNodeLayout(split.second, split_rect.second, out);
            },
        }
    }

    fn computeNodeSplitters(
        self: *const Graph,
        node_id: NodeId,
        rect: draw_context.Rect,
        out: *SplitterResult,
    ) void {
        const node = self.getNode(node_id) orelse return;
        switch (node.*) {
            .tabs => {},
            .split => |split| {
                const gap: f32 = 6.0;
                const split_rect = splitRect(rect, split.axis, split.ratio, gap);
                const handle_rect = switch (split.axis) {
                    .vertical => draw_context.Rect.fromMinSize(
                        .{ split_rect.first.max[0], rect.min[1] },
                        .{ gap, rect.size()[1] },
                    ),
                    .horizontal => draw_context.Rect.fromMinSize(
                        .{ rect.min[0], split_rect.first.max[1] },
                        .{ rect.size()[0], gap },
                    ),
                };
                out.append(.{
                    .node_id = node_id,
                    .axis = split.axis,
                    .handle_rect = handle_rect,
                    .container_rect = rect,
                });
                self.computeNodeSplitters(split.first, split_rect.first, out);
                self.computeNodeSplitters(split.second, split_rect.second, out);
            },
        }
    }
};

const SplitRects = struct {
    first: draw_context.Rect,
    second: draw_context.Rect,
};

fn splitRect(rect: draw_context.Rect, axis: Axis, ratio: f32, gap: f32) SplitRects {
    const size = rect.size();
    const clamped_ratio = std.math.clamp(ratio, 0.1, 0.9);
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
