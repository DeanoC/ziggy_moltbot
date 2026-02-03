const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const config = @import("../../client/config.zig");
const sessions_panel = @import("sessions_panel.zig");
const settings_panel = @import("settings_panel.zig");
const showcase_panel = @import("showcase_panel.zig");
const projects_view = @import("../projects_view.zig");
const sources_view = @import("../sources_view.zig");
const artifact_workspace_view = @import("../artifact_workspace_view.zig");
const run_inspector_view = @import("../run_inspector_view.zig");
const approvals_inbox_view = @import("../approvals_inbox_view.zig");
const agents_view = @import("../agents_view.zig");
const operator_view = @import("../operator_view.zig");
const workspace = @import("../workspace.zig");
const components = @import("../components/components.zig");

pub const ControlPanelAction = struct {
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    refresh_sessions: bool = false,
    new_session: bool = false,
    select_session: ?[]u8 = null,
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
    open_attachment: ?sessions_panel.AttachmentOpen = null,
    open_url: ?[]u8 = null,
};

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    is_connected: bool,
    app_version: []const u8,
    panel: *workspace.ControlPanel,
) ControlPanelAction {
    var action = ControlPanelAction{};

    if (components.core.tab_bar.begin("WorkspaceTabs")) {
        if (components.core.tab_bar.beginItem("Projects")) {
            panel.active_tab = .Projects;
            const projects_action = projects_view.draw(allocator, ctx);
            action.refresh_sessions = projects_action.refresh_sessions;
            action.new_session = projects_action.new_session;
            action.select_session = projects_action.select_session;
            action.open_attachment = projects_action.open_attachment;
            action.open_url = projects_action.open_url;
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Sources")) {
            panel.active_tab = .Sources;
            const sources_action = sources_view.draw(allocator, ctx);
            action.select_session = sources_action.select_session;
            action.open_attachment = sources_action.open_attachment;
            action.open_url = sources_action.open_url;
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Artifact Workspace")) {
            panel.active_tab = .ArtifactWorkspace;
            artifact_workspace_view.draw();
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Run Inspector")) {
            panel.active_tab = .RunInspector;
            run_inspector_view.draw(ctx);
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Approvals Inbox")) {
            panel.active_tab = .ApprovalsInbox;
            const approvals_action = approvals_inbox_view.draw(allocator, ctx);
            action.resolve_approval = approvals_action.resolve_approval;
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Active Agents")) {
            panel.active_tab = .ActiveAgents;
            agents_view.draw(ctx);
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Sessions")) {
            panel.active_tab = .Sessions;
            const sessions_action = sessions_panel.draw(allocator, ctx);
            action.refresh_sessions = sessions_action.refresh;
            action.new_session = sessions_action.new_session;
            action.select_session = sessions_action.selected_key;
            action.open_attachment = sessions_action.open_attachment;
            action.open_url = sessions_action.open_url;
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Settings")) {
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
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Operator")) {
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
            components.core.tab_bar.endItem();
        }
        if (components.core.tab_bar.beginItem("Showcase")) {
            panel.active_tab = .Showcase;
            showcase_panel.draw();
            components.core.tab_bar.endItem();
        }
        components.core.tab_bar.end();
    }

    return action;
}
