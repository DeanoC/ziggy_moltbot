const std = @import("std");
const state = @import("../../client/state.zig");
const agent_registry = @import("../../client/agent_registry.zig");
const session_keys = @import("../../client/session_keys.zig");
const session_kind = @import("../../client/session_kind.zig");
const session_presenter = @import("../session_presenter.zig");
const types = @import("../../protocol/types.zig");
const workspace = @import("../workspace.zig");
const draw_context = @import("../draw_context.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const nav_router = @import("../input/nav_router.zig");
const cursor = @import("../input/cursor.zig");
const widgets = @import("../widgets/widgets.zig");
const text_editor = @import("../widgets/text_editor.zig");
const panel_chrome = @import("../panel_chrome.zig");
const theme_runtime = @import("../theme_engine/runtime.zig");
const surface_chrome = @import("../surface_chrome.zig");

pub const AgentSessionAction = struct {
    agent_id: []u8,
    session_key: []u8,
};

pub const AddAgentAction = struct {
    id: []u8,
    display_name: []u8,
    icon: []u8,
};

pub const AgentFileKind = enum {
    soul,
    config,
    personality,
};

pub const AgentFileOpenAction = struct {
    agent_id: []u8,
    kind: AgentFileKind,
    path: ?[]u8 = null,

    pub fn deinit(self: *AgentFileOpenAction, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        if (self.path) |path| allocator.free(path);
    }
};

pub const AgentsPanelAction = struct {
    refresh: bool = false,
    new_chat_agent_id: ?[]u8 = null,
    open_session: ?AgentSessionAction = null,
    set_default: ?AgentSessionAction = null,
    delete_session: ?[]u8 = null,
    open_agent_file: ?AgentFileOpenAction = null,
    add_agent: ?AddAgentAction = null,
    remove_agent_id: ?[]u8 = null,
};

var add_id_editor: ?text_editor.TextEditor = null;
var add_name_editor: ?text_editor.TextEditor = null;
var add_icon_editor: ?text_editor.TextEditor = null;
var add_initialized = false;
var split_width: f32 = 240.0;
var split_dragging = false;
var list_scroll_y: f32 = 0.0;
var list_scroll_max: f32 = 0.0;
var details_scroll_y: f32 = 0.0;
var details_scroll_max: f32 = 0.0;
var show_system_sessions = false;
var pending_remove_agent_id: ?[]u8 = null;
var add_agent_modal_open = false;

pub fn deinit(allocator: std.mem.Allocator) void {
    if (add_id_editor) |*editor| editor.deinit(allocator);
    if (add_name_editor) |*editor| editor.deinit(allocator);
    if (add_icon_editor) |*editor| editor.deinit(allocator);
    if (pending_remove_agent_id) |agent_id| allocator.free(agent_id);
    pending_remove_agent_id = null;
    add_agent_modal_open = false;
    add_id_editor = null;
    add_name_editor = null;
    add_icon_editor = null;
    add_initialized = false;
}

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
    rect_override: ?draw_context.Rect,
) AgentsPanelAction {
    var action = AgentsPanelAction{};
    const t = theme.activeTheme();

    if (!add_initialized) {
        _ = ensureEditor(&add_id_editor, allocator);
        _ = ensureEditor(&add_name_editor, allocator);
        ensureEditor(&add_icon_editor, allocator).setText(allocator, "A");
        add_initialized = true;
    }

    ensureSelection(allocator, registry, panel);

    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();
    surface_chrome.drawBackground(&dc, panel_rect);

    const gap = t.spacing.md;
    const min_left: f32 = 220.0;
    const min_right: f32 = 260.0;
    if (split_width == 0.0) {
        split_width = @min(280.0, panel_rect.size()[0] * 0.35);
    }
    const max_left = @max(min_left, panel_rect.size()[0] - min_right - gap);
    split_width = std.math.clamp(split_width, min_left, max_left);

    const left_rect = draw_context.Rect.fromMinSize(
        panel_rect.min,
        .{ split_width, panel_rect.size()[1] },
    );
    const right_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap, panel_rect.min[1] },
        .{ panel_rect.max[0] - left_rect.max[0] - gap, panel_rect.size()[1] },
    );

    const queue = input_router.getQueue();
    var blocked_queue = input_state.InputQueue{ .events = .empty, .state = .{} };
    blocked_queue.state.mouse_pos = .{ -10000.0, -10000.0 };
    const interaction_queue = if (add_agent_modal_open) &blocked_queue else queue;

    drawAgentList(allocator, registry, panel, &dc, left_rect, interaction_queue, &action);
    handleSplitResize(&dc, panel_rect, left_rect, interaction_queue, gap, min_left, max_left);
    if (right_rect.size()[0] > 0.0) {
        drawAgentDetailsPane(allocator, ctx, registry, panel, &dc, right_rect, interaction_queue, &action);
    }

    if (add_agent_modal_open) {
        drawAddAgentModal(allocator, registry, panel, &dc, panel_rect, queue, &action);
    }

    return action;
}

