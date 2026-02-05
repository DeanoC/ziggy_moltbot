const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const components = @import("components/components.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const sessions_panel = @import("panels/sessions_panel.zig");
const cursor = @import("input/cursor.zig");

const source_browser = components.composite.source_browser;

pub const SourcesViewAction = struct {
    select_session: ?[]u8 = null,
    open_attachment: ?sessions_panel.AttachmentOpen = null,
    open_url: ?[]u8 = null,
};

const Line = struct {
    start: usize,
    end: usize,
};

var selected_source_index: ?usize = null;
var selected_file_index: ?usize = null;
var split_width: f32 = 240.0;
var split_dragging = false;
var sources_scroll_y: f32 = 0.0;
var sources_scroll_max: f32 = 0.0;
var files_scroll_y: f32 = 0.0;
var files_scroll_max: f32 = 0.0;
var expand_research = true;
var expand_drive = true;
var expand_repo = true;

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext, rect_override: ?draw_context.Rect) SourcesViewAction {
    var action = SourcesViewAction{};
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();

    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&dc, panel_rect, queue);

    const sep_gap = t.spacing.xs;
    const sep_y = panel_rect.min[1] + header.height + sep_gap;
    const sep_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], sep_y },
        .{ panel_rect.size()[0], 1.0 },
    );
    dc.drawRect(sep_rect, .{ .fill = t.colors.divider });

    const content_top = sep_rect.max[1] + sep_gap;
    const remaining = panel_rect.max[1] - content_top;
    if (remaining <= 0.0) return action;

    var sources_buf: [24]source_browser.Source = undefined;
    var sources_map: [24]?usize = undefined;
    var sources_len: usize = 0;

    addSource(&sources_buf, &sources_map, &sources_len, .{
        .name = "Local Files",
        .source_type = .local,
        .connected = true,
    }, null);

    for (ctx.sessions.items, 0..) |session, idx| {
        if (sources_len >= sources_buf.len) break;
        const name = displayName(session);
        addSource(&sources_buf, &sources_map, &sources_len, .{
            .name = name,
            .source_type = .local,
            .connected = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key),
        }, idx);
    }

    addSource(&sources_buf, &sources_map, &sources_len, .{
        .name = "Cloud Drives",
        .source_type = .cloud,
        .connected = false,
    }, null);
    addSource(&sources_buf, &sources_map, &sources_len, .{
        .name = "Code Repos",
        .source_type = .git,
        .connected = false,
    }, null);

    const active_index = resolveSelectedIndex(ctx, sources_map[0..sources_len]);

    var files_buf: [16]source_browser.FileEntry = undefined;
    var fallback = fallbackFiles();
    const messages = messagesForActiveSession(ctx, active_index, sources_map[0..sources_len]);
    var files = collectFiles(messages, &files_buf);
    var previews_buf: [16]sessions_panel.AttachmentOpen = undefined;
    var previews = collectAttachmentPreviews(messages, &previews_buf);
    var sections_buf: [3]source_browser.Section = undefined;
    var sections_len: usize = 0;
    if (active_index == null or sources_map[active_index.?] == null) {
        files = fallback[0..];
        previews = &[_]sessions_panel.AttachmentOpen{};
    } else {
        sections_len = buildSections(files, &sections_buf);
    }

    const current_path = if (active_index != null) blk: {
        if (sources_map[active_index.?]) |session_index| {
            break :blk ctx.sessions.items[session_index].key;
        }
        break :blk sources_buf[active_index.?].name;
    } else "";

    const gap = t.spacing.md;
    var card_height = computeSelectedCardHeight(&dc, previews, t);
    var split_height = remaining;
    if (card_height > 0.0 and remaining > card_height + gap) {
        split_height = remaining - card_height - gap;
    } else {
        card_height = 0.0;
    }
    const min_split_height: f32 = 220.0;
    if (card_height > 0.0 and split_height < min_split_height and remaining > min_split_height) {
        card_height = @max(120.0, remaining - min_split_height - gap);
        split_height = remaining - card_height - gap;
    }

    const split_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], split_height },
    );

    if (split_height > 0.0) {
        drawSplitBrowser(
            allocator,
            ctx,
            &dc,
            split_rect,
            queue,
            sources_buf[0..sources_len],
            sources_map[0..sources_len],
            active_index,
            current_path,
            files,
            sections_buf[0..sections_len],
            previews,
            &action,
        );
    }

    if (card_height > 0.0) {
        const card_rect = draw_context.Rect.fromMinSize(
            .{ panel_rect.min[0], split_rect.max[1] + gap },
            .{ panel_rect.size()[0], card_height },
        );
        drawSelectedFileCard(allocator, &dc, card_rect, previews, queue, &action);
    }

    return action;
}

