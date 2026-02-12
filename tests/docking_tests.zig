const std = @import("std");
const zsc = @import("ziggystarclaw");
const dock_graph = zsc.ui.layout.dock_graph;
const dock_drop = zsc.ui.layout.dock_drop;
const dock_detach = zsc.ui.layout.dock_detach;
const dock_rail = zsc.ui.layout.dock_rail;
const dock_transfer = zsc.ui.dock_transfer;
const draw_context = zsc.ui.draw_context;
const main_window = zsc.ui.main_window;
const panel_manager = zsc.ui.panel_manager;
const workspace_store = zsc.ui.workspace_store;

const workspace = zsc.ui.workspace;

fn testViewport() draw_context.Rect {
    return draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 1200.0, 800.0 });
}

fn focusPanelAndActivate(manager: *panel_manager.PanelManager, panel_id: workspace.PanelId) !void {
    manager.workspace.focused_panel_id = panel_id;
    const loc = manager.workspace.dock_layout.findPanel(panel_id) orelse return error.TestExpectedPanel;
    _ = manager.workspace.dock_layout.setActiveTab(loc.node_id, loc.tab_index);
}

fn applyShortcut(
    allocator: std.mem.Allocator,
    manager: *panel_manager.PanelManager,
    key: main_window.DockShortcutTestKey,
    mods: main_window.DockShortcutTestMods,
) main_window.DockShortcutTestResult {
    return main_window.applyDockShortcutForTest(allocator, manager, testViewport(), key, mods);
}

fn applyShortcutWithState(
    allocator: std.mem.Allocator,
    manager: *panel_manager.PanelManager,
    win_state: *main_window.WindowUiState,
    key: main_window.DockShortcutTestKey,
    mods: main_window.DockShortcutTestMods,
) main_window.DockShortcutTestResult {
    return main_window.applyDockShortcutForTestWithState(allocator, manager, testViewport(), win_state, key, mods);
}

fn tabsForPanelNode(graph: *const dock_graph.Graph, panel_id: workspace.PanelId) ![]const workspace.PanelId {
    const loc = graph.findPanel(panel_id) orelse return error.TestExpectedPanel;
    const node = graph.getNode(loc.node_id) orelse return error.TestExpectedNode;
    return switch (node.*) {
        .tabs => |tabs| tabs.tabs.items,
        .split => error.TestExpectedTabsNode,
    };
}

fn centerXForNode(graph: *const dock_graph.Graph, node_id: dock_graph.NodeId, viewport: draw_context.Rect) !f32 {
    const groups = graph.computeLayout(viewport).slice();
    for (groups) |g| {
        if (g.node_id != node_id) continue;
        return g.rect.min[0] + g.rect.size()[0] * 0.5;
    }
    return error.TestExpectedNode;
}

fn layoutContainsNode(graph: *const dock_graph.Graph, node_id: dock_graph.NodeId, viewport: draw_context.Rect) bool {
    const groups = graph.computeLayout(viewport).slice();
    for (groups) |g| {
        if (g.node_id == node_id) return true;
    }
    return false;
}

fn workspaceContainsPanelId(ws: *const workspace.Workspace, panel_id: workspace.PanelId) bool {
    for (ws.panels.items) |panel| {
        if (panel.id == panel_id) return true;
    }
    return false;
}

test "dock drop classifier maps side and center regions" {
    const rect = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 100.0, 100.0 });

    try std.testing.expectEqual(dock_graph.DropLocation.left, dock_drop.classifyDropLocation(rect, .{ 10.0, 50.0 }));
    try std.testing.expectEqual(dock_graph.DropLocation.right, dock_drop.classifyDropLocation(rect, .{ 90.0, 50.0 }));
    try std.testing.expectEqual(dock_graph.DropLocation.top, dock_drop.classifyDropLocation(rect, .{ 50.0, 10.0 }));
    try std.testing.expectEqual(dock_graph.DropLocation.bottom, dock_drop.classifyDropLocation(rect, .{ 50.0, 90.0 }));
    try std.testing.expectEqual(dock_graph.DropLocation.center, dock_drop.classifyDropLocation(rect, .{ 50.0, 50.0 }));
}