fn drawAgentList(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) void {
    const t = dc.theme;
    panel_chrome.draw(dc, rect, .{
        .radius = t.radius.md,
        .draw_shadow = true,
        .draw_frame = false,
    });

    const padding = t.spacing.sm;
    const left = rect.min[0] + padding;
    var cursor_y = rect.min[1] + padding;

    theme.pushFor(t, .heading);
    dc.drawText("Agents", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const line_height = dc.lineHeight();
    const button_height = widgets.button.defaultHeight(t, line_height);
    cursor_y += line_height + t.spacing.xs;

    const refresh_label = "Refresh Sessions";
    const add_label = "Add Agent";
    const refresh_width = buttonWidth(dc, refresh_label, t);
    const add_width = buttonWidth(dc, add_label, t);
    const buttons_gap = t.spacing.xs;
    const use_stacked = refresh_width + buttons_gap + add_width > rect.size()[0] - padding * 2.0;

    const refresh_rect = draw_context.Rect.fromMinSize(
        .{ left, cursor_y },
        .{ if (use_stacked) rect.size()[0] - padding * 2.0 else refresh_width, button_height },
    );
    if (widgets.button.draw(dc, refresh_rect, refresh_label, queue, .{ .variant = .secondary })) {
        action.refresh = true;
    }
    if (use_stacked) {
        cursor_y += button_height + buttons_gap;
        const add_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ rect.size()[0] - padding * 2.0, button_height });
        if (widgets.button.draw(dc, add_rect, add_label, queue, .{ .variant = .primary })) {
            openAddAgentModal(allocator);
        }
        cursor_y += button_height + t.spacing.sm;
    } else {
        const add_rect = draw_context.Rect.fromMinSize(
            .{ refresh_rect.max[0] + buttons_gap, cursor_y },
            .{ add_width, button_height },
        );
        if (widgets.button.draw(dc, add_rect, add_label, queue, .{ .variant = .primary })) {
            openAddAgentModal(allocator);
        }
        cursor_y += button_height + t.spacing.sm;
    }
    const divider = draw_context.Rect.fromMinSize(
        .{ rect.min[0], cursor_y },
        .{ rect.size()[0], 1.0 },
    );
    dc.drawRect(divider, .{ .fill = t.colors.divider });
    cursor_y += t.spacing.sm;

    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) return;

    if (registry.agents.items.len == 0) {
        dc.drawText("No agents configured.", .{ list_rect.min[0], list_rect.min[1] }, .{ .color = t.colors.text_secondary });
        return;
    }

    const row_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);
    const row_gap = t.spacing.xs;
    const total_height = @as(f32, @floatFromInt(registry.agents.items.len)) * (row_height + row_gap);
    list_scroll_max = @max(0.0, total_height - list_rect.size()[1]);
    handleWheelScroll(queue, list_rect, &list_scroll_y, list_scroll_max, 28.0);

    dc.pushClip(list_rect);
    var row_y = list_rect.min[1] - list_scroll_y;
    for (registry.agents.items) |agent| {
        nav_router.pushScope(std.hash.Wyhash.hash(0, agent.id));
        defer nav_router.popScope();

        const row_rect = draw_context.Rect.fromMinSize(.{ list_rect.min[0], row_y }, .{ list_rect.size()[0], row_height });
        if (row_rect.max[1] >= list_rect.min[1] and row_rect.min[1] <= list_rect.max[1]) {
            const selected = if (panel.selected_agent_id) |sel| std.mem.eql(u8, sel, agent.id) else false;
            if (drawAgentRow(dc, row_rect, agent, selected, queue)) {
                setSelectedAgent(allocator, panel, agent.id);
            }
        }
        row_y += row_height + row_gap;
    }
    dc.popClip();
}

