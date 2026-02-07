const std = @import("std");

const draw_context = @import("draw_context.zig");
const image_cache = @import("image_cache.zig");
const theme = @import("theme.zig");
const theme_runtime = @import("theme_engine/runtime.zig");
const style_sheet = @import("theme_engine/style_sheet.zig");

pub const Options = struct {
    radius: ?f32 = null,
    draw_shadow: bool = true,
    draw_fill: bool = true,
    draw_frame: bool = true,
    draw_border: bool = true,
};

pub fn draw(dc: *draw_context.DrawContext, rect: draw_context.Rect, opts: Options) void {
    const t = dc.theme;
    const ss = theme_runtime.getStyleSheet();

    const radius = opts.radius orelse ss.panel.radius orelse t.radius.md;

    if (opts.draw_shadow) {
        drawPanelShadow(dc, rect, radius);
    }

    if (opts.draw_fill) {
        const fill = ss.panel.fill orelse style_sheet.Paint{ .solid = t.colors.surface };
        switch (fill) {
            .solid => |c| dc.drawRoundedRect(rect, radius, .{ .fill = c }),
            .gradient4 => |g| dc.drawRoundedRectGradient(rect, radius, .{
                .tl = g.tl,
                .tr = g.tr,
                .bl = g.bl,
                .br = g.br,
            }),
        }
    }

    if (opts.draw_frame) {
        drawPanelFrame(dc, rect);
    }

    if (opts.draw_border) {
        const border = ss.panel.border orelse t.colors.border;
        dc.drawRoundedRect(rect, radius, .{ .fill = null, .stroke = border, .thickness = 1.0 });
    }
}

fn drawPanelShadow(dc: *draw_context.DrawContext, rect: draw_context.Rect, radius: f32) void {
    const ss = theme_runtime.getStyleSheet();
    if (ss.panel.shadow.color) |shadow_color| {
        const blur = @max(0.0, ss.panel.shadow.blur_px orelse 12.0);
        const spread = @max(0.0, ss.panel.shadow.spread_px orelse 0.0);
        const offset = ss.panel.shadow.offset orelse .{ 0.0, 6.0 };
        const falloff_exp = @max(0.001, ss.panel.shadow.falloff_exp orelse 1.0);
        const respect_clip = !(ss.panel.shadow.ignore_clip orelse false);

        const shape_rect = draw_context.Rect{
            .min = .{ rect.min[0] + offset[0] - spread, rect.min[1] + offset[1] - spread },
            .max = .{ rect.max[0] + offset[0] + spread, rect.max[1] + offset[1] + spread },
        };
        const draw_rect = draw_context.Rect{
            .min = .{ shape_rect.min[0] - blur, shape_rect.min[1] - blur },
            .max = .{ shape_rect.max[0] + blur, shape_rect.max[1] + blur },
        };

        const w = shape_rect.max[0] - shape_rect.min[0];
        const h = shape_rect.max[1] - shape_rect.min[1];
        const r_max = @min(w, h) * 0.5;
        const r = @max(0.0, @min(radius + spread, r_max));

        // Single GPU draw using an SDF rounded-rect shader.
        dc.drawSoftRoundedRect(draw_rect, shape_rect, r, .fill_soft, 0.0, blur, falloff_exp, shadow_color, respect_clip);
    }
}

fn drawPanelFrame(dc: *draw_context.DrawContext, rect: draw_context.Rect) void {
    const ss = theme_runtime.getStyleSheet();
    if (!ss.panel.frame_image.isSet()) return;
    const rel_img = ss.panel.frame_image.slice();
    const slices = ss.panel.frame_slices_px orelse return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = theme_runtime.resolveThemeAssetPath(path_buf[0..], rel_img) orelse return;

    image_cache.request(abs_path);
    const entry = image_cache.get(abs_path) orelse return;
    if (entry.state != .ready) return;

    const tint = ss.panel.frame_tint orelse .{ 1.0, 1.0, 1.0, 1.0 };
    dc.drawNineSlice(
        draw_context.DrawContext.textureFromId(entry.texture_id),
        rect,
        slices,
        tint,
    );
}
