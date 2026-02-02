const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");

pub const Variant = enum {
    neutral,
    primary,
    success,
    warning,
    danger,
};

pub const Size = enum {
    small,
    medium,
};

pub const Args = struct {
    variant: Variant = .neutral,
    size: Size = .small,
    filled: bool = false,
};

fn baseColor(t: *const theme.Theme, variant: Variant) colors.Color {
    return switch (variant) {
        .neutral => t.colors.surface,
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
    };
}

pub fn draw(label: []const u8, args: Args) void {
    const t = theme.activeTheme();
    const base = baseColor(t, args.variant);
    const bg = if (args.filled) base else colors.withAlpha(base, 0.14);
    const border = colors.withAlpha(base, if (args.filled) 0.4 else 0.55);
    const text_color = switch (args.variant) {
        .neutral, .warning => t.colors.text_primary,
        else => if (args.filled) t.colors.background else base,
    };
    const padding = switch (args.size) {
        .small => .{ t.spacing.xs, t.spacing.xs * 0.5 },
        .medium => .{ t.spacing.sm, t.spacing.xs },
    };

    const label_size = zgui.calcTextSize(label, .{});
    const size = .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
    const pos = zgui.getCursorScreenPos();
    const rect_min = pos;
    const rect_max = .{ pos[0] + size[0], pos[1] + size[1] };
    const rounding = t.radius.lg;

    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = rect_min,
        .pmax = rect_max,
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = rounding,
    });
    draw_list.addRect(.{
        .pmin = rect_min,
        .pmax = rect_max,
        .col = zgui.colorConvertFloat4ToU32(border),
        .rounding = rounding,
    });
    draw_list.addText(
        .{ pos[0] + padding[0], pos[1] + padding[1] },
        zgui.colorConvertFloat4ToU32(text_color),
        "{s}",
        .{label},
    );

    zgui.dummy(.{ .w = size[0], .h = size[1] });
}
