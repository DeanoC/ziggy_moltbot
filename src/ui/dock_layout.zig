const std = @import("std");
const zgui = @import("zgui");
const workspace = @import("workspace.zig");
const imgui_bridge = @import("imgui_bridge.zig");

pub const DockState = struct {
    dockspace_id: workspace.DockNodeId = 0,
    left: workspace.DockNodeId = 0,
    center: workspace.DockNodeId = 0,
    right: workspace.DockNodeId = 0,
    bottom: workspace.DockNodeId = 0,
    initialized: bool = false,
};

pub fn ensureDockLayout(
    state: *DockState,
    workspace_state: *workspace.Workspace,
    dockspace_id: workspace.DockNodeId,
) void {
    if (state.initialized) return;
    state.initialized = true;
    state.dockspace_id = dockspace_id;

    if (workspace_state.layout.imgui_ini.len > 0) return;

    const viewport = zgui.getMainViewport();
    zgui.dockBuilderRemoveNode(dockspace_id);
    _ = zgui.dockBuilderAddNode(dockspace_id, .{ .dock_space = true });
    zgui.dockBuilderSetNodePos(dockspace_id, viewport.work_pos);
    zgui.dockBuilderSetNodeSize(dockspace_id, viewport.work_size);

    var left: zgui.Ident = 0;
    var right: zgui.Ident = 0;
    var bottom: zgui.Ident = 0;
    var center: zgui.Ident = 0;
    var middle: zgui.Ident = 0;

    _ = zgui.dockBuilderSplitNode(dockspace_id, .left, 0.22, &left, &middle);
    _ = zgui.dockBuilderSplitNode(middle, .right, 0.25, &right, &center);
    _ = zgui.dockBuilderSplitNode(center, .down, 0.28, &bottom, &center);

    state.left = left;
    state.right = right;
    state.bottom = bottom;
    state.center = center;

    zgui.dockBuilderFinish(dockspace_id);
}

pub fn defaultDockForKind(state: *DockState, kind: workspace.PanelKind) workspace.DockNodeId {
    return switch (kind) {
        .Chat => if (state.bottom != 0) state.bottom else state.dockspace_id,
        .CodeEditor => if (state.center != 0) state.center else state.dockspace_id,
        .ToolOutput => if (state.right != 0) state.right else state.dockspace_id,
        .Control => if (state.left != 0) state.left else state.dockspace_id,
    };
}

pub fn captureIni(allocator: std.mem.Allocator, workspace_state: *workspace.Workspace) !void {
    const ini = try imgui_bridge.saveIniToMemory(allocator);
    allocator.free(workspace_state.layout.imgui_ini);
    workspace_state.layout.imgui_ini = ini;
}
