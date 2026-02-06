const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const text_editor = @import("widgets/text_editor.zig");
const cursor = @import("input/cursor.zig");

pub const NodeInvokeAction = struct {
    node_id: []u8,
    command: []u8,
    params_json: ?[]u8 = null,
    timeout_ms: ?u32 = null,

    pub fn deinit(self: *const NodeInvokeAction, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.command);
        if (self.params_json) |params| {
            allocator.free(params);
        }
    }
};

pub const ExecApprovalResolveAction = struct {
    request_id: []u8,
    decision: ExecApprovalDecision,

    pub fn deinit(self: *const ExecApprovalResolveAction, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
    }
};

pub const ExecApprovalDecision = enum {
    allow_once,
    allow_always,
    deny,
};

pub const OperatorAction = struct {
    refresh_nodes: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
};

const Line = struct {
    start: usize,
    end: usize,
};

const perms_box_height: f32 = 100.0;
const describe_box_height: f32 = 120.0;
const params_box_height: f32 = 120.0;
const result_box_height: f32 = 140.0;
const approval_payload_height: f32 = 120.0;

var node_id_editor: ?text_editor.TextEditor = null;
var command_editor: ?text_editor.TextEditor = null;
var params_editor: ?text_editor.TextEditor = null;
var timeout_editor: ?text_editor.TextEditor = null;
var initialized = false;
var sidebar_collapsed = false;
var sidebar_width: f32 = 280.0;
var sidebar_dragging = false;
var sidebar_scroll_y: f32 = 0.0;
var sidebar_scroll_max: f32 = 0.0;
var main_scroll_y: f32 = 0.0;
var main_scroll_max: f32 = 0.0;

const max_text_scrolls = 64;
var text_scroll_ids: [max_text_scrolls]u64 = [_]u64{0} ** max_text_scrolls;
var text_scroll_vals: [max_text_scrolls]f32 = [_]f32{0.0} ** max_text_scrolls;
var text_scroll_len: usize = 0;

pub fn deinit(allocator: std.mem.Allocator) void {
    if (node_id_editor) |*editor| editor.deinit(allocator);
    if (command_editor) |*editor| editor.deinit(allocator);
    if (params_editor) |*editor| editor.deinit(allocator);
    if (timeout_editor) |*editor| editor.deinit(allocator);
    node_id_editor = null;
    command_editor = null;
    params_editor = null;
    timeout_editor = null;
    initialized = false;
}

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    is_connected: bool,
    rect_override: ?draw_context.Rect,
) OperatorAction {
    var action = OperatorAction{};

    if (!initialized) {
        _ = ensureEditor(&node_id_editor, allocator);
        _ = ensureEditor(&command_editor, allocator);
        _ = ensureEditor(&params_editor, allocator);
        ensureEditor(&timeout_editor, allocator).setText(allocator, "30000");
        initialized = true;
    }

    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();

    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&dc, panel_rect);

    const sep_gap = t.spacing.xs;
    const sep_y = panel_rect.min[1] + header.height + sep_gap;
    const sep_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], sep_y },
        .{ panel_rect.size()[0], 1.0 },
    );
    dc.drawRect(sep_rect, .{ .fill = t.colors.divider });

    const content_top = sep_rect.max[1] + sep_gap;
    const content_height = panel_rect.max[1] - content_top;
    if (content_height <= 0.0) return action;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], content_height },
    );

    const gap = t.spacing.md;
    const collapsed_width: f32 = 48.0;
    const min_sidebar_width: f32 = 240.0;
    const min_main_width: f32 = 360.0;
    const max_sidebar_width = @max(min_sidebar_width, content_rect.size()[0] - min_main_width - gap);
    if (sidebar_collapsed) {
        sidebar_width = collapsed_width;
    } else {
        sidebar_width = std.math.clamp(sidebar_width, min_sidebar_width, max_sidebar_width);
    }
    const main_width = @max(0.0, content_rect.size()[0] - sidebar_width - gap);

    const sidebar_rect = draw_context.Rect.fromMinSize(
        content_rect.min,
        .{ sidebar_width, content_rect.size()[1] },
    );
    const main_rect = draw_context.Rect.fromMinSize(
        .{ sidebar_rect.max[0] + gap, content_rect.min[1] },
        .{ main_width, content_rect.size()[1] },
    );

    drawSidebar(allocator, ctx, &dc, sidebar_rect, queue, &action, is_connected);
    handleSidebarResize(&dc, content_rect, sidebar_rect, queue, gap, min_sidebar_width, max_sidebar_width);
    if (main_width > 0.0) {
        drawMainContent(allocator, ctx, &dc, main_rect, queue, &action, is_connected);
    }

    return action;
}

