const std = @import("std");

const draw_context = @import("draw_context.zig");
const image_cache = @import("image_cache.zig");
const theme_runtime = @import("theme_engine/runtime.zig");
const style_sheet = @import("theme_engine/style_sheet.zig");

fn paintOrSolid(p: ?style_sheet.Paint, fallback: draw_context.Color) style_sheet.Paint {
    return p orelse style_sheet.Paint{ .solid = fallback };
}

fn drawPaintRect(dc: *draw_context.DrawContext, rect: draw_context.Rect, paint: style_sheet.Paint) void {
    const t = dc.theme;
    switch (paint) {
        .solid => |c| dc.drawRect(rect, .{ .fill = c }),
        .gradient4 => |g| dc.drawRectGradient(rect, .{
            .tl = g.tl,
            .tr = g.tr,
            .bl = g.bl,
            .br = g.br,
        }),
        .image => |img| {
            if (!img.path.isSet()) {
                // Best-effort fallback.
                dc.drawRect(rect, .{ .fill = t.colors.background });
                return;
            }
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

pub fn drawBackground(dc: *draw_context.DrawContext, rect: draw_context.Rect) void {
    const ss = theme_runtime.getStyleSheet();
    const paint = paintOrSolid(ss.surfaces.background, dc.theme.colors.background);
    drawPaintRect(dc, rect, paint);
}

pub fn drawSurface(dc: *draw_context.DrawContext, rect: draw_context.Rect) void {
    const ss = theme_runtime.getStyleSheet();
    const paint = paintOrSolid(ss.surfaces.surface, dc.theme.colors.surface);
    drawPaintRect(dc, rect, paint);
}

pub fn drawMenuBar(dc: *draw_context.DrawContext, rect: draw_context.Rect) void {
    const ss = theme_runtime.getStyleSheet();
    const paint = paintOrSolid(ss.surfaces.menu_bar orelse ss.surfaces.surface, dc.theme.colors.surface);
    drawPaintRect(dc, rect, paint);
}

pub fn drawStatusBar(dc: *draw_context.DrawContext, rect: draw_context.Rect) void {
    const ss = theme_runtime.getStyleSheet();
    const paint = paintOrSolid(ss.surfaces.status_bar orelse ss.surfaces.surface, dc.theme.colors.surface);
    drawPaintRect(dc, rect, paint);
}
