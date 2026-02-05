const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const sessions_panel = @import("panels/sessions_panel.zig");
const cursor = @import("input/cursor.zig");

pub const ProjectsViewAction = struct {
    refresh_sessions: bool = false,
    new_session: bool = false,
    select_session: ?[]u8 = null,
    open_attachment: ?sessions_panel.AttachmentOpen = null,
    open_url: ?[]u8 = null,
};

const BadgeVariant = enum {
    primary,
    success,
    neutral,
};

const Category = struct {
    name: []const u8,
    variant: BadgeVariant = .neutral,
};

const Artifact = struct {
    name: []const u8,
    file_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

const HeaderResult = struct {
    height: f32,
    refresh: bool,
    new_project: bool,
};

const Line = struct {
    start: usize,
    end: usize,
};

var selected_project_index: ?usize = null;
var sidebar_collapsed = false;
var sidebar_width: f32 = 260.0;
var sidebar_dragging = false;
var sidebar_scroll_y: f32 = 0.0;
var sidebar_scroll_max: f32 = 0.0;
var main_scroll_y: f32 = 0.0;
var main_scroll_max: f32 = 0.0;

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext, rect_override: ?draw_context.Rect) ProjectsViewAction {
    var action = ProjectsViewAction{};
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return action;
    var ctx_draw = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer ctx_draw.deinit();

    ctx_draw.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&ctx_draw, panel_rect, queue, ctx.approvals.items.len);
    if (header.refresh) action.refresh_sessions = true;
    if (header.new_project) action.new_session = true;

    const sep_gap = t.spacing.xs;
    const sep_y = panel_rect.min[1] + header.height + sep_gap;
    const sep_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], sep_y },
        .{ panel_rect.size()[0], 1.0 },
    );
    ctx_draw.drawRect(sep_rect, .{ .fill = t.colors.divider });

    const content_top = sep_rect.max[1] + sep_gap;
    const content_height = panel_rect.max[1] - content_top;
    if (content_height <= 0.0) return action;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], content_height },
    );

    const gap = t.spacing.md;
    const collapsed_width: f32 = 48.0;
    const min_sidebar_width: f32 = 220.0;
    const min_main_width: f32 = 320.0;
    const max_sidebar_width = @max(min_sidebar_width, content_rect.size()[0] - min_main_width - gap);
    if (sidebar_collapsed) {
        sidebar_width = collapsed_width;
    } else {
        sidebar_width = std.math.clamp(sidebar_width, min_sidebar_width, max_sidebar_width);
    }
    const main_width = @max(0.0, content_rect.size()[0] - sidebar_width - gap);

    const sidebar_rect = draw_context.Rect.fromMinSize(
        content_rect.min,
        .{ sidebar_width, content_rect.size()[1] },
    );
    const main_rect = draw_context.Rect.fromMinSize(
        .{ sidebar_rect.max[0] + gap, content_rect.min[1] },
        .{ main_width, content_rect.size()[1] },
    );

    drawSidebar(allocator, ctx, &ctx_draw, sidebar_rect, queue, &action);
    handleSidebarResize(&ctx_draw, content_rect, sidebar_rect, queue, gap, min_sidebar_width, max_sidebar_width);
    if (main_width > 0.0) {
        drawMainContent(allocator, ctx, &ctx_draw, main_rect, queue, &action);
    }

    return action;
}