fn drawHeader(dc: *draw_context.DrawContext, rect: draw_context.Rect) struct { height: f32 } {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Operator", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Nodes, approvals, and command execution", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    const height = top_pad + title_height + gap + subtitle_height + top_pad;
    return .{ .height = height };
}

fn drawSidebar(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *OperatorAction,
    is_connected: bool,
) void {
    const t = theme.activeTheme();
    dc.drawRect(rect, .{ .fill = t.colors.surface, .stroke = t.colors.border });

    const padding = t.spacing.sm;
    const line_height = dc.lineHeight();
    const toggle_size = line_height + t.spacing.xs * 2.0;

    const toggle_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - padding - toggle_size, rect.min[1] + padding },
        .{ toggle_size, toggle_size },
    );
    const toggle_label = if (sidebar_collapsed) ">" else "<";
    if (widgets.button.draw(dc, toggle_rect, toggle_label, queue, .{ .variant = .ghost })) {
        sidebar_collapsed = !sidebar_collapsed;
    }

    if (sidebar_collapsed) {
        const label = if (rect.size()[0] > 60.0) "Operator" else "Ops";
        dc.drawText(label, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_secondary });
        return;
    }

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Nodes", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.xs;

    const button_height = line_height + t.spacing.xs * 2.0;
    const refresh_w = buttonWidth(dc, "Refresh", t);
    const describe_w = buttonWidth(dc, "Describe Selected", t);

    const refresh_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ refresh_w, button_height },
    );
    if (widgets.button.draw(dc, refresh_rect, "Refresh", queue, .{ .variant = .secondary, .disabled = !is_connected or ctx.nodes_loading })) {
        action.refresh_nodes = true;
    }

    const describe_rect = draw_context.Rect.fromMinSize(
        .{ refresh_rect.max[0] + t.spacing.sm, cursor_y },
        .{ describe_w, button_height },
    );
    if (widgets.button.draw(dc, describe_rect, "Describe Selected", queue, .{ .variant = .secondary, .disabled = !is_connected or ctx.current_node == null })) {
        if (ctx.current_node) |node_id| {
            action.describe_node = allocator.dupe(u8, node_id) catch null;
        }
    }
    cursor_y += button_height + t.spacing.sm;

    if (!is_connected) {
        dc.drawText("Connect to load nodes.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.sm;
    } else if (ctx.nodes_loading) {
        dc.drawText("Loading nodes...", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.sm;
    }

    const scroll_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - padding - cursor_y },
    );
    if (scroll_rect.size()[0] <= 0.0 or scroll_rect.size()[1] <= 0.0) return;

    handleWheelScroll(queue, scroll_rect, &sidebar_scroll_y, sidebar_scroll_max, 28.0);

    dc.pushClip(scroll_rect);
    const start_y = scroll_rect.min[1] - sidebar_scroll_y;
    var y = start_y;

    y += drawSidebarSectionTitle(dc, scroll_rect, y, "Node List");
    y += t.spacing.xs;
    y += drawNodesList(allocator, ctx, dc, scroll_rect, y, queue, action);

    y += t.spacing.md;
    y += drawSidebarSectionTitle(dc, scroll_rect, y, "Execution Approvals");
    y += t.spacing.xs;
    y += drawApprovalsList(allocator, ctx, dc, scroll_rect, y, queue, action, is_connected);

    const content_height = y - start_y;
    sidebar_scroll_max = @max(0.0, content_height - scroll_rect.size()[1]);
    if (sidebar_scroll_y > sidebar_scroll_max) sidebar_scroll_y = sidebar_scroll_max;

    dc.popClip();
}

fn drawSidebarSectionTitle(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    y: f32,
    label: []const u8,
) f32 {
    const t = theme.activeTheme();
    dc.drawText(label, .{ rect.min[0], y }, .{ .color = t.colors.text_secondary });
    return dc.lineHeight();
}

