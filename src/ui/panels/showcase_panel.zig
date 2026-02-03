const std = @import("std");
const zgui = @import("zgui");
const components = @import("../components/components.zig");
const draw_context = @import("../draw_context.zig");
const theme = @import("../theme.zig");

var draw_ctx_toggle = false;

pub fn draw() void {
    const t = theme.activeTheme();

    if (components.layout.scroll_area.begin(.{ .id = "ShowcaseScroll", .border = false })) {
        components.composite.project_card.draw(.{
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
        });

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        _ = components.composite.source_browser.draw(.{
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
        });

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        _ = components.composite.task_progress.draw(.{
            .title = "Build Pipeline",
            .steps = &[_]components.composite.task_progress.Step{
                .{ .label = "Plan", .state = .complete },
                .{ .label = "Build", .state = .active },
                .{ .label = "Ship", .state = .pending },
            },
            .detail = "Compiling UI assets and validating layout rules.",
            .show_logs_button = true,
        });

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });
        if (components.layout.card.begin(.{ .title = "Draw Context Demo", .id = "draw_ctx_demo" })) {
            const cursor = zgui.getCursorScreenPos();
            const size = .{ 180.0, 40.0 };
            const rect = draw_context.Rect.fromMinSize(cursor, size);
            var ctx = draw_context.DrawContext.init(
                std.heap.page_allocator,
                .{ .imgui = .{} },
                t,
                rect,
            );
            defer ctx.deinit();
            if (components.core.rect_button.draw(&ctx, rect, "Context Button", .{
                .variant = if (draw_ctx_toggle) .success else .primary,
            })) {
                draw_ctx_toggle = !draw_ctx_toggle;
            }
            zgui.dummy(.{ .w = size[0], .h = size[1] });
            zgui.textDisabled("State: {s}", .{if (draw_ctx_toggle) "on" else "off"});
        }
        components.layout.card.end();
    }
    components.layout.scroll_area.end();
}
