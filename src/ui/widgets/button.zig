const std = @import("std");
const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const image_cache = @import("../image_cache.zig");
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
        .image => paint,
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
        .image => paint,
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
    /// Optional style override applied on top of the base variant style.
    /// Useful for special-purpose buttons (panel header controls, etc) without introducing
    /// a new widget type.
    style_override: ?*const style_sheet.ButtonVariantStyle = null,
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
    const variant_style_base = switch (opts.variant) {
        .primary => ss.button.primary,
        .secondary => ss.button.secondary,
        .ghost => ss.button.ghost,
    };
    var variant_style = variant_style_base;
    if (opts.style_override) |ov| {
        if (ov.radius) |v| variant_style.radius = v;
        if (ov.fill) |v| variant_style.fill = v;
        if (ov.text) |v| variant_style.text = v;
        if (ov.border) |v| variant_style.border = v;
        if (ov.states.hover.isSet()) variant_style.states.hover = ov.states.hover;
        if (ov.states.pressed.isSet()) variant_style.states.pressed = ov.states.pressed;
        if (ov.states.focused.isSet()) variant_style.states.focused = ov.states.focused;
        if (ov.states.disabled.isSet()) variant_style.states.disabled = ov.states.disabled;
    }

    const State = enum { none, hover, pressed, focused, disabled };
    const state: State = blk: {
        if (opts.disabled) break :blk .disabled;
        if (pressed) break :blk .pressed;
        if (hovered) break :blk .hover;
        if (focused) break :blk .focused;
        break :blk .none;
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

    // Optional explicit state overrides (hover/pressed/focused/disabled).
    const st = switch (state) {
        .hover => variant_style.states.hover,
        .pressed => variant_style.states.pressed,
        .focused => variant_style.states.focused,
        .disabled => variant_style.states.disabled,
        .none => style_sheet.ButtonVariantStateStyle{},
    };
    if (st.fill) |v| fill = v;
    if (st.text) |v| text_color = v;
    if (st.border) |v| border = v;

    if (opts.disabled and !variant_style.states.disabled.isSet()) {
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
        .image => |img| {
            if (!img.path.isSet()) return false;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_path = theme_runtime.resolveThemeAssetPath(path_buf[0..], img.path.slice()) orelse return false;
            image_cache.request(abs_path);
            const entry = image_cache.get(abs_path) orelse return false;
            if (entry.state != .ready) return false;
            const w: f32 = @floatFromInt(@max(entry.width, 1));
            const h: f32 = @floatFromInt(@max(entry.height, 1));
            const scale = img.scale orelse 1.0;
            var tint = img.tint orelse .{ 1.0, 1.0, 1.0, 1.0 };
            if (opts.disabled) tint[3] *= 0.6;
            const offset = img.offset_px orelse .{ 0.0, 0.0 };
            const size = rect.size();

            if (img.mode == .tile) {
                const uv0_x = offset[0] / (w * scale);
                const uv0_y = offset[1] / (h * scale);
                const uv1_x = uv0_x + (size[0] / (w * scale));
                const uv1_y = uv0_y + (size[1] / (h * scale));
                ctx.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    rect,
                    .{ uv0_x, uv0_y },
                    .{ uv1_x, uv1_y },
                    tint,
                    true,
                );
            } else {
                ctx.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    rect,
                    .{ 0.0, 0.0 },
                    .{ 1.0, 1.0 },
                    tint,
                    false,
                );
            }

            // Simple state overlay (keeps image fill but still feels interactive).
            if (!opts.disabled) {
                if (pressed) {
                    ctx.drawRoundedRect(rect, radius, .{ .fill = colors.withAlpha(t.colors.primary, 0.10) });
                } else if (hovered) {
                    ctx.drawRoundedRect(rect, radius, .{ .fill = colors.withAlpha(t.colors.primary, 0.06) });
                }
            }

            // Border pass.
            ctx.drawRoundedRect(rect, radius, .{ .fill = null, .stroke = border, .thickness = 1.0 });
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
