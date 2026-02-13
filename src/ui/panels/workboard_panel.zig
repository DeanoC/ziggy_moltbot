const std = @import("std");
const state = @import("../../client/state.zig");
const draw_context = @import("../draw_context.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets/widgets.zig");

pub const WorkboardAction = struct {
    refresh: bool = false,
};

const Column = struct {
    label: []const u8,
    statuses: []const []const u8,
};

const columns = [_]Column{
    .{ .label = "Queued", .statuses = &[_][]const u8{ "queued", "pending", "todo" } },
    .{ .label = "Running", .statuses = &[_][]const u8{ "running", "active", "working", "in_progress" } },
    .{ .label = "Done", .statuses = &[_][]const u8{ "done", "completed", "success" } },
};

pub fn draw(
    ctx: *state.ClientContext,
    is_connected: bool,
    rect_override: ?draw_context.Rect,
) WorkboardAction {
    var action: WorkboardAction = .{};
    const panel_rect = rect_override orelse return action;
    const t = theme.activeTheme();
    var dc = draw_context.DrawContext.init(ctx.allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();
    const queue = input_router.getQueue();

    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const top_pad = t.spacing.md;
    const side_pad = t.spacing.md;
    const header_y = panel_rect.min[1] + top_pad;
    dc.drawText("Workboard", .{ panel_rect.min[0] + side_pad, header_y }, .{ .color = t.colors.text_primary });

    const refresh_label = "Refresh";
    const line_h = dc.lineHeight();
    const btn_h = widgets.button.defaultHeight(t, line_h);
    const btn_w = dc.measureText(refresh_label, 0.0)[0] + t.spacing.md * 2.0;
    const btn_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.max[0] - side_pad - btn_w, header_y - t.spacing.xs },
        .{ btn_w, btn_h },
    );
    if (widgets.button.draw(&dc, btn_rect, refresh_label, queue, .{ .variant = .secondary })) {
        action.refresh = true;
    }

    const status_text = if (!is_connected) "Disconnected"
    else if (ctx.pending_workboard_request_id != null) "Updating..."
    else "Live";
    dc.drawText(
        status_text,
        .{ panel_rect.min[0] + side_pad, header_y + line_h + t.spacing.xs },
        .{ .color = t.colors.text_secondary },
    );

    const content_top = header_y + line_h * 2.0 + t.spacing.md;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0] + side_pad, content_top },
        .{ panel_rect.size()[0] - side_pad * 2.0, panel_rect.max[1] - content_top - t.spacing.md },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) return action;

    const timeline_h = @min(180.0, content_rect.size()[1] * 0.34);
    const board_h = @max(1.0, content_rect.size()[1] - timeline_h - t.spacing.sm);
    const board_rect = draw_context.Rect.fromMinSize(content_rect.min, .{ content_rect.size()[0], board_h });
    const timeline_rect = draw_context.Rect.fromMinSize(
        .{ content_rect.min[0], board_rect.max[1] + t.spacing.sm },
        .{ content_rect.size()[0], content_rect.max[1] - board_rect.max[1] - t.spacing.sm },
    );

    const gap = t.spacing.sm;
    const col_count = columns.len;
    const col_w = @max(1.0, (board_rect.size()[0] - gap * @as(f32, @floatFromInt(col_count - 1))) / @as(f32, @floatFromInt(col_count)));

    for (columns, 0..) |col, idx| {
        const x = board_rect.min[0] + @as(f32, @floatFromInt(idx)) * (col_w + gap);
        const col_rect = draw_context.Rect.fromMinSize(.{ x, board_rect.min[1] }, .{ col_w, board_rect.size()[1] });
        drawColumn(&dc, col_rect, col, ctx.workboard_items.items);
    }

    drawTimeline(&dc, timeline_rect, ctx.workboard_items.items);

    return action;
}

