const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const config = @import("../../client/config.zig");
const agent_registry = @import("../../client/agent_registry.zig");
const agents_panel = @import("agents_panel.zig");
const notifications_panel = @import("notifications_panel.zig");
const settings_panel = @import("settings_panel.zig");
const operator_view = @import("../operator_view.zig");
const workspace = @import("../workspace.zig");

pub const ControlPanelAction = struct {
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
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,
    refresh_nodes: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?operator_view.NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?operator_view.ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
};

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    panel: *workspace.ControlPanel,
) ControlPanelAction {
    var action = ControlPanelAction{};

    if (zgui.beginTabBar("ControlTabs", .{})) {
        if (zgui.beginTabItem("Agents", .{})) {
            panel.active_tab = .Agents;
            const agents_action = agents_panel.draw(allocator, ctx, registry, panel);
            action.refresh_sessions = agents_action.refresh;
            action.new_chat_agent_id = agents_action.new_chat_agent_id;
            action.open_session = agents_action.open_session;
            action.set_default_session = agents_action.set_default;
            action.delete_session = agents_action.delete_session;
            action.add_agent = agents_action.add_agent;
            action.remove_agent_id = agents_action.remove_agent_id;
            zgui.endTabItem();
        }
        if (zgui.beginTabItem("Notifications", .{})) {
            panel.active_tab = .Notifications;
            const notify_action = notifications_panel.draw(allocator, ctx);
            action.refresh_sessions = action.refresh_sessions or notify_action.refresh;
            zgui.endTabItem();
        }
        if (zgui.beginTabItem("Settings", .{})) {
            panel.active_tab = .Settings;
            const settings_action = settings_panel.draw(
                allocator,
                cfg,
                ctx.state,
                is_connected,
                &ctx.update_state,
                app_version,
            );
            action.connect = settings_action.connect;
            action.disconnect = settings_action.disconnect;
            action.save_config = settings_action.save;
            action.clear_saved = settings_action.clear_saved;
            action.config_updated = settings_action.config_updated;
            action.check_updates = settings_action.check_updates;
            action.open_release = settings_action.open_release;
            action.download_update = settings_action.download_update;
            action.open_download = settings_action.open_download;
            action.install_update = settings_action.install_update;
            zgui.endTabItem();
        }
        if (zgui.beginTabItem("Operator", .{})) {
            panel.active_tab = .Operator;
            const operator_action = operator_view.draw(allocator, ctx, is_connected);
            action.refresh_nodes = operator_action.refresh_nodes;
            action.select_node = operator_action.select_node;
            action.invoke_node = operator_action.invoke_node;
            action.describe_node = operator_action.describe_node;
            action.resolve_approval = operator_action.resolve_approval;
            action.clear_node_describe = operator_action.clear_node_describe;
            action.clear_node_result = operator_action.clear_node_result;
            action.clear_operator_notice = operator_action.clear_operator_notice;
            zgui.endTabItem();
        }
        zgui.endTabBar();
    }

    return action;
}