fn drawAgentRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    agent: agent_registry.AgentProfile,
    selected: bool,
    queue: *input_state.InputQueue,
) bool {
    const t = dc.theme;
    const nav_state = nav_router.get();
    const nav_id = if (nav_state != null) nav_router.makeWidgetId(@returnAddress(), "agents_panel.agent_row", "row") else 0;
    if (nav_state) |navp| navp.registerItem(dc.allocator, nav_id, rect);
    const nav_active = if (nav_state) |navp| navp.isActive() else false;
    const focused = if (nav_state) |navp| navp.isFocusedId(nav_id) else false;

    const allow_hover = theme_runtime.allowHover(queue);
    const hovered = (allow_hover and rect.contains(queue.state.mouse_pos)) or (nav_active and focused);
    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    if (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging) {
                        clicked = true;
                    }
                }
            },
            else => {},
        }
    }
    if (!clicked and nav_active and focused) {
        clicked = nav_router.wasActivated(queue, nav_id);
    }

    if (selected or hovered) {
        const base = if (selected) t.colors.primary else t.colors.surface;
        const alpha: f32 = if (selected) 0.12 else 0.08;
        dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(base, alpha) });
    }

    var label_buf: [256]u8 = undefined;
    const text = if (std.mem.eql(u8, agent.display_name, agent.id))
        (std.fmt.bufPrint(&label_buf, "{s} {s}", .{ agent.icon, agent.display_name }) catch agent.display_name)
    else
        (std.fmt.bufPrint(&label_buf, "{s} {s} ({s})", .{ agent.icon, agent.display_name, agent.id }) catch agent.display_name);
    const left = rect.min[0] + t.spacing.sm;
    const text_max = @max(0.0, rect.max[0] - left - t.spacing.sm);
    var fit_buf: [256]u8 = undefined;
    const text_fit = fitTextEnd(dc, text, text_max, &fit_buf);
    dc.drawText(text_fit, .{ left, rect.min[1] + t.spacing.xs }, .{ .color = t.colors.text_primary });

    return clicked;
}

fn drawAgentDetailsPane(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) void {
    const t = dc.theme;
    panel_chrome.draw(dc, rect, .{
        .radius = t.radius.md,
        .draw_shadow = true,
        .draw_frame = false,
    });

    const padding = t.spacing.md;
    const inner_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );
    if (inner_rect.size()[0] <= 0.0 or inner_rect.size()[1] <= 0.0) return;

    handleWheelScroll(queue, rect, &details_scroll_y, details_scroll_max, 36.0);

    dc.pushClip(inner_rect);
    var cursor_y = inner_rect.min[1] - details_scroll_y;

    if (panel.selected_agent_id) |selected_id| {
        if (registry.find(selected_id)) |agent| {
            cursor_y += drawAgentActionsCard(allocator, dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0], agent, panel, queue, action);
            cursor_y += t.spacing.md;
            cursor_y += drawAgentSessionsCard(allocator, ctx, dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0], agent, queue, action);
        } else {
            cursor_y += drawEmptyState(dc, .{ inner_rect.min[0], cursor_y }, "Select an agent to view details.");
        }
    } else {
        cursor_y += drawEmptyState(dc, .{ inner_rect.min[0], cursor_y }, "Select an agent to view details.");
    }

    dc.popClip();

    const content_height = (cursor_y + details_scroll_y) - inner_rect.min[1];
    const view_height = inner_rect.size()[1];
    details_scroll_max = @max(0.0, content_height - view_height);
    if (details_scroll_y > details_scroll_max) details_scroll_y = details_scroll_max;
    if (details_scroll_y < 0.0) details_scroll_y = 0.0;
}

fn drawEmptyState(
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    label: []const u8,
) f32 {
    const t = dc.theme;
    const line_height = dc.lineHeight();
    dc.drawText(label, pos, .{ .color = t.colors.text_secondary });
    return line_height + t.spacing.sm;
}