fn drawNodesList(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    start_y: f32,
    queue: *input_state.InputQueue,
    action: *OperatorAction,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const row_height = line_height + t.spacing.xs * 2.0;
    const row_gap = t.spacing.xs;
    var y = start_y;

    if (ctx.nodes.items.len == 0) {
        dc.drawText("No nodes available.", .{ rect.min[0], y }, .{ .color = t.colors.text_secondary });
        return line_height;
    }

    for (ctx.nodes.items) |node| {
        const row_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], row_height });
        if (row_rect.max[1] >= rect.min[1] and row_rect.min[1] <= rect.max[1]) {
            const selected = ctx.current_node != null and std.mem.eql(u8, ctx.current_node.?, node.id);
            const connected_label = statusLabel(node.connected);
            const paired_label = statusLabel(node.paired);
            const name = node.display_name orelse node.id;
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(
                &label_buf,
                "{s} ({s}, {s})",
                .{ name, connected_label, paired_label },
            ) catch name;
            if (drawSelectableRow(dc, row_rect, label, selected, queue)) {
                action.select_node = allocator.dupe(u8, node.id) catch null;
            }
        }
        y += row_height + row_gap;
    }

    return y - start_y;
}

fn drawApprovalsList(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    start_y: f32,
    queue: *input_state.InputQueue,
    action: *OperatorAction,
    is_connected: bool,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    var y = start_y;

    if (!is_connected) {
        dc.drawText("Connect to receive approvals.", .{ rect.min[0], y }, .{ .color = t.colors.text_secondary });
        return line_height;
    }

    if (ctx.approvals.items.len == 0) {
        dc.drawText("No pending approvals.", .{ rect.min[0], y }, .{ .color = t.colors.text_secondary });
        return line_height;
    }

    const card_gap = t.spacing.sm;
    for (ctx.approvals.items) |approval| {
        const card_height = approvalCardHeight(allocator, dc, rect.size()[0], approval.summary, approval.can_resolve);
        const card_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], card_height });
        if (card_rect.max[1] >= rect.min[1] and card_rect.min[1] <= rect.max[1]) {
            const decision = drawApprovalCard(allocator, dc, card_rect, queue, approval);
            if (decision != .none) {
                const id_copy = allocator.dupe(u8, approval.id) catch null;
                if (id_copy) |value| {
                    action.resolve_approval = ExecApprovalResolveAction{
                        .request_id = value,
                        .decision = switch (decision) {
                            .allow_once => .allow_once,
                            .allow_always => .allow_always,
                            .deny => .deny,
                            .none => unreachable,
                        },
                    };
                }
            }
        }
        y += card_height + card_gap;
    }

    return y - start_y;
}

fn handleSidebarResize(
    dc: *draw_context.DrawContext,
    content_rect: draw_context.Rect,
    sidebar_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    gap: f32,
    min_sidebar_width: f32,
    max_sidebar_width: f32,
) void {
    if (sidebar_collapsed) return;
    const t = theme.activeTheme();
    const divider_w: f32 = 6.0;
    const divider_rect = draw_context.Rect.fromMinSize(
        .{ sidebar_rect.max[0] + gap * 0.5 - divider_w * 0.5, content_rect.min[1] },
        .{ divider_w, content_rect.size()[1] },
    );

    const hover = divider_rect.contains(queue.state.mouse_pos);
    if (hover) {
        cursor.set(.resize_ew);
    }

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and divider_rect.contains(md.pos)) {
                    sidebar_dragging = true;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    sidebar_dragging = false;
                }
            },
            else => {},
        }
    }

    if (sidebar_dragging) {
        const target = queue.state.mouse_pos[0] - content_rect.min[0];
        sidebar_width = std.math.clamp(target, min_sidebar_width, max_sidebar_width);
    }

    const divider = draw_context.Rect.fromMinSize(
        .{ sidebar_rect.max[0] + gap * 0.5 - 1.0, content_rect.min[1] },
        .{ 2.0, content_rect.size()[1] },
    );
    const alpha: f32 = if (hover or sidebar_dragging) 0.25 else 0.12;
    const line_color = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], alpha };
    dc.drawRect(divider, .{ .fill = line_color });
}

