const std = @import("std");
const components = @import("../components/components.zig");
const draw_context = @import("../draw_context.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets/widgets.zig");
const panel_chrome = @import("../panel_chrome.zig");

var draw_ctx_toggle = false;
var sdf_debug_enabled = false;
var scroll_y: f32 = 0.0;
var scroll_max: f32 = 0.0;

pub fn draw(allocator: std.mem.Allocator, rect_override: ?draw_context.Rect) void {
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return;
    var dc = draw_context.DrawContext.init(
        allocator,
        .{ .direct = .{} },
        t,
        panel_rect,
    );
    defer dc.deinit();
    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const padding = t.spacing.md;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0] + padding, panel_rect.min[1] + padding },
        .{ panel_rect.size()[0] - padding * 2.0, panel_rect.size()[1] - padding * 2.0 },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) {
        return;
    }

    handleWheelScroll(queue, panel_rect, &scroll_y, scroll_max, 36.0);

    dc.pushClip(content_rect);
    var cursor_y = content_rect.min[1] - scroll_y;

    const project_args = components.composite.project_card.Args{
        .id = "showcase_project",
        .name = "Ziggy Starclaw",
        .description = "Major UI redesign milestone",
        .categories = &[_]components.composite.project_card.Category{
            .{ .name = "desktop", .variant = .primary },
            .{ .name = "release", .variant = .success },
        },
        .recent_artifacts = &[_]components.composite.project_card.Artifact{
            .{ .name = "ui_layout.zig", .file_type = "zig", .status = "edited" },
            .{ .name = "theme_tokens.json", .file_type = "json", .status = "synced" },
            .{ .name = "wireframe.png", .file_type = "image", .status = "exported" },
        },
    };
    const project_width = content_rect.size()[0];
    const project_height = components.composite.project_card.measureHeight(
        allocator,
        &dc,
        project_args,
        project_width,
    );
    const project_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, project_height });
    components.composite.project_card.draw(
        allocator,
        &dc,
        project_rect,
        project_args,
    );
    cursor_y += project_height + t.spacing.md;

    const source_height = @max(220.0, @min(360.0, content_rect.size()[1] * 0.35));
    const source_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, source_height });
    _ = components.composite.source_browser.draw(allocator, &dc, .{
        .id = "showcase_source",
        .sources = &[_]components.composite.source_browser.Source{
            .{ .name = "Local Workspace", .source_type = .local, .connected = true },
            .{ .name = "Design Repo", .source_type = .git, .connected = true },
            .{ .name = "Cloud Backup", .source_type = .cloud, .connected = false },
        },
        .selected_source = 0,
        .current_path = "/ui/components",
        .files = &[_]components.composite.source_browser.FileEntry{
            .{ .name = "project_card.zig", .language = "zig", .status = "modified", .dirty = true },
            .{ .name = "source_browser.zig", .language = "zig", .status = "synced", .dirty = false },
            .{ .name = "layout.md", .language = "md", .status = "review", .dirty = false },
        },
        .rect = source_rect,
    });
    cursor_y += source_height + t.spacing.md;

    const task_args = components.composite.task_progress.Args{
        .title = "Build Pipeline",
        .steps = &[_]components.composite.task_progress.Step{
            .{ .label = "Plan", .state = .complete },
            .{ .label = "Build", .state = .active },
            .{ .label = "Ship", .state = .pending },
        },
        .detail = "Compiling UI assets and validating layout rules.",
        .show_logs_button = true,
    };
    const task_height = components.composite.task_progress.measureHeight(
        allocator,
        &dc,
        task_args,
        project_width,
    );
    const task_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, task_height });
    _ = components.composite.task_progress.draw(
        allocator,
        &dc,
        task_rect,
        queue,
        task_args,
    );
    cursor_y += task_height + t.spacing.md;

    const demo_height = drawContextDemoCard(&dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t);
    cursor_y += demo_height + t.spacing.md;

    const sdf_height = sdfDebugCard(&dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t);
    cursor_y += sdf_height + t.spacing.md;

    dc.popClip();

    const content_height = (cursor_y + scroll_y) - content_rect.min[1];
    scroll_max = @max(0.0, content_height - content_rect.size()[1]);
    if (scroll_y > scroll_max) scroll_y = scroll_max;
    if (scroll_y < 0.0) scroll_y = 0.0;
}

