const std = @import("std");
const state = @import("../../client/state.zig");
const agent_registry = @import("../../client/agent_registry.zig");
const session_keys = @import("../../client/session_keys.zig");
const types = @import("../../protocol/types.zig");
const workspace = @import("../workspace.zig");
const draw_context = @import("../draw_context.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const cursor = @import("../input/cursor.zig");
const widgets = @import("../widgets/widgets.zig");
const text_editor = @import("../widgets/text_editor.zig");

pub const AgentSessionAction = struct {
    agent_id: []u8,
    session_key: []u8,
};

pub const AddAgentAction = struct {
    id: []u8,
    display_name: []u8,
    icon: []u8,
};

pub const AgentsPanelAction = struct {
    refresh: bool = false,
    new_chat_agent_id: ?[]u8 = null,
    open_session: ?AgentSessionAction = null,
    set_default: ?AgentSessionAction = null,
    delete_session: ?[]u8 = null,
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

pub fn deinit(allocator: std.mem.Allocator) void {
    if (add_id_editor) |*editor| editor.deinit(allocator);
    if (add_name_editor) |*editor| editor.deinit(allocator);
    if (add_icon_editor) |*editor| editor.deinit(allocator);
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
    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

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
    drawAgentList(allocator, registry, panel, &dc, left_rect, queue, &action);
    handleSplitResize(&dc, panel_rect, left_rect, queue, gap, min_left, max_left);
    if (right_rect.size()[0] > 0.0) {
        drawAgentDetailsPane(allocator, ctx, registry, panel, &dc, right_rect, queue, &action);
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
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    const left = rect.min[0] + padding;
    var cursor_y = rect.min[1] + padding;

    theme.push(.heading);
    dc.drawText("Agents", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    cursor_y += line_height + t.spacing.xs;

    const refresh_label = "Refresh Sessions";
    const refresh_width = buttonWidth(dc, refresh_label, t);
    const refresh_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ refresh_width, button_height });
    if (widgets.button.draw(dc, refresh_rect, refresh_label, queue, .{ .variant = .secondary })) {
        action.refresh = true;
    }

    cursor_y += button_height + t.spacing.sm;
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

    const row_height = line_height + t.spacing.xs * 2.0;
    const row_gap = t.spacing.xs;
    const total_height = @as(f32, @floatFromInt(registry.agents.items.len)) * (row_height + row_gap);
    list_scroll_max = @max(0.0, total_height - list_rect.size()[1]);
    handleWheelScroll(queue, list_rect, &list_scroll_y, list_scroll_max, 28.0);

    dc.pushClip(list_rect);
    var row_y = list_rect.min[1] - list_scroll_y;
    for (registry.agents.items) |agent| {
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

    if (selected or hovered) {
        const base = if (selected) t.colors.primary else t.colors.surface;
        const alpha: f32 = if (selected) 0.12 else 0.08;
        dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(base, alpha) });
    }

    var label_buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&label_buf, "{s} {s}", .{ agent.icon, agent.display_name }) catch agent.display_name;
    dc.drawText(text, .{ rect.min[0] + t.spacing.sm, rect.min[1] + t.spacing.xs }, .{ .color = t.colors.text_primary });

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
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

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
            cursor_y += drawAgentDetailsCard(dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0], agent);
            cursor_y += t.spacing.md;
            cursor_y += drawAgentActionsCard(allocator, dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0], agent, panel, queue, action);
            cursor_y += t.spacing.md;
            cursor_y += drawAgentSessionsCard(allocator, ctx, dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0], agent, queue, action);
            cursor_y += t.spacing.md;
            cursor_y += drawAddAgentCard(allocator, registry, panel, dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0], queue, action);
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
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    dc.drawText(label, pos, .{ .color = t.colors.text_secondary });
    return line_height + t.spacing.sm;
}

