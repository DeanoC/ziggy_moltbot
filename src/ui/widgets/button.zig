const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const theme_runtime = @import("../theme_engine/runtime.zig");
const style_sheet = @import("../theme_engine/style_sheet.zig");
const nav_router = @import("../input/nav_router.zig");
const focus_ring = @import("focus_ring.zig");

fn blendPaint(paint: anytype, over: colors.Color, factor: f32) @TypeOf(paint) {
    return switch (paint) {
        .solid => |c| .{ .solid = colors.blend(c, over, factor) },
        .gradient4 => |g| .{ .gradient4 = .{
            .tl = colors.blend(g.tl, over, factor),
            .tr = colors.blend(g.tr, over, factor),
            .bl = colors.blend(g.bl, over, factor),
            .br = colors.blend(g.br, over, factor),
        } },
    };
}

fn withAlphaPaint(paint: anytype, a: f32) @TypeOf(paint) {
    return switch (paint) {
        .solid => |c| .{ .solid = colors.withAlpha(c, a) },
        .gradient4 => |g| .{ .gradient4 = .{
            .tl = colors.withAlpha(g.tl, a),
            .tr = colors.withAlpha(g.tr, a),
            .bl = colors.withAlpha(g.bl, a),
            .br = colors.withAlpha(g.br, a),
        } },
    };
}

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

pub fn defaultHeight(t: *const theme.Theme, line_height: f32) f32 {
    const profile = theme_runtime.getProfile();
    const base = line_height + t.spacing.xs * 2.0;
    return @max(base, profile.hit_target_min_px);
}

pub fn draw(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    queue: *input_state.InputQueue,
    opts: Options,
) bool {
    const t = ctx.theme;
    const nav_state = nav_router.get();
    const widget_id = nav_router.makeWidgetId(@returnAddress(), "button", label);
    const nav_id: u64 = if (nav_state != null) widget_id else 0;
    if (nav_state) |nav| nav.registerItem(ctx.allocator, nav_id, rect);
    const nav_active = if (nav_state) |nav| nav.isActive() else false;
    const focused = if (nav_state) |nav| nav.isFocusedId(nav_id) else false;

    const allow_hover = theme_runtime.allowHover(queue);
    const inside = rect.contains(queue.state.mouse_pos);
    const hovered = (allow_hover and inside) or (nav_active and focused);
    const pressed = inside and queue.state.mouse_down_left and queue.state.pointer_kind != .nav;

    const ss = theme_runtime.getStyleSheet();
    const variant_style = switch (opts.variant) {
        .primary => ss.button.primary,
        .secondary => ss.button.secondary,
        .ghost => ss.button.ghost,
    };

    var clicked = false;
    if (!opts.disabled) {
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button == .left and rect.contains(md.pos)) {
                        // Capture the press so a later mouse_up in this rect counts as a click.
                        if (queue.state.mouse_capture_left_id == 0) {
                            queue.state.mouse_capture_left_id = widget_id;
                        }
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left and queue.state.mouse_capture_left_id == widget_id) {
                        // Touch/pen drags should scroll, not click.
                        if (rect.contains(mu.pos) and (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging)) {
                            clicked = true;
                        }
                        queue.state.mouse_capture_left_id = 0;
                    }
                },
                else => {},
            }
        }
        if (!clicked and nav_active and focused) {
            clicked = nav_router.wasActivated(queue, nav_id);
        }
    }

    const white: colors.Color = .{ 1.0, 1.0, 1.0, 1.0 };
    const transparent: colors.Color = .{ 0.0, 0.0, 0.0, 0.0 };
    const base_bg = switch (opts.variant) {
        .primary => variant_style.fill orelse style_sheet.Paint{ .solid = t.colors.primary },
        .secondary => variant_style.fill orelse style_sheet.Paint{ .solid = t.colors.surface },
        .ghost => variant_style.fill orelse style_sheet.Paint{ .solid = transparent },
    };
    const hover_bg = switch (opts.variant) {
        .primary => blendPaint(base_bg, white, 0.12),
        .secondary => blendPaint(base_bg, t.colors.primary, 0.06),
        .ghost => style_sheet.Paint{ .solid = colors.withAlpha(t.colors.primary, 0.08) },
    };
    const active_bg = switch (opts.variant) {
        .primary => blendPaint(base_bg, white, 0.2),
        .secondary => blendPaint(base_bg, t.colors.primary, 0.12),
        .ghost => style_sheet.Paint{ .solid = colors.withAlpha(t.colors.primary, 0.14) },
    };

    var fill = base_bg;
    if (pressed) {
        fill = active_bg;
    } else if (hovered) {
        fill = hover_bg;
    }

    var text_color = t.colors.text_primary;
    if (opts.variant == .primary) {
        text_color = colors.rgba(255, 255, 255, 255);
    }
    if (variant_style.text) |override| {
        text_color = override;
    }
    var border = t.colors.border;
    if (variant_style.border) |override| {
        border = override;
    }
    if (hovered) {
        border = colors.blend(border, t.colors.primary, 0.2);
    }

    if (opts.disabled) {
        fill = withAlphaPaint(fill, 0.4);
        text_color = t.colors.text_secondary;
        border = colors.withAlpha(border, 0.6);
    }

    const radius = opts.radius orelse variant_style.radius orelse t.radius.sm;
    switch (fill) {
        .solid => |c| ctx.drawRoundedRect(rect, radius, .{
            .fill = c,
            .stroke = border,
            .thickness = 1.0,
        }),
        .gradient4 => |g| {
            ctx.drawRoundedRectGradient(rect, radius, .{
                .tl = g.tl,
                .tr = g.tr,
                .bl = g.bl,
                .br = g.br,
            });
            ctx.drawRoundedRect(rect, radius, .{ .stroke = border, .thickness = 1.0 });
        },
    }

    const text_w = ctx.measureText(label, 0.0)[0];
    const text_h = ctx.lineHeight();
    const pos = .{
        rect.min[0] + (rect.size()[0] - text_w) * 0.5,
        rect.min[1] + (rect.size()[1] - text_h) * 0.5,
    };
    ctx.drawText(label, pos, .{ .color = text_color });

    if (focused and !opts.disabled) {
        const ring_radius = opts.radius orelse variant_style.radius orelse t.radius.sm;
        focus_ring.draw(ctx, rect, ring_radius);
    }

    return clicked and !opts.disabled;
}
