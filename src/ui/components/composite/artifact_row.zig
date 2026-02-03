const std = @import("std");
const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const components = @import("../components.zig");

pub const Args = struct {
    name: []const u8,
    file_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub fn draw(args: Args) void {
    const t = theme.activeTheme();
    const cursor = zgui.getCursorScreenPos();
    const avail = zgui.getContentRegionAvail();
    const row_height = zgui.getFrameHeight() + t.spacing.xs;
    _ = zgui.invisibleButton("##artifact_row", .{ .w = avail[0], .h = row_height });

    const icon_size = row_height - t.spacing.xs * 2.0;
    const icon_color = zgui.colorConvertFloat4ToU32(iconColor(t, args.file_type));
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = .{ cursor[0] + t.spacing.xs, cursor[1] + t.spacing.xs },
        .pmax = .{ cursor[0] + t.spacing.xs + icon_size, cursor[1] + t.spacing.xs + icon_size },
        .col = icon_color,
        .rounding = 2.0,
    });

    const text_pos = .{ cursor[0] + icon_size + t.spacing.sm * 1.5, cursor[1] + t.spacing.xs * 0.5 };
    draw_list.addText(text_pos, zgui.colorConvertFloat4ToU32(t.colors.text_primary), "{s}", .{args.name});

    const badge_spacing = t.spacing.xs;
    var total_badge_width: f32 = 0.0;
    var badge_count: usize = 0;
    if (args.file_type) |file_type| {
        total_badge_width += pillSize(file_type, t)[0];
        badge_count += 1;
    }
    if (args.status) |status| {
        total_badge_width += pillSize(status, t)[0];
        badge_count += 1;
    }
    if (badge_count > 1) {
        total_badge_width += badge_spacing * @as(f32, @floatFromInt(badge_count - 1));
    }

    if (badge_count > 0) {
        var x = cursor[0] + avail[0] - total_badge_width - t.spacing.sm;
        if (args.file_type) |file_type| {
            drawPill(draw_list, t, file_type, .neutral, x, cursor[1], row_height);
            x += pillSize(file_type, t)[0] + badge_spacing;
        }
        if (args.status) |status| {
            drawPill(draw_list, t, status, statusVariant(status), x, cursor[1], row_height);
        }
    }
}

fn iconColor(t: *const theme.Theme, file_type: ?[]const u8) colors.Color {
    if (file_type == null) return colors.withAlpha(t.colors.primary, 0.2);
    const ft = file_type.?;
    if (std.ascii.eqlIgnoreCase(ft, "png") or std.ascii.eqlIgnoreCase(ft, "jpg") or
        std.ascii.eqlIgnoreCase(ft, "jpeg") or std.ascii.eqlIgnoreCase(ft, "gif"))
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

fn statusVariant(status: []const u8) components.core.badge.Variant {
    if (std.ascii.eqlIgnoreCase(status, "assistant")) return .primary;
    if (std.ascii.eqlIgnoreCase(status, "tool")) return .warning;
    if (std.ascii.eqlIgnoreCase(status, "system")) return .danger;
    return .neutral;
}

fn pillSize(label: []const u8, t: *const theme.Theme) [2]f32 {
    const label_size = zgui.calcTextSize(label, .{});
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    return .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
}

fn drawPill(
    draw_list: zgui.DrawList,
    t: *const theme.Theme,
    label: []const u8,
    variant: components.core.badge.Variant,
    x: f32,
    row_y: f32,
    row_height: f32,
) void {
    const size = pillSize(label, t);
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
    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + size[0], y + size[1] },
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = t.radius.lg,
    });
    draw_list.addRect(.{
        .pmin = .{ x, y },
        .pmax = .{ x + size[0], y + size[1] },
        .col = zgui.colorConvertFloat4ToU32(border),
        .rounding = t.radius.lg,
    });
    draw_list.addText(
        .{ x + padding[0], y + padding[1] },
        zgui.colorConvertFloat4ToU32(text_color),
        "{s}",
        .{label},
    );
}
