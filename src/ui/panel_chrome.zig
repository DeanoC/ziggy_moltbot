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
    const t = theme.activeTheme();
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
        const blur = ss.panel.shadow.blur_px orelse 12.0;
        const spread = ss.panel.shadow.spread_px orelse 0.0;
        const offset = ss.panel.shadow.offset orelse .{ 0.0, 6.0 };
        const steps_u8 = ss.panel.shadow.steps orelse 10;
        const steps: u32 = @max(1, @min(@as(u32, steps_u8), 24));

        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const t01: f32 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(steps));
            const grow = spread + blur * t01;
            const rr = draw_context.Rect{
                .min = .{ rect.min[0] - grow + offset[0], rect.min[1] - grow + offset[1] },
                .max = .{ rect.max[0] + grow + offset[0], rect.max[1] + grow + offset[1] },
            };
            var c = shadow_color;
            const falloff = (1.0 - t01);
            c[3] *= (falloff * falloff) * 0.65;
            if (c[3] <= 0.001) continue;
            dc.drawRoundedRect(rr, radius + grow, .{ .fill = c });
        }
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