test "dock rail side classifier maps groups to left and right rails" {
    const host = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 1200.0, 800.0 });
    const left_group = draw_context.Rect.fromMinSize(.{ 40.0, 0.0 }, .{ 300.0, 800.0 });
    const right_group = draw_context.Rect.fromMinSize(.{ 860.0, 0.0 }, .{ 300.0, 800.0 });
    const center_left = draw_context.Rect.fromMinSize(.{ 500.0, 0.0 }, .{ 200.0, 800.0 });
    // Wide group anchored to the right edge (center drifts left of midpoint).
    const right_anchored_wide = draw_context.Rect.fromMinSize(.{ 380.0, 0.0 }, .{ 820.0, 800.0 });

    try std.testing.expectEqual(dock_rail.Side.left, dock_rail.sideForRect(host, left_group));
    try std.testing.expectEqual(dock_rail.Side.right, dock_rail.sideForRect(host, right_group));
    try std.testing.expectEqual(dock_rail.Side.left, dock_rail.sideForRect(host, center_left));
    try std.testing.expectEqual(dock_rail.Side.right, dock_rail.sideForRect(host, right_anchored_wide));
}

test "dock rail collapsible side only applies to edge-anchored groups" {
    const host = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 1200.0, 800.0 });
    const left_group = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 320.0, 800.0 });
    const right_group = draw_context.Rect.fromMinSize(.{ 880.0, 0.0 }, .{ 320.0, 800.0 });
    const center_group = draw_context.Rect.fromMinSize(.{ 300.0, 0.0 }, .{ 600.0, 800.0 });
    const full_width = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 1200.0, 800.0 });

    try std.testing.expectEqual(dock_rail.Side.left, dock_rail.collapsibleSideForRect(host, left_group) orelse return error.TestExpectedValue);
    try std.testing.expectEqual(dock_rail.Side.right, dock_rail.collapsibleSideForRect(host, right_group) orelse return error.TestExpectedValue);
    try std.testing.expect(dock_rail.collapsibleSideForRect(host, center_group) == null);
    try std.testing.expect(dock_rail.collapsibleSideForRect(host, full_width) == null);
}

test "dock rail collapsed set collapse expand and prune behavior" {
    var collapsed = dock_rail.CollapsedSet{};
    collapsed.collapse(10, .left);
    collapsed.collapse(11, .right);
    collapsed.collapse(10, .right); // update side for existing entry

    try std.testing.expect(collapsed.isCollapsed(10));
    try std.testing.expectEqual(dock_rail.Side.right, collapsed.sideForNode(10) orelse return error.TestExpectedValue);
    try std.testing.expectEqual(@as(usize, 0), collapsed.countForSide(.left));
    try std.testing.expectEqual(@as(usize, 2), collapsed.countForSide(.right));

    try std.testing.expect(collapsed.expand(11));
    try std.testing.expect(!collapsed.isCollapsed(11));
    try std.testing.expectEqual(@as(usize, 1), collapsed.countForSide(.right));

    const allocator = std.testing.allocator;
    var graph = dock_graph.Graph.init(allocator);
    defer graph.deinit();

    const tabs = try graph.addTabsNode(&[_]workspace.PanelId{1}, 0);
    const tabs2 = try graph.addTabsNode(&[_]workspace.PanelId{2}, 0);
    const split = try graph.addSplitNode(.vertical, 0.5, tabs, tabs2);
    graph.root = tabs;

    collapsed.collapse(tabs, .left);
    collapsed.collapse(split, .right); // prune should remove split entries
    collapsed.collapse(9999, .left); // and missing nodes
    collapsed.prune(&graph);

    try std.testing.expect(collapsed.isCollapsed(tabs));
    try std.testing.expect(!collapsed.isCollapsed(split));
    try std.testing.expect(!collapsed.isCollapsed(9999));
}

test "dock drop classifier corners prefer horizontal sides and degenerate rect centers" {
    const rect = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 100.0, 100.0 });
    try std.testing.expectEqual(dock_graph.DropLocation.left, dock_drop.classifyDropLocation(rect, .{ 5.0, 5.0 }));
    try std.testing.expectEqual(dock_graph.DropLocation.right, dock_drop.classifyDropLocation(rect, .{ 95.0, 5.0 }));

    const degenerate = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 0.0, 100.0 });
    try std.testing.expectEqual(dock_graph.DropLocation.center, dock_drop.classifyDropLocation(degenerate, .{ 0.0, 10.0 }));
}

