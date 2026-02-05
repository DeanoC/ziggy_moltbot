const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");

const AgentStatus = struct {
    label: []const u8,
    variant: BadgeVariant,
};

const BadgeVariant = enum {
    primary,
    success,
    warning,
    neutral,
};

const StatusCounts = struct {
    ready: usize = 0,
    pairing: usize = 0,
    offline: usize = 0,
};

var list_scroll_y: f32 = 0.0;
var list_scroll_max: f32 = 0.0;

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext, rect_override: ?draw_context.Rect) void {
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();
    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&dc, panel_rect, ctx.nodes.items.len);

    const sep_gap = t.spacing.xs;
    const sep_y = panel_rect.min[1] + header.height + sep_gap;
    const sep_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], sep_y },
        .{ panel_rect.size()[0], 1.0 },
    );
    dc.drawRect(sep_rect, .{ .fill = t.colors.divider });

    const content_top = sep_rect.max[1] + sep_gap;
    const content_height = panel_rect.max[1] - content_top;
    if (content_height <= 0.0) return;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], content_height },
    );

    const padding = t.spacing.md;
    var cursor_y = content_rect.min[1] + padding;

    const counts = collectCounts(ctx.nodes.items);
    const card_height = drawOverviewCard(&dc, content_rect, cursor_y, counts);
    cursor_y += card_height + t.spacing.md;

    if (cursor_y >= content_rect.max[1]) return;
    const list_rect = draw_context.Rect.fromMinSize(
        .{ content_rect.min[0] + padding, cursor_y },
        .{ content_rect.size()[0] - padding * 2.0, content_rect.max[1] - cursor_y - padding },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) return;

    drawAgentList(&dc, list_rect, queue, ctx.nodes.items);
}

fn drawHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    total: usize,
) struct { height: f32 } {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Active Agents", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Live status", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    var total_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&total_buf, "{d} agents", .{total}) catch "0 agents";
    const badge_size = badgeSize(dc, label, t);
    const badge_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - t.spacing.md - badge_size[0], rect.min[1] + top_pad },
        badge_size,
    );
    drawBadge(dc, badge_rect, label, .primary);

    const height = top_pad + title_height + gap + subtitle_height + top_pad;
    return .{ .height = height };
}

fn drawOverviewCard(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    y: f32,
    counts: StatusCounts,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.sm;
    theme.push(.heading);
    const title_height = dc.lineHeight();
    theme.pop();
    const badge_h = badgeSize(dc, "Ready (0)", t)[1];
    const height = padding + title_height + t.spacing.xs + badge_h + padding;
    const card_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.md, y },
        .{ rect.size()[0] - t.spacing.md * 2.0, height },
    );
    dc.drawRoundedRect(card_rect, t.radius.md, .{
        .fill = t.colors.surface,
        .stroke = t.colors.border,
        .thickness = 1.0,
    });

    var cursor_y = card_rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Status Overview", .{ card_rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + t.spacing.xs;

    var ready_buf: [32]u8 = undefined;
    var pairing_buf: [32]u8 = undefined;
    var offline_buf: [32]u8 = undefined;
    const ready_label = std.fmt.bufPrint(&ready_buf, "Ready ({d})", .{counts.ready}) catch "Ready";
    const pairing_label = std.fmt.bufPrint(&pairing_buf, "Pairing ({d})", .{counts.pairing}) catch "Pairing";
    const offline_label = std.fmt.bufPrint(&offline_buf, "Offline ({d})", .{counts.offline}) catch "Offline";

    var cursor_x = card_rect.min[0] + padding;
    const ready_size = badgeSize(dc, ready_label, t);
    drawBadge(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, ready_size), ready_label, .success);
    cursor_x += ready_size[0] + t.spacing.sm;

    const pairing_size = badgeSize(dc, pairing_label, t);
    drawBadge(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, pairing_size), pairing_label, .warning);
    cursor_x += pairing_size[0] + t.spacing.sm;

    const offline_size = badgeSize(dc, offline_label, t);
    drawBadge(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, offline_size), offline_label, .neutral);

    return height;
}

fn drawAgentList(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    nodes: []const types.Node,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) return;

    if (nodes.len == 0) {
        dc.drawText("No active agents connected.", .{ list_rect.min[0], list_rect.min[1] }, .{ .color = t.colors.text_secondary });
        return;
    }

    const line_height = dc.lineHeight();
    const row_height = line_height * 2.0 + t.spacing.sm * 2.0;
    const row_gap = t.spacing.xs;
    const total_height = @as(f32, @floatFromInt(nodes.len)) * (row_height + row_gap);
    list_scroll_max = @max(0.0, total_height - list_rect.size()[1]);
    handleWheelScroll(queue, list_rect, &list_scroll_y, list_scroll_max, 28.0);

    dc.pushClip(list_rect);
    var row_y = list_rect.min[1] - list_scroll_y;
    for (nodes) |node| {
        const row_rect = draw_context.Rect.fromMinSize(.{ list_rect.min[0], row_y }, .{ list_rect.size()[0], row_height });
        if (row_rect.max[1] >= list_rect.min[1] and row_rect.min[1] <= list_rect.max[1]) {
            drawAgentRow(dc, row_rect, node, queue);
        }
        row_y += row_height + row_gap;
    }
    dc.popClip();
}

fn drawAgentRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    node: types.Node,
    queue: *input_state.InputQueue,
) void {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);
    if (hovered) {
        dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(t.colors.surface, 0.35) });
    }

    const padding = t.spacing.sm;
    const line_height = dc.lineHeight();
    var cursor_y = rect.min[1] + t.spacing.xs;
    const label = node.display_name orelse node.id;

    theme.push(.heading);
    dc.drawText(label, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const status = statusForNode(node);
    const status_size = badgeSize(dc, status.label, t);
    const status_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - padding - status_size[0], cursor_y },
        status_size,
    );
    drawBadge(dc, status_rect, status.label, status.variant);

    cursor_y += line_height + t.spacing.xs;
    const subtitle = node.device_family orelse node.model_identifier orelse node.platform;
    if (subtitle) |text| {
        dc.drawText(text, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    }

    if (node.platform) |platform| {
        if (subtitle == null or !std.mem.eql(u8, subtitle.?, platform)) {
            const badge_size = badgeSize(dc, platform, t);
            const badge_rect = draw_context.Rect.fromMinSize(
                .{ rect.max[0] - padding - badge_size[0], cursor_y },
                badge_size,
            );
            drawBadge(dc, badge_rect, platform, .neutral);
        }
    }
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

fn statusForNode(node: types.Node) AgentStatus {
    const connected = node.connected orelse false;
    const paired = node.paired orelse false;
    if (connected and paired) {
        return .{ .label = "Ready", .variant = .success };
    }
    if (connected and !paired) {
        return .{ .label = "Pairing", .variant = .warning };
    }
    return .{ .label = "Offline", .variant = .neutral };
}

fn collectCounts(nodes: []const types.Node) StatusCounts {
    var counts = StatusCounts{};
    for (nodes) |node| {
        const status = statusForNode(node);
        switch (status.variant) {
            .success => counts.ready += 1,
            .warning => counts.pairing += 1,
            else => counts.offline += 1,
        }
    }
    return counts;
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