fn drawHeader(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    approvals_count: usize,
) HeaderResult {
    _ = approvals_count;
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = ctx.lineHeight();
    ctx.drawText("Projects Overview", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = ctx.lineHeight();
    ctx.drawText("ZiggyStarClaw", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    const button_height = subtitle_height + t.spacing.xs * 2.0;
    const buttons_y = cursor_y + subtitle_height + gap;

    const new_label = "New Project";
    const refresh_label = "Refresh";
    const new_width = buttonWidth(ctx, new_label, t);
    const refresh_width = buttonWidth(ctx, refresh_label, t);

    var cursor_x = rect.max[0] - t.spacing.md;
    cursor_x -= new_width;
    const new_rect = draw_context.Rect.fromMinSize(
        .{ cursor_x, buttons_y },
        .{ new_width, button_height },
    );
    const new_clicked = widgets.button.draw(ctx, new_rect, new_label, queue, .{
        .variant = .primary,
    });

    cursor_x -= t.spacing.xs + refresh_width;
    const refresh_rect = draw_context.Rect.fromMinSize(
        .{ cursor_x, buttons_y },
        .{ refresh_width, button_height },
    );
    const refresh_clicked = widgets.button.draw(ctx, refresh_rect, refresh_label, queue, .{
        .variant = .secondary,
    });

    const height = top_pad + title_height + gap + subtitle_height + gap + button_height + top_pad;

    return .{
        .height = height,
        .refresh = refresh_clicked,
        .new_project = new_clicked,
    };
}

fn drawSidebar(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *ProjectsViewAction,
) void {
    const t = theme.activeTheme();
    dc.drawRect(rect, .{ .fill = t.colors.surface, .stroke = t.colors.border });

    const padding = t.spacing.sm;
    const line_height = dc.lineHeight();
    const toggle_size = line_height + t.spacing.xs * 2.0;

    const toggle_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - padding - toggle_size, rect.min[1] + padding },
        .{ toggle_size, toggle_size },
    );
    const toggle_label = if (sidebar_collapsed) ">" else "<";
    if (widgets.button.draw(dc, toggle_rect, toggle_label, queue, .{ .variant = .ghost })) {
        sidebar_collapsed = !sidebar_collapsed;
    }

    if (sidebar_collapsed) {
        const label = if (rect.size()[0] > 60.0) "Projects" else "Proj";
        dc.drawText(label, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_secondary });
        return;
    }

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("My Projects", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.xs;

    const new_label = "+ New Project";
    const button_height = line_height + t.spacing.xs * 2.0;
    const new_width = buttonWidth(dc, new_label, t);
    const new_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ new_width, button_height },
    );
    if (widgets.button.draw(dc, new_rect, new_label, queue, .{
        .variant = .primary,
        .disabled = ctx.sessions_loading,
    })) {
        action.new_session = true;
    }
    cursor_y += button_height + t.spacing.xs;

    if (ctx.sessions_loading) {
        const badge_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            badgeSize(dc, "Loading", t),
        );
        drawBadge(dc, badge_rect, "Loading", .primary);
        cursor_y += badge_rect.size()[1] + t.spacing.xs;
    }

    const list_top = cursor_y + t.spacing.xs;
    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, list_top },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - padding - list_top },
    );

    drawProjectList(allocator, ctx, dc, list_rect, queue, action);
}

fn handleSidebarResize(
    dc: *draw_context.DrawContext,
    content_rect: draw_context.Rect,
    sidebar_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    gap: f32,
    min_sidebar_width: f32,
    max_sidebar_width: f32,
) void {
    if (sidebar_collapsed) return;
    const t = theme.activeTheme();
    const divider_w: f32 = 6.0;
    const divider_rect = draw_context.Rect.fromMinSize(
        .{ sidebar_rect.max[0] + gap * 0.5 - divider_w * 0.5, content_rect.min[1] },
        .{ divider_w, content_rect.size()[1] },
    );

    const hover = divider_rect.contains(queue.state.mouse_pos);
    if (hover) {
        cursor.set(.resize_ew);
    }

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and divider_rect.contains(md.pos)) {
                    sidebar_dragging = true;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    sidebar_dragging = false;
                }
            },
            else => {},
        }
    }

    if (sidebar_dragging) {
        const target = queue.state.mouse_pos[0] - content_rect.min[0];
        sidebar_width = std.math.clamp(target, min_sidebar_width, max_sidebar_width);
    }

    // Draw a subtle divider so it’s easy to hit.
    const divider = draw_context.Rect.fromMinSize(
        .{ sidebar_rect.max[0] + gap * 0.5 - 1.0, content_rect.min[1] },
        .{ 2.0, content_rect.size()[1] },
    );
    const alpha: f32 = if (hover or sidebar_dragging) 0.25 else 0.12;
    const line_color = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], alpha };
    dc.drawRect(divider, .{ .fill = line_color });
}

