const std = @import("std");
const state = @import("../client/state.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const surface_chrome = @import("surface_chrome.zig");

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
    gateway_compatibility: state.GatewayCompatibilityMode,
    last_error: ?[]const u8,
) void {
    const t = dc.theme;
    _ = message_count;
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
    const gateway_variant: BadgeVariant = switch (gateway_compatibility) {
        .fork => .primary,
        .upstream => .warning,
        .unknown => .neutral,
    };
    const gateway_label = switch (gateway_compatibility) {
        .fork => "fork",
        .upstream => "upstream",
        .unknown => "unknown",
    };

    surface_chrome.drawStatusBar(dc, rect);
    dc.drawRect(rect, .{ .stroke = t.colors.border, .thickness = 1.0 });
    dc.pushClip(rect);
    defer dc.popClip();

    const line_height = dc.lineHeight();
    var cursor_x = rect.min[0] + t.spacing.sm;
    const right_limit = rect.max[0] - t.spacing.sm;
    const text_y = rect.min[1] + (rect.size()[1] - line_height) * 0.5;

    cursor_x += drawLabel(dc, "Status:", cursor_x, text_y, label) + spacing;
    cursor_x += drawBadgeCustom(dc, @tagName(client_state), status_variant, true, cursor_x, rect) + spacing;
    cursor_x += drawLabel(dc, "Connection:", cursor_x, text_y, label) + spacing;
    cursor_x += drawBadgeCustom(dc, if (is_connected) "online" else "offline", connection_variant, true, cursor_x, rect) + spacing;

    if (gateway_compatibility != .unknown) {
        cursor_x += drawLabel(dc, "Gateway:", cursor_x, text_y, label) + spacing;
        cursor_x += drawBadgeCustom(dc, gateway_label, gateway_variant, true, cursor_x, rect) + spacing;
    }

    var right_cursor = right_limit;
    if (last_error) |err| {
        const prefix = "Error:";
        const prefix_w = dc.measureText(prefix, 0.0)[0];
        const max_err_w = std.math.clamp(rect.size()[0] * 0.40, 120.0, 360.0);
        const available = right_cursor - (cursor_x + spacing + prefix_w + spacing);
        const err_w = @min(max_err_w, available);
        if (err_w >= 40.0) {
            var err_buf: [256]u8 = undefined;
            const err_fit = fitTextEnd(dc, err, err_w, &err_buf);
            const err_fit_w = dc.measureText(err_fit, 0.0)[0];
            right_cursor -= err_fit_w;
            dc.drawText(err_fit, .{ right_cursor, text_y }, .{ .color = t.colors.danger });
            right_cursor -= spacing + prefix_w;
            dc.drawText(prefix, .{ right_cursor, text_y }, .{ .color = t.colors.danger });
            right_cursor -= spacing;
        }
    }

    const show_chat_context = agent_name != null or session_name != null;
    if (show_chat_context and right_cursor > cursor_x + 24.0) {
        var context_buf: [320]u8 = undefined;
        const context = if (agent_name != null and session_name != null)
            std.fmt.bufPrint(&context_buf, "Agent {s} • Conversation {s}", .{ agent_name.?, session_name.? }) catch ""
        else if (agent_name != null)
            std.fmt.bufPrint(&context_buf, "Agent {s}", .{agent_name.?}) catch ""
        else
            std.fmt.bufPrint(&context_buf, "Conversation {s}", .{session_name.?}) catch "";

        if (context.len > 0) {
            var context_fit_buf: [320]u8 = undefined;
            const context_fit = fitTextEnd(dc, context, right_cursor - cursor_x, &context_fit_buf);
            if (context_fit.len > 0) {
                _ = drawLabel(dc, context_fit, cursor_x, text_y, value);
            }
        }
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
    const t = dc.theme;
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
