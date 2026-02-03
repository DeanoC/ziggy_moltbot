const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const draw_context = @import("../../draw_context.zig");

pub const Variant = enum {
    primary,
    secondary,
    success,
    danger,
    ghost,
};

pub const Args = struct {
    variant: Variant = .primary,
    disabled: bool = false,
    radius: ?f32 = null,
};

fn shift(color: colors.Color, amount: f32) colors.Color {
    const target = if (theme.getMode() == .light)
        colors.rgba(0, 0, 0, 255)
    else
        colors.rgba(255, 255, 255, 255);
    return colors.blend(color, target, amount);
}

pub fn draw(ctx: *draw_context.DrawContext, rect: draw_context.Rect, label: []const u8, args: Args) bool {
    const t = theme.activeTheme();
    const base = switch (args.variant) {
        .primary => t.colors.primary,
        .secondary => t.colors.surface,
        .success => t.colors.success,
        .danger => t.colors.danger,
        .ghost => colors.withAlpha(t.colors.primary, 0.0),
    };

    const hovered = if (args.variant == .ghost)
        colors.withAlpha(t.colors.primary, 0.1)
    else
        shift(base, 0.08);
    const active = if (args.variant == .ghost)
        colors.withAlpha(t.colors.primary, 0.2)
    else
        shift(base, 0.16);

    const text_color = switch (args.variant) {
        .secondary => t.colors.text_primary,
        .ghost => t.colors.primary,
        else => t.colors.background,
    };
    const disabled_text = colors.withAlpha(t.colors.text_secondary, 0.7);
    const disabled_bg = colors.withAlpha(t.colors.surface, 0.6);

    const radius = args.radius orelse t.radius.md;
    const is_hovered = ctx.isHovered(rect);
    const is_active = is_hovered and zgui.isMouseDown(.left);
    const bg = if (args.disabled) disabled_bg else if (is_active) active else if (is_hovered) hovered else base;
    const fg = if (args.disabled) disabled_text else text_color;

    ctx.drawRoundedRect(rect, radius, .{
        .fill = bg,
        .stroke = if (args.variant == .secondary) colors.withAlpha(t.colors.border, 0.9) else null,
        .thickness = 1.0,
    });

    const label_size = zgui.calcTextSize(label, .{});
    const pos = .{
        rect.min[0] + (rect.size()[0] - label_size[0]) * 0.5,
        rect.min[1] + (rect.size()[1] - label_size[1]) * 0.5,
    };
    ctx.drawText(label, pos, .{ .color = fg });

    if (args.disabled) return false;
    return ctx.isClicked(rect);
}