test "dock drop target picker selects hovered group and directional zone" {
    const allocator = std.testing.allocator;
    var graph = dock_graph.Graph.init(allocator);
    defer graph.deinit();

    const left = try graph.addTabsNode(&[_]workspace.PanelId{1}, 0);
    const right = try graph.addTabsNode(&[_]workspace.PanelId{2}, 0);
    graph.root = try graph.addSplitNode(.vertical, 0.5, left, right);

    const viewport = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 1000.0, 600.0 });

    const left_center = dock_drop.pickDropTarget(&graph, viewport, .{ 200.0, 300.0 }) orelse return error.TestExpectedDropTarget;
    try std.testing.expectEqual(left, left_center.node_id);
    try std.testing.expectEqual(dock_graph.DropLocation.center, left_center.location);

    const right_top = dock_drop.pickDropTarget(&graph, viewport, .{ 700.0, 40.0 }) orelse return error.TestExpectedDropTarget;
    try std.testing.expectEqual(right, right_top.node_id);
    try std.testing.expectEqual(dock_graph.DropLocation.top, right_top.location);
}

test "dock drop target picker falls back to first tabs node outside groups" {
    const allocator = std.testing.allocator;
    var graph = dock_graph.Graph.init(allocator);
    defer graph.deinit();

    const left = try graph.addTabsNode(&[_]workspace.PanelId{1}, 0);
    const right = try graph.addTabsNode(&[_]workspace.PanelId{2}, 0);
    graph.root = try graph.addSplitNode(.vertical, 0.5, left, right);

    const viewport = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 1000.0, 600.0 });
    // x=500 lands in the split gap for a 0.5 split with 6px handle gap.
    const fallback = dock_drop.pickDropTarget(&graph, viewport, .{ 500.0, 300.0 }) orelse return error.TestExpectedDropTarget;
    try std.testing.expectEqual(left, fallback.node_id);
    try std.testing.expectEqual(dock_graph.DropLocation.center, fallback.location);

    var empty = dock_graph.Graph.init(allocator);
    defer empty.deinit();
    try std.testing.expect(dock_drop.pickDropTarget(&empty, viewport, .{ 10.0, 10.0 }) == null);
}

test "dock detach helper cross-window attach routing" {
    try std.testing.expect(!dock_detach.shouldTryCrossWindowAttach(false, 10, 20));
    try std.testing.expect(!dock_detach.shouldTryCrossWindowAttach(true, 10, 0));
    try std.testing.expect(!dock_detach.shouldTryCrossWindowAttach(true, 10, 10));
    try std.testing.expect(dock_detach.shouldTryCrossWindowAttach(true, 10, 11));
}

test "dock detach helper group rollback rule" {
    try std.testing.expect(dock_detach.shouldRollbackGroupTransfer(false, 3));
    try std.testing.expect(dock_detach.shouldRollbackGroupTransfer(true, 0));
    try std.testing.expect(!dock_detach.shouldRollbackGroupTransfer(true, 2));
}

test "dock detach helper plans missing split empty and tabs nodes" {
    const allocator = std.testing.allocator;
    var graph = dock_graph.Graph.init(allocator);
    defer graph.deinit();

    switch (dock_detach.planGroupDetach(&graph, 9999)) {
        .node_not_found => {},
        else => return error.TestUnexpectedDetachPlan,
    }

    const empty_tabs = try graph.addTabsNode(&[_]workspace.PanelId{}, 0);
    switch (dock_detach.planGroupDetach(&graph, empty_tabs)) {
        .empty_tabs => {},
        else => return error.TestUnexpectedDetachPlan,
    }

    const left = try graph.addTabsNode(&[_]workspace.PanelId{1}, 0);
    const right = try graph.addTabsNode(&[_]workspace.PanelId{2}, 0);
    const split = try graph.addSplitNode(.vertical, 0.5, left, right);
    switch (dock_detach.planGroupDetach(&graph, split)) {
        .split_node => {},
        else => return error.TestUnexpectedDetachPlan,
    }

    switch (dock_detach.planGroupDetach(&graph, left)) {
        .tabs => |ids| {
            try std.testing.expectEqual(@as(usize, 1), ids.len);
            try std.testing.expectEqual(@as(workspace.PanelId, 1), ids[0]);
        },
        else => return error.TestUnexpectedDetachPlan,
    }
}

