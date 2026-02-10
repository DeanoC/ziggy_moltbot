const draw_context = @import("../draw_context.zig");
const theme_runtime = @import("../theme_engine/runtime.zig");

pub fn draw(ctx: *draw_context.DrawContext, rect: draw_context.Rect, radius: f32) void {
    const t = ctx.theme;
    const ss = theme_runtime.getStyleSheet();
    const thickness = ss.focus_ring.thickness orelse 2.0;
    const color = ss.focus_ring.color orelse t.colors.primary;
    if (thickness <= 0.0) return;

    const inset: f32 = thickness * 0.5;
    const ring_rect = draw_context.Rect{
        .min = .{ rect.min[0] - inset, rect.min[1] - inset },
        .max = .{ rect.max[0] + inset, rect.max[1] + inset },
    };

    // Optional outer glow (single SDF GPU draw).
    if (ss.focus_ring.glow.color) |glow_color| {
        const blur = @max(0.0, ss.focus_ring.glow.blur_px orelse 14.0);
        const spread = @max(0.0, ss.focus_ring.glow.spread_px orelse 0.0);
        const offset = ss.focus_ring.glow.offset orelse .{ 0.0, 0.0 };
        const falloff_exp = @max(0.001, ss.focus_ring.glow.falloff_exp orelse 1.0);
        const respect_clip = !(ss.focus_ring.glow.ignore_clip orelse false);
        const blend_mode = ss.focus_ring.glow.blend orelse .alpha;
        const blend: draw_context.BlendMode = if (blend_mode == .additive) .additive else .alpha;
        const glow_thickness = thickness + spread * 2.0;
        const expand = glow_thickness * 0.5 + blur;

        const boundary_rect = draw_context.Rect{
            .min = .{ ring_rect.min[0] + offset[0], ring_rect.min[1] + offset[1] },
            .max = .{ ring_rect.max[0] + offset[0], ring_rect.max[1] + offset[1] },
        };
        const draw_rect = draw_context.Rect{
            .min = .{ boundary_rect.min[0] - expand, boundary_rect.min[1] - expand },
            .max = .{ boundary_rect.max[0] + expand, boundary_rect.max[1] + expand },
        };
        ctx.drawSoftRoundedRect(draw_rect, boundary_rect, radius + inset, .stroke_soft, glow_thickness, blur, falloff_exp, glow_color, respect_clip, blend);
    }

    ctx.drawRoundedRect(ring_rect, radius + inset, .{
        .fill = null,
        .stroke = color,
        .thickness = thickness,
    });
}
