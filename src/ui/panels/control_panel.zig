const std = @import("std");
const state = @import("../../client/state.zig");
const config = @import("../../client/config.zig");
const agent_registry = @import("../../client/agent_registry.zig");
const agents_panel = @import("agents_panel.zig");
const sessions_panel = @import("sessions_panel.zig");
const settings_panel = @import("settings_panel.zig");
const operator_view = @import("../operator_view.zig");
const workspace = @import("../workspace.zig");
const draw_context = @import("../draw_context.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const widgets = @import("../widgets/widgets.zig");

pub const ControlPanelAction = struct {
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
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

const Tab = struct {
    label: []const u8,
    kind: workspace.ControlTab,
};

const tabs = [_]Tab{
    .{ .label = "Agents", .kind = .Agents },
    .{ .label = "Operator", .kind = .Operator },
    .{ .label = "Settings", .kind = .Settings },
};

var tab_scroll_x: f32 = 0.0;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    panel: *workspace.ControlPanel,
    rect_override: ?draw_context.Rect,
) ControlPanelAction {
    var action = ControlPanelAction{};
    const t = theme.activeTheme();

    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();

    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    if (panel.active_tab != .Agents and panel.active_tab != .Operator and panel.active_tab != .Settings) {
        panel.active_tab = .Agents;
    }
    const tab_height = drawTabs(&dc, panel_rect, queue, &panel.active_tab);
    const content_gap = t.spacing.sm;
    const content_top = panel_rect.min[1] + tab_height + content_gap;
    const content_height = panel_rect.max[1] - content_top;
    if (content_height <= 0.0) return action;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], content_height },
    );

    switch (panel.active_tab) {
        .Agents => {
            const agents_action = agents_panel.draw(allocator, ctx, registry, panel, content_rect);
            action.refresh_sessions = agents_action.refresh;
            action.new_chat_agent_id = agents_action.new_chat_agent_id;
            action.open_session = agents_action.open_session;
            action.set_default_session = agents_action.set_default;
            action.delete_session = agents_action.delete_session;
            action.add_agent = agents_action.add_agent;
            action.remove_agent_id = agents_action.remove_agent_id;
        },
        .Operator => {
            const op_action = operator_view.draw(allocator, ctx, is_connected, content_rect);
            action.refresh_nodes = op_action.refresh_nodes;
            action.select_node = op_action.select_node;
            action.invoke_node = op_action.invoke_node;
            action.describe_node = op_action.describe_node;
            action.resolve_approval = op_action.resolve_approval;
            action.clear_node_describe = op_action.clear_node_describe;
            action.clear_node_result = op_action.clear_node_result;
            action.clear_operator_notice = op_action.clear_operator_notice;
        },
        .Settings => {
            const settings_action = settings_panel.draw(
                allocator,
                cfg,
                ctx.state,
                is_connected,
                &ctx.update_state,
                app_version,
                content_rect,
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
        },
        else => unreachable,
    }

    return action;
}