test "dock transfer helper moves panels and skips missing ids" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    try ws.panels.append(allocator, try workspace.makeShowcasePanel(allocator, 99));

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    var dst = workspace.Workspace.initEmpty(allocator);
    defer dst.deinit(allocator);

    const result = dock_transfer.transferPanelsToWorkspace(
        allocator,
        &manager,
        &[_]workspace.PanelId{ 2, 999, 99 },
        &dst,
    );
    try std.testing.expect(result.moved_ok);
    try std.testing.expectEqual(@as(usize, 2), result.moved_count);
    try std.testing.expect(!workspaceContainsPanelId(&manager.workspace, 2));
    try std.testing.expect(!workspaceContainsPanelId(&manager.workspace, 99));
    try std.testing.expect(workspaceContainsPanelId(&dst, 2));
    try std.testing.expect(workspaceContainsPanelId(&dst, 99));
}

test "dock transfer helper restore puts moved panels back" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    try ws.panels.append(allocator, try workspace.makeShowcasePanel(allocator, 99));

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    var dst = workspace.Workspace.initEmpty(allocator);
    defer dst.deinit(allocator);

    const result = dock_transfer.transferPanelsToWorkspace(
        allocator,
        &manager,
        &[_]workspace.PanelId{ 2, 99 },
        &dst,
    );
    try std.testing.expect(result.moved_ok);
    try std.testing.expectEqual(@as(usize, 2), result.moved_count);

    dock_transfer.restorePanelsFromWorkspace(&manager, &dst);
    try std.testing.expectEqual(@as(usize, 0), dst.panels.items.len);
    try std.testing.expect(workspaceContainsPanelId(&manager.workspace, 2));
    try std.testing.expect(workspaceContainsPanelId(&manager.workspace, 99));
}

test "dock transfer helper reports allocation failure and preserves source" {
    const allocator = std.testing.allocator;

    const ws = try workspace.Workspace.initDefault(allocator);
    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    var dst = workspace.Workspace.initEmpty(allocator);
    defer dst.deinit(allocator);

    var tiny_buf: [1]u8 = undefined;
    var tiny_fba = std.heap.FixedBufferAllocator.init(&tiny_buf);
    const tiny_alloc = tiny_fba.allocator();

    const result = dock_transfer.transferPanelsToWorkspace(
        tiny_alloc,
        &manager,
        &[_]workspace.PanelId{2},
        &dst,
    );
    try std.testing.expect(!result.moved_ok);
    try std.testing.expectEqual(@as(usize, 0), result.moved_count);
    try std.testing.expect(workspaceContainsPanelId(&manager.workspace, 2));
    try std.testing.expectEqual(@as(usize, 0), dst.panels.items.len);
}

test "dock graph can split a tab out of its own group" {
    const allocator = std.testing.allocator;

    var graph = dock_graph.Graph.init(allocator);
    defer graph.deinit();

    const root = try graph.addTabsNode(&[_]workspace.PanelId{ 1, 2 }, 0);
    graph.root = root;

    const changed = try graph.splitNodeWithPanel(root, 1, .right);
    try std.testing.expect(changed);

    const loc1 = graph.findPanel(1) orelse return error.TestExpectedPanel;
    const loc2 = graph.findPanel(2) orelse return error.TestExpectedPanel;
    try std.testing.expect(loc1.node_id != loc2.node_id);
    try std.testing.expect(layoutContainsNode(&graph, loc1.node_id, testViewport()));
    try std.testing.expect(layoutContainsNode(&graph, loc2.node_id, testViewport()));
}

test "dock graph splitters and ratio updates" {
    const allocator = std.testing.allocator;

    var graph = dock_graph.Graph.init(allocator);
    defer graph.deinit();

    const a = try graph.addTabsNode(&[_]workspace.PanelId{1}, 0);
    const b = try graph.addTabsNode(&[_]workspace.PanelId{2}, 0);
    const root = try graph.addSplitNode(.vertical, 0.5, a, b);
    graph.root = root;

    try std.testing.expect(graph.setSplitRatio(root, 0.72));

    const viewport = draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 1000.0, 700.0 });
    const splitters = graph.computeSplitters(viewport);
    try std.testing.expect(splitters.len >= 1);
}

