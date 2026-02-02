const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");

pub const Variant = enum {
    primary,
    secondary,
    success,
    danger,
    ghost,
};

pub const Size = enum {
    small,
    medium,
    large,
};

pub const Args = struct {
    variant: Variant = .primary,
    size: Size = .medium,
    disabled: bool = false,
    full_width: bool = false,
    id: ?[]const u8 = null,
};

fn shift(color: colors.Color, amount: f32) colors.Color {
    const target = if (theme.getMode() == .light)
        colors.rgba(0, 0, 0, 255)
    else
        colors.rgba(255, 255, 255, 255);
    return colors.blend(color, target, amount);
}

pub fn draw(label: []const u8, args: Args) bool {
    const t = theme.activeTheme();
    const base = switch (args.variant) {
        .primary => t.colors.primary,
        .secondary => t.colors.surface,
        .success => t.colors.success,
        .danger => t.colors.danger,
        .ghost => colors.withAlpha(t.colors.primary, 0.0),
    };

    const background = base;
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

    const padding = switch (args.size) {
        .small => .{ t.spacing.sm, t.spacing.xs },
        .medium => .{ t.spacing.md, t.spacing.sm },
        .large => .{ t.spacing.lg, t.spacing.md },
    };
    const rounding = t.radius.md;
    const border_size: f32 = if (args.variant == .secondary) 1.0 else 0.0;

    const label_z = if (args.id) |id|
        zgui.formatZ("{s}##{s}", .{ label, id })
    else
        zgui.formatZ("{s}", .{ label });

    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = padding });
    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = rounding });
    zgui.pushStyleVar1f(.{ .idx = .frame_border_size, .v = border_size });

    if (args.disabled) {
        zgui.pushStyleColor4f(.{ .idx = .button, .c = disabled_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = disabled_bg });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = disabled_bg });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = disabled_text });
    } else {
        zgui.pushStyleColor4f(.{ .idx = .button, .c = background });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = hovered });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = active });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = text_color });
    }

    zgui.beginDisabled(.{ .disabled = args.disabled });
    const width = if (args.full_width) zgui.getContentRegionAvail()[0] else 0.0;
    const clicked = zgui.button(label_z, .{ .w = width, .h = 0.0 });
    zgui.endDisabled();

    zgui.popStyleColor(.{ .count = 4 });
    zgui.popStyleVar(.{ .count = 3 });
    return clicked;
}
