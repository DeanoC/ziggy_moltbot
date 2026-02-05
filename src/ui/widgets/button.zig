const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");

pub const Variant = enum {
    primary,
    secondary,
    ghost,
};

pub const Options = struct {
    disabled: bool = false,
    variant: Variant = .secondary,
    radius: ?f32 = null,
};

pub fn draw(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    queue: *input_state.InputQueue,
    opts: Options,
) bool {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);
    const active = hovered and queue.state.mouse_down_left;

    var clicked = false;
    if (!opts.disabled) {
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_up => |mu| {
                    if (mu.button == .left and rect.contains(mu.pos)) {
                        clicked = true;
                    }
                },
                else => {},
            }
        }
    }

    const white: colors.Color = .{ 1.0, 1.0, 1.0, 1.0 };
    const transparent: colors.Color = .{ 0.0, 0.0, 0.0, 0.0 };
    const base_bg = switch (opts.variant) {
        .primary => t.colors.primary,
        .secondary => t.colors.surface,
        .ghost => transparent,
    };
    const hover_bg = switch (opts.variant) {
        .primary => colors.blend(base_bg, white, 0.12),
        .secondary => colors.blend(base_bg, t.colors.primary, 0.06),
        .ghost => colors.withAlpha(t.colors.primary, 0.08),
    };
    const active_bg = switch (opts.variant) {
        .primary => colors.blend(base_bg, white, 0.2),
        .secondary => colors.blend(base_bg, t.colors.primary, 0.12),
        .ghost => colors.withAlpha(t.colors.primary, 0.14),
    };

    var fill = base_bg;
    if (active) {
        fill = active_bg;
    } else if (hovered) {
        fill = hover_bg;
    }

    var text_color = t.colors.text_primary;
    if (opts.variant == .primary) {
        text_color = colors.rgba(255, 255, 255, 255);
    }
    var border = t.colors.border;
    if (hovered) {
        border = colors.blend(border, t.colors.primary, 0.2);
    }

    if (opts.disabled) {
        fill = colors.withAlpha(fill, 0.4);
        text_color = t.colors.text_secondary;
        border = colors.withAlpha(border, 0.6);
    }

    const radius = opts.radius orelse t.radius.sm;
    ctx.drawRoundedRect(rect, radius, .{
        .fill = fill,
        .stroke = border,
        .thickness = 1.0,
    });

    const text_w = ctx.measureText(label, 0.0)[0];
    const text_h = ctx.lineHeight();
    const pos = .{
        rect.min[0] + (rect.size()[0] - text_w) * 0.5,
        rect.min[1] + (rect.size()[1] - text_h) * 0.5,
    };
    ctx.drawText(label, pos, .{ .color = text_color });

    return clicked and !opts.disabled;
}
