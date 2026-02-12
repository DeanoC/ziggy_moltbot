const std = @import("std");
const state = @import("../../client/state.zig");
const config = @import("../../client/config.zig");
const agent_registry = @import("../../client/agent_registry.zig");
const agents_panel = @import("agents_panel.zig");
const sessions_panel = @import("sessions_panel.zig");
const operator_view = @import("../operator_view.zig");
const workspace = @import("../workspace.zig");
const draw_context = @import("../draw_context.zig");

pub const ControlPanelAction = struct {
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    reload_theme_pack: bool = false,
    browse_theme_pack: bool = false,
    browse_theme_pack_override: bool = false,
    clear_theme_pack_override: bool = false,
    reload_theme_pack_override: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    refresh_sessions: bool = false,
    new_session: bool = false,
    select_session: ?[]u8 = null,
    new_chat_agent_id: ?[]u8 = null,
    open_session: ?agents_panel.AgentSessionAction = null,
    set_default_session: ?agents_panel.AgentSessionAction = null,
    delete_session: ?[]u8 = null,
    add_agent: ?agents_panel.AddAgentAction = null,
    remove_agent_id: ?[]u8 = null,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,

    node_profile_apply_client: bool = false,
    node_profile_apply_service: bool = false,
    node_profile_apply_session: bool = false,

    // Windows node runner helpers (SCM service)
    node_service_install_onlogon: bool = false,
    node_service_start: bool = false,
    node_service_stop: bool = false,
    node_service_status: bool = false,
    node_service_uninstall: bool = false,
    open_node_logs: bool = false,

    refresh_nodes: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?operator_view.NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?operator_view.ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
    open_attachment: ?sessions_panel.AttachmentOpen = null,
    open_url: ?[]u8 = null,
};

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    panel: *workspace.ControlPanel,
    rect_override: ?draw_context.Rect,
    window_theme_pack_override: ?[]const u8,
    install_profile_only_mode: bool,
) ControlPanelAction {
    _ = cfg;
    _ = registry;
    _ = is_connected;
    _ = app_version;
    _ = panel;
    _ = window_theme_pack_override;
    _ = install_profile_only_mode;

    var action = ControlPanelAction{};
    const panel_rect = rect_override orelse return action;

    // "Workspace" now hosts session-level navigation/tools only. Agents/Settings/Operator/
    // Approvals/Inbox are first-class dockable panels rendered by main_window.zig.
    const sessions_action = sessions_panel.draw(allocator, ctx, panel_rect);
    action.refresh_sessions = sessions_action.refresh;
    action.new_session = sessions_action.new_session;
    action.select_session = sessions_action.selected_key;
    action.open_attachment = sessions_action.open_attachment;
    action.open_url = sessions_action.open_url;

    return action;
}