fn drawHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) struct { height: f32 } {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Sources", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Indexed Content", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    const button_height = subtitle_height + t.spacing.xs * 2.0;
    const button_label = "Add Source";
    const button_width = buttonWidth(dc, button_label, t);
    const button_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - t.spacing.md - button_width, cursor_y + subtitle_height + gap },
        .{ button_width, button_height },
    );
    _ = widgets.button.draw(dc, button_rect, button_label, queue, .{ .variant = .secondary });

    const height = top_pad + title_height + gap + subtitle_height + gap + button_height + top_pad;
    return .{ .height = height };
}

fn drawSplitBrowser(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    sources: []const source_browser.Source,
    map: []?usize,
    active_index: ?usize,
    current_path: []const u8,
    files: []const source_browser.FileEntry,
    sections: []const source_browser.Section,
    previews: []const sessions_panel.AttachmentOpen,
    action: *SourcesViewAction,
) void {
    const t = theme.activeTheme();
    const gap = t.spacing.md;
    const min_left: f32 = 200.0;
    const min_right: f32 = 240.0;

    if (split_width <= 0.0) split_width = 240.0;
    const max_left = @max(min_left, rect.size()[0] - min_right - gap);
    split_width = std.math.clamp(split_width, min_left, max_left);

    const left_rect = draw_context.Rect.fromMinSize(
        rect.min,
        .{ split_width, rect.size()[1] },
    );
    const right_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap, rect.min[1] },
        .{ rect.max[0] - left_rect.max[0] - gap, rect.size()[1] },
    );

    drawSourcesPanel(allocator, ctx, dc, left_rect, queue, sources, map, active_index, action);
    handleSplitResize(dc, rect, left_rect, queue, gap, min_left, max_left);

    if (right_rect.size()[0] > 0.0) {
        drawFilesPanel(
            allocator,
            ctx,
            dc,
            right_rect,
            queue,
            current_path,
            files,
            sections,
            previews,
            action,
        );
    }
}

fn drawSourcesPanel(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    sources: []const source_browser.Source,
    map: []?usize,
    active_index: ?usize,
    action: *SourcesViewAction,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    var cursor_y = rect.min[1] + padding;

    theme.push(.heading);
    dc.drawText("Sources", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += dc.lineHeight() + t.spacing.xs;

    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding - 34.0 },
    );

    drawSourcesList(allocator, ctx, dc, list_rect, queue, sources, map, active_index, action);

    const add_label = "+ Add Source";
    const button_height = dc.lineHeight() + t.spacing.xs * 2.0;
    const button_width = buttonWidth(dc, add_label, t);
    const button_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.max[1] - padding - button_height },
        .{ button_width, button_height },
    );
    _ = widgets.button.draw(dc, button_rect, add_label, queue, .{ .variant = .secondary });
}

