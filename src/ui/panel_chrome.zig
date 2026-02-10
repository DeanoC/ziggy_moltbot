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

pub fn contentRect(rect: draw_context.Rect) draw_context.Rect {
    const ss = theme_runtime.getStyleSheet();
    const inset = ss.panel.content_inset_px orelse .{ 0.0, 0.0, 0.0, 0.0 };

    const w = rect.size()[0];
    const h = rect.size()[1];
    if (w <= 0.0 or h <= 0.0) return rect;

    const left = std.math.clamp(inset[0], 0.0, w);
    const top = std.math.clamp(inset[1], 0.0, h);
    const right = std.math.clamp(inset[2], 0.0, w - left);
    const bottom = std.math.clamp(inset[3], 0.0, h - top);

    const min_x = rect.min[0] + left;
    const min_y = rect.min[1] + top;
    const max_x = rect.max[0] - right;
    const max_y = rect.max[1] - bottom;
    if (max_x <= min_x or max_y <= min_y) return rect;
    return .{ .min = .{ min_x, min_y }, .max = .{ max_x, max_y } };
}

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
            .image => |img| {
                if (!img.path.isSet()) return;
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const abs_path = theme_runtime.resolveThemeAssetPath(path_buf[0..], img.path.slice()) orelse return;
                image_cache.request(abs_path);
                const entry = image_cache.get(abs_path) orelse return;
                if (entry.state != .ready) return;
                const w: f32 = @floatFromInt(@max(entry.width, 1));
                const h: f32 = @floatFromInt(@max(entry.height, 1));
                const scale = img.scale orelse 1.0;
                const tint = img.tint orelse .{ 1.0, 1.0, 1.0, 1.0 };
                const offset = img.offset_px orelse .{ 0.0, 0.0 };
                const size = rect.size();

                if (img.mode == .tile) {
                    // UVs expressed in "tiles" (repeat sampler wraps outside 0..1).
                    const uv0_x = offset[0] / (w * scale);
                    const uv0_y = offset[1] / (h * scale);
                    const uv1_x = uv0_x + (size[0] / (w * scale));
                    const uv1_y = uv0_y + (size[1] / (h * scale));
                    dc.drawImageUv(
                        draw_context.DrawContext.textureFromId(entry.texture_id),
                        rect,
                        .{ uv0_x, uv0_y },
                        .{ uv1_x, uv1_y },
                        tint,
                        true,
                    );
                } else {
                    dc.drawImageUv(
                        draw_context.DrawContext.textureFromId(entry.texture_id),
                        rect,
                        .{ 0.0, 0.0 },
                        .{ 1.0, 1.0 },
                        tint,
                        false,
                    );
                }
            },
        }
    }

    if (opts.draw_frame) {
        drawPanelFrame(dc, rect);
    }

    if (ss.panel.overlay) |overlay| {
        // Overlay is intentionally drawn after the frame so "lighting" layers can affect edges too.
        // If a theme needs rounded-corner masking, the overlay image should include alpha in corners.
        drawPaintRect(dc, rect, overlay);
    }

    if (opts.draw_border) {
        const border = ss.panel.border orelse t.colors.border;
        dc.drawRoundedRect(rect, radius, .{ .fill = null, .stroke = border, .thickness = 1.0 });
    }
}

pub fn drawPaintRect(dc: *draw_context.DrawContext, rect: draw_context.Rect, paint: style_sheet.Paint) void {
    switch (paint) {
        .solid => |c| dc.drawRect(rect, .{ .fill = c }),
        .gradient4 => |g| dc.drawRectGradient(rect, .{
            .tl = g.tl,
            .tr = g.tr,
            .bl = g.bl,
            .br = g.br,
        }),
        .image => |img| {
            if (!img.path.isSet()) return;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_path = theme_runtime.resolveThemeAssetPath(path_buf[0..], img.path.slice()) orelse return;
            image_cache.request(abs_path);
            const entry = image_cache.get(abs_path) orelse return;
            if (entry.state != .ready) return;

            const w: f32 = @floatFromInt(@max(entry.width, 1));
            const h: f32 = @floatFromInt(@max(entry.height, 1));
            const scale = img.scale orelse 1.0;
            const tint = img.tint orelse .{ 1.0, 1.0, 1.0, 1.0 };
            const offset = img.offset_px orelse .{ 0.0, 0.0 };
            const size = rect.size();

            if (img.mode == .tile) {
                const uv0_x = offset[0] / (w * scale);
                const uv0_y = offset[1] / (h * scale);
                const uv1_x = uv0_x + (size[0] / (w * scale));
                const uv1_y = uv0_y + (size[1] / (h * scale));
                dc.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    rect,
                    .{ uv0_x, uv0_y },
                    .{ uv1_x, uv1_y },
                    tint,
                    true,
                );
            } else {
                dc.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    rect,
                    .{ 0.0, 0.0 },
                    .{ 1.0, 1.0 },
                    tint,
                    false,
                );
            }
        },
    }
}