fn drawAgentActionsCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    agent: *agent_registry.AgentProfile,
    panel: *workspace.ControlPanel,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) f32 {
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = widgets.button.defaultHeight(t, line_height);
    const content_width = width - padding * 2.0;
    const gap = t.spacing.sm;

    const open_current_label = "Open Current";
    const remove_label = "Remove Agent";
    const soul_label = "Open Soul";
    const config_label = "Open Config";
    const personality_label = "Open Personality";
    const open_current_w = buttonWidth(dc, open_current_label, t);
    const remove_w = buttonWidth(dc, remove_label, t);
    const stacked = open_current_w + gap + remove_w > content_width;
    const is_main = std.mem.eql(u8, agent.id, "main");
    const pending_remove = pending_remove_agent_id != null and std.mem.eql(u8, pending_remove_agent_id.?, agent.id);
    var content_height = if (stacked) button_height * 2.0 + gap else button_height;
    if (pending_remove) {
        content_height += t.spacing.xs;
        content_height += line_height * 2.0 + t.spacing.xs + button_height;
    }
    content_height += gap;
    content_height += button_height * 3.0 + gap * 2.0;
    if (is_main) {
        content_height += line_height + t.spacing.xs;
    }
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Actions");
    const left = rect.min[0] + padding;

    if (stacked) {
        const full_width = content_width;
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ full_width, button_height }), open_current_label, queue, .{ .variant = .primary })) {
            if (makeMainSessionAction(allocator, agent.id)) |session_action| {
                action.open_session = session_action;
            }
        }
        cursor_y += button_height + gap;
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ full_width, button_height }), remove_label, queue, .{
            .variant = .secondary,
            .disabled = is_main,
        })) {
            setPendingRemoveAgent(allocator, agent.id);
        }
        cursor_y += button_height;
    } else {
        const btn_w = (content_width - gap) * 0.5;
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ btn_w, button_height }), open_current_label, queue, .{ .variant = .primary })) {
            if (makeMainSessionAction(allocator, agent.id)) |session_action| {
                action.open_session = session_action;
            }
        }
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left + btn_w + gap, cursor_y }, .{ btn_w, button_height }), remove_label, queue, .{
            .variant = .secondary,
            .disabled = is_main,
        })) {
            setPendingRemoveAgent(allocator, agent.id);
        }
        cursor_y += button_height;
    }

    if (pending_remove) {
        cursor_y += t.spacing.xs;
        const prompt_h = line_height * 2.0 + t.spacing.xs + button_height;
        const prompt_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_width, prompt_h });
        dc.drawRoundedRect(prompt_rect, t.radius.sm, .{
            .fill = colors.withAlpha(t.colors.warning, 0.10),
            .stroke = colors.withAlpha(t.colors.warning, 0.45),
            .thickness = 1.0,
        });

        const inner_left = prompt_rect.min[0] + t.spacing.xs;
        var prompt_y = prompt_rect.min[1] + t.spacing.xs;
        var prompt_buf: [160]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "Delete agent \"{s}\"?", .{agent.display_name}) catch "Delete this agent?";
        dc.drawText(prompt, .{ inner_left, prompt_y }, .{ .color = t.colors.text_primary });
        prompt_y += line_height;
        dc.drawText("This removes it locally and requests gateway delete.", .{ inner_left, prompt_y }, .{ .color = t.colors.text_secondary });
        prompt_y += line_height + t.spacing.xs;

        const confirm_gap = t.spacing.sm;
        const confirm_w = (content_width - confirm_gap) * 0.5;
        const proceed_rect = draw_context.Rect.fromMinSize(.{ left, prompt_y }, .{ confirm_w, button_height });
        const cancel_rect = draw_context.Rect.fromMinSize(.{ left + confirm_w + confirm_gap, prompt_y }, .{ confirm_w, button_height });

        if (widgets.button.draw(dc, proceed_rect, "Proceed", queue, .{ .variant = .primary })) {
            action.remove_agent_id = allocator.dupe(u8, agent.id) catch null;
            clearPendingRemoveAgent(allocator);
            clearSelectedAgent(allocator, panel);
        }
        if (widgets.button.draw(dc, cancel_rect, "Cancel", queue, .{ .variant = .secondary })) {
            clearPendingRemoveAgent(allocator);
        }

        cursor_y += prompt_h;
    }

    cursor_y += gap;

    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_width, button_height }), soul_label, queue, .{ .variant = .ghost })) {
        if (makeAgentFileAction(allocator, agent.id, .soul, agent.soul_path)) |file_action| {
            action.open_agent_file = file_action;
        }
    }
    cursor_y += button_height + gap;

    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_width, button_height }), config_label, queue, .{ .variant = .ghost })) {
        if (makeAgentFileAction(allocator, agent.id, .config, agent.config_path)) |file_action| {
            action.open_agent_file = file_action;
        }
    }
    cursor_y += button_height + gap;

    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_width, button_height }), personality_label, queue, .{ .variant = .ghost })) {
        if (makeAgentFileAction(allocator, agent.id, .personality, agent.personality_path)) |file_action| {
            action.open_agent_file = file_action;
        }
    }
    cursor_y += button_height;

    if (is_main) {
        cursor_y += t.spacing.xs;
        dc.drawText("Main agent cannot be removed.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    }

    return height;
}

fn drawAgentSessionsCard(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    agent: *agent_registry.AgentProfile,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) f32 {
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = widgets.button.defaultHeight(t, line_height);
    const row_gap = t.spacing.sm;
    const row_height = line_height * 2.0 + t.spacing.xs * 2.0 + t.spacing.sm * 2.0 + button_height;

    const toggle_label = "Show system sessions";
    const toggle_width = line_height + t.spacing.xs + dc.measureText(toggle_label, 0.0)[0];
    const toggle_height = @max(line_height, 20.0);

    var session_indices = std.ArrayList(usize).empty;
    defer session_indices.deinit(allocator);
    if (ctx.sessions.items.len > 0) {
        for (ctx.sessions.items, 0..) |session, index| {
            if (!session_presenter.includeForAgent(session, agent.id, show_system_sessions)) continue;
            session_indices.append(allocator, index) catch {};
        }
    }
    if (session_indices.items.len > 1) {
        std.sort.heap(usize, session_indices.items, ctx.sessions.items, session_presenter.updatedDesc);
    }

    var list_height: f32 = 0.0;
    const empty_list = session_indices.items.len == 0;
    if (empty_list) {
        list_height = line_height + t.spacing.sm;
    } else {
        list_height = row_height * @as(f32, @floatFromInt(session_indices.items.len));
        if (session_indices.items.len > 1) {
            list_height += row_gap * @as(f32, @floatFromInt(session_indices.items.len - 1));
        }
    }

    const height = padding + line_height + t.spacing.xs + toggle_height + t.spacing.xs + list_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Chats");
    const left = rect.min[0] + padding;
    const content_width = width - padding * 2.0;
    const toggle_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ toggle_width, toggle_height });
    _ = widgets.checkbox.draw(dc, toggle_rect, toggle_label, &show_system_sessions, queue, .{});
    cursor_y += toggle_height + t.spacing.xs;

    if (empty_list) {
        dc.drawText("No chats for this agent.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        return height;
    }

    const now_ms = std.time.milliTimestamp();
    for (session_indices.items, 0..) |idx, ordinal| {
        const session = ctx.sessions.items[idx];
        const row_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_width, row_height });
        drawAgentSessionRow(allocator, dc, row_rect, agent, session, ordinal, now_ms, queue, action);
        cursor_y += row_height + row_gap;
    }

    return height;
}