fn drawSourcesList(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    sources: []const source_browser.Source,
    map: []?usize,
    active_index: ?usize,
    action: *SourcesViewAction,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    const line_height = dc.lineHeight();
    const row_height = line_height + t.spacing.xs * 2.0;
    const group_height = line_height + t.spacing.xs + 1.0;

    var total_height: f32 = 0.0;
    var last_type: ?source_browser.SourceType = null;
    for (sources) |source| {
        if (last_type == null or last_type.? != source.source_type) {
            if (last_type != null) total_height += t.spacing.xs;
            total_height += group_height;
            last_type = source.source_type;
        }
        total_height += row_height + t.spacing.xs;
    }

    sources_scroll_max = @max(0.0, total_height - rect.size()[1]);
    handleWheelScroll(queue, rect, &sources_scroll_y, sources_scroll_max, 28.0);

    if (sources.len == 0) {
        dc.drawText("No sources available.", rect.min, .{ .color = t.colors.text_secondary });
        return;
    }

    dc.pushClip(rect);
    var y = rect.min[1] - sources_scroll_y;
    last_type = null;
    for (sources, 0..) |source, idx| {
        if (last_type == null or last_type.? != source.source_type) {
            if (last_type != null) {
                y += t.spacing.xs;
            }
            theme.push(.heading);
            dc.drawText(sourceGroupLabel(source.source_type), .{ rect.min[0], y }, .{ .color = t.colors.text_primary });
            theme.pop();
            y += line_height + t.spacing.xs;
            dc.drawRect(draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], 1.0 }), .{ .fill = t.colors.divider });
            y += 1.0;
            last_type = source.source_type;
        }

        const row_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], row_height });
        if (row_rect.max[1] >= rect.min[1] and row_rect.min[1] <= rect.max[1]) {
            const selected = active_index != null and active_index.? == idx;
            var label_buf: [196]u8 = undefined;
            const label = sourceLabel(&label_buf, source);
            if (drawSourceRow(dc, row_rect, label, selected, queue)) {
                selected_source_index = idx;
                selected_file_index = null;
                if (map[idx]) |session_index| {
                    const session_key = ctx.sessions.items[session_index].key;
                    action.select_session = allocator.dupe(u8, session_key) catch null;
                }
            }
        }
        y += row_height + t.spacing.xs;
    }
    dc.popClip();
}

fn drawSourceRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
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

    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs }, .{ .color = t.colors.text_primary });
    return clicked;
}

fn drawFilesPanel(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    current_path: []const u8,
    files: []const source_browser.FileEntry,
    sections: []const source_browser.Section,
    previews: []const sessions_panel.AttachmentOpen,
    action: *SourcesViewAction,
) void {
    _ = ctx;
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    var cursor_y = rect.min[1] + padding;

    const button_height = dc.lineHeight() + t.spacing.xs * 2.0;
    const button_width = buttonWidth(dc, "Project Files ▾", t);
    const button_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ button_width, button_height },
    );
    _ = widgets.button.draw(dc, button_rect, "Project Files ▾", queue, .{ .variant = .secondary });

    if (current_path.len > 0) {
        dc.drawText(current_path, .{ button_rect.max[0] + t.spacing.sm, cursor_y + t.spacing.xs }, .{ .color = t.colors.text_secondary });
    }

    cursor_y += button_height + t.spacing.xs;
    dc.drawRect(draw_context.Rect.fromMinSize(.{ rect.min[0] + padding, cursor_y }, .{ rect.size()[0] - padding * 2.0, 1.0 }), .{ .fill = t.colors.divider });
    cursor_y += t.spacing.xs;

    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding },
    );

    drawFilesList(allocator, dc, list_rect, queue, files, sections, previews, action);
}