fn drawProjectList(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *ProjectsViewAction,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    const line_height = dc.lineHeight();
    const row_height = line_height + t.spacing.xs * 2.0;
    const row_gap = t.spacing.xs;
    const content_height = @as(f32, @floatFromInt(ctx.sessions.items.len)) * (row_height + row_gap);
    sidebar_scroll_max = @max(0.0, content_height - rect.size()[1]);

    handleWheelScroll(queue, rect, &sidebar_scroll_y, sidebar_scroll_max, 28.0);

    if (ctx.sessions.items.len == 0) {
        dc.drawText("No projects available.", rect.min, .{ .color = t.colors.text_secondary });
        return;
    }

    const active_index = resolveSelectedIndex(ctx);

    dc.pushClip(rect);
    var y = rect.min[1] - sidebar_scroll_y;
    for (ctx.sessions.items, 0..) |session, idx| {
        const row_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0], y },
            .{ rect.size()[0], row_height },
        );
        if (row_rect.max[1] >= rect.min[1] and row_rect.min[1] <= rect.max[1]) {
            const name = displayName(session);
            const is_active = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key);
            const selected = active_index != null and active_index.? == idx;
            if (drawProjectRow(dc, row_rect, name, is_active, selected, queue)) {
                selected_project_index = idx;
                action.select_session = allocator.dupe(u8, session.key) catch null;
            }
        }
        y += row_height + row_gap;
    }
    dc.popClip();
}

fn drawProjectRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    active: bool,
    selected: bool,
    queue: *input_state.InputQueue,
) bool {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);
    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    clicked = true;
                }
            },
            else => {},
        }
    }

    if (selected or hovered) {
        const base = if (selected) t.colors.primary else t.colors.surface;
        const alpha: f32 = if (selected) 0.12 else 0.08;
        dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(base, alpha) });
    }

    const icon_size = rect.size()[1] - t.spacing.xs * 2.0;
    const icon_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs },
        .{ icon_size, icon_size },
    );
    dc.drawRoundedRect(icon_rect, 3.0, .{ .fill = colors.withAlpha(t.colors.primary, 0.2) });

    const text_pos = .{ icon_rect.max[0] + t.spacing.sm, rect.min[1] + t.spacing.xs };
    dc.drawText(label, text_pos, .{ .color = t.colors.text_primary });

    if (active) {
        const badge = badgeSize(dc, "active", t);
        const badge_rect = draw_context.Rect.fromMinSize(
            .{ rect.max[0] - badge[0] - t.spacing.sm, rect.min[1] + (rect.size()[1] - badge[1]) * 0.5 },
            badge,
        );
        drawBadge(dc, badge_rect, "active", .success);
    }

    return clicked;
}