pub fn drawPaintRoundedRect(dc: *draw_context.DrawContext, rect: draw_context.Rect, radius: f32, paint: style_sheet.Paint) void {
    switch (paint) {
        .solid => |c| dc.drawRoundedRect(rect, radius, .{ .fill = c }),
        .gradient4 => |g| dc.drawRoundedRectGradient(rect, radius, .{
            .tl = g.tl,
            .tr = g.tr,
            .bl = g.bl,
            .br = g.br,
        }),
        .image => |img| {
            if (!img.path.isSet()) return;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_path = theme_runtime.resolveThemeAssetPath(path_buf[0..], img.path.slice()) orelse return;
            image_cache.request(abs_path);
            const entry = image_cache.get(abs_path) orelse return;
            if (entry.state != .ready) return;

            const w: f32 = @floatFromInt(@max(entry.width, 1));
            const h: f32 = @floatFromInt(@max(entry.height, 1));
            const scale = img.scale orelse 1.0;
            const tint = img.tint orelse .{ 1.0, 1.0, 1.0, 1.0 };
            const offset = img.offset_px orelse .{ 0.0, 0.0 };
            const size = rect.size();

            if (img.mode == .tile) {
                const uv0_x = offset[0] / (w * scale);
                const uv0_y = offset[1] / (h * scale);
                const uv1_x = uv0_x + (size[0] / (w * scale));
                const uv1_y = uv0_y + (size[1] / (h * scale));
                dc.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    rect,
                    .{ uv0_x, uv0_y },
                    .{ uv1_x, uv1_y },
                    tint,
                    true,
                );
            } else {
                dc.drawImageUv(
                    draw_context.DrawContext.textureFromId(entry.texture_id),
                    rect,
                    .{ 0.0, 0.0 },
                    .{ 1.0, 1.0 },
                    tint,
                    false,
                );
            }
        },
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
        const blend_mode = ss.panel.shadow.blend orelse style_sheet.BlendMode.alpha;
        const blend: draw_context.BlendMode = if (blend_mode == .additive) .additive else .alpha;

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
        dc.drawSoftRoundedRect(draw_rect, shape_rect, r, .fill_soft, 0.0, blur, falloff_exp, shadow_color, respect_clip, blend);
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
    const tile_center = ss.panel.frame_tile_center;
    const tile_center_x = ss.panel.frame_tile_center_x;
    const tile_center_y = ss.panel.frame_tile_center_y;
    const draw_center = ss.panel.frame_draw_center;
    const tile_anchor_end = ss.panel.frame_tile_anchor_end;
    dc.drawNineSlice(
        draw_context.DrawContext.textureFromId(entry.texture_id),
        rect,
        slices,
        tint,
        draw_center,
        tile_center,
        tile_center_x,
        tile_center_y,
        tile_anchor_end,
    );

    // Optional overlay drawn only in the 9-slice interior rect.
    if (ss.panel.frame_center_overlay) |overlay| {
        const w_tex: f32 = @floatFromInt(@max(entry.width, 1));
        const h_tex: f32 = @floatFromInt(@max(entry.height, 1));
        const left_src = std.math.clamp(slices[0], 0.0, w_tex);
        const top_src = std.math.clamp(slices[1], 0.0, h_tex);
        const right_src = std.math.clamp(slices[2], 0.0, w_tex);
        const bottom_src = std.math.clamp(slices[3], 0.0, h_tex);

        const dst_w = rect.max[0] - rect.min[0];
        const dst_h = rect.max[1] - rect.min[1];
        if (dst_w <= 0.0 or dst_h <= 0.0) return;

        var left = left_src;
        var right = right_src;
        var top = top_src;
        var bottom = bottom_src;
        if (left + right > dst_w and (left + right) > 0.0001) {
            const s = dst_w / (left + right);
            left *= s;
            right *= s;
        }
        if (top + bottom > dst_h and (top + bottom) > 0.0001) {
            const s = dst_h / (top + bottom);
            top *= s;
            bottom *= s;
        }
        if (tile_center and draw_center) {
            left = @round(left);
            right = @round(right);
            top = @round(top);
            bottom = @round(bottom);
            if (left + right > dst_w) {
                const overflow = (left + right) - dst_w;
                right = @max(0.0, right - overflow);
            }
            if (top + bottom > dst_h) {
                const overflow = (top + bottom) - dst_h;
                bottom = @max(0.0, bottom - overflow);
            }
        }

        const x1 = rect.min[0] + left;
        const x2 = rect.max[0] - right;
        const y1 = rect.min[1] + top;
        const y2 = rect.max[1] - bottom;
        if (x2 - x1 <= 0.5 or y2 - y1 <= 0.5) return;

        drawPaintRect(dc, .{ .min = .{ x1, y1 }, .max = .{ x2, y2 } }, overlay);
    }
}