fn drawAgentSessionRow(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    agent: *agent_registry.AgentProfile,
    session: types.Session,
    ordinal: usize,
    now_ms: i64,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) void {
    const t = dc.theme;
    const padding = t.spacing.xs;
    const line_height = dc.lineHeight();
    const button_height = widgets.button.defaultHeight(t, line_height);
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(t.colors.surface, 0.6), .stroke = t.colors.border, .thickness = 1.0 });
    const inner_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );
    dc.pushClip(inner_rect);

    var cursor_y = inner_rect.min[1];
    var label_buf: [96]u8 = undefined;
    const label = session_presenter.displayLabel(session, agent.id, ordinal, &label_buf);
    const text_width = @max(0.0, inner_rect.size()[0]);
    var label_fit_buf: [128]u8 = undefined;
    const label_fit = fitTextEnd(dc, label, text_width, &label_fit_buf);
    dc.drawText(label_fit, .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.xs;

    var time_buf: [64]u8 = undefined;
    const time_label = session_presenter.secondaryLabel(now_ms, session, &time_buf);
    const is_default = agent.default_session_key != null and std.mem.eql(u8, agent.default_session_key.?, session.key);
    const is_system = session_kind.isAutomationSession(session) and !std.mem.startsWith(u8, time_label, "System");
    var secondary_buf: [192]u8 = undefined;
    const secondary = if (is_default and is_system)
        std.fmt.bufPrint(&secondary_buf, "{s} • Default • System", .{time_label}) catch time_label
    else if (is_default)
        std.fmt.bufPrint(&secondary_buf, "{s} • Default", .{time_label}) catch time_label
    else if (is_system)
        std.fmt.bufPrint(&secondary_buf, "{s} • System", .{time_label}) catch time_label
    else
        time_label;
    var secondary_fit_buf: [192]u8 = undefined;
    const secondary_fit = fitTextEnd(dc, secondary, text_width, &secondary_fit_buf);
    dc.drawText(secondary_fit, .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });

    const button_count: f32 = 2.0;
    const button_gap = t.spacing.sm;
    const total_gap = button_gap * (button_count - 1.0);
    const button_width = (inner_rect.size()[0] - total_gap) / button_count;
    const button_y = inner_rect.max[1] - button_height;
    var button_x = inner_rect.min[0];

    // Scope interactive controls to the session key so repeating labels like "Open"
    // produce unique/stable nav ids across rows.
    nav_router.pushScope(std.hash.Wyhash.hash(0, session.key));
    defer nav_router.popScope();

    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_width, button_height }), "Open", queue, .{ .variant = .secondary })) {
        if (setSessionAction(allocator, agent.id, session.key)) |session_action| {
            action.open_session = session_action;
        }
    }
    button_x += button_width + button_gap;
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_width, button_height }), "Delete", queue, .{ .variant = .ghost })) {
        action.delete_session = allocator.dupe(u8, session.key) catch action.delete_session;
    }

    dc.popClip();
}