test "workspace from legacy snapshot builds dock layout" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    defer ws.deinit(allocator);

    var snap = try ws.toSnapshot(allocator);
    defer snap.deinit(allocator);

    if (snap.layout_v2) |*layout| {
        layout.deinit(allocator);
        snap.layout_v2 = null;
    }
    snap.layout_version = 1;

    var migrated = try workspace.Workspace.fromSnapshot(allocator, snap);
    defer migrated.deinit(allocator);

    try std.testing.expect(migrated.dock_layout.root != null);
    try std.testing.expectEqual(ws.panels.items.len, migrated.panels.items.len);
}

test "workspace snapshot roundtrip preserves dock layout" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    defer ws.deinit(allocator);

    const showcase = try workspace.makeShowcasePanel(allocator, 99);
    try ws.panels.append(allocator, showcase);
    _ = try ws.syncDockLayout();

    const focus_id = ws.panels.items[0].id;
    const focus_loc = ws.dock_layout.findPanel(focus_id) orelse return error.TestExpectedPanel;
    _ = try ws.dock_layout.splitNodeWithPanel(focus_loc.node_id, focus_id, .right);

    var snap = try ws.toSnapshot(allocator);
    defer snap.deinit(allocator);
    try std.testing.expect(snap.layout_v2 != null);

    var ws2 = try workspace.Workspace.fromSnapshot(allocator, snap);
    defer ws2.deinit(allocator);

    try std.testing.expect(ws2.dock_layout.root != null);
    try std.testing.expectEqual(ws.panels.items.len, ws2.panels.items.len);
}

test "keyboard shortcut ctrl+tab cycles tabs in focused group" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    const extra_id: workspace.PanelId = 99;
    try ws.panels.append(allocator, try workspace.makeShowcasePanel(allocator, extra_id));
    _ = try ws.syncDockLayout();

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    const chat_id: workspace.PanelId = 2;
    try focusPanelAndActivate(&manager, chat_id);

    const next = applyShortcut(allocator, &manager, .tab, .{ .ctrl = true });
    try std.testing.expect(next.changed_layout);
    try std.testing.expectEqual(extra_id, next.focus_panel_id orelse return error.TestExpectedPanel);

    try focusPanelAndActivate(&manager, next.focus_panel_id orelse return error.TestExpectedPanel);
    const prev = applyShortcut(allocator, &manager, .tab, .{ .ctrl = true, .shift = true });
    try std.testing.expect(prev.changed_layout);
    try std.testing.expectEqual(chat_id, prev.focus_panel_id orelse return error.TestExpectedPanel);
}

test "keyboard shortcut ctrl+page up/down cycles dock groups" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    _ = try ws.syncDockLayout();

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    const chat_id: workspace.PanelId = 2;
    const control_id: workspace.PanelId = 1;
    try focusPanelAndActivate(&manager, chat_id);

    const down = applyShortcut(allocator, &manager, .page_down, .{ .ctrl = true });
    try std.testing.expect(down.changed_layout);
    try std.testing.expectEqual(control_id, down.focus_panel_id orelse return error.TestExpectedPanel);

    try focusPanelAndActivate(&manager, down.focus_panel_id orelse return error.TestExpectedPanel);
    const up = applyShortcut(allocator, &manager, .page_up, .{ .ctrl = true });
    try std.testing.expect(up.changed_layout);
    try std.testing.expectEqual(chat_id, up.focus_panel_id orelse return error.TestExpectedPanel);
}