fn sdfDebugCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    t: *const theme.Theme,
) f32 {
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const toggle_height = line_height + t.spacing.xs * 2.0;
    const demo_h: f32 = 220.0;
    const content_height = toggle_height + t.spacing.sm + (if (sdf_debug_enabled) demo_h else 0.0);
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "SDF Effects Lab");
    const left = rect.min[0] + padding;

    var enabled = sdf_debug_enabled;
    _ = widgets.checkbox.draw(
        dc,
        draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ rect.size()[0] - padding * 2.0, toggle_height }),
        "Show SDF debug shapes",
        &enabled,
        queue,
        .{},
    );
    sdf_debug_enabled = enabled;
    cursor_y += toggle_height + t.spacing.sm;

    if (!sdf_debug_enabled) return height;

    const demo_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ rect.size()[0] - padding * 2.0, demo_h });
    drawSdfDemos(dc, demo_rect, t);
    return height;
}

fn drawSdfDemos(dc: *draw_context.DrawContext, rect: draw_context.Rect, t: *const theme.Theme) void {
    // Background for the demo area.
    panel_chrome.draw(dc, rect, .{
        .radius = t.radius.md,
        .draw_shadow = false,
        .draw_frame = false,
    });

    const pad = t.spacing.md;
    const col_w = (rect.size()[0] - pad) * 0.5;
    const row_h = (rect.size()[1] - pad) * 0.5;
    const a = draw_context.Rect.fromMinSize(.{ rect.min[0] + pad, rect.min[1] + pad }, .{ col_w - pad, row_h - pad });
    const b = draw_context.Rect.fromMinSize(.{ rect.min[0] + col_w + pad, rect.min[1] + pad }, .{ col_w - pad, row_h - pad });
    const c = draw_context.Rect.fromMinSize(.{ rect.min[0] + pad, rect.min[1] + row_h + pad }, .{ col_w - pad, row_h - pad });
    const d = draw_context.Rect.fromMinSize(.{ rect.min[0] + col_w + pad, rect.min[1] + row_h + pad }, .{ col_w - pad, row_h - pad });

    // 1) Soft shadow
    {
        const base = draw_context.Rect.fromMinSize(.{ a.min[0] + 10, a.min[1] + 18 }, .{ a.size()[0] - 20, a.size()[1] - 36 });
        const draw_rect = draw_context.Rect{
            .min = .{ base.min[0] - 24, base.min[1] - 24 },
            .max = .{ base.max[0] + 24, base.max[1] + 24 },
        };
        dc.drawSoftRoundedRect(draw_rect, base, 10.0, .fill_soft, 0.0, 18.0, 1.0, .{ 0, 0, 0, 0.55 }, true);
        dc.drawRoundedRect(base, 10.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawText("shadow (soft fill)", .{ a.min[0] + 10, a.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }

    // 2) Glow stroke
    {
        const base = draw_context.Rect.fromMinSize(.{ b.min[0] + 10, b.min[1] + 18 }, .{ b.size()[0] - 20, b.size()[1] - 36 });
        const draw_rect = draw_context.Rect{
            .min = .{ base.min[0] - 26, base.min[1] - 26 },
            .max = .{ base.max[0] + 26, base.max[1] + 26 },
        };
        dc.drawSoftRoundedRect(draw_rect, base, 12.0, .stroke_soft, 10.0, 16.0, 1.0, .{ t.colors.primary[0], t.colors.primary[1], t.colors.primary[2], 0.9 }, true);
        dc.drawRoundedRect(base, 12.0, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawText("glow (soft stroke)", .{ b.min[0] + 10, b.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }

    // 3) Falloff exponent (alpha curve)
    {
        const left_w = (c.size()[0] - 30) * 0.5;
        const base0 = draw_context.Rect.fromMinSize(.{ c.min[0] + 10, c.min[1] + 18 }, .{ left_w, c.size()[1] - 36 });
        const base1 = draw_context.Rect.fromMinSize(.{ base0.max[0] + 10, c.min[1] + 18 }, .{ left_w, c.size()[1] - 36 });
        const blur: f32 = 18.0;
        const draw0 = draw_context.Rect{ .min = .{ base0.min[0] - 26, base0.min[1] - 26 }, .max = .{ base0.max[0] + 26, base0.max[1] + 26 } };
        const draw1 = draw_context.Rect{ .min = .{ base1.min[0] - 26, base1.min[1] - 26 }, .max = .{ base1.max[0] + 26, base1.max[1] + 26 } };
        dc.drawSoftRoundedRect(draw0, base0, 14.0, .fill_soft, 0.0, blur, 0.6, .{ 0, 0, 0, 0.45 }, true);
        dc.drawSoftRoundedRect(draw1, base1, 14.0, .fill_soft, 0.0, blur, 2.4, .{ 0, 0, 0, 0.45 }, true);
        dc.drawRoundedRect(base0, 14.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawRoundedRect(base1, 14.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawText("falloff exp: 0.6 | 2.4", .{ c.min[0] + 10, c.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }

    // 4) Clip stack behavior (respect vs ignore)
    {
        const clip_rect = draw_context.Rect.fromMinSize(.{ d.min[0] + 10, d.min[1] + 18 }, .{ d.size()[0] - 20, d.size()[1] - 36 });
        dc.drawRoundedRect(clip_rect, 12.0, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

        const base = draw_context.Rect.fromMinSize(.{ clip_rect.min[0] + 10, clip_rect.min[1] + 10 }, .{ clip_rect.size()[0] * 0.75, clip_rect.size()[1] * 0.55 });
        const draw_rect = draw_context.Rect{
            .min = .{ base.min[0] - 32, base.min[1] - 32 },
            .max = .{ base.max[0] + 32, base.max[1] + 32 },
        };

        // A) Respect clip
        dc.pushClip(clip_rect);
        dc.drawSoftRoundedRect(draw_rect, base, 12.0, .fill_soft, 0.0, 22.0, 1.0, .{ 0, 0, 0, 0.55 }, true);
        dc.drawRoundedRect(base, 12.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.popClip();

        // B) Ignore clip (draws outside the clip_rect)
        const base2 = draw_context.Rect.fromMinSize(.{ base.min[0] + 18, base.min[1] + 34 }, .{ base.size()[0], base.size()[1] });
        const draw_rect2 = draw_context.Rect{
            .min = .{ base2.min[0] - 32, base2.min[1] - 32 },
            .max = .{ base2.max[0] + 32, base2.max[1] + 32 },
        };
        dc.pushClip(clip_rect);
        dc.drawSoftRoundedRect(draw_rect2, base2, 12.0, .fill_soft, 0.0, 22.0, 1.0, .{ 0, 0, 0, 0.45 }, false);
        dc.drawRoundedRect(base2, 12.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.popClip();

        dc.drawText("clip: respect | ignore", .{ d.min[0] + 10, d.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }
}

fn drawContextDemoCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    t: *const theme.Theme,
) f32 {
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const button_label = "Context Button";
    const button_width = buttonWidth(dc, button_label, t);
    const content_height = button_height + t.spacing.sm + line_height;
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Draw Context Demo");
    const left = rect.min[0] + padding;
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ button_width, button_height }), button_label, queue, .{
        .variant = if (draw_ctx_toggle) .primary else .secondary,
    })) {
        draw_ctx_toggle = !draw_ctx_toggle;
    }
    cursor_y += button_height + t.spacing.sm;
    dc.drawText("State: ", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    const state_offset = dc.measureText("State: ", 0.0)[0];
    dc.drawText(if (draw_ctx_toggle) "on" else "off", .{ left + state_offset, cursor_y }, .{ .color = t.colors.text_primary });
    return height;
}

fn drawCardBase(dc: *draw_context.DrawContext, rect: draw_context.Rect, title: []const u8) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();

    panel_chrome.draw(dc, rect, .{
        .radius = t.radius.md,
        .draw_shadow = true,
        .draw_frame = false,
    });
    theme.push(.heading);
    dc.drawText(title, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();

    return rect.min[1] + padding + line_height + t.spacing.xs;
}

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn handleWheelScroll(
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    scroll_value: *f32,
    max_scroll: f32,
    step: f32,
) void {
    if (max_scroll <= 0.0) {
        scroll_value.* = 0.0;
        return;
    }
    if (!rect.contains(queue.state.mouse_pos)) return;
    for (queue.events.items) |evt| {
        if (evt == .mouse_wheel) {
            const delta = evt.mouse_wheel.delta[1];
            scroll_value.* -= delta * step;
        }
    }
    if (scroll_value.* < 0.0) scroll_value.* = 0.0;
    if (scroll_value.* > max_scroll) scroll_value.* = max_scroll;
}
