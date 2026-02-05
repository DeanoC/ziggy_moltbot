const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const cursor = @import("input/cursor.zig");

var split_width: f32 = 520.0;
var split_dragging = false;
var show_logs = false;
var left_scroll_y: f32 = 0.0;
var left_scroll_max: f32 = 0.0;
var right_scroll_y: f32 = 0.0;
var right_scroll_max: f32 = 0.0;

const Step = struct {
    label: []const u8,
    state: StepState,
};

const StepState = enum {
    pending,
    active,
    complete,
    failed,
};

const BadgeVariant = enum {
    primary,
    success,
    warning,
    neutral,
};

pub fn draw(ctx: *state.ClientContext, rect_override: ?draw_context.Rect) void {
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return;
    var dc = draw_context.DrawContext.init(std.heap.page_allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();

    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&dc, panel_rect, queue);

    const sep_gap = t.spacing.xs;
    const sep_y = panel_rect.min[1] + header.height + sep_gap;
    const sep_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], sep_y },
        .{ panel_rect.size()[0], 1.0 },
    );
    dc.drawRect(sep_rect, .{ .fill = t.colors.divider });

    const content_top = sep_rect.max[1] + sep_gap;
    const remaining = panel_rect.max[1] - content_top;
    if (remaining <= 0.0) return;

    const gap = t.spacing.md;
    const min_left: f32 = 360.0;
    const min_right: f32 = 240.0;
    if (split_width <= 0.0) split_width = 520.0;
    const max_left = @max(min_left, panel_rect.size()[0] - min_right - gap);
    split_width = std.math.clamp(split_width, min_left, max_left);

    const left_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ split_width, remaining },
    );
    const right_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap, content_top },
        .{ panel_rect.max[0] - left_rect.max[0] - gap, remaining },
    );

    drawLeftPanel(ctx, &dc, left_rect, queue);
    handleSplitResize(&dc, panel_rect, left_rect, queue, gap, min_left, max_left);
    if (right_rect.size()[0] > 0.0) {
        drawRightPanel(ctx, &dc, right_rect, queue);
    }
}

fn drawHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) struct { height: f32 } {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Task Progress", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Run Inspector", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    const height = top_pad + title_height + gap + subtitle_height + top_pad;
    _ = queue;
    return .{ .height = height };
}

fn drawLeftPanel(
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) void {
    _ = ctx;
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.md;
    const inner_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );

    handleWheelScroll(queue, rect, &left_scroll_y, left_scroll_max, 36.0);

    dc.pushClip(inner_rect);
    var cursor_y = inner_rect.min[1] - left_scroll_y;

    theme.push(.heading);
    dc.drawText("Task Progress", .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += dc.lineHeight();
    dc.drawRect(draw_context.Rect.fromMinSize(.{ inner_rect.min[0], cursor_y + t.spacing.xs }, .{ inner_rect.size()[0], 1.0 }), .{ .fill = t.colors.divider });
    cursor_y += t.spacing.sm;

    const steps = [_]Step{
        .{ .label = "Collect Sources", .state = .complete },
        .{ .label = "Analyze Data", .state = .complete },
        .{ .label = "Draft Summary", .state = .active },
        .{ .label = "Review Outputs", .state = .pending },
    };
    for (steps, 0..) |step, idx| {
        const row_h = drawStepRow(dc, inner_rect, cursor_y, step, idx + 1, queue);
        cursor_y += row_h + t.spacing.md;
    }

    const button_height = dc.lineHeight() + t.spacing.xs * 2.0;
    const button_width = buttonWidth(dc, "View Logs", t);
    const button_rect = draw_context.Rect.fromMinSize(
        .{ inner_rect.min[0], cursor_y },
        .{ button_width, button_height },
    );
    if (widgets.button.draw(dc, button_rect, "View Logs", queue, .{ .variant = .secondary })) {
        show_logs = !show_logs;
    }
    cursor_y += button_height + t.spacing.md;

    const details_height = drawDetailsCard(dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0]);
    cursor_y += details_height + t.spacing.md;

    if (show_logs) {
        const logs_height = drawLogsCard(dc, .{ inner_rect.min[0], cursor_y }, inner_rect.size()[0]);
        cursor_y += logs_height + t.spacing.md;
    }

    dc.popClip();

    const content_height = (cursor_y + left_scroll_y) - inner_rect.min[1] + padding;
    const view_h = inner_rect.size()[1];
    left_scroll_max = @max(0.0, content_height - view_h);
    if (left_scroll_y > left_scroll_max) left_scroll_y = left_scroll_max;
    if (left_scroll_y < 0.0) left_scroll_y = 0.0;
}