fn drawAgentDetailsCard(
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    agent: *agent_registry.AgentProfile,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const field_gap = t.spacing.sm;
    const field_height = line_height * 2.0 + t.spacing.xs;
    const content_height = field_height * 5.0 + field_gap * 4.0;
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Agent Details");
    const left = rect.min[0] + padding;

    var name_buf: [256]u8 = undefined;
    const display = std.fmt.bufPrint(&name_buf, "{s} {s}", .{ agent.icon, agent.display_name }) catch agent.display_name;
    cursor_y += drawLabelValue(dc, left, cursor_y, "Display Name", display);
    cursor_y += field_gap;
    cursor_y += drawLabelValue(dc, left, cursor_y, "Id", agent.id);
    cursor_y += field_gap;
    cursor_y += drawLabelValue(dc, left, cursor_y, "Soul", agent.soul_path orelse "(not set)");
    cursor_y += field_gap;
    cursor_y += drawLabelValue(dc, left, cursor_y, "Config", agent.config_path orelse "(not set)");
    cursor_y += field_gap;
    _ = drawLabelValue(dc, left, cursor_y, "Personality", agent.personality_path orelse "(not set)");

    return height;
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
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const content_width = width - padding * 2.0;
    const gap = t.spacing.sm;

    const new_label = "New Chat";
    const remove_label = "Remove Agent";
    const new_w = buttonWidth(dc, new_label, t);
    const remove_w = buttonWidth(dc, remove_label, t);
    const stacked = new_w + gap + remove_w > content_width;
    const is_main = std.mem.eql(u8, agent.id, "main");
    var content_height = if (stacked) button_height * 2.0 + gap else button_height;
    if (is_main) {
        content_height += line_height + t.spacing.xs;
    }
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Actions");
    const left = rect.min[0] + padding;

    if (stacked) {
        const full_width = content_width;
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ full_width, button_height }), new_label, queue, .{ .variant = .primary })) {
            action.new_chat_agent_id = allocator.dupe(u8, agent.id) catch null;
        }
        cursor_y += button_height + gap;
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ full_width, button_height }), remove_label, queue, .{
            .variant = .secondary,
            .disabled = is_main,
        })) {
            action.remove_agent_id = allocator.dupe(u8, agent.id) catch null;
            clearSelectedAgent(allocator, panel);
        }
        cursor_y += button_height;
    } else {
        const btn_w = (content_width - gap) * 0.5;
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ btn_w, button_height }), new_label, queue, .{ .variant = .primary })) {
            action.new_chat_agent_id = allocator.dupe(u8, agent.id) catch null;
        }
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left + btn_w + gap, cursor_y }, .{ btn_w, button_height }), remove_label, queue, .{
            .variant = .secondary,
            .disabled = is_main,
        })) {
            action.remove_agent_id = allocator.dupe(u8, agent.id) catch null;
            clearSelectedAgent(allocator, panel);
        }
        cursor_y += button_height;
    }

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
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const row_gap = t.spacing.sm;
    const row_height = line_height * 3.0 + t.spacing.xs * 2.0 + t.spacing.sm * 2.0 + button_height;

    var session_indices = std.ArrayList(usize).empty;
    defer session_indices.deinit(allocator);
    if (ctx.sessions.items.len > 0) {
        for (ctx.sessions.items, 0..) |session, index| {
            if (isNotificationSession(session)) continue;
            if (session_keys.parse(session.key)) |parts| {
                if (!std.mem.eql(u8, parts.agent_id, agent.id)) continue;
            } else {
                if (!std.mem.eql(u8, agent.id, "main")) continue;
            }
            session_indices.append(allocator, index) catch {};
        }
    }
    if (session_indices.items.len > 1) {
        std.sort.heap(usize, session_indices.items, ctx.sessions.items, sessionUpdatedDesc);
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

    const height = padding + line_height + t.spacing.xs + list_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Chats");
    const left = rect.min[0] + padding;
    const content_width = width - padding * 2.0;

    if (empty_list) {
        dc.drawText("No chats for this agent.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        return height;
    }

    const now_ms = std.time.milliTimestamp();
    for (session_indices.items) |idx| {
        const session = ctx.sessions.items[idx];
        const row_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_width, row_height });
        drawAgentSessionRow(allocator, dc, row_rect, agent, session, now_ms, queue, action);
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
    now_ms: i64,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) void {
    const t = theme.activeTheme();
    const padding = t.spacing.xs;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(t.colors.surface, 0.6), .stroke = t.colors.border, .thickness = 1.0 });
    const inner_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );
    dc.pushClip(inner_rect);

    var cursor_y = inner_rect.min[1];
    const legacy = session_keys.parse(session.key) == null;
    const base_label = session.display_name orelse session.label orelse session.key;
    var label_buf: [256]u8 = undefined;
    const label = if (legacy)
        (std.fmt.bufPrint(&label_buf, "[legacy] {s}", .{base_label}) catch base_label)
    else
        base_label;
    dc.drawText(label, .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.xs;

    var time_buf: [32]u8 = undefined;
    const time_label = relativeTimeLabel(now_ms, session.updated_at, &time_buf);
    dc.drawText(time_label, .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });
    const is_default = agent.default_session_key != null and std.mem.eql(u8, agent.default_session_key.?, session.key);
    if (is_default) {
        const offset = dc.measureText(time_label, 0.0)[0] + t.spacing.sm;
        dc.drawText("Default", .{ inner_rect.min[0] + offset, cursor_y }, .{ .color = t.colors.text_secondary });
    }
    cursor_y += line_height + t.spacing.xs;

    dc.drawText(session.key, .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });

    const button_count: f32 = if (is_default) 2.0 else 3.0;
    const button_gap = t.spacing.sm;
    const total_gap = button_gap * (button_count - 1.0);
    const button_width = (inner_rect.size()[0] - total_gap) / button_count;
    const button_y = inner_rect.max[1] - button_height;
    var button_x = inner_rect.min[0];

    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_width, button_height }), "Open", queue, .{ .variant = .secondary })) {
        if (setSessionAction(allocator, agent.id, session.key)) |session_action| {
            action.open_session = session_action;
        }
    }
    button_x += button_width + button_gap;
    if (!is_default) {
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_width, button_height }), "Make Default", queue, .{ .variant = .ghost })) {
            if (setSessionAction(allocator, agent.id, session.key)) |session_action| {
                action.set_default = session_action;
            }
        }
        button_x += button_width + button_gap;
    }
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_width, button_height }), "Delete", queue, .{ .variant = .ghost })) {
        action.delete_session = allocator.dupe(u8, session.key) catch action.delete_session;
    }

    dc.popClip();
}

