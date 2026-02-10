const std = @import("std");
const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
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
    const t = ctx.theme;
    const nav_state = nav_router.get();
    const widget_id = nav_router.makeWidgetId(@returnAddress(), "checkbox", label);
    const nav_id: u64 = if (nav_state != null) widget_id else 0;
    if (nav_state) |nav| nav.registerItem(ctx.allocator, nav_id, rect);
    const nav_active = if (nav_state) |nav| nav.isActive() else false;
    const focused = if (nav_state) |nav| nav.isFocusedId(nav_id) else false;

    const hovered = (theme_runtime.allowHover(queue) and rect.contains(queue.state.mouse_pos)) or (nav_active and focused);
    const pressed = rect.contains(queue.state.mouse_pos) and queue.state.mouse_down_left and queue.state.pointer_kind != .nav;
    const ss = theme_runtime.getStyleSheet();
    const cs = ss.checkbox;
    var clicked = false;
    if (!opts.disabled) {
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button == .left and rect.contains(md.pos)) {
                        if (queue.state.mouse_capture_left_id == 0) {
                            queue.state.mouse_capture_left_id = widget_id;
                        }
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left and queue.state.mouse_capture_left_id == widget_id) {
                        // Touch/pen drags should scroll, not toggle.
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

    const line_h = ctx.lineHeight();
    // If the checkbox row is tall (phone/fullscreen hit targets), keep the box large enough
    // to match the intended interaction affordance.
    const box_size = @min(rect.size()[1], @max(line_h, rect.size()[1] * 0.6));
    const box_min = .{
        rect.min[0],
        rect.min[1] + (rect.size()[1] - box_size) * 0.5,
    };
    const box_rect = draw_context.Rect{
        .min = box_min,
        .max = .{ box_min[0] + box_size, box_min[1] + box_size },
    };

    const white: colors.Color = .{ 1.0, 1.0, 1.0, 1.0 };
    const unchecked_fill = cs.fill orelse style_sheet.Paint{ .solid = t.colors.surface };
    const checked_fill = cs.fill_checked orelse style_sheet.Paint{ .solid = t.colors.primary };
    var fill = if (value.*) checked_fill else unchecked_fill;

    var border = cs.border orelse t.colors.border;
    if (value.*) {
        border = cs.border_checked orelse colors.blend(t.colors.primary, white, 0.1);
    }
    if (hovered) {
        border = colors.blend(border, t.colors.primary, 0.25);
        fill = blendPaint(fill, white, 0.08);
    }
    if (opts.disabled) {
        border = colors.withAlpha(border, 0.6);
        fill = withAlphaPaint(fill, 0.6);
    }

    // Optional explicit state overrides.
    const st = blk: {
        if (opts.disabled) break :blk cs.states.disabled;
        if (pressed) break :blk cs.states.pressed;
        if (hovered) break :blk cs.states.hover;
        if (focused) break :blk cs.states.focused;
        break :blk style_sheet.CheckboxStateStyle{};
    };
    if (st.fill) |v| fill = v;
    if (st.fill_checked) |v| {
        if (value.*) fill = v;
    }
    if (st.border) |v| border = v;
    if (st.border_checked) |v| {
        if (value.*) border = v;
    }

    const radius = cs.radius orelse t.radius.sm;
    switch (fill) {
        .solid => |c| ctx.drawRoundedRect(box_rect, radius, .{
            .fill = c,
            .stroke = border,
            .thickness = 1.0,
        }),
        .gradient4 => |g| {
            ctx.drawRoundedRectGradient(box_rect, radius, .{
                .tl = g.tl,
                .tr = g.tr,
                .bl = g.bl,
                .br = g.br,
            });
            ctx.drawRoundedRect(box_rect, radius, .{ .stroke = border, .thickness = 1.0 });
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
            const size = box_rect.size();

            if (img.mode == .tile) {
                const uv0_x = offset[0] / (w * scale);
                const uv0_y = offset[1] / (h * scale);
                const uv1_x = uv0_x + (size[0] / (w * scale));
                const uv1_y = uv0_y + (size[1] / (h * scale));
                ctx.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    box_rect,
                    .{ uv0_x, uv0_y },
                    .{ uv1_x, uv1_y },
                    tint,
                    true,
                );
            } else {
                ctx.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    box_rect,
                    .{ 0.0, 0.0 },
                    .{ 1.0, 1.0 },
                    tint,
                    false,
                );
            }

            if (hovered and !opts.disabled) {
                ctx.drawRoundedRect(box_rect, radius, .{ .fill = colors.withAlpha(t.colors.primary, 0.05) });
            }
            ctx.drawRoundedRect(box_rect, radius, .{ .fill = null, .stroke = border, .thickness = 1.0 });
        },
    }
    if (value.*) {
        var check_color = cs.check orelse colors.rgba(255, 255, 255, 255);
        if (st.check) |v| check_color = v;
        if (opts.disabled) check_color = t.colors.text_secondary;
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

    if (focused and !opts.disabled) {
        const ring_radius = cs.radius orelse t.radius.sm;
        focus_ring.draw(ctx, rect, ring_radius);
    }

    return false;
}
