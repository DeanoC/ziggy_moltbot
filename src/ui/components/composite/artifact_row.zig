const std = @import("std");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const draw_context = @import("../../draw_context.zig");

pub const Args = struct {
    name: []const u8,
    file_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub fn rowHeight(dc: *draw_context.DrawContext, t: *const theme.Theme) f32 {
    return dc.lineHeight() + t.spacing.xs * 2.0;
}

pub fn draw(dc: *draw_context.DrawContext, rect: draw_context.Rect, args: Args) void {
    const t = theme.activeTheme();
    const row_height = rect.size()[1];
    const icon_size = row_height - t.spacing.xs * 2.0;
    const icon_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs },
        .{ icon_size, icon_size },
    );
    dc.drawRoundedRect(icon_rect, 2.0, .{ .fill = iconColor(t, args.file_type) });

    const text_pos = .{ icon_rect.max[0] + t.spacing.sm, rect.min[1] + t.spacing.xs * 0.5 };
    dc.drawText(args.name, text_pos, .{ .color = t.colors.text_primary });

    const badge_spacing = t.spacing.xs;
    var total_badge_width: f32 = 0.0;
    var badge_count: usize = 0;
    if (args.file_type) |file_type| {
        total_badge_width += pillSize(dc, file_type, t)[0];
        badge_count += 1;
    }
    if (args.status) |status| {
        total_badge_width += pillSize(dc, status, t)[0];
        badge_count += 1;
    }
    if (badge_count > 1) {
        total_badge_width += badge_spacing * @as(f32, @floatFromInt(badge_count - 1));
    }

    if (badge_count > 0) {
        var x = rect.max[0] - total_badge_width - t.spacing.sm;
        if (args.file_type) |file_type| {
            drawPill(dc, t, file_type, .neutral, x, rect.min[1], row_height);
            x += pillSize(dc, file_type, t)[0] + badge_spacing;
        }
        if (args.status) |status| {
            drawPill(dc, t, status, statusVariant(status), x, rect.min[1], row_height);
        }
    }
}

const BadgeVariant = enum {
    neutral,
    primary,
    success,
    warning,
    danger,
};

fn iconColor(t: *const theme.Theme, file_type: ?[]const u8) colors.Color {
    if (file_type == null) return colors.withAlpha(t.colors.primary, 0.2);
    const ft = file_type.?;
    if (std.ascii.eqlIgnoreCase(ft, "png") or std.ascii.eqlIgnoreCase(ft, "jpg") or
        std.ascii.eqlIgnoreCase(ft, "jpeg") or std.ascii.eqlIgnoreCase(ft, "gif") or std.ascii.eqlIgnoreCase(ft, "webp"))
    {
        return colors.withAlpha(t.colors.warning, 0.4);
    }
    if (std.ascii.eqlIgnoreCase(ft, "csv") or std.ascii.eqlIgnoreCase(ft, "xls") or std.ascii.eqlIgnoreCase(ft, "xlsx")) {
        return colors.withAlpha(t.colors.success, 0.4);
    }
    if (std.ascii.eqlIgnoreCase(ft, "json") or std.ascii.eqlIgnoreCase(ft, "yaml") or std.ascii.eqlIgnoreCase(ft, "yml")) {
        return colors.withAlpha(t.colors.primary, 0.4);
    }
    if (std.ascii.eqlIgnoreCase(ft, "md") or std.ascii.eqlIgnoreCase(ft, "txt")) {
        return colors.withAlpha(t.colors.primary, 0.3);
    }
    return colors.withAlpha(t.colors.primary, 0.25);
}

fn statusVariant(status: []const u8) BadgeVariant {
    if (std.ascii.eqlIgnoreCase(status, "assistant")) return .primary;
    if (std.ascii.eqlIgnoreCase(status, "tool")) return .warning;
    if (std.ascii.eqlIgnoreCase(status, "system")) return .danger;
    return .neutral;
}

fn pillSize(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) [2]f32 {
    const label_size = dc.measureText(label, 0.0);
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    return .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
}

fn drawPill(
    dc: *draw_context.DrawContext,
    t: *const theme.Theme,
    label: []const u8,
    variant: BadgeVariant,
    x: f32,
    row_y: f32,
    row_height: f32,
) void {
    const size = pillSize(dc, label, t);
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    const y = row_y + (row_height - size[1]) * 0.5;
    const base = switch (variant) {
        .neutral => t.colors.surface,
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
    };
    const bg = colors.withAlpha(base, 0.16);
    const border = colors.withAlpha(base, 0.4);
    const text_color = switch (variant) {
        .neutral, .warning => t.colors.text_primary,
        else => base,
    };
    const rect = draw_context.Rect.fromMinSize(.{ x, y }, size);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(label, .{ x + padding[0], y + padding[1] }, .{ .color = text_color });
}
