const std = @import("std");
const state = @import("../client/state.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");

const BadgeVariant = enum {
    neutral,
    primary,
    success,
    warning,
    danger,
};


pub fn drawCustom(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    client_state: state.ClientState,
    is_connected: bool,
    agent_name: ?[]const u8,
    session_name: ?[]const u8,
    message_count: usize,
    last_error: ?[]const u8,
) void {
    const t = theme.activeTheme();
    const spacing = t.spacing.sm;
    const label = t.colors.text_secondary;
    const value = t.colors.text_primary;
    const status_variant: BadgeVariant = switch (client_state) {
        .connected => .success,
        .connecting, .authenticating => .warning,
        .error_state => .danger,
        .disconnected => if (is_connected) .success else .neutral,
    };
    const connection_variant: BadgeVariant = if (is_connected) .success else .neutral;

    dc.drawRect(rect, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const line_height = dc.lineHeight();
    var cursor_x = rect.min[0] + t.spacing.sm;
    const text_y = rect.min[1] + (rect.size()[1] - line_height) * 0.5;

    cursor_x += drawLabel(dc, "Status:", cursor_x, text_y, label) + spacing;
    cursor_x += drawBadgeCustom(dc, @tagName(client_state), status_variant, true, cursor_x, rect) + spacing;
    cursor_x += drawLabel(dc, "Connection:", cursor_x, text_y, label) + spacing;
    cursor_x += drawBadgeCustom(dc, if (is_connected) "online" else "offline", connection_variant, true, cursor_x, rect) + spacing;
    cursor_x += drawLabel(dc, "Agent:", cursor_x, text_y, label) + spacing;
    if (agent_name) |name| {
        cursor_x += drawLabel(dc, name, cursor_x, text_y, value) + spacing;
    } else {
        cursor_x += drawLabel(dc, "(none)", cursor_x, text_y, label) + spacing;
    }
    cursor_x += drawLabel(dc, "Session:", cursor_x, text_y, label) + spacing;
    if (session_name) |name| {
        cursor_x += drawLabel(dc, name, cursor_x, text_y, value) + spacing;
    } else {
        cursor_x += drawLabel(dc, "(none)", cursor_x, text_y, label) + spacing;
    }
    cursor_x += drawLabel(dc, "Messages:", cursor_x, text_y, label) + spacing;
    var msg_buf: [32]u8 = undefined;
    const msg_text = std.fmt.bufPrint(&msg_buf, "{d}", .{message_count}) catch "0";
    cursor_x += drawLabel(dc, msg_text, cursor_x, text_y, value) + spacing;

    if (last_error) |err| {
        cursor_x += drawLabel(dc, "Error:", cursor_x, text_y, t.colors.danger) + spacing;
        _ = drawLabel(dc, err, cursor_x, text_y, t.colors.danger);
    }
}

fn badgeBaseColor(t: *const theme.Theme, variant: BadgeVariant) colors.Color {
    return switch (variant) {
        .neutral => t.colors.surface,
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
    };
}


fn drawBadgeCustom(
    dc: *draw_context.DrawContext,
    label: []const u8,
    variant: BadgeVariant,
    filled: bool,
    x: f32,
    bar_rect: draw_context.Rect,
) f32 {
    const t = theme.activeTheme();
    const base = badgeBaseColor(t, variant);
    const bg = if (filled) base else colors.withAlpha(base, 0.14);
    const border = colors.withAlpha(base, if (filled) 0.4 else 0.55);
    const text_color = switch (variant) {
        .neutral, .warning => t.colors.text_primary,
        else => if (filled) t.colors.background else base,
    };
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    const label_size = dc.measureText(label, 0.0);
    const size = .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
    const y = bar_rect.min[1] + (bar_rect.size()[1] - size[1]) * 0.5;
    const rect = draw_context.Rect.fromMinSize(.{ x, y }, size);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + padding[0], rect.min[1] + padding[1] }, .{ .color = text_color });
    return size[0];
}

fn drawLabel(
    dc: *draw_context.DrawContext,
    text: []const u8,
    x: f32,
    y: f32,
    color: colors.Color,
) f32 {
    dc.drawText(text, .{ x, y }, .{ .color = color });
    return dc.measureText(text, 0.0)[0];
}