fn drawRightPanel(
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.md;
    const inner_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );

    handleWheelScroll(queue, rect, &right_scroll_y, right_scroll_max, 36.0);

    dc.pushClip(inner_rect);
    var cursor_y = inner_rect.min[1] - right_scroll_y;

    theme.push(.heading);
    dc.drawText("Agent Notifications", .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += dc.lineHeight() + t.spacing.sm;

    var refs_buf: [3][]const u8 = undefined;
    const refs = collectReferenceNames(ctx, &refs_buf);

    if (ctx.nodes.items.len == 0) {
        dc.drawText("No active agents yet.", .{ inner_rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += dc.lineHeight();
    } else {
        for (ctx.nodes.items, 0..) |node, idx| {
            const label = node.display_name orelse node.id;
            const platform = node.platform orelse "unknown";
            const connected = node.connected orelse false;
            const paired = node.paired orelse false;
            const section_height = drawAgentBlock(dc, inner_rect, cursor_y, label, platform, connected, paired, refs);
            cursor_y += section_height;
            if (idx + 1 < ctx.nodes.items.len) {
                cursor_y += t.spacing.sm;
            }
        }
    }

    dc.popClip();

    const content_height = (cursor_y + right_scroll_y) - inner_rect.min[1] + padding;
    const view_h = inner_rect.size()[1];
    right_scroll_max = @max(0.0, content_height - view_h);
    if (right_scroll_y > right_scroll_max) right_scroll_y = right_scroll_max;
    if (right_scroll_y < 0.0) right_scroll_y = 0.0;
}

fn drawStepRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    y: f32,
    step: Step,
    index: usize,
    queue: *input_state.InputQueue,
) f32 {
    _ = queue;
    const t = theme.activeTheme();
    const row_height = dc.lineHeight() + t.spacing.sm;
    const row_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], row_height });

    const circle_size: f32 = row_height - t.spacing.xs;
    const center = .{ row_rect.min[0] + circle_size * 0.5, row_rect.min[1] + circle_size * 0.5 };
    const variant = statusVariant(step.state);
    const color = badgeColor(t, variant);

    dc.drawRoundedRect(
        draw_context.Rect.fromMinSize(
            .{ center[0] - circle_size * 0.5, center[1] - circle_size * 0.5 },
            .{ circle_size, circle_size },
        ),
        circle_size * 0.5,
        .{ .fill = color },
    );

    if (step.state == .complete) {
        drawCheckmark(dc, t, center, circle_size * 0.45);
    } else {
        var idx_buf: [8]u8 = undefined;
        const idx_label = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch "1";
        const idx_size = dc.measureText(idx_label, 0.0);
        dc.drawText(
            idx_label,
            .{ center[0] - idx_size[0] * 0.5, center[1] - idx_size[1] * 0.5 },
            .{ .color = t.colors.background },
        );
    }

    const text_pos = .{ row_rect.min[0] + circle_size + t.spacing.sm, row_rect.min[1] + t.spacing.xs };
    dc.drawText(step.label, text_pos, .{ .color = t.colors.text_primary });

    const badge_label = statusLabel(step.state);
    const badge_size = badgeSize(dc, badge_label, t);
    const badge_rect = draw_context.Rect.fromMinSize(
        .{ row_rect.max[0] - badge_size[0] - t.spacing.sm, row_rect.min[1] + (row_height - badge_size[1]) * 0.5 },
        badge_size,
    );
    drawBadge(dc, badge_rect, badge_label, variant);

    return row_height;
}

fn drawDetailsCard(dc: *draw_context.DrawContext, pos: [2]f32, width: f32) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const title_height = dc.lineHeight();
    const line_height = dc.lineHeight();
    const badge_height = badgeSize(dc, "In Progress", t)[1];
    const body_height = line_height * 3.0 + badge_height + t.spacing.xs * 3.0;
    const card_height = padding * 2.0 + title_height + t.spacing.sm + body_height;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Current Step Details", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height + t.spacing.sm;

    dc.drawText("Step: Draft Summary", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.xs;

    const badge_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        badgeSize(dc, "In Progress", t),
    );
    drawBadge(dc, badge_rect, "In Progress", .primary);
    cursor_y += badge_rect.size()[1] + t.spacing.xs;

    dc.drawText("ETA: 2 minutes", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;
    dc.drawText("Outputs: Summary doc, chart annotations", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });

    return card_height;
}

