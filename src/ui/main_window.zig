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
const image_cache = @import("image_cache.zig");
const chat_panel = @import("panels/chat_panel.zig");
const agents_panel = @import("panels/agents_panel.zig");
const code_editor_panel = @import("panels/code_editor_panel.zig");
const tool_output_panel = @import("panels/tool_output_panel.zig");
const control_panel = @import("panels/control_panel.zig");
const status_bar = @import("status_bar.zig");
const agent_registry = @import("../client/agent_registry.zig");
const session_keys = @import("../client/session_keys.zig");
const types = @import("../protocol/types.zig");

pub const SendMessageAction = struct {
    session_key: []u8,
    message: []u8,
};

pub const UiAction = struct {
    send_message: ?SendMessageAction = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    refresh_sessions: bool = false,
    new_chat_agent_id: ?[]u8 = null,
    open_session: ?agents_panel.AgentSessionAction = null,
    set_default_session: ?agents_panel.AgentSessionAction = null,
    delete_session: ?[]u8 = null,
    add_agent: ?agents_panel.AddAgentAction = null,
    remove_agent_id: ?[]u8 = null,
    focus_session: ?[]u8 = null,
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
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
    dock_state: *dock_layout.DockState,
) UiAction {
    var action = UiAction{};
    image_cache.beginFrame();

    var session_it = ctx.session_states.iterator();
    while (session_it.next()) |entry| {
        inbox.collectFromMessages(allocator, entry.value_ptr.messages.items, manager);
    }

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

    var focused_session_key: ?[]const u8 = null;
    var focused_agent_id: ?[]const u8 = null;

    if (zgui.begin("WorkspaceHost", .{ .flags = host_flags })) {
        const dockspace_id = zgui.dockSpace("MainDockSpace", .{ 0.0, 0.0 }, .{ .passthru_central_node = true });
        dock_layout.ensureDockLayout(dock_state, &manager.workspace, dockspace_id);

        var index: usize = 0;
        while (index < manager.workspace.panels.items.len) {
            var panel = &manager.workspace.panels.items[index];
            var panel_session_key: ?[]const u8 = null;
            var panel_agent_id: ?[]const u8 = null;
            if (panel.state.dock_node == 0 and dock_state.dockspace_id != 0) {
                imgui_bridge.setNextWindowDockId(
                    dock_layout.defaultDockForKind(dock_state, panel.kind),
                    .first_use_ever,
                );
            }
            if (manager.focus_request_id != null and manager.focus_request_id.? == panel.id) {
                zgui.setNextWindowFocus();
                manager.focus_request_id = null;
            }

            var open = true;
            const label = zgui.formatZ("{s}##panel_{d}", .{ panel.title, panel.id });
            if (zgui.begin(label, .{ .popen = &open })) {
                switch (panel.kind) {
                    .Chat => {
                        var agent_id = panel.data.Chat.agent_id;
                        if (agent_id == null) {
                            if (panel.data.Chat.session_key) |session_key| {
                                if (session_keys.parse(session_key)) |parts| {
                                    panel.data.Chat.agent_id = allocator.dupe(u8, parts.agent_id) catch panel.data.Chat.agent_id;
                                    agent_id = panel.data.Chat.agent_id;
                                    manager.workspace.markDirty();
                                }
                            }
                        }

                        var resolved_session_key = panel.data.Chat.session_key;
                        if (resolved_session_key == null and agent_id != null) {
                            if (registry.find(agent_id.?)) |agent| {
                                if (agent.default_session_key) |default_key| {
                                    resolved_session_key = default_key;
                                }
                            }
                        }

                        const agent_info = resolveAgentInfo(registry, agent_id);
                        const session_label = if (resolved_session_key) |session_key|
                            resolveSessionLabel(ctx.sessions.items, session_key)
                        else
                            null;

                        const session_state = if (resolved_session_key) |session_key|
                            ctx.getOrCreateSessionState(session_key) catch null
                        else
                            null;

                        const chat_action = chat_panel.draw(
                            allocator,
                            resolved_session_key,
                            session_state,
                            agent_info.icon,
                            agent_info.name,
                            session_label,
                            inbox,
                        );
                        if (chat_action.send_message) |message| {
                            if (resolved_session_key) |session_key| {
                                const key_copy = allocator.dupe(u8, session_key) catch null;
                                if (key_copy) |owned| {
                                    action.send_message = .{ .session_key = owned, .message = message };
                                } else {
                                    allocator.free(message);
                                }
                            } else {
                                allocator.free(message);
                            }
                        }

                        panel_session_key = resolved_session_key;
                        panel_agent_id = agent_id;
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
                            registry,
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
                        action.new_chat_agent_id = control_action.new_chat_agent_id;
                        action.open_session = control_action.open_session;
                        action.set_default_session = control_action.set_default_session;
                        action.delete_session = control_action.delete_session;
                        action.add_agent = control_action.add_agent;
                        action.remove_agent_id = control_action.remove_agent_id;
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
                if (panel.kind == .Chat) {
                    if (panel_session_key) |key| {
                        focused_session_key = key;
                        focused_agent_id = panel_agent_id;
                    }
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

    if (focused_session_key) |key| {
        action.focus_session = allocator.dupe(u8, key) catch null;
    }

    var status_agent: ?[]const u8 = null;
    var status_session: ?[]const u8 = null;
    var status_messages: usize = 0;
    if (focused_session_key) |session_key| {
        status_session = resolveSessionLabel(ctx.sessions.items, session_key) orelse session_key;
        if (ctx.findSessionState(session_key)) |state_ptr| {
            status_messages = state_ptr.messages.items.len;
        }
        var agent_id = focused_agent_id;
        if (agent_id == null) {
            if (session_keys.parse(session_key)) |parts| {
                agent_id = parts.agent_id;
            }
        }
        if (agent_id) |agent| {
            if (registry.find(agent)) |profile| {
                status_agent = profile.display_name;
            } else {
                status_agent = agent;
            }
        }
    }

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
        status_bar.draw(ctx.state, is_connected, status_agent, status_session, status_messages, ctx.last_error);
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

const AgentInfo = struct {
    name: []const u8,
    icon: []const u8,
};

fn resolveAgentInfo(registry: *agent_registry.AgentRegistry, agent_id: ?[]const u8) AgentInfo {
    if (agent_id) |id| {
        if (registry.find(id)) |agent| {
            return .{ .name = agent.display_name, .icon = agent.icon };
        }
        return .{ .name = id, .icon = "?" };
    }
    return .{ .name = "Agent", .icon = "?" };
}

fn resolveSessionLabel(sessions: []const types.Session, key: []const u8) ?[]const u8 {
    for (sessions) |session| {
        if (std.mem.eql(u8, session.key, key)) {
            return session.display_name orelse session.label orelse session.key;
        }
    }
    return null;
}

pub fn syncSettings(cfg: config.Config) void {
    @import("settings_view.zig").syncFromConfig(cfg);
}