test "keyboard shortcut alt+shift left/right reorders tabs" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    try ws.panels.append(allocator, try workspace.makeShowcasePanel(allocator, 99));
    try ws.panels.append(allocator, try workspace.makeShowcasePanel(allocator, 100));
    _ = try ws.syncDockLayout();

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    const chat_id: workspace.PanelId = 2;
    try focusPanelAndActivate(&manager, chat_id);

    const move_right = applyShortcut(allocator, &manager, .right_arrow, .{ .alt = true, .shift = true });
    try std.testing.expect(move_right.changed_layout);
    try std.testing.expectEqual(chat_id, move_right.focus_panel_id orelse return error.TestExpectedPanel);
    try std.testing.expectEqualSlices(
        workspace.PanelId,
        &[_]workspace.PanelId{ 99, 2, 100 },
        try tabsForPanelNode(&manager.workspace.dock_layout, chat_id),
    );

    try focusPanelAndActivate(&manager, chat_id);
    const move_left = applyShortcut(allocator, &manager, .left_arrow, .{ .alt = true, .shift = true });
    try std.testing.expect(move_left.changed_layout);
    try std.testing.expectEqual(chat_id, move_left.focus_panel_id orelse return error.TestExpectedPanel);
    try std.testing.expectEqualSlices(
        workspace.PanelId,
        &[_]workspace.PanelId{ 2, 99, 100 },
        try tabsForPanelNode(&manager.workspace.dock_layout, chat_id),
    );
}

test "keyboard shortcut ctrl+alt+arrow docks toward directional target" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    _ = try ws.syncDockLayout();

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    const viewport = testViewport();
    const chat_id: workspace.PanelId = 2;
    const control_id: workspace.PanelId = 1;
    const before = manager.workspace.dock_layout.findPanel(chat_id) orelse return error.TestExpectedPanel;

    try focusPanelAndActivate(&manager, chat_id);
    const moved = applyShortcut(allocator, &manager, .right_arrow, .{ .ctrl = true, .alt = true });
    try std.testing.expect(moved.changed_layout);
    try std.testing.expectEqual(chat_id, moved.focus_panel_id orelse return error.TestExpectedPanel);

    const after = manager.workspace.dock_layout.findPanel(chat_id) orelse return error.TestExpectedPanel;
    const control_loc = manager.workspace.dock_layout.findPanel(control_id) orelse return error.TestExpectedPanel;
    try std.testing.expect(after.node_id != before.node_id);
    try std.testing.expect(after.node_id != control_loc.node_id);

    const chat_center_x = try centerXForNode(&manager.workspace.dock_layout, after.node_id, viewport);
    const control_center_x = try centerXForNode(&manager.workspace.dock_layout, control_loc.node_id, viewport);
    try std.testing.expect(chat_center_x > control_center_x);
}

test "keyboard shortcut ctrl+alt+enter merges into nearest dock group center" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    _ = try ws.syncDockLayout();

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    const chat_id: workspace.PanelId = 2;
    const control_id: workspace.PanelId = 1;
    try focusPanelAndActivate(&manager, chat_id);

    const merged = applyShortcut(allocator, &manager, .enter, .{ .ctrl = true, .alt = true });
    try std.testing.expect(merged.changed_layout);
    try std.testing.expectEqual(chat_id, merged.focus_panel_id orelse return error.TestExpectedPanel);

    const chat_loc = manager.workspace.dock_layout.findPanel(chat_id) orelse return error.TestExpectedPanel;
    const control_loc = manager.workspace.dock_layout.findPanel(control_id) orelse return error.TestExpectedPanel;
    try std.testing.expectEqual(chat_loc.node_id, control_loc.node_id);

    const layout = manager.workspace.dock_layout.computeLayout(testViewport()).slice();
    try std.testing.expectEqual(@as(usize, 1), layout.len);
}

test "keyboard shortcut ctrl+shift left/right collapses focused group to rail sides" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    _ = try ws.syncDockLayout();

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    const chat_id: workspace.PanelId = 2;
    try focusPanelAndActivate(&manager, chat_id);
    const loc = manager.workspace.dock_layout.findPanel(chat_id) orelse return error.TestExpectedPanel;

    var win_state = main_window.WindowUiState{};

    const collapse_left = applyShortcutWithState(allocator, &manager, &win_state, .left_arrow, .{ .ctrl = true, .shift = true });
    try std.testing.expect(collapse_left.changed_layout);
    try std.testing.expectEqual(chat_id, collapse_left.focus_panel_id orelse return error.TestExpectedPanel);
    try std.testing.expectEqual(@as(usize, 1), collapse_left.collapsed_count);
    try std.testing.expect(win_state.collapsed_docks.isCollapsed(loc.node_id));
    try std.testing.expectEqual(dock_rail.Side.left, win_state.collapsed_docks.sideForNode(loc.node_id) orelse return error.TestExpectedValue);

    const collapse_right = applyShortcutWithState(allocator, &manager, &win_state, .right_arrow, .{ .ctrl = true, .shift = true });
    try std.testing.expect(collapse_right.changed_layout);
    try std.testing.expectEqual(@as(usize, 1), collapse_right.collapsed_count);
    try std.testing.expectEqual(dock_rail.Side.right, win_state.collapsed_docks.sideForNode(loc.node_id) orelse return error.TestExpectedValue);
}