fn drawMainContent(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *ProjectsViewAction,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    handleWheelScroll(queue, rect, &main_scroll_y, main_scroll_max, 40.0);

    const padding = t.spacing.md;
    const start_x = rect.min[0] + padding;
    const content_width = rect.size()[0] - padding * 2.0;

    dc.pushClip(rect);
    var cursor_y = rect.min[1] + padding - main_scroll_y;

    const selected_index = resolveSelectedIndex(ctx);
    if (selected_index == null) {
        dc.drawText("Create or select a project to see details.", .{ start_x, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += dc.lineHeight();
    } else {
        const session = ctx.sessions.items[selected_index.?];
        const messages = messagesForSession(ctx, session.key);
        var previews_buf: [12]sessions_panel.AttachmentOpen = undefined;
        const previews = collectAttachmentPreviews(messages, &previews_buf);
        var artifacts_buf: [6]Artifact = undefined;
        const artifacts = previewsToArtifacts(previews, &artifacts_buf);

        theme.push(.title);
        const title_height = dc.lineHeight();
        dc.drawText("Welcome back!", .{ start_x, cursor_y }, .{ .color = t.colors.text_primary });
        theme.pop();
        cursor_y += title_height + t.spacing.xs;

        dc.drawText("Here's a snapshot of your active project workspace.", .{ start_x, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += dc.lineHeight() + t.spacing.md;

        var categories_buf: [3]Category = undefined;
        var categories_len: usize = 0;
        if (session.kind) |kind| {
            categories_buf[categories_len] = .{ .name = kind, .variant = .primary };
            categories_len += 1;
        }
        if (ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key)) {
            categories_buf[categories_len] = .{ .name = "active", .variant = .success };
            categories_len += 1;
        }

        const card_height = drawProjectSummaryCard(
            allocator,
            dc,
            .{ start_x, cursor_y },
            content_width,
            displayName(session),
            session.label orelse session.kind,
            categories_buf[0..categories_len],
            artifacts,
        );
        cursor_y += card_height + t.spacing.md;

        const categories_height = drawCategoriesCard(dc, .{ start_x, cursor_y }, content_width);
        cursor_y += categories_height + t.spacing.md;

        const artifacts_height = drawArtifactsCard(
            allocator,
            dc,
            .{ start_x, cursor_y },
            content_width,
            previews,
            queue,
            action,
        );
        cursor_y += artifacts_height + padding;
    }

    dc.popClip();

    const content_height = (cursor_y + main_scroll_y) - (rect.min[1] + padding);
    main_scroll_max = @max(0.0, content_height - rect.size()[1]);
    if (main_scroll_y > main_scroll_max) main_scroll_y = main_scroll_max;
    if (main_scroll_y < 0.0) main_scroll_y = 0.0;
}

fn drawProjectSummaryCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    name: []const u8,
    description: ?[]const u8,
    categories: []const Category,
    artifacts: []const Artifact,
) f32 {
    _ = artifacts;
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const inner_width = @max(0.0, width - padding * 2.0);

    theme.push(.heading);
    const title_height = dc.lineHeight();
    theme.pop();

    var desc_height: f32 = 0.0;
    if (description) |desc| {
        desc_height = measureWrappedTextHeight(allocator, dc, desc, inner_width);
    }

    const badge_line_height = badgeLineHeight(dc, t);

    var card_height = padding * 2.0 + title_height;
    if (desc_height > 0.0) card_height += t.spacing.xs + desc_height;
    if (categories.len > 0) card_height += t.spacing.xs + badge_line_height;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText(name, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height;

    if (description) |desc| {
        cursor_y += t.spacing.xs;
        _ = drawWrappedText(allocator, dc, desc, .{ rect.min[0] + padding, cursor_y }, inner_width, t.colors.text_secondary);
        cursor_y += desc_height;
    }

    if (categories.len > 0) {
        cursor_y += t.spacing.xs;
        drawBadgeRow(dc, .{ rect.min[0] + padding, cursor_y }, inner_width, categories);
    }

    return card_height;
}

fn drawCategoriesCard(
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    theme.push(.heading);
    const title_height = dc.lineHeight();
    theme.pop();
    const mini_height: f32 = 86.0;
    const card_height = padding * 2.0 + title_height + t.spacing.sm + mini_height;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Categories", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height + t.spacing.sm;

    const gap = t.spacing.sm;
    const mini_width = (width - padding * 2.0 - gap) / 2.0;
    const left_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ mini_width, mini_height },
    );
    const right_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap, cursor_y },
        .{ mini_width, mini_height },
    );

    dc.drawRoundedRect(left_rect, t.radius.md, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });
    dc.drawRoundedRect(right_rect, t.radius.md, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    theme.push(.heading);
    dc.drawText("Marketing Analysis", .{ left_rect.min[0] + padding, left_rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();
    const badge_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.min[0] + padding, left_rect.min[1] + padding + title_height + t.spacing.xs },
        badgeSize(dc, "active", t),
    );
    drawBadge(dc, badge_rect, "active", .primary);

    theme.push(.heading);
    dc.drawText("Design Concepts", .{ right_rect.min[0] + padding, right_rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();
    const badge2_rect = draw_context.Rect.fromMinSize(
        .{ right_rect.min[0] + padding, right_rect.min[1] + padding + title_height + t.spacing.xs },
        badgeSize(dc, "draft", t),
    );
    drawBadge(dc, badge2_rect, "draft", .neutral);

    return card_height;
}

fn drawArtifactsCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    previews: []const sessions_panel.AttachmentOpen,
    queue: *input_state.InputQueue,
    action: *ProjectsViewAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    theme.push(.heading);
    const title_height = dc.lineHeight();
    theme.pop();
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const row_spacing = t.spacing.sm;

    var body_height: f32 = 0.0;
    if (previews.len == 0) {
        body_height = line_height + t.spacing.sm;
    } else {
        body_height = @as(f32, @floatFromInt(previews.len)) * (line_height + button_height + row_spacing * 2.0);
    }

    const card_height = padding * 2.0 + title_height + t.spacing.sm + body_height;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Recent Artifacts", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height + t.spacing.sm;

    if (previews.len == 0) {
        dc.drawText("No artifacts generated yet.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        return card_height;
    }

    for (previews, 0..) |preview, idx| {
        _ = idx;
        const name = preview.name;
        dc.drawText(name, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
        cursor_y += line_height + t.spacing.xs;

        const open_label = "Open in Editor";
        const open_width = buttonWidth(dc, open_label, t);
        const open_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ open_width, button_height },
        );
        if (widgets.button.draw(dc, open_rect, open_label, queue, .{ .variant = .secondary })) {
            action.open_attachment = preview;
        }

        if (isHttpUrl(preview.url)) {
            const url_label = "Open URL";
            const url_width = buttonWidth(dc, url_label, t);
            const url_rect = draw_context.Rect.fromMinSize(
                .{ open_rect.max[0] + t.spacing.sm, cursor_y },
                .{ url_width, button_height },
            );
            if (widgets.button.draw(dc, url_rect, url_label, queue, .{ .variant = .ghost })) {
                action.open_url = allocator.dupe(u8, preview.url) catch null;
            }
        }
        cursor_y += button_height + row_spacing;
    }

    return card_height;
}

fn handleWheelScroll(
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    scroll_y: *f32,
    max_scroll: f32,
    step: f32,
) void {
    if (max_scroll <= 0.0) {
        scroll_y.* = 0.0;
        return;
    }
    if (!rect.contains(queue.state.mouse_pos)) return;
    for (queue.events.items) |evt| {
        if (evt == .mouse_wheel) {
            const delta = evt.mouse_wheel.delta[1];
            scroll_y.* -= delta * step;
        }
    }
    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
    if (scroll_y.* > max_scroll) scroll_y.* = max_scroll;
}

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn badgeLineHeight(dc: *draw_context.DrawContext, t: *const theme.Theme) f32 {
    const line_height = dc.lineHeight();
    return line_height + t.spacing.xs;
}

fn badgeSize(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) [2]f32 {
    const text_size = ctx.measureText(label, 0.0);
    return .{ text_size[0] + t.spacing.xs * 2.0, text_size[1] + t.spacing.xs };
}

fn drawBadge(dc: *draw_context.DrawContext, rect: draw_context.Rect, label: []const u8, variant: BadgeVariant) void {
    const t = theme.activeTheme();
    const colorset = badgeColors(t, variant);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = colorset.fill, .stroke = colorset.border, .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs * 0.5 }, .{ .color = colorset.text });
}

