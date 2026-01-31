const std = @import("std");
const zgui = @import("zgui");
const builtin = @import("builtin");
const state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const theme = @import("theme.zig");
const panel_manager = @import("panel_manager.zig");
const dock_layout = @import("dock_layout.zig");
const ui_command_inbox = @import("ui_command_inbox.zig");
const imgui_bridge = @import("imgui_bridge.zig");
const chat_panel = @import("panels/chat_panel.zig");
const code_editor_panel = @import("panels/code_editor_panel.zig");
const tool_output_panel = @import("panels/tool_output_panel.zig");
const control_panel = @import("panels/control_panel.zig");
const status_bar = @import("status_bar.zig");

pub const UiAction = struct {
    send_message: ?[]u8 = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    refresh_sessions: bool = false,
    select_session: ?[]u8 = null,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,
    refresh_nodes: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?@import("operator_view.zig").NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?@import("operator_view.zig").ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
    save_workspace: bool = false,
};

var safe_insets: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };

pub fn setSafeInsets(left: f32, top: f32, right: f32, bottom: f32) void {
    safe_insets = .{ left, top, right, bottom };
}

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    is_connected: bool,
    app_version: []const u8,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
    dock_state: *dock_layout.DockState,
) UiAction {
    var action = UiAction{};

    inbox.collectFromMessages(allocator, ctx.messages.items, manager);

    const display = zgui.io.getDisplaySize();
    if (display[0] > 0.0 and display[1] > 0.0) {
        const left = safe_insets[0];
        const top = safe_insets[1];
        const right = safe_insets[2];
        const bottom = safe_insets[3];
        const width = @max(1.0, display[0] - left - right);
        const extra_bottom: f32 = if (builtin.abi == .android) 24.0 else 0.0;
        const height = @max(1.0, display[1] - top - bottom - extra_bottom);
        zgui.setNextWindowPos(.{ .x = left, .y = top, .cond = .always });
        zgui.setNextWindowSize(.{ .w = width, .h = height, .cond = .always });
    }

    const host_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_bring_to_front_on_focus = true,
        .no_saved_settings = true,
        .no_nav_focus = true,
        .no_background = true,
    };

    if (zgui.begin("WorkspaceHost", .{ .flags = host_flags })) {
        const dockspace_id = zgui.dockSpace("MainDockSpace", .{ 0.0, 0.0 }, .{ .passthru_central_node = true });
        dock_layout.ensureDockLayout(dock_state, &manager.workspace, dockspace_id);

        var index: usize = 0;
        while (index < manager.workspace.panels.items.len) {
            var panel = &manager.workspace.panels.items[index];
            if (panel.state.dock_node == 0 and dock_state.dockspace_id != 0) {
                imgui_bridge.setNextWindowDockId(
                    dock_layout.defaultDockForKind(dock_state, panel.kind),
                    .first_use_ever,
                );
            }
            if (manager.workspace.focused_panel_id != null and
                manager.workspace.focused_panel_id.? == panel.id)
            {
                zgui.setNextWindowFocus();
            }

            var open = true;
            const label = zgui.formatZ("{s}##panel_{d}", .{ panel.title, panel.id });
            if (zgui.begin(label, .{ .popen = &open, .flags = .{ .no_saved_settings = true } })) {
                switch (panel.kind) {
                    .Chat => {
                        const chat_action = chat_panel.draw(allocator, ctx, inbox);
                        action.send_message = chat_action.send_message;
                    },
                    .CodeEditor => {
                        if (code_editor_panel.draw(panel, allocator)) {
                            manager.workspace.markDirty();
                        }
                    },
                    .ToolOutput => {
                        tool_output_panel.draw(panel, allocator);
                    },
                    .Control => {
                        const control_action = control_panel.draw(
                            allocator,
                            ctx,
                            cfg,
                            is_connected,
                            app_version,
                            &panel.data.Control,
                        );
                        action.connect = control_action.connect;
                        action.disconnect = control_action.disconnect;
                        action.save_config = control_action.save_config;
                        action.clear_saved = control_action.clear_saved;
                        action.config_updated = control_action.config_updated;
                        action.refresh_sessions = control_action.refresh_sessions;
                        action.select_session = control_action.select_session;
                        action.check_updates = control_action.check_updates;
                        action.open_release = control_action.open_release;
                        action.download_update = control_action.download_update;
                        action.open_download = control_action.open_download;
                        action.install_update = control_action.install_update;
                        action.refresh_nodes = control_action.refresh_nodes;
                        action.select_node = control_action.select_node;
                        action.invoke_node = control_action.invoke_node;
                        action.describe_node = control_action.describe_node;
                        action.resolve_approval = control_action.resolve_approval;
                        action.clear_node_describe = control_action.clear_node_describe;
                        action.clear_node_result = control_action.clear_node_result;
                        action.clear_operator_notice = control_action.clear_operator_notice;
                    },
                }
            }

            const dock_id = imgui_bridge.getWindowDockId();
            if (dock_id != 0 and dock_id != panel.state.dock_node) {
                panel.state.dock_node = dock_id;
                manager.workspace.markDirty();
            } else {
                panel.state.dock_node = dock_id;
            }
            panel.state.is_focused = zgui.isWindowFocused(zgui.FocusedFlags.root_and_child_windows);
            if (panel.state.is_focused) {
                if (manager.workspace.focused_panel_id == null or manager.workspace.focused_panel_id.? != panel.id) {
                    manager.workspace.focused_panel_id = panel.id;
                    manager.workspace.markDirty();
                }
            }

            zgui.end();

            if (!open) {
                _ = manager.closePanel(panel.id);
                continue;
            }

            index += 1;
        }
    }
    zgui.end();

    const viewport = zgui.getMainViewport();
    const status_height = zgui.getFrameHeightWithSpacing();
    zgui.setNextWindowPos(.{ .x = viewport.work_pos[0], .y = viewport.work_pos[1] + viewport.work_size[1] - status_height, .cond = .always });
    zgui.setNextWindowSize(.{ .w = viewport.work_size[0], .h = status_height, .cond = .always });
    const status_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_saved_settings = true,
        .no_docking = true,
    };
    if (zgui.begin("StatusBar##overlay", .{ .flags = status_flags })) {
        theme.push(.body);
        status_bar.draw(ctx.state, is_connected, ctx.current_session, ctx.messages.items.len, ctx.last_error);
        theme.pop();
    }
    zgui.end();

    if (imgui_bridge.wantSaveIniSettings()) {
        action.save_workspace = true;
        imgui_bridge.clearWantSaveIniSettings();
    }
    if (manager.workspace.dirty) action.save_workspace = true;

    return action;
}

pub fn syncSettings(cfg: config.Config) void {
    @import("settings_view.zig").syncFromConfig(cfg);
}