fn drawMainContent(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *OperatorAction,
    is_connected: bool,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    handleWheelScroll(queue, rect, &main_scroll_y, main_scroll_max, 40.0);

    const padding = t.spacing.md;
    const content_width = rect.size()[0] - padding * 2.0;

    dc.pushClip(rect);
    var cursor_y = rect.min[1] + padding - main_scroll_y;
    const start_y = cursor_y;

    cursor_y += drawSelectedNodeCard(allocator, ctx, dc, .{ rect.min[0] + padding, cursor_y }, content_width, queue, action);
    cursor_y += t.spacing.md;

    cursor_y += drawHealthTelemetryCard(allocator, ctx, dc, .{ rect.min[0] + padding, cursor_y }, content_width, queue);
    cursor_y += t.spacing.md;

    cursor_y += drawInvokeCard(allocator, ctx, dc, .{ rect.min[0] + padding, cursor_y }, content_width, queue, action, is_connected);

    if (ctx.operator_notice) |notice| {
        cursor_y += t.spacing.md;
        cursor_y += drawNoticeCard(allocator, dc, .{ rect.min[0] + padding, cursor_y }, content_width, queue, notice, action);
    }

    if (ctx.node_result) |result| {
        cursor_y += t.spacing.md;
        cursor_y += drawResultCard(allocator, dc, .{ rect.min[0] + padding, cursor_y }, content_width, queue, result, action);
    }

    const content_height = cursor_y - start_y;
    main_scroll_max = @max(0.0, content_height - rect.size()[1] + padding);
    if (main_scroll_y > main_scroll_max) main_scroll_y = main_scroll_max;

    dc.popClip();
}