fn drawBadgeRow(
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    width: f32,
    categories: []const Category,
) void {
    const t = theme.activeTheme();
    var cursor_x = pos[0];
    const max_x = pos[0] + width;
    for (categories) |category| {
        const size = badgeSize(dc, category.name, t);
        if (cursor_x + size[0] > max_x) break;
        const rect = draw_context.Rect.fromMinSize(.{ cursor_x, pos[1] }, size);
        drawBadge(dc, rect, category.name, category.variant);
        cursor_x += size[0] + t.spacing.xs;
    }
}

fn badgeColors(t: *const theme.Theme, variant: BadgeVariant) struct { fill: colors.Color, border: colors.Color, text: colors.Color } {
    const base = switch (variant) {
        .primary => t.colors.primary,
        .success => t.colors.success,
        .neutral => t.colors.text_secondary,
    };
    return .{
        .fill = colors.withAlpha(base, 0.18),
        .border = colors.withAlpha(base, 0.4),
        .text = base,
    };
}

fn drawWrappedText(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    pos: [2]f32,
    wrap_width: f32,
    color: colors.Color,
) f32 {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, wrap_width, &lines);

    var y = pos[1];
    const line_height = dc.lineHeight();
    for (lines.items) |line| {
        const slice = text[line.start..line.end];
        if (slice.len > 0) {
            dc.drawText(slice, .{ pos[0], y }, .{ .color = color });
        }
        y += line_height;
    }
    return y - pos[1];
}