fn drawAddAgentCard(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    queue: *input_state.InputQueue,
    action: *AgentsPanelAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const input_height = widgets.text_input.defaultHeight(line_height);
    const button_height = line_height + t.spacing.xs * 2.0;

    const id_text = editorText(add_id_editor);
    const name_text = editorText(add_name_editor);
    const icon_text = editorText(add_icon_editor);
    const valid_id = session_keys.isAgentIdValid(id_text);
    const exists = id_text.len > 0 and registry.find(id_text) != null;
    const can_add = valid_id and !exists and id_text.len > 0;

    var content_height: f32 = 0.0;
    content_height += labeledInputHeight(input_height, line_height, t) * 3.0;
    content_height += button_height + t.spacing.sm;
    if (!valid_id and id_text.len > 0) {
        content_height += line_height + t.spacing.xs;
    } else if (exists) {
        content_height += line_height + t.spacing.xs;
    }

    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    var cursor_y = drawCardBase(dc, rect, "Add Agent");
    const left = rect.min[0] + padding;
    const content_width = width - padding * 2.0;

    cursor_y += drawLabeledInput(dc, queue, allocator, left, cursor_y, content_width, "Id", ensureEditor(&add_id_editor, allocator), .{});
    cursor_y += drawLabeledInput(dc, queue, allocator, left, cursor_y, content_width, "Name", ensureEditor(&add_name_editor, allocator), .{});
    cursor_y += drawLabeledInput(dc, queue, allocator, left, cursor_y, content_width, "Icon", ensureEditor(&add_icon_editor, allocator), .{});

    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ buttonWidth(dc, "Add", t), button_height }), "Add", queue, .{
        .variant = .primary,
        .disabled = !can_add,
    })) {
        const display = if (name_text.len > 0) name_text else id_text;
        const icon = if (icon_text.len > 0) icon_text else "?";
        const id_copy = allocator.dupe(u8, id_text) catch return height;
        errdefer allocator.free(id_copy);
        const name_copy = allocator.dupe(u8, display) catch {
            allocator.free(id_copy);
            return height;
        };
        errdefer allocator.free(name_copy);
        const icon_copy = allocator.dupe(u8, icon) catch {
            allocator.free(id_copy);
            allocator.free(name_copy);
            return height;
        };
        action.add_agent = .{
            .id = id_copy,
            .display_name = name_copy,
            .icon = icon_copy,
        };
        setSelectedAgent(allocator, panel, id_text);
        ensureEditor(&add_id_editor, allocator).clear();
        ensureEditor(&add_name_editor, allocator).clear();
        ensureEditor(&add_icon_editor, allocator).setText(allocator, "A");
    }
    cursor_y += button_height + t.spacing.sm;

    if (!valid_id and id_text.len > 0) {
        dc.drawText("Use letters, numbers, _ or -.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    } else if (exists) {
        dc.drawText("Agent id already exists.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    }

    return height;
}

fn drawCardBase(dc: *draw_context.DrawContext, rect: draw_context.Rect, title: []const u8) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
    theme.push(.heading);
    dc.drawText(title, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();

    return rect.min[1] + padding + line_height + t.spacing.xs;
}

fn drawLabelValue(
    dc: *draw_context.DrawContext,
    x: f32,
    y: f32,
    label: []const u8,
    value: []const u8,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    dc.drawText(label, .{ x, y }, .{ .color = t.colors.text_secondary });
    dc.drawText(value, .{ x, y + line_height }, .{ .color = t.colors.text_primary });
    return line_height * 2.0 + t.spacing.xs;
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
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    dc.drawText(label, .{ x, y }, .{ .color = t.colors.text_primary });
    const input_height = widgets.text_input.defaultHeight(line_height);
    const input_rect = draw_context.Rect.fromMinSize(.{ x, y + line_height + t.spacing.xs }, .{ width, input_height });
    _ = widgets.text_input.draw(editor, allocator, dc, input_rect, queue, opts);
    return labeledInputHeight(input_height, line_height, t);
}

fn labeledInputHeight(input_height: f32, line_height: f32, t: *const theme.Theme) f32 {
    return line_height + t.spacing.xs + input_height + t.spacing.sm;
}

fn relativeTimeLabel(now_ms: i64, updated_at: ?i64, buf: []u8) []const u8 {
    const ts = updated_at orelse 0;
    if (ts <= 0) return "never";
    const delta_ms = if (now_ms > ts) now_ms - ts else 0;
    const seconds = @as(u64, @intCast(@divTrunc(delta_ms, 1000)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;

    if (seconds < 60) {
        return std.fmt.bufPrint(buf, "{d}s ago", .{seconds}) catch "now";
    }
    if (minutes < 60) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "now";
    }
    if (hours < 24) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "today";
    }
    return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "days ago";
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

fn handleSplitResize(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    left_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    gap: f32,
    min_left: f32,
    max_left: f32,
) void {
    const t = theme.activeTheme();
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
    if (max_scroll <= 0.0) {
        scroll_y.* = 0.0;
        return;
    }
    if (!rect.contains(queue.state.mouse_pos)) return;
    for (queue.events.items) |evt| {
        if (evt == .mouse_wheel) {
            const delta = evt.mouse_wheel.delta[1];
            scroll_y.* -= delta * step;
        }
    }
    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
    if (scroll_y.* > max_scroll) scroll_y.* = max_scroll;
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
    panel.selected_agent_id = allocator.dupe(u8, id) catch panel.selected_agent_id;
}

fn clearSelectedAgent(allocator: std.mem.Allocator, panel: *workspace.ControlPanel) void {
    if (panel.selected_agent_id) |selected| {
        allocator.free(selected);
    }
    panel.selected_agent_id = null;
}

fn sessionUpdatedDesc(sessions: []const types.Session, a: usize, b: usize) bool {
    const updated_a = sessions[a].updated_at orelse 0;
    const updated_b = sessions[b].updated_at orelse 0;
    return updated_a > updated_b;
}

fn isNotificationSession(session: types.Session) bool {
    const kind = session.kind orelse return false;
    return std.ascii.eqlIgnoreCase(kind, "cron") or std.ascii.eqlIgnoreCase(kind, "heartbeat");
}