test "keyboard shortcut ctrl+shift up/down/enter controls flyout and expand" {
    const allocator = std.testing.allocator;

    var ws = try workspace.Workspace.initDefault(allocator);
    _ = try ws.syncDockLayout();

    var next_panel_id: workspace.PanelId = 1000;
    var manager = panel_manager.PanelManager.init(allocator, ws, &next_panel_id);
    defer manager.deinit();

    const chat_id: workspace.PanelId = 2;
    try focusPanelAndActivate(&manager, chat_id);
    const loc = manager.workspace.dock_layout.findPanel(chat_id) orelse return error.TestExpectedPanel;

    var win_state = main_window.WindowUiState{};
    _ = applyShortcutWithState(allocator, &manager, &win_state, .left_arrow, .{ .ctrl = true, .shift = true });
    try std.testing.expect(win_state.collapsed_docks.isCollapsed(loc.node_id));

    const open_flyout = applyShortcutWithState(allocator, &manager, &win_state, .up_arrow, .{ .ctrl = true, .shift = true });
    try std.testing.expectEqual(loc.node_id, open_flyout.flyout_node_id orelse return error.TestExpectedNode);
    try std.testing.expect(!open_flyout.flyout_pinned);

    const pin_flyout = applyShortcutWithState(allocator, &manager, &win_state, .up_arrow, .{ .ctrl = true, .shift = true });
    try std.testing.expectEqual(loc.node_id, pin_flyout.flyout_node_id orelse return error.TestExpectedNode);
    try std.testing.expect(pin_flyout.flyout_pinned);

    const close_flyout = applyShortcutWithState(allocator, &manager, &win_state, .down_arrow, .{ .ctrl = true, .shift = true });
    try std.testing.expect(close_flyout.flyout_node_id == null);
    try std.testing.expect(!close_flyout.flyout_pinned);
    try std.testing.expectEqual(@as(usize, 1), close_flyout.collapsed_count);

    _ = applyShortcutWithState(allocator, &manager, &win_state, .up_arrow, .{ .ctrl = true, .shift = true });
    const expand = applyShortcutWithState(allocator, &manager, &win_state, .enter, .{ .ctrl = true, .shift = true });
    try std.testing.expect(expand.changed_layout);
    try std.testing.expectEqual(chat_id, expand.focus_panel_id orelse return error.TestExpectedPanel);
    try std.testing.expectEqual(@as(usize, 0), expand.collapsed_count);
    try std.testing.expect(expand.flyout_node_id == null);
    try std.testing.expect(!win_state.collapsed_docks.isCollapsed(loc.node_id));
}