fn drawFilesList(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    files: []const source_browser.FileEntry,
    sections: []const source_browser.Section,
    previews: []const sessions_panel.AttachmentOpen,
    action: *SourcesViewAction,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    const line_height = dc.lineHeight();
    const row_height = line_height + t.spacing.xs * 2.0;
    const section_height = line_height + t.spacing.xs * 2.0;

    var total_height: f32 = 0.0;
    if (sections.len > 0) {
        for (sections) |section| {
            total_height += section_height;
            if (section.expanded.*) {
                total_height += @as(f32, @floatFromInt(section.files.len)) * (row_height + t.spacing.xs);
                total_height += t.spacing.xs;
            }
        }
    } else if (files.len > 0) {
        total_height = @as(f32, @floatFromInt(files.len)) * (row_height + t.spacing.xs);
    } else {
        total_height = line_height;
    }

    files_scroll_max = @max(0.0, total_height - rect.size()[1]);
    handleWheelScroll(queue, rect, &files_scroll_y, files_scroll_max, 28.0);

    dc.pushClip(rect);
    var y = rect.min[1] - files_scroll_y;

    if (sections.len > 0) {
        for (sections, 0..) |section, section_idx| {
            const header_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], section_height });
            const header_label = if (section.expanded.*) "v" else ">";
            const label = std.fmt.allocPrint(allocator, "{s} {s}", .{ header_label, section.name }) catch section.name;
            defer if (label.ptr != section.name.ptr) allocator.free(label);

            if (drawSectionHeader(dc, header_rect, label, queue)) {
                section.expanded.* = !section.expanded.*;
            }
            y += section_height;

            if (section.expanded.*) {
                for (section.files, 0..) |file, idx| {
                    const row_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], row_height });
                    if (row_rect.max[1] >= rect.min[1] and row_rect.min[1] <= rect.max[1]) {
                        const global_index = section.start_index + idx;
                        const selected = selected_file_index != null and selected_file_index.? == global_index;
                        if (drawFileRow(dc, row_rect, file, selected, queue)) {
                            selected_file_index = global_index;
                        }
                    }
                    y += row_height + t.spacing.xs;
                }
                y += t.spacing.xs;
            }

            if (section_idx + 1 < sections.len) {
                y += t.spacing.xs;
            }
        }
    } else if (files.len == 0) {
        dc.drawText("No files in this source.", .{ rect.min[0], y }, .{ .color = t.colors.text_secondary });
    } else {
        for (files, 0..) |file, idx| {
            const row_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], row_height });
            if (row_rect.max[1] >= rect.min[1] and row_rect.min[1] <= rect.max[1]) {
                const selected = selected_file_index != null and selected_file_index.? == idx;
                if (drawFileRow(dc, row_rect, file, selected, queue)) {
                    selected_file_index = idx;
                }
            }
            y += row_height + t.spacing.xs;
        }
    }

    dc.popClip();

    _ = previews;
    _ = action;
}

fn drawSectionHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
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

    if (hovered) {
        dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(t.colors.primary, 0.06) });
    }

    theme.push(.heading);
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs }, .{ .color = t.colors.text_primary });
    theme.pop();
    return clicked;
}

fn drawFileRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    file: source_browser.FileEntry,
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
    dc.drawRoundedRect(icon_rect, 2.0, .{ .fill = colors.withAlpha(t.colors.primary, 0.18) });

    var text_buf: [256]u8 = undefined;
    const name = if (file.language != null)
        std.fmt.bufPrint(&text_buf, "{s} ({s})", .{ file.name, file.language.? }) catch file.name
    else
        file.name;
    dc.drawText(name, .{ icon_rect.max[0] + t.spacing.sm, rect.min[1] + t.spacing.xs }, .{ .color = t.colors.text_primary });

    if (file.status) |status| {
        if (std.ascii.eqlIgnoreCase(status, "indexed")) {
            drawCheckmark(dc, t, rect, icon_size);
        } else {
            drawStatusBadge(dc, t, rect, status);
        }
    }

    return clicked;
}

fn drawStatusBadge(dc: *draw_context.DrawContext, t: *const theme.Theme, rect: draw_context.Rect, label: []const u8) void {
    const label_size = dc.measureText(label, 0.0);
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    const badge_size = .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
    const x = rect.max[0] - badge_size[0] - t.spacing.sm;
    const y = rect.min[1] + (rect.size()[1] - badge_size[1]) * 0.5;
    const variant = if (std.ascii.eqlIgnoreCase(label, "indexed"))
        t.colors.success
    else if (std.ascii.eqlIgnoreCase(label, "pending"))
        t.colors.warning
    else
        t.colors.primary;
    const bg = colors.withAlpha(variant, 0.18);
    const border = colors.withAlpha(variant, 0.4);
    dc.drawRoundedRect(
        draw_context.Rect.fromMinSize(.{ x, y }, badge_size),
        t.radius.lg,
        .{ .fill = bg, .stroke = border, .thickness = 1.0 },
    );
    dc.drawText(label, .{ x + padding[0], y + padding[1] }, .{ .color = variant });
}