fn drawTabs(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    active: *workspace.ControlTab,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const tab_height = line_height + t.spacing.xs * 2.0;
    const bar_height = tab_height + t.spacing.sm * 2.0;
    const bar_rect = draw_context.Rect.fromMinSize(rect.min, .{ rect.size()[0], bar_height });
    dc.drawRect(bar_rect, .{ .fill = t.colors.surface });
    dc.drawLine(.{ bar_rect.min[0], bar_rect.max[1] }, .{ bar_rect.max[0], bar_rect.max[1] }, 1.0, t.colors.divider);

    const tab_gap = t.spacing.xs;
    var total_width: f32 = 0.0;
    for (tabs) |tab| {
        total_width += tabWidth(dc, tab.label, t) + tab_gap;
    }
    if (total_width > 0.0) total_width -= tab_gap;

    var left_pad = t.spacing.sm;
    var right_pad = t.spacing.sm;
    const button_size = tab_height;
    const button_gap = t.spacing.xs;
    const show_scroll = total_width > bar_rect.size()[0] - (left_pad + right_pad);
    if (show_scroll) {
        left_pad += button_size + button_gap;
        right_pad += button_size + button_gap;
    }
    const view_width = @max(0.0, bar_rect.size()[0] - left_pad - right_pad);
    const max_scroll = @max(0.0, total_width - view_width);
    tab_scroll_x = std.math.clamp(tab_scroll_x, 0.0, max_scroll);

    if (show_scroll) {
        const button_y = bar_rect.min[1] + (bar_rect.size()[1] - button_size) * 0.5;
        const left_button = draw_context.Rect.fromMinSize(
            .{ bar_rect.min[0] + t.spacing.sm, button_y },
            .{ button_size, button_size },
        );
        const right_button = draw_context.Rect.fromMinSize(
            .{ bar_rect.max[0] - t.spacing.sm - button_size, button_y },
            .{ button_size, button_size },
        );
        const can_scroll_left = tab_scroll_x > 0.5;
        const can_scroll_right = tab_scroll_x < max_scroll - 0.5;
        const scroll_step = @max(60.0, view_width * 0.5);
        if (widgets.button.draw(dc, left_button, "<", queue, .{
            .variant = .ghost,
            .radius = t.radius.sm,
            .disabled = !can_scroll_left,
        })) {
            tab_scroll_x = std.math.clamp(tab_scroll_x - scroll_step, 0.0, max_scroll);
        }
        if (widgets.button.draw(dc, right_button, ">", queue, .{
            .variant = .ghost,
            .radius = t.radius.sm,
            .disabled = !can_scroll_right,
        })) {
            tab_scroll_x = std.math.clamp(tab_scroll_x + scroll_step, 0.0, max_scroll);
        }
    }

    if (bar_rect.contains(queue.state.mouse_pos)) {
        for (queue.events.items) |evt| {
            if (evt == .mouse_wheel) {
                const delta = evt.mouse_wheel.delta;
                const scroll = if (delta[0] != 0.0) delta[0] else delta[1];
                if (scroll != 0.0) {
                    tab_scroll_x = std.math.clamp(tab_scroll_x - scroll * 36.0, 0.0, max_scroll);
                }
            }
        }
    }

    var cursor_x = bar_rect.min[0] + left_pad - tab_scroll_x;
    const cursor_y = bar_rect.min[1] + (bar_rect.size()[1] - tab_height) * 0.5;
    dc.pushClip(bar_rect);
    for (tabs) |tab| {
        const width = tabWidth(dc, tab.label, t);
        const tab_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ width, tab_height });
        if (drawTab(dc, tab_rect, tab.label, active.* == tab.kind, queue)) {
            active.* = tab.kind;
        }
        if (active.* == tab.kind) {
            const view_min = bar_rect.min[0] + left_pad;
            const view_max = bar_rect.max[0] - right_pad;
            if (tab_rect.min[0] < view_min) {
                const delta = view_min - tab_rect.min[0];
                tab_scroll_x = std.math.clamp(tab_scroll_x - delta, 0.0, max_scroll);
            } else if (tab_rect.max[0] > view_max) {
                const delta = tab_rect.max[0] - view_max;
                tab_scroll_x = std.math.clamp(tab_scroll_x + delta, 0.0, max_scroll);
            }
        }
        cursor_x += width + tab_gap;
    }
    dc.popClip();

    return bar_height;
}

fn tabWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    const text_size = dc.measureText(label, 0.0);
    return text_size[0] + t.spacing.sm * 2.0;
}

fn drawTab(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    active: bool,
    queue: *input_state.InputQueue,
) bool {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);
    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    clicked = true;
                }
            },
            else => {},
        }
    }

    const base = if (active) t.colors.primary else t.colors.surface;
    const alpha: f32 = if (active) 0.2 else if (hovered) 0.1 else 0.0;
    dc.drawRoundedRect(rect, t.radius.lg, .{
        .fill = colors.withAlpha(base, alpha),
        .stroke = colors.withAlpha(t.colors.border, 0.4),
        .thickness = 1.0,
    });

    const text_color = if (active) t.colors.primary else t.colors.text_secondary;
    const text_size = dc.measureText(label, 0.0);
    dc.drawText(
        label,
        .{ rect.min[0] + (rect.size()[0] - text_size[0]) * 0.5, rect.min[1] + (rect.size()[1] - text_size[1]) * 0.5 },
        .{ .color = text_color },
    );

    if (active) {
        dc.drawLine(.{ rect.min[0], rect.max[1] }, .{ rect.max[0], rect.max[1] }, 2.0, t.colors.primary);
    }

    return clicked;
}
