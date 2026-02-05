const std = @import("std");
const components = @import("../components/components.zig");
const draw_context = @import("../draw_context.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets/widgets.zig");

var draw_ctx_toggle = false;
var scroll_y: f32 = 0.0;
var scroll_max: f32 = 0.0;

pub fn draw(rect_override: ?draw_context.Rect) void {
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return;
    var dc = draw_context.DrawContext.init(
        std.heap.page_allocator,
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
        std.heap.page_allocator,
        &dc,
        project_args,
        project_width,
    );
    const project_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, project_height });
    components.composite.project_card.draw(
        std.heap.page_allocator,
        &dc,
        project_rect,
        project_args,
    );
    cursor_y += project_height + t.spacing.md;

    const source_height = @max(220.0, @min(360.0, content_rect.size()[1] * 0.35));
    const source_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, source_height });
    _ = components.composite.source_browser.draw(std.heap.page_allocator, .{
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
        std.heap.page_allocator,
        &dc,
        task_args,
        project_width,
    );
    const task_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, task_height });
    _ = components.composite.task_progress.draw(
        std.heap.page_allocator,
        &dc,
        task_rect,
        queue,
        task_args,
    );
    cursor_y += task_height + t.spacing.md;

    const demo_height = drawContextDemoCard(&dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t);
    cursor_y += demo_height + t.spacing.md;

    dc.popClip();

    const content_height = (cursor_y + scroll_y) - content_rect.min[1];
    scroll_max = @max(0.0, content_height - content_rect.size()[1]);
    if (scroll_y > scroll_max) scroll_y = scroll_max;
    if (scroll_y < 0.0) scroll_y = 0.0;
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

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
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