fn drawSelectedNodeCard(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    queue: *input_state.InputQueue,
    action: *OperatorAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;

    const height = selectedNodeHeight(dc, ctx, width);
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Selected Node", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.sm;

    if (ctx.current_node == null) {
        dc.drawText("No node selected.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        return height;
    }

    const node_id = ctx.current_node.?;
    const node = findNode(ctx.nodes.items, node_id) orelse {
        dc.drawText("Selected node not found.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        return height;
    };

    const label = node.display_name orelse node.id;
    theme.push(.title);
    dc.drawText(label, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.xs;

    if (node.display_name != null) {
        dc.drawText(node.id, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    const status_label = statusLabel(node.connected);
    const paired_label = statusLabel(node.paired);
    var status_buf: [128]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_buf, "Status: {s} / paired: {s}", .{ status_label, paired_label }) catch "Status unavailable";
    dc.drawText(status_line, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    if (node.version) |version| {
        drawKeyValue(dc, rect.min[0] + padding, cursor_y, "Version", version);
        cursor_y += line_height + t.spacing.xs;
    }
    if (node.core_version) |core| {
        drawKeyValue(dc, rect.min[0] + padding, cursor_y, "Core Version", core);
        cursor_y += line_height + t.spacing.xs;
    }
    if (node.ui_version) |ui| {
        drawKeyValue(dc, rect.min[0] + padding, cursor_y, "UI Version", ui);
        cursor_y += line_height + t.spacing.xs;
    }
    if (node.connected_at_ms) |ts| {
        var time_buf: [32]u8 = undefined;
        const label_line = std.fmt.bufPrint(&time_buf, "{d}", .{ts}) catch "unknown";
        drawKeyValue(dc, rect.min[0] + padding, cursor_y, "Connected At (ms)", label_line);
        cursor_y += line_height + t.spacing.xs;
    }

    if (node.permissions_json) |perm| {
        dc.drawText("Permissions", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
        cursor_y += line_height + t.spacing.xs;
        const box_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ width - padding * 2.0, perms_box_height },
        );
        drawTextBox(allocator, dc, box_rect, queue, scrollKey(node.id, 0xA11CE), perm);
        cursor_y = box_rect.max[1] + t.spacing.sm;
    }

    dc.drawText("Capabilities", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.xs;
    if (node.caps) |caps| {
        if (caps.len == 0) {
            dc.drawText("none", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
            cursor_y += line_height + t.spacing.xs;
        } else {
            for (caps) |cap| {
                drawBullet(dc, .{ rect.min[0] + padding, cursor_y }, cap);
                cursor_y += line_height + t.spacing.xs;
            }
        }
    } else {
        dc.drawText("none", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    dc.drawText("Commands", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.xs;
    if (node.commands) |commands| {
        if (commands.len == 0) {
            dc.drawText("none", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
            cursor_y += line_height + t.spacing.xs;
        } else {
            for (commands) |command| {
                drawBullet(dc, .{ rect.min[0] + padding, cursor_y }, command);
                cursor_y += line_height + t.spacing.xs;
            }
        }
    } else {
        dc.drawText("none", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    dc.drawText("Describe Response", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.xs;
    if (findNodeDescribe(ctx.node_describes.items, node.id)) |describe| {
        const box_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ width - padding * 2.0, describe_box_height },
        );
        drawTextBox(allocator, dc, box_rect, queue, scrollKey(node.id, 0xBEEF), describe.payload_json);
        cursor_y = box_rect.max[1] + t.spacing.xs;
        const clear_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ buttonWidth(dc, "Clear Describe", t), button_height },
        );
        if (widgets.button.draw(dc, clear_rect, "Clear Describe", queue, .{ .variant = .secondary })) {
            action.clear_node_describe = allocator.dupe(u8, node.id) catch null;
        }
    } else {
        dc.drawText("No describe response yet.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    }

    return height;
}

fn drawHealthTelemetryCard(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    queue: *input_state.InputQueue,
) f32 {
    _ = allocator;
    _ = queue;

    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();

    const height: f32 = 132.0;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Node Health Telemetry", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.sm;

    if (ctx.current_node == null) {
        dc.drawText("Select a node to view health metrics.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
        dc.drawText("(Coming soon) Gateway → periodic health frames.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        return height;
    }

    dc.drawText("Health frames are not wired up yet.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;
    dc.drawText("For now: use the Describe button to inspect node-reported data.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });

    return height;
}

fn drawInvokeCard(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    queue: *input_state.InputQueue,
    action: *OperatorAction,
    is_connected: bool,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;

    const height = invokeCardHeight(dc.lineHeight());
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Invoke Node Command", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.sm;

    cursor_y += drawLabeledInput(dc, queue, allocator, rect.min[0] + padding, cursor_y, width - padding * 2.0, "Node ID", ensureEditor(&node_id_editor, allocator), .{ .placeholder = "node-id" });

    var cursor_x = rect.min[0] + padding;
    const use_w = buttonWidth(dc, "Use Selected", t);
    const use_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ use_w, button_height });
    if (widgets.button.draw(dc, use_rect, "Use Selected", queue, .{ .variant = .secondary, .disabled = ctx.current_node == null })) {
        if (ctx.current_node) |node_id| {
            ensureEditor(&node_id_editor, allocator).setText(allocator, node_id);
        }
    }
    cursor_x += use_w + t.spacing.sm;
    const describe_w = buttonWidth(dc, "Describe", t);
    const describe_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ describe_w, button_height });
    if (widgets.button.draw(dc, describe_rect, "Describe", queue, .{ .variant = .secondary, .disabled = !is_connected })) {
        const node_text = editorText(node_id_editor);
        if (node_text.len > 0) {
            action.describe_node = allocator.dupe(u8, node_text) catch null;
        }
    }
    cursor_y += button_height + t.spacing.sm;

    cursor_y += drawLabeledInput(dc, queue, allocator, rect.min[0] + padding, cursor_y, width - padding * 2.0, "Command", ensureEditor(&command_editor, allocator), .{ .placeholder = "command" });
    cursor_y += drawLabeledInput(dc, queue, allocator, rect.min[0] + padding, cursor_y, width - padding * 2.0, "Timeout (ms)", ensureEditor(&timeout_editor, allocator), .{ .placeholder = "30000" });

    dc.drawText("Params (JSON)", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.xs;
    const params_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ width - padding * 2.0, params_box_height },
    );
    _ = ensureEditor(&params_editor, allocator).draw(
        allocator,
        dc,
        params_rect,
        queue,
        .{ .submit_on_enter = false, .read_only = false },
    );
    cursor_y = params_rect.max[1] + t.spacing.sm;

    const invoke_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ buttonWidth(dc, "Invoke", t), button_height },
    );
    if (widgets.button.draw(dc, invoke_rect, "Invoke", queue, .{ .variant = .primary, .disabled = !is_connected })) {
        const node_text = editorText(node_id_editor);
        const command_text = editorText(command_editor);
        const params_text = editorText(params_editor);
        var node_copy = allocator.dupe(u8, node_text) catch null;
        if (node_copy) |node_id| {
            const command_copy = allocator.dupe(u8, command_text) catch {
                allocator.free(node_id);
                node_copy = null;
                return height;
            };
            var params_copy: ?[]u8 = null;
            if (params_text.len > 0) {
                params_copy = allocator.dupe(u8, params_text) catch {
                    allocator.free(command_copy);
                    allocator.free(node_id);
                    return height;
                };
            }
            action.invoke_node = NodeInvokeAction{
                .node_id = node_id,
                .command = command_copy,
                .params_json = params_copy,
                .timeout_ms = parseTimeout(editorText(timeout_editor)),
            };
        }
    }

    return height;
}

fn drawNoticeCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    queue: *input_state.InputQueue,
    notice: []const u8,
    action: *OperatorAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const body_height = measureWrappedTextHeight(allocator, dc, notice, width - padding * 2.0);
    const height = padding + line_height + t.spacing.sm + body_height + t.spacing.sm + button_height + padding;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Notice", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.warning });
    theme.pop();
    cursor_y += line_height + t.spacing.sm;

    _ = drawWrappedText(allocator, dc, notice, .{ rect.min[0] + padding, cursor_y }, width - padding * 2.0, t.colors.text_secondary);
    cursor_y += body_height + t.spacing.sm;

    const clear_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ buttonWidth(dc, "Clear Notice", t), button_height },
    );
    if (widgets.button.draw(dc, clear_rect, "Clear Notice", queue, .{ .variant = .ghost })) {
        action.clear_operator_notice = true;
    }

    return height;
}

fn drawResultCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    queue: *input_state.InputQueue,
    result: []const u8,
    action: *OperatorAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const height = padding + line_height + t.spacing.sm + result_box_height + t.spacing.sm + button_height + padding;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Last Operator Response", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.sm;

    const box_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ width - padding * 2.0, result_box_height },
    );
    drawTextBox(allocator, dc, box_rect, queue, 0xDEADBEEF, result);
    cursor_y = box_rect.max[1] + t.spacing.sm;

    const clear_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ buttonWidth(dc, "Clear Response", t), button_height },
    );
    if (widgets.button.draw(dc, clear_rect, "Clear Response", queue, .{ .variant = .secondary })) {
        action.clear_node_result = true;
    }

    return height;
}