fn drawColumn(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    col: Column,
    items: []const @import("../../protocol/types.zig").WorkboardItem,
) void {
    const t = dc.theme;
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const pad = t.spacing.sm;
    const heading_pos = [2]f32{ rect.min[0] + pad, rect.min[1] + pad };
    dc.drawText(col.label, heading_pos, .{ .color = t.colors.text_primary });

    const line_h = dc.lineHeight();
    var y = heading_pos[1] + line_h + t.spacing.xs;
    const row_h = line_h * 2.0 + t.spacing.xs * 3.0;
    const max_rows = @as(usize, @intFromFloat(@max(0.0, (rect.max[1] - y - pad) / (row_h + t.spacing.xs))));

    var drawn: usize = 0;
    const now_ms = std.time.milliTimestamp();
    for (items) |item| {
        if (!itemMatchesColumn(item, col)) continue;
        if (drawn >= max_rows) break;

        const row_rect = draw_context.Rect.fromMinSize(.{ rect.min[0] + pad, y }, .{ rect.size()[0] - pad * 2.0, row_h });
        dc.drawRoundedRect(row_rect, t.radius.sm, .{
            .fill = t.colors.background,
            .stroke = statusColor(item.status, t),
            .thickness = 1.0,
        });

        const dot_size = 6.0;
        const dot_rect = draw_context.Rect.fromMinSize(
            .{ row_rect.min[0] + t.spacing.xs, row_rect.min[1] + t.spacing.xs + (line_h - dot_size) * 0.5 },
            .{ dot_size, dot_size },
        );
        dc.drawRoundedRect(dot_rect, dot_size * 0.5, .{ .fill = statusColor(item.status, t) });

        const title = item.title orelse item.summary orelse item.id;
        dc.drawText(
            title,
            .{ row_rect.min[0] + t.spacing.xs + dot_size + t.spacing.xs, row_rect.min[1] + t.spacing.xs },
            .{ .color = t.colors.text_primary },
        );

        const ts = item.updated_at_ms orelse item.created_at_ms;
        if (ts) |value| {
            var ts_buf: [32]u8 = undefined;
            const label = formatRelativeTime(now_ms, value, &ts_buf);
            dc.drawText(
                label,
                .{ row_rect.min[0] + t.spacing.xs + dot_size + t.spacing.xs, row_rect.min[1] + t.spacing.xs + line_h + t.spacing.xs * 0.5 },
                .{ .color = t.colors.text_secondary },
            );
        }

        y += row_h + t.spacing.xs;
        drawn += 1;
    }

    if (drawn == 0) {
        dc.drawText("No items", .{ rect.min[0] + pad, y }, .{ .color = t.colors.text_secondary });
    }
}

fn itemMatchesColumn(item: @import("../../protocol/types.zig").WorkboardItem, col: Column) bool {
    const status = item.status orelse return false;
    for (col.statuses) |candidate| {
        if (std.ascii.eqlIgnoreCase(status, candidate)) return true;
    }
    return false;
}

fn drawTimeline(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    items: []const @import("../../protocol/types.zig").WorkboardItem,
) void {
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;
    const t = dc.theme;
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const pad = t.spacing.sm;
    dc.drawText("Timeline", .{ rect.min[0] + pad, rect.min[1] + pad }, .{ .color = t.colors.text_primary });
    var y = rect.min[1] + pad + dc.lineHeight() + t.spacing.xs;
    const line_h = dc.lineHeight() + t.spacing.xs;
    const max_rows = @as(usize, @intFromFloat(@max(0.0, (rect.max[1] - y - pad) / line_h)));
    var drawn: usize = 0;
    const now_ms = std.time.milliTimestamp();
    for (items) |item| {
        if (drawn >= max_rows) break;
        const ts = item.updated_at_ms orelse item.created_at_ms orelse continue;
        var ts_buf: [32]u8 = undefined;
        const ts_label = formatRelativeTime(now_ms, ts, &ts_buf);
        const title = item.title orelse item.summary orelse item.id;
        var line_buf: [360]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}  {s}", .{ ts_label, title }) catch title;
        dc.drawText(line, .{ rect.min[0] + pad, y }, .{ .color = statusColor(item.status, t) });
        y += line_h;
        drawn += 1;
    }
    if (drawn == 0) {
        dc.drawText("No recent updates", .{ rect.min[0] + pad, y }, .{ .color = t.colors.text_secondary });
    }
}

fn statusColor(status_opt: ?[]const u8, t: @TypeOf(theme.activeTheme())) [4]f32 {
    const status = status_opt orelse return t.colors.text_secondary;
    if (std.ascii.eqlIgnoreCase(status, "queued") or
        std.ascii.eqlIgnoreCase(status, "pending") or
        std.ascii.eqlIgnoreCase(status, "todo"))
    {
        return t.colors.warning;
    }
    if (std.ascii.eqlIgnoreCase(status, "running") or
        std.ascii.eqlIgnoreCase(status, "active") or
        std.ascii.eqlIgnoreCase(status, "working") or
        std.ascii.eqlIgnoreCase(status, "in_progress"))
    {
        return t.colors.primary;
    }
    if (std.ascii.eqlIgnoreCase(status, "done") or
        std.ascii.eqlIgnoreCase(status, "completed") or
        std.ascii.eqlIgnoreCase(status, "success"))
    {
        return t.colors.success;
    }
    if (std.ascii.eqlIgnoreCase(status, "failed") or
        std.ascii.eqlIgnoreCase(status, "error") or
        std.ascii.eqlIgnoreCase(status, "cancelled"))
    {
        return t.colors.danger;
    }
    return t.colors.text_secondary;
}

fn formatRelativeTime(now_ms: i64, ts_ms: i64, buf: []u8) []const u8 {
    const delta_ms_abs: i64 = if (now_ms >= ts_ms) (now_ms - ts_ms) else (ts_ms - now_ms);
    const minutes: i64 = @divTrunc(delta_ms_abs, 60_000);
    if (minutes < 1) return "just now";
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "recent";
    const hours: i64 = @divTrunc(minutes, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "today";
    const days: i64 = @divTrunc(hours, 24);
    if (days < 30) return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "this month";
    const months: i64 = @divTrunc(days, 30);
    return std.fmt.bufPrint(buf, "{d}mo ago", .{months}) catch "older";
}