fn drawAddAgentModal(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
    dc: *draw_context.DrawContext,
    panel_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) void {
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const input_height = widgets.text_input.defaultHeight(t, line_height);
    const button_height = widgets.button.defaultHeight(t, line_height);

    const id_text = editorText(add_id_editor);
    const name_text = editorText(add_name_editor);
    const icon_text = editorText(add_icon_editor);
    const requested_id = std.mem.trim(u8, id_text, " \t\r\n");
    const requested_name = std.mem.trim(u8, name_text, " \t\r\n");
    const requested_icon = std.mem.trim(u8, icon_text, " \t\r\n");
    const gateway_name = if (requested_name.len > 0) requested_name else requested_id;
    var normalized_id_buf: [128]u8 = undefined;
    const normalized_id = normalizeAgentIdForGateway(gateway_name, &normalized_id_buf);
    const valid_id = normalized_id.len > 0 and session_keys.isAgentIdValid(normalized_id);
    const exists = valid_id and registry.find(normalized_id) != null;
    const can_add = valid_id and !exists and gateway_name.len > 0;

    var content_height: f32 = 0.0;
    content_height += labeledInputHeight(input_height, line_height, t) * 3.0;
    content_height += button_height + t.spacing.sm;
    content_height += line_height;

    const width = std.math.clamp(panel_rect.size()[0] * 0.46, 340.0, 560.0);
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(
        .{
            panel_rect.min[0] + (panel_rect.size()[0] - width) * 0.5,
            panel_rect.min[1] + (panel_rect.size()[1] - height) * 0.5,
        },
        .{ width, height },
    );

    dc.drawRect(panel_rect, .{ .fill = colors.withAlpha(t.colors.background, 0.55) });

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and !rect.contains(md.pos)) {
                    add_agent_modal_open = false;
                    return;
                }
            },
            else => {},
        }
    }

    var cursor_y = drawCardBase(dc, rect, "Add Agent");
    const left = rect.min[0] + padding;
    const content_width = width - padding * 2.0;

    cursor_y += drawLabeledInput(dc, queue, allocator, left, cursor_y, content_width, "Id", ensureEditor(&add_id_editor, allocator), .{});
    cursor_y += drawLabeledInput(dc, queue, allocator, left, cursor_y, content_width, "Name", ensureEditor(&add_name_editor, allocator), .{});
    cursor_y += drawLabeledInput(dc, queue, allocator, left, cursor_y, content_width, "Icon", ensureEditor(&add_icon_editor, allocator), .{});

    const cancel_w = buttonWidth(dc, "Cancel", t);
    const add_w = buttonWidth(dc, "Add", t);
    const buttons_gap = t.spacing.sm;
    const cancel_x = rect.max[0] - padding - cancel_w;
    const add_x = cancel_x - buttons_gap - add_w;
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ add_x, cursor_y }, .{ add_w, button_height }), "Add", queue, .{
        .variant = .primary,
        .disabled = !can_add,
    })) {
        const display = if (requested_name.len > 0) requested_name else normalized_id;
        const icon = if (requested_icon.len > 0) requested_icon else "?";
        const id_copy = allocator.dupe(u8, normalized_id) catch return;
        errdefer allocator.free(id_copy);
        const name_copy = allocator.dupe(u8, display) catch {
            allocator.free(id_copy);
            return;
        };
        errdefer allocator.free(name_copy);
        const icon_copy = allocator.dupe(u8, icon) catch {
            allocator.free(id_copy);
            allocator.free(name_copy);
            return;
        };
        action.add_agent = .{
            .id = id_copy,
            .display_name = name_copy,
            .icon = icon_copy,
        };
        setSelectedAgent(allocator, panel, normalized_id);
        ensureEditor(&add_id_editor, allocator).clear();
        ensureEditor(&add_name_editor, allocator).clear();
        ensureEditor(&add_icon_editor, allocator).setText(allocator, "A");
        add_agent_modal_open = false;
    }
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cancel_x, cursor_y }, .{ cancel_w, button_height }), "Cancel", queue, .{
        .variant = .secondary,
    })) {
        add_agent_modal_open = false;
    }
    cursor_y += button_height + t.spacing.sm;

    if (!valid_id and gateway_name.len > 0) {
        dc.drawText("Provide a name or id with letters or numbers.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    } else if (exists) {
        dc.drawText("Agent id already exists.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    }
}

fn drawCardBase(dc: *draw_context.DrawContext, rect: draw_context.Rect, title: []const u8) f32 {
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();

    panel_chrome.draw(dc, rect, .{
        .radius = t.radius.md,
        .draw_shadow = true,
        .draw_frame = false,
    });
    theme.pushFor(t, .heading);
    dc.drawText(title, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();

    return rect.min[1] + padding + line_height + t.spacing.xs;
}

fn drawLabeledInput(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    width: f32,
    label: []const u8,
    editor: *text_editor.TextEditor,
    opts: widgets.text_input.Options,
) f32 {
    const t = dc.theme;
    const line_height = dc.lineHeight();
    dc.drawText(label, .{ x, y }, .{ .color = t.colors.text_primary });
    const input_height = widgets.text_input.defaultHeight(t, line_height);
    const input_rect = draw_context.Rect.fromMinSize(.{ x, y + line_height + t.spacing.xs }, .{ width, input_height });
    nav_router.pushScope(std.hash.Wyhash.hash(0, label));
    _ = widgets.text_input.draw(editor, allocator, dc, input_rect, queue, opts);
    nav_router.popScope();
    return labeledInputHeight(input_height, line_height, t);
}

fn labeledInputHeight(input_height: f32, line_height: f32, t: *const theme.Theme) f32 {
    return line_height + t.spacing.xs + input_height + t.spacing.sm;
}

fn setSessionAction(
    allocator: std.mem.Allocator,
    agent_id: []const u8,
    session_key: []const u8,
) ?AgentSessionAction {
    const agent_copy = allocator.dupe(u8, agent_id) catch return null;
    errdefer allocator.free(agent_copy);
    const session_copy = allocator.dupe(u8, session_key) catch {
        allocator.free(agent_copy);
        return null;
    };
    return .{ .agent_id = agent_copy, .session_key = session_copy };
}

fn makeMainSessionAction(allocator: std.mem.Allocator, agent_id: []const u8) ?AgentSessionAction {
    const main_key = session_keys.buildMainSessionKey(allocator, agent_id) catch return null;
    defer allocator.free(main_key);
    return setSessionAction(allocator, agent_id, main_key);
}

fn openAddAgentModal(allocator: std.mem.Allocator) void {
    ensureEditor(&add_id_editor, allocator).clear();
    ensureEditor(&add_name_editor, allocator).clear();
    ensureEditor(&add_icon_editor, allocator).setText(allocator, "A");
    add_agent_modal_open = true;
}

fn makeAgentFileAction(
    allocator: std.mem.Allocator,
    agent_id: []const u8,
    kind: AgentFileKind,
    path: ?[]const u8,
) ?AgentFileOpenAction {
    const agent_copy = allocator.dupe(u8, agent_id) catch return null;
    errdefer allocator.free(agent_copy);
    const path_copy = if (path) |value|
        allocator.dupe(u8, value) catch {
            allocator.free(agent_copy);
            return null;
        }
    else
        null;
    return .{
        .agent_id = agent_copy,
        .kind = kind,
        .path = path_copy,
    };
}

fn handleSplitResize(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    left_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    gap: f32,
    min_left: f32,
    max_left: f32,
) void {
    const t = dc.theme;
    const divider_w: f32 = 6.0;
    const divider_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap * 0.5 - divider_w * 0.5, rect.min[1] },
        .{ divider_w, rect.size()[1] },
    );

    const hover = divider_rect.contains(queue.state.mouse_pos);
    if (hover) {
        cursor.set(.resize_ew);
    }

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and divider_rect.contains(md.pos)) {
                    split_dragging = true;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    split_dragging = false;
                }
            },
            else => {},
        }
    }

    if (split_dragging) {
        const target = queue.state.mouse_pos[0] - rect.min[0];
        split_width = std.math.clamp(target, min_left, max_left);
    }

    const divider = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap * 0.5 - 1.0, rect.min[1] },
        .{ 2.0, rect.size()[1] },
    );
    const alpha: f32 = if (hover or split_dragging) 0.25 else 0.12;
    const line_color = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], alpha };
    dc.drawRect(divider, .{ .fill = line_color });
}