fn drawSelectableRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
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

    const text_pos = .{ rect.min[0] + t.spacing.sm, rect.min[1] + t.spacing.xs };
    dc.drawText(label, text_pos, .{ .color = t.colors.text_primary });

    return clicked;
}

const ApprovalDecision = enum {
    none,
    allow_once,
    allow_always,
    deny,
};

fn approvalCardHeight(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    width: f32,
    summary: ?[]const u8,
    can_resolve: bool,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.sm;
    const line_height = dc.lineHeight();
    var height: f32 = padding + line_height + t.spacing.xs;
    if (summary) |text| {
        height += measureWrappedTextHeight(allocator, dc, text, width - padding * 2.0);
        height += t.spacing.xs;
    }
    height += line_height + t.spacing.xs;
    height += 1.0 + t.spacing.xs;
    height += approval_payload_height + t.spacing.sm;
    if (can_resolve) {
        const button_height = line_height + t.spacing.xs * 2.0;
        height += button_height * 3.0 + t.spacing.xs * 2.0;
    } else {
        height += line_height;
    }
    height += padding;
    return height;
}

fn drawApprovalCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    approval: types.ExecApproval,
) ApprovalDecision {
    const t = theme.activeTheme();
    const padding = t.spacing.sm;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const max_width = rect.size()[0] - padding * 2.0;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Approval Needed", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.xs;

    if (approval.summary) |summary| {
        _ = drawWrappedText(allocator, dc, summary, .{ rect.min[0] + padding, cursor_y }, max_width, t.colors.text_primary);
        cursor_y += measureWrappedTextHeight(allocator, dc, summary, max_width) + t.spacing.xs;
    }

    if (approval.requested_at_ms) |ts| {
        var time_buf: [32]u8 = undefined;
        const label = formatRelativeTime(std.time.milliTimestamp(), ts, &time_buf);
        dc.drawText(label, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    dc.drawRect(
        draw_context.Rect.fromMinSize(.{ rect.min[0] + padding, cursor_y }, .{ max_width, 1.0 }),
        .{ .fill = t.colors.divider },
    );
    cursor_y += t.spacing.xs;

    const payload_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ max_width, approval_payload_height },
    );
    drawTextBox(allocator, dc, payload_rect, queue, scrollKey(approval.id, 0xA11CE), approval.payload_json);
    cursor_y = payload_rect.max[1] + t.spacing.sm;

    var decision: ApprovalDecision = .none;
    if (approval.can_resolve) {
        const approve_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ max_width, button_height },
        );
        if (widgets.button.draw(dc, approve_rect, "Approve", queue, .{ .variant = .primary })) {
            decision = .allow_once;
        }
        cursor_y += button_height + t.spacing.xs;

        const decline_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ max_width, button_height },
        );
        if (widgets.button.draw(dc, decline_rect, "Decline", queue, .{ .variant = .secondary })) {
            decision = .deny;
        }
        cursor_y += button_height + t.spacing.xs;

        const allow_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ max_width, button_height },
        );
        if (widgets.button.draw(dc, allow_rect, "Allow Always", queue, .{ .variant = .secondary })) {
            decision = .allow_always;
        }
    } else {
        dc.drawText("Missing approval id in payload.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    }

    return decision;
}

fn selectedNodeHeight(dc: *draw_context.DrawContext, ctx: *state.ClientContext, width: f32) f32 {
    _ = width;
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    var height = padding + line_height + t.spacing.sm;

    if (ctx.current_node == null) {
        height += line_height + padding;
        return height;
    }

    const node_id = ctx.current_node.?;
    const node = findNode(ctx.nodes.items, node_id) orelse {
        height += line_height + padding;
        return height;
    };

    height += line_height + t.spacing.xs;
    if (node.display_name != null) {
        height += line_height + t.spacing.xs;
    }
    height += line_height + t.spacing.xs;
    if (node.version != null) height += line_height + t.spacing.xs;
    if (node.core_version != null) height += line_height + t.spacing.xs;
    if (node.ui_version != null) height += line_height + t.spacing.xs;
    if (node.connected_at_ms != null) height += line_height + t.spacing.xs;

    if (node.permissions_json != null) {
        height += line_height + t.spacing.xs;
        height += perms_box_height + t.spacing.sm;
    }

    height += line_height + t.spacing.xs;
    const caps_len = if (node.caps) |caps| if (caps.len == 0) 1 else caps.len else 1;
    height += @as(f32, @floatFromInt(caps_len)) * (line_height + t.spacing.xs);

    height += line_height + t.spacing.xs;
    const cmd_len = if (node.commands) |commands| if (commands.len == 0) 1 else commands.len else 1;
    height += @as(f32, @floatFromInt(cmd_len)) * (line_height + t.spacing.xs);

    height += line_height + t.spacing.xs;
    if (findNodeDescribe(ctx.node_describes.items, node.id) != null) {
        height += describe_box_height + t.spacing.xs + button_height + t.spacing.xs;
    } else {
        height += line_height + t.spacing.xs;
    }

    height += padding;
    return height;
}

fn invokeCardHeight(line_height: f32) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const input_height = widgets.text_input.defaultHeight(line_height);
    const button_height = line_height + t.spacing.xs * 2.0;

    var height = padding + line_height + t.spacing.sm;
    height += labeledInputHeight(input_height, line_height, t);
    height += button_height + t.spacing.sm;
    height += labeledInputHeight(input_height, line_height, t);
    height += labeledInputHeight(input_height, line_height, t);
    height += line_height + t.spacing.xs + params_box_height + t.spacing.sm;
    height += button_height + padding;
    return height;
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

fn drawTextBox(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    key: u64,
    text: []const u8,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, rect.size()[0] - t.spacing.sm * 2.0, &lines);

    const line_height = dc.lineHeight();
    const content_height = @as(f32, @floatFromInt(lines.items.len)) * line_height;
    const scroll_ptr = scrollFor(key);
    const max_scroll = @max(0.0, content_height - rect.size()[1]);

    handleWheelScroll(queue, rect, scroll_ptr, max_scroll, 24.0);

    dc.pushClip(rect);
    var start_index: usize = 0;
    if (line_height > 0.0) {
        start_index = @intFromFloat(@floor(scroll_ptr.* / line_height));
    }
    var y = rect.min[1] + t.spacing.xs - scroll_ptr.* + @as(f32, @floatFromInt(start_index)) * line_height;
    for (lines.items[start_index..], start_index..) |line, idx| {
        const slice = text[line.start..line.end];
        if (slice.len > 0) {
            dc.drawText(slice, .{ rect.min[0] + t.spacing.sm, y }, .{ .color = t.colors.text_secondary });
        }
        y += line_height;
        if (y > rect.max[1]) break;
        _ = idx;
    }
    dc.popClip();

    if (scroll_ptr.* > max_scroll) scroll_ptr.* = max_scroll;
    if (scroll_ptr.* < 0.0) scroll_ptr.* = 0.0;
}

