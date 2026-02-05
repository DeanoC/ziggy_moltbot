const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");

pub const Options = struct {
    disabled: bool = false,
};

pub fn draw(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    value: *bool,
    queue: *input_state.InputQueue,
    opts: Options,
) bool {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);
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

    const line_h = ctx.lineHeight();
    const box_size = @min(rect.size()[1], line_h);
    const box_min = .{
        rect.min[0],
        rect.min[1] + (rect.size()[1] - box_size) * 0.5,
    };
    const box_rect = draw_context.Rect{
        .min = box_min,
        .max = .{ box_min[0] + box_size, box_min[1] + box_size },
    };

    var border = t.colors.border;
    var fill = t.colors.surface;
    if (value.*) {
        fill = t.colors.primary;
        border = colors.blend(t.colors.primary, colors.rgba(255, 255, 255, 255), 0.1);
    }
    if (hovered) {
        border = colors.blend(border, t.colors.primary, 0.25);
        fill = colors.blend(fill, colors.rgba(255, 255, 255, 255), 0.08);
    }
    if (opts.disabled) {
        border = colors.withAlpha(border, 0.6);
        fill = colors.withAlpha(fill, 0.6);
    }

    ctx.drawRoundedRect(box_rect, t.radius.sm, .{
        .fill = fill,
        .stroke = border,
        .thickness = 1.0,
    });
    if (value.*) {
        var check_color = colors.rgba(255, 255, 255, 255);
        if (opts.disabled) {
            check_color = t.colors.text_secondary;
        }
        const check_size = box_rect.size()[0];
        const inset = check_size * 0.2;
        const x0 = box_rect.min[0] + inset;
        const y0 = box_rect.min[1] + check_size * 0.55;
        const x1 = box_rect.min[0] + check_size * 0.45;
        const y1 = box_rect.min[1] + check_size * 0.75;
        const x2 = box_rect.min[0] + check_size * 0.8;
        const y2 = box_rect.min[1] + check_size * 0.3;
        const thickness = @max(1.5, check_size * 0.12);
        ctx.drawLine(.{ x0, y0 }, .{ x1, y1 }, thickness, check_color);
        ctx.drawLine(.{ x1, y1 }, .{ x2, y2 }, thickness, check_color);
    }

    const label_x = box_rect.max[0] + t.spacing.xs;
    const label_h = line_h;
    const label_pos = .{
        label_x,
        rect.min[1] + (rect.size()[1] - label_h) * 0.5,
    };
    const label_color = if (opts.disabled) t.colors.text_secondary else t.colors.text_primary;
    ctx.drawText(label, label_pos, .{ .color = label_color });

    if (clicked and !opts.disabled) {
        value.* = !value.*;
        return true;
    }
    return false;
}