test "workspace store roundtrip preserves detached window chrome settings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs_tmp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_tmp);
    const path = try std.fs.path.join(allocator, &.{ abs_tmp, "workspace.json" });
    defer allocator.free(path);

    var main_ws = try workspace.Workspace.initDefault(allocator);
    defer main_ws.deinit(allocator);

    var detached_ws = try workspace.Workspace.initDefault(allocator);
    defer detached_ws.deinit(allocator);

    const main_collapsed = [_]workspace.CollapsedDockSnapshot{
        .{ .node_id = 11, .side = .left },
    };
    const detached_collapsed = [_]workspace.CollapsedDockSnapshot{
        .{ .node_id = 7, .side = .right },
        .{ .node_id = 8, .side = .left },
    };
    const windows = [_]workspace_store.DetachedWindowView{
        .{
            .title = "Detached Utility",
            .width = 720,
            .height = 480,
            .chrome_mode = "template_utility",
            .menu_profile = "minimal",
            .show_status_bar = false,
            .show_menu_bar = false,
            .profile = "desktop",
            .variant = "dark",
            .image_sampling = "nearest",
            .pixel_snap_textured = true,
            .collapsed_docks = detached_collapsed[0..],
            .ws = &detached_ws,
        },
    };

    try workspace_store.saveMulti(allocator, path, &main_ws, main_collapsed[0..], &windows, 4242);

    var loaded = try workspace_store.loadMultiOrDefault(allocator, path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(workspace.PanelId, 4242), loaded.next_panel_id);
    try std.testing.expect(loaded.main_collapsed_docks != null);
    try std.testing.expectEqual(@as(usize, 1), loaded.main_collapsed_docks.?.len);
    try std.testing.expectEqual(@as(workspace.DockNodeId, 11), loaded.main_collapsed_docks.?[0].node_id);
    try std.testing.expectEqual(@as(@TypeOf(loaded.main_collapsed_docks.?[0].side), .left), loaded.main_collapsed_docks.?[0].side);
    try std.testing.expectEqual(@as(usize, 1), loaded.windows.len);

    const w = loaded.windows[0];
    try std.testing.expectEqualStrings("Detached Utility", w.title);
    try std.testing.expectEqual(@as(u32, 720), w.width);
    try std.testing.expectEqual(@as(u32, 480), w.height);
    try std.testing.expectEqualStrings("template_utility", w.chrome_mode orelse return error.TestExpectedValue);
    try std.testing.expectEqualStrings("minimal", w.menu_profile orelse return error.TestExpectedValue);
    try std.testing.expect(w.show_status_bar != null and !w.show_status_bar.?);
    try std.testing.expect(w.show_menu_bar != null and !w.show_menu_bar.?);
    try std.testing.expectEqualStrings("desktop", w.profile orelse return error.TestExpectedValue);
    try std.testing.expectEqualStrings("dark", w.variant orelse return error.TestExpectedValue);
    try std.testing.expectEqualStrings("nearest", w.image_sampling orelse return error.TestExpectedValue);
    try std.testing.expect(w.pixel_snap_textured != null and w.pixel_snap_textured.?);
    try std.testing.expect(w.collapsed_docks != null);
    try std.testing.expectEqual(@as(usize, 2), w.collapsed_docks.?.len);
    try std.testing.expectEqual(@as(workspace.DockNodeId, 7), w.collapsed_docks.?[0].node_id);
    try std.testing.expectEqual(@as(workspace.DockNodeId, 8), w.collapsed_docks.?[1].node_id);
    try std.testing.expectEqual(@as(@TypeOf(w.collapsed_docks.?[0].side), .right), w.collapsed_docks.?[0].side);
    try std.testing.expectEqual(@as(@TypeOf(w.collapsed_docks.?[1].side), .left), w.collapsed_docks.?[1].side);
}

test "workspace store loads legacy detached window snapshots without chrome fields" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs_tmp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_tmp);
    const path = try std.fs.path.join(allocator, &.{ abs_tmp, "workspace_legacy.json" });
    defer allocator.free(path);

    const legacy_json =
        \\{
        \\  "active_project": 0,
        \\  "focused_panel_id": null,
        \\  "next_panel_id": 88,
        \\  "layout_version": 1,
        \\  "panels": [],
        \\  "detached_windows": [
        \\    {
        \\      "title": "Legacy Detached",
        \\      "width": 640,
        \\      "height": 360,
        \\      "layout_version": 1,
        \\      "panels": []
        \\    }
        \\  ]
        \\}
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = legacy_json });

    var loaded = try workspace_store.loadMultiOrDefault(allocator, path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(workspace.PanelId, 88), loaded.next_panel_id);
    try std.testing.expect(loaded.main_collapsed_docks == null);
    try std.testing.expectEqual(@as(usize, 1), loaded.windows.len);
    const w = loaded.windows[0];
    try std.testing.expectEqualStrings("Legacy Detached", w.title);
    try std.testing.expect(w.chrome_mode == null);
    try std.testing.expect(w.menu_profile == null);
    try std.testing.expect(w.show_status_bar == null);
    try std.testing.expect(w.show_menu_bar == null);
    try std.testing.expect(w.collapsed_docks == null);
}