fn drawCheckmark(dc: *draw_context.DrawContext, t: *const theme.Theme, rect: draw_context.Rect, icon_size: f32) void {
    const size = rect.size()[1] * 0.35;
    const x = rect.max[0] - size - t.spacing.sm;
    const y = rect.min[1] + (rect.size()[1] - size) * 0.5;
    const color = t.colors.success;
    dc.drawLine(.{ x, y + size * 0.6 }, .{ x + size * 0.4, y + size }, 2.0, color);
    dc.drawLine(.{ x + size * 0.4, y + size }, .{ x + size, y }, 2.0, color);
    _ = icon_size;
}

fn drawSelectedFileCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    previews: []const sessions_panel.AttachmentOpen,
    queue: *input_state.InputQueue,
    action: *SourcesViewAction,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.md;
    var cursor_y = rect.min[1] + padding;

    theme.push(.heading);
    dc.drawText("Selected File", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += dc.lineHeight() + t.spacing.sm;

    if (selected_file_index == null or selected_file_index.? >= previews.len) {
        dc.drawText("Select a file to see details and actions.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        return;
    }

    const preview = previews[selected_file_index.?];
    dc.drawText("Name:", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    dc.drawText(preview.name, .{ rect.min[0] + padding + 60.0, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += dc.lineHeight() + t.spacing.xs;

    dc.drawText("Type:", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    dc.drawText(preview.kind, .{ rect.min[0] + padding + 60.0, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += dc.lineHeight() + t.spacing.xs;

    dc.drawText("Role:", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    dc.drawText(preview.role, .{ rect.min[0] + padding + 60.0, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += dc.lineHeight() + t.spacing.sm;

    const button_height = dc.lineHeight() + t.spacing.xs * 2.0;
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
}

fn computeSelectedCardHeight(dc: *draw_context.DrawContext, previews: []const sessions_panel.AttachmentOpen, t: *const theme.Theme) f32 {
    const padding = t.spacing.md;
    const title_height = dc.lineHeight();
    if (previews.len == 0) {
        const body_height = dc.lineHeight();
        return padding * 2.0 + title_height + t.spacing.sm + body_height;
    }
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const body_height = line_height * 3.0 + t.spacing.xs * 2.0 + t.spacing.sm + button_height;
    return padding * 2.0 + title_height + t.spacing.sm + body_height;
}

fn handleSplitResize(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    left_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    gap: f32,
    min_left: f32,
    max_left: f32,
) void {
    const t = theme.activeTheme();
    const divider_w: f32 = 6.0;
    const divider_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap * 0.5 - divider_w * 0.5, rect.min[1] },
        .{ divider_w, rect.size()[1] },
    );

    const hover = divider_rect.contains(queue.state.mouse_pos);
    if (hover) {
        cursor.set(.resize_ew);
    }

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and divider_rect.contains(md.pos)) {
                    split_dragging = true;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    split_dragging = false;
                }
            },
            else => {},
        }
    }

    if (split_dragging) {
        const target = queue.state.mouse_pos[0] - rect.min[0];
        split_width = std.math.clamp(target, min_left, max_left);
    }

    const divider = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap * 0.5 - 1.0, rect.min[1] },
        .{ 2.0, rect.size()[1] },
    );
    const alpha: f32 = if (hover or split_dragging) 0.25 else 0.12;
    const line_color = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], alpha };
    dc.drawRect(divider, .{ .fill = line_color });
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

fn sourceTypeLabel(source_type: source_browser.SourceType) []const u8 {
    return switch (source_type) {
        .local => "local",
        .cloud => "cloud",
        .git => "git",
    };
}

fn sourceGroupLabel(source_type: source_browser.SourceType) []const u8 {
    return switch (source_type) {
        .local => "Local Sources",
        .cloud => "Cloud Drives",
        .git => "Code Repos",
    };
}

fn sourceLabel(buf: *[196]u8, source: source_browser.Source) []const u8 {
    const status = if (source.connected) "connected" else "offline";
    return std.fmt.bufPrint(
        buf,
        "{s} ({s}, {s})",
        .{ source.name, sourceTypeLabel(source.source_type), status },
    ) catch source.name;
}

fn buildSections(files: []const source_browser.FileEntry, buf: []source_browser.Section) usize {
    if (files.len == 0 or buf.len < 3) return 0;
    const first_count = @min(files.len, 3);
    const second_count = if (files.len > first_count) @min(files.len - first_count, 3) else 0;
    const third_count = if (files.len > first_count + second_count)
        files.len - first_count - second_count
    else
        0;
    var len: usize = 0;
    if (first_count > 0) {
        buf[len] = .{
            .name = "Research Docs",
            .files = files[0..first_count],
            .start_index = 0,
            .expanded = &expand_research,
        };
        len += 1;
    }
    if (second_count > 0) {
        const start = first_count;
        buf[len] = .{
            .name = "Google Drive Team",
            .files = files[start .. start + second_count],
            .start_index = start,
            .expanded = &expand_drive,
        };
        len += 1;
    }
    if (third_count > 0) {
        const start = first_count + second_count;
        buf[len] = .{
            .name = "GitHub Repo",
            .files = files[start .. start + third_count],
            .start_index = start,
            .expanded = &expand_repo,
        };
        len += 1;
    }
    return len;
}

fn addSource(
    buf: []source_browser.Source,
    map: []?usize,
    len: *usize,
    source: source_browser.Source,
    session_index: ?usize,
) void {
    if (len.* >= buf.len) return;
    buf[len.*] = source;
    map[len.*] = session_index;
    len.* += 1;
}

fn resolveSelectedIndex(ctx: *state.ClientContext, map: []?usize) ?usize {
    if (map.len == 0) {
        selected_source_index = null;
        return null;
    }
    if (selected_source_index) |idx| {
        if (idx < map.len) return idx;
        selected_source_index = null;
    }
    if (ctx.current_session) |key| {
        for (map, 0..) |session_idx, idx| {
            if (session_idx) |value| {
                if (std.mem.eql(u8, ctx.sessions.items[value].key, key)) {
                    selected_source_index = idx;
                    return idx;
                }
            }
        }
    }
    selected_source_index = 0;
    return 0;
}

fn messagesForActiveSession(
    ctx: *state.ClientContext,
    active_index: ?usize,
    map: []?usize,
) []const types.ChatMessage {
    if (active_index) |idx| {
        if (idx < map.len) {
            if (map[idx]) |session_index| {
                const session_key = ctx.sessions.items[session_index].key;
                if (ctx.findSessionState(session_key)) |session_state| {
                    return session_state.messages.items;
                }
            }
        }
    }
    return &[_]types.ChatMessage{};
}

fn displayName(session: types.Session) []const u8 {
    return session.display_name orelse session.label orelse session.key;
}

fn collectFiles(
    messages: []const types.ChatMessage,
    buf: []source_browser.FileEntry,
) []source_browser.FileEntry {
    var len: usize = 0;
    var index: usize = messages.len;
    while (index > 0 and len < buf.len) : (index -= 1) {
        const message = messages[index - 1];
        if (message.attachments) |attachments| {
            const status = statusForRole(message.role);
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                const name = attachment.name orelse attachment.url;
                buf[len] = .{
                    .name = name,
                    .language = attachment.kind,
                    .status = status,
                    .dirty = false,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn statusForRole(role: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(role, "assistant") or std.ascii.eqlIgnoreCase(role, "tool")) {
        return "indexed";
    }
    if (std.ascii.eqlIgnoreCase(role, "user")) {
        return "pending";
    }
    return "indexed";
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

fn fallbackFiles() [4]source_browser.FileEntry {
    return .{
        .{ .name = "proposal.docx", .language = "docx", .status = "indexed" },
        .{ .name = "data.csv", .language = "csv", .status = "indexed" },
        .{ .name = "image.png", .language = "png", .status = "pending" },
        .{ .name = "notes.md", .language = "md", .status = "indexed" },
    };
}