fn handleWheelScroll(
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    scroll_y: *f32,
    max_scroll: f32,
    step: f32,
) void {
    widgets.kinetic_scroll.apply(queue, rect, scroll_y, max_scroll, step);
}

fn ensureEditor(
    slot: *?text_editor.TextEditor,
    allocator: std.mem.Allocator,
) *text_editor.TextEditor {
    if (slot.* == null) {
        slot.* = text_editor.TextEditor.init(allocator) catch unreachable;
    }
    return &slot.*.?;
}

fn editorText(editor: ?text_editor.TextEditor) []const u8 {
    if (editor) |value| {
        return value.slice();
    }
    return "";
}

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn ensureSelection(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
) void {
    if (registry.agents.items.len == 0) {
        clearSelectedAgent(allocator, panel);
        return;
    }
    if (panel.selected_agent_id) |selected| {
        if (registry.find(selected) != null) return;
        clearSelectedAgent(allocator, panel);
    }
    const fallback = registry.agents.items[0].id;
    setSelectedAgent(allocator, panel, fallback);
}

fn setSelectedAgent(allocator: std.mem.Allocator, panel: *workspace.ControlPanel, id: []const u8) void {
    if (panel.selected_agent_id) |selected| {
        if (std.mem.eql(u8, selected, id)) return;
        allocator.free(selected);
    }
    clearPendingRemoveAgent(allocator);
    panel.selected_agent_id = allocator.dupe(u8, id) catch panel.selected_agent_id;
}

