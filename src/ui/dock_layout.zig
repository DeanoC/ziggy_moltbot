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
    dock_pos: [2]f32,
    dock_size: [2]f32,
) void {
    if (state.initialized) return;
    state.initialized = true;
    state.dockspace_id = dockspace_id;

    if (workspace_state.layout.imgui_ini.len > 0) return;

    zgui.dockBuilderRemoveNode(dockspace_id);
    _ = zgui.dockBuilderAddNode(dockspace_id, .{ .dock_space = true });
    zgui.dockBuilderSetNodePos(dockspace_id, dock_pos);
    zgui.dockBuilderSetNodeSize(dockspace_id, dock_size);

    var left: zgui.Ident = 0;
    var right: zgui.Ident = 0;

    _ = zgui.dockBuilderSplitNode(dockspace_id, .left, 0.35, &left, &right);

    state.left = left;
    state.right = right;
    state.bottom = 0;
    state.center = right;

    for (workspace_state.panels.items) |panel| {
        var label_buf: [256:0]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{s}##panel_{d}", .{ panel.title, panel.id }) catch continue;
        const target = defaultDockForKind(state, panel.kind);
        zgui.dockBuilderDockWindow(label, target);
    }

    zgui.dockBuilderFinish(dockspace_id);
}

pub fn defaultDockForKind(state: *DockState, kind: workspace.PanelKind) workspace.DockNodeId {
    return switch (kind) {
        .Chat => if (state.left != 0) state.left else state.dockspace_id,
        .CodeEditor => if (state.right != 0) state.right else state.dockspace_id,
        .ToolOutput => if (state.right != 0) state.right else state.dockspace_id,
        .Control => if (state.right != 0) state.right else state.dockspace_id,
    };
}

pub fn captureIni(allocator: std.mem.Allocator, workspace_state: *workspace.Workspace) !void {
    const ini = try imgui_bridge.saveIniToMemory(allocator);
    allocator.free(workspace_state.layout.imgui_ini);
    workspace_state.layout.imgui_ini = ini;
}

pub fn resetDockLayout(
    allocator: std.mem.Allocator,
    state: *DockState,
    workspace_state: *workspace.Workspace,
) void {
    if (state.dockspace_id != 0) {
        zgui.dockBuilderRemoveNode(state.dockspace_id);
    }
    imgui_bridge.resetIni();
    allocator.free(workspace_state.layout.imgui_ini);
    workspace_state.layout.imgui_ini = allocator.dupe(u8, "") catch unreachable;
    for (workspace_state.panels.items) |*panel| {
        panel.state.dock_node = 0;
    }
    workspace_state.markDirty();
    state.* = DockState{};
}