fn scrollFor(key: u64) *f32 {
    var idx: usize = 0;
    while (idx < text_scroll_len) : (idx += 1) {
        if (text_scroll_ids[idx] == key) {
            return &text_scroll_vals[idx];
        }
    }
    if (text_scroll_len < max_text_scrolls) {
        text_scroll_ids[text_scroll_len] = key;
        text_scroll_vals[text_scroll_len] = 0.0;
        text_scroll_len += 1;
        return &text_scroll_vals[text_scroll_len - 1];
    }
    return &text_scroll_vals[0];
}

fn scrollKey(id: []const u8, salt: u64) u64 {
    const base = std.hash.Wyhash.hash(0, id);
    return base ^ salt;
}

fn drawBullet(dc: *draw_context.DrawContext, pos: [2]f32, text: []const u8) void {
    const t = theme.activeTheme();
    const radius: f32 = 3.0;
    const bullet_center = .{ pos[0] + radius, pos[1] + radius + 3.0 };
    dc.drawRoundedRect(
        draw_context.Rect.fromMinSize(.{ bullet_center[0] - radius, bullet_center[1] - radius }, .{ radius * 2.0, radius * 2.0 }),
        radius,
        .{ .fill = t.colors.text_secondary },
    );
    dc.drawText(text, .{ pos[0] + radius * 2.0 + t.spacing.xs, pos[1] }, .{ .color = t.colors.text_secondary });
}