fn clearSelectedAgent(allocator: std.mem.Allocator, panel: *workspace.ControlPanel) void {
    clearPendingRemoveAgent(allocator);
    if (panel.selected_agent_id) |selected| {
        allocator.free(selected);
    }
    panel.selected_agent_id = null;
}

fn setPendingRemoveAgent(allocator: std.mem.Allocator, id: []const u8) void {
    if (pending_remove_agent_id) |existing| {
        if (std.mem.eql(u8, existing, id)) return;
        allocator.free(existing);
    }
    pending_remove_agent_id = allocator.dupe(u8, id) catch pending_remove_agent_id;
}

fn clearPendingRemoveAgent(allocator: std.mem.Allocator) void {
    if (pending_remove_agent_id) |existing| {
        allocator.free(existing);
    }
    pending_remove_agent_id = null;
}

fn normalizeAgentIdForGateway(value: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return "";

    var out_len: usize = 0;
    var prev_dash = false;
    for (trimmed) |ch| {
        if (out_len >= 64 or out_len >= buf.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
            buf[out_len] = std.ascii.toLower(ch);
            out_len += 1;
            prev_dash = false;
        } else if (!prev_dash and out_len > 0) {
            buf[out_len] = '-';
            out_len += 1;
            prev_dash = true;
        }
    }

    while (out_len > 0 and buf[0] == '-') {
        std.mem.copyForwards(u8, buf[0 .. out_len - 1], buf[1..out_len]);
        out_len -= 1;
    }
    while (out_len > 0 and buf[out_len - 1] == '-') {
        out_len -= 1;
    }

    return buf[0..out_len];
}

fn fitTextEnd(
    dc: *draw_context.DrawContext,
    text: []const u8,
    max_width: f32,
    buf: []u8,
) []const u8 {
    if (text.len == 0) return "";
    if (max_width <= 0.0) return "";
    if (dc.measureText(text, 0.0)[0] <= max_width) return text;

    const ellipsis = "...";
    const ellipsis_w = dc.measureText(ellipsis, 0.0)[0];
    if (ellipsis_w > max_width) return "";
    if (buf.len <= ellipsis.len) return ellipsis;

    var low: usize = 0;
    var high: usize = @min(text.len, buf.len - ellipsis.len - 1);
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const candidate = std.fmt.bufPrint(buf, "{s}{s}", .{ text[0..mid], ellipsis }) catch ellipsis;
        const w = dc.measureText(candidate, 0.0)[0];
        if (w <= max_width) {
            best = mid;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    if (best == 0) return ellipsis;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ text[0..best], ellipsis }) catch ellipsis;
}