fn drawLogsCard(dc: *draw_context.DrawContext, pos: [2]f32, width: f32) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const title_height = dc.lineHeight();
    const line_height = dc.lineHeight();
    const body_height = line_height * 4.0 + t.spacing.xs * 3.0;
    const card_height = padding * 2.0 + title_height + t.spacing.sm + body_height;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Live Logs", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height + t.spacing.sm;

    dc.drawText("[info] Fetching competitor data...", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;
    dc.drawText("[info] Aggregating weekly metrics...", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;
    dc.drawText("[warn] Missing segment in region APAC.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;
    dc.drawText("[info] Writing summary section...", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });

    return card_height;
}

fn drawAgentBlock(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    y: f32,
    label: []const u8,
    platform: []const u8,
    connected: bool,
    paired: bool,
    refs: [][]const u8,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const badge_h = badgeSize(dc, "connected", t)[1];

    var cursor_y = y;
    dc.drawText(label, .{ rect.min[0], cursor_y }, .{ .color = t.colors.text_primary });

    var badge_x = rect.max[0] - t.spacing.xs;
    if (paired) {
        const label_size = badgeSize(dc, "paired", t);
        badge_x -= label_size[0];
        drawBadge(dc, draw_context.Rect.fromMinSize(.{ badge_x, cursor_y }, label_size), "paired", .primary);
        badge_x -= t.spacing.xs;
    }
    if (connected) {
        const label_size = badgeSize(dc, "connected", t);
        badge_x -= label_size[0];
        drawBadge(dc, draw_context.Rect.fromMinSize(.{ badge_x, cursor_y }, label_size), "connected", .success);
    }

    cursor_y += line_height + t.spacing.xs;
    dc.drawText(platform, .{ rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    dc.drawText("Referenced files:", .{ rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    if (refs.len == 0) {
        dc.drawText("No references yet.", .{ rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    } else {
        var badge_x2 = rect.min[0];
        const max_x = rect.max[0];
        for (refs, 0..) |ref_name, idx| {
            if (idx >= 3) break;
            const size = badgeSize(dc, ref_name, t);
            if (badge_x2 + size[0] > max_x) break;
            drawBadge(dc, draw_context.Rect.fromMinSize(.{ badge_x2, cursor_y }, size), ref_name, .neutral);
            badge_x2 += size[0] + t.spacing.xs;
        }
        cursor_y += badge_h + t.spacing.xs;
    }

    return cursor_y - y;
}

fn drawCheckmark(dc: *draw_context.DrawContext, t: *const theme.Theme, center: [2]f32, size: f32) void {
    const x = center[0] - size * 0.5;
    const y = center[1] - size * 0.2;
    const color = t.colors.background;
    dc.drawLine(.{ x, y + size * 0.4 }, .{ x + size * 0.35, y + size }, 2.0, color);
    dc.drawLine(.{ x + size * 0.35, y + size }, .{ x + size, y }, 2.0, color);
}

fn drawBadge(dc: *draw_context.DrawContext, rect: draw_context.Rect, label: []const u8, variant: BadgeVariant) void {
    const t = theme.activeTheme();
    const base = badgeColor(t, variant);
    const bg = colors.withAlpha(base, 0.18);
    const border = colors.withAlpha(base, 0.4);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs * 0.5 }, .{ .color = base });
}

fn badgeSize(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) [2]f32 {
    const text_size = dc.measureText(label, 0.0);
    return .{ text_size[0] + t.spacing.xs * 2.0, text_size[1] + t.spacing.xs };
}

fn badgeColor(t: *const theme.Theme, variant: BadgeVariant) colors.Color {
    return switch (variant) {
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .neutral => t.colors.text_secondary,
    };
}

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
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

fn statusVariant(step_state: StepState) BadgeVariant {
    return switch (step_state) {
        .pending => .neutral,
        .active => .primary,
        .complete => .success,
        .failed => .warning,
    };
}

fn statusLabel(step_state: StepState) []const u8 {
    return switch (step_state) {
        .pending => "Pending",
        .active => "In Progress",
        .complete => "Complete",
        .failed => "Failed",
    };
}

fn collectReferenceNames(ctx: *state.ClientContext, buf: [][]const u8) [][]const u8 {
    var len: usize = 0;
    const messages = messagesForCurrentSession(ctx);
    var index: usize = messages.len;
    while (index > 0 and len < buf.len) : (index -= 1) {
        const message: types.ChatMessage = messages[index - 1];
        if (message.attachments) |attachments| {
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                buf[len] = attachment.name orelse attachment.url;
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn messagesForCurrentSession(ctx: *state.ClientContext) []const types.ChatMessage {
    if (ctx.current_session) |session_key| {
        if (ctx.findSessionState(session_key)) |session_state| {
            return session_state.messages.items;
        }
    }
    return &[_]types.ChatMessage{};
}