fn drawKeyValue(dc: *draw_context.DrawContext, x: f32, y: f32, label: []const u8, value: []const u8) void {
    const t = theme.activeTheme();
    dc.drawText(label, .{ x, y }, .{ .color = t.colors.text_secondary });
    const label_w = dc.measureText(label, 0.0)[0];
    dc.drawText(value, .{ x + label_w + t.spacing.xs, y }, .{ .color = t.colors.text_primary });
}

fn drawWrappedText(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    pos: [2]f32,
    wrap_width: f32,
    color: colors.Color,
) f32 {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, wrap_width, &lines);

    var y = pos[1];
    const line_height = dc.lineHeight();
    for (lines.items) |line| {
        const slice = text[line.start..line.end];
        if (slice.len > 0) {
            dc.drawText(slice, .{ pos[0], y }, .{ .color = color });
        }
        y += line_height;
    }
    return y - pos[1];
}

fn measureWrappedTextHeight(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
) f32 {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, wrap_width, &lines);
    return @as(f32, @floatFromInt(lines.items.len)) * dc.lineHeight();
}

fn buildLinesInto(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
    lines: *std.ArrayList(Line),
) void {
    lines.clearRetainingCapacity();
    const effective_wrap = if (wrap_width <= 1.0) 10_000.0 else wrap_width;
    var line_start: usize = 0;
    var line_width: f32 = 0.0;
    var last_space: ?usize = null;
    var index: usize = 0;

    while (index < text.len) {
        const ch = text[index];
        if (ch == '\n') {
            _ = lines.append(allocator, .{ .start = line_start, .end = index }) catch {};
            index += 1;
            line_start = index;
            line_width = 0.0;
            last_space = null;
            continue;
        }

        const next = nextCharIndex(text, index);
        const slice = text[index..next];
        const char_w = dc.measureText(slice, 0.0)[0];

        if (ch == ' ' or ch == '\t') {
            last_space = next;
        }

        if (line_width + char_w > effective_wrap and line_width > 0.0) {
            if (last_space != null and last_space.? > line_start) {
                _ = lines.append(allocator, .{ .start = line_start, .end = last_space.? - 1 }) catch {};
                index = last_space.?;
            } else {
                _ = lines.append(allocator, .{ .start = line_start, .end = index }) catch {};
            }
            line_start = index;
            line_width = 0.0;
            last_space = null;
            continue;
        }

        line_width += char_w;
        index = next;
    }

    _ = lines.append(allocator, .{ .start = line_start, .end = text.len }) catch {};
}

fn nextCharIndex(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const first = text[index];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const next = index + @as(usize, len);
    return if (next > text.len) text.len else next;
}

fn formatRelativeTime(now_ms: i64, ts_ms: i64, buf: []u8) []const u8 {
    const delta_ms = if (now_ms > ts_ms) now_ms - ts_ms else 0;
    const seconds = @as(u64, @intCast(@divTrunc(delta_ms, 1000)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;
    if (seconds < 60) {
        return std.fmt.bufPrint(buf, "{d}s ago", .{seconds}) catch "just now";
    }
    if (minutes < 60) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "today";
    }
    if (hours < 24) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "today";
    }
    return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "days ago";
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

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn statusLabel(value: ?bool) []const u8 {
    if (value) |flag| return if (flag) "online" else "offline";
    return "unknown";
}

fn findNode(nodes: []const types.Node, node_id: []const u8) ?types.Node {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.id, node_id)) return node;
    }
    return null;
}

fn findNodeDescribe(describes: []const state.NodeDescribe, node_id: []const u8) ?state.NodeDescribe {
    for (describes) |describe| {
        if (std.mem.eql(u8, describe.node_id, node_id)) return describe;
    }
    return null;
}

fn parseTimeout(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
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