fn measureWrappedTextHeight(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
) f32 {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, wrap_width, &lines);
    return @as(f32, @floatFromInt(lines.items.len)) * dc.lineHeight();
}

fn buildLinesInto(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
    lines: *std.ArrayList(Line),
) void {
    lines.clearRetainingCapacity();
    const effective_wrap = if (wrap_width <= 1.0) 10_000.0 else wrap_width;
    var line_start: usize = 0;
    var line_width: f32 = 0.0;
    var last_space: ?usize = null;
    var index: usize = 0;

    while (index < text.len) {
        const ch = text[index];
        if (ch == '\n') {
            _ = lines.append(allocator, .{ .start = line_start, .end = index }) catch {};
            index += 1;
            line_start = index;
            line_width = 0.0;
            last_space = null;
            continue;
        }

        const next = nextCharIndex(text, index);
        const slice = text[index..next];
        const char_w = dc.measureText(slice, 0.0)[0];

        if (ch == ' ' or ch == '\t') {
            last_space = next;
        }

        if (line_width + char_w > effective_wrap and line_width > 0.0) {
            if (last_space != null and last_space.? > line_start) {
                _ = lines.append(allocator, .{ .start = line_start, .end = last_space.? - 1 }) catch {};
                index = last_space.?;
            } else {
                _ = lines.append(allocator, .{ .start = line_start, .end = index }) catch {};
            }
            line_start = index;
            line_width = 0.0;
            last_space = null;
            continue;
        }

        line_width += char_w;
        index = next;
    }

    _ = lines.append(allocator, .{ .start = line_start, .end = text.len }) catch {};
}

fn nextCharIndex(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const first = text[index];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const next = index + @as(usize, len);
    return if (next > text.len) text.len else next;
}

fn resolveSelectedIndex(ctx: *state.ClientContext) ?usize {
    if (ctx.sessions.items.len == 0) {
        selected_project_index = null;
        return null;
    }
    if (selected_project_index) |idx| {
        if (idx < ctx.sessions.items.len) return idx;
        selected_project_index = null;
    }
    if (ctx.current_session) |key| {
        if (findSessionIndex(ctx.sessions.items, key)) |index| {
            selected_project_index = index;
            return index;
        }
    }
    selected_project_index = 0;
    return 0;
}

fn findSessionIndex(sessions: []const types.Session, key: []const u8) ?usize {
    for (sessions, 0..) |session, idx| {
        if (std.mem.eql(u8, session.key, key)) return idx;
    }
    return null;
}

fn messagesForSession(ctx: *state.ClientContext, session_key: []const u8) []const types.ChatMessage {
    if (ctx.findSessionState(session_key)) |session_state| {
        return session_state.messages.items;
    }
    return &[_]types.ChatMessage{};
}

fn displayName(session: types.Session) []const u8 {
    return session.display_name orelse session.label orelse session.key;
}

fn previewsToArtifacts(
    previews: []const sessions_panel.AttachmentOpen,
    buf: []Artifact,
) []Artifact {
    const count = @min(previews.len, buf.len);
    for (previews[0..count], 0..) |preview, idx| {
        buf[idx] = .{
            .name = preview.name,
            .file_type = preview.kind,
            .status = preview.role,
        };
    }
    return buf[0..count];
}

fn collectAttachmentPreviews(
    messages: []const types.ChatMessage,
    buf: []sessions_panel.AttachmentOpen,
) []sessions_panel.AttachmentOpen {
    var len: usize = 0;
    var index: usize = messages.len;
    while (index > 0 and len < buf.len) : (index -= 1) {
        const message = messages[index - 1];
        if (message.attachments) |attachments| {
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                const name = attachment.name orelse attachment.url;
                buf[len] = .{
                    .name = name,
                    .kind = attachment.kind,
                    .url = attachment.url,
                    .role = message.role,
                    .timestamp = message.timestamp,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}
