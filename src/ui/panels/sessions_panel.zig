const std = @import("std");
const state = @import("../../client/state.zig");
const types = @import("../../protocol/types.zig");
const components = @import("../components/components.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const image_cache = @import("../image_cache.zig");
const data_uri = @import("../data_uri.zig");
const attachment_cache = @import("../attachment_cache.zig");
const draw_context = @import("../draw_context.zig");
const clipboard = @import("../clipboard.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const cursor = @import("../input/cursor.zig");
const widgets = @import("../widgets/widgets.zig");

pub const AttachmentOpen = struct {
    name: []const u8,
    kind: []const u8,
    url: []const u8,
    role: []const u8,
    timestamp: i64,
};

pub const SessionPanelAction = struct {
    refresh: bool = false,
    new_session: bool = false,
    selected_key: ?[]u8 = null,
    open_attachment: ?AttachmentOpen = null,
    open_url: ?[]u8 = null,
};

const Line = struct {
    start: usize,
    end: usize,
};

var split_width: f32 = 260.0;
var split_dragging = false;
var list_scroll_y: f32 = 0.0;
var list_scroll_max: f32 = 0.0;
var selected_file_index: ?usize = null;
var last_preview_index: ?usize = null;
var preview_scroll_y: f32 = 0.0;
var details_scroll_y: f32 = 0.0;
var details_scroll_max: f32 = 0.0;
const attachment_preview_limit: usize = 256 * 1024;
const text_preview_limit: usize = 12 * 1024;
const json_preview_limit: usize = 32 * 1024;
const log_preview_lines: usize = 80;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    rect_override: ?draw_context.Rect,
) SessionPanelAction {
    var action = SessionPanelAction{};
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();
    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const gap = t.spacing.md;
    const min_left: f32 = 220.0;
    const min_right: f32 = 260.0;
    if (split_width == 0.0) {
        split_width = @min(280.0, panel_rect.size()[0] * 0.35);
    }
    const max_left = @max(min_left, panel_rect.size()[0] - min_right - gap);
    split_width = std.math.clamp(split_width, min_left, max_left);

    const left_rect = draw_context.Rect.fromMinSize(
        panel_rect.min,
        .{ split_width, panel_rect.size()[1] },
    );
    const right_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap, panel_rect.min[1] },
        .{ panel_rect.max[0] - left_rect.max[0] - gap, panel_rect.size()[1] },
    );

    const queue = input_router.getQueue();
    drawSessionList(allocator, ctx, &dc, left_rect, queue, &action);
    handleSplitResize(&dc, panel_rect, left_rect, queue, gap, min_left, max_left);
    if (right_rect.size()[0] > 0.0) {
        drawSessionDetailsPane(allocator, ctx, t, right_rect, &action, queue);
    }

    return action;
}

fn drawSessionList(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *SessionPanelAction,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    const left = rect.min[0] + padding;
    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Sessions", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    cursor_y += line_height + t.spacing.xs;

    const refresh_label = "Refresh";
    const refresh_width = buttonWidth(dc, refresh_label, t);
    const refresh_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ refresh_width, button_height });
    if (widgets.button.draw(dc, refresh_rect, refresh_label, queue, .{ .variant = .secondary })) {
        action.refresh = true;
    }

    const new_label = "New";
    const new_width = buttonWidth(dc, new_label, t);
    const new_rect = draw_context.Rect.fromMinSize(
        .{ refresh_rect.max[0] + t.spacing.sm, cursor_y },
        .{ new_width, button_height },
    );
    if (widgets.button.draw(dc, new_rect, new_label, queue, .{ .variant = .primary })) {
        action.new_session = true;
    }

    if (ctx.sessions_loading) {
        const badge_width = badgeWidth(dc, "Loading", t);
        const badge_rect = draw_context.Rect.fromMinSize(
            .{ rect.max[0] - padding - badge_width, cursor_y },
            .{ badge_width, button_height },
        );
        drawBadge(dc, badge_rect, "Loading", t.colors.primary, t);
    }

    cursor_y += button_height + t.spacing.sm;
    const divider = draw_context.Rect.fromMinSize(
        .{ rect.min[0], cursor_y },
        .{ rect.size()[0], 1.0 },
    );
    dc.drawRect(divider, .{ .fill = t.colors.divider });
    cursor_y += t.spacing.sm;

    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) return;

    const row_height = line_height + t.spacing.xs * 2.0;
    const row_gap = t.spacing.xs;
    const total_height = @as(f32, @floatFromInt(ctx.sessions.items.len)) * (row_height + row_gap);
    list_scroll_max = @max(0.0, total_height - list_rect.size()[1]);
    handleWheelScroll(queue, list_rect, &list_scroll_y, list_scroll_max, 28.0);

    dc.pushClip(list_rect);
    var row_y = list_rect.min[1] - list_scroll_y;
    for (ctx.sessions.items) |session| {
        const row_rect = draw_context.Rect.fromMinSize(.{ list_rect.min[0], row_y }, .{ list_rect.size()[0], row_height });
        if (row_rect.max[1] >= list_rect.min[1] and row_rect.min[1] <= list_rect.max[1]) {
            const selected = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key);
            const clicked = drawSessionRow(dc, row_rect, session, selected, queue);
            if (clicked) {
                action.selected_key = allocator.dupe(u8, session.key) catch null;
                selected_file_index = null;
            }
        }
        row_y += row_height + row_gap;
    }
    dc.popClip();
}

fn drawSessionRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    session: types.Session,
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

    const label = session.display_name orelse session.label orelse session.key;
    const text_pos = .{ rect.min[0] + t.spacing.sm, rect.min[1] + t.spacing.xs };
    dc.drawText(label, text_pos, .{ .color = t.colors.text_primary });

    if (selected) {
        const badge_label = "active";
        const badge_w = badgeWidth(dc, badge_label, t);
        const badge_rect = draw_context.Rect.fromMinSize(
            .{ rect.max[0] - badge_w - t.spacing.sm, rect.min[1] + t.spacing.xs * 0.5 },
            .{ badge_w, rect.size()[1] - t.spacing.xs },
        );
        drawBadge(dc, badge_rect, badge_label, t.colors.success, t);
    }

    return clicked;
}

fn drawSessionDetailsPane(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    t: *const theme.Theme,
    rect: draw_context.Rect,
    action: *SessionPanelAction,
    queue: *input_state.InputQueue,
) void {
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, rect);
    defer dc.deinit();

    handleWheelScroll(queue, rect, &details_scroll_y, details_scroll_max, 40.0);

    const padding = t.spacing.md;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) return;

    dc.pushClip(rect);
    var cursor_y = content_rect.min[1] - details_scroll_y;
    const start_y = cursor_y;
    cursor_y += drawSessionDetailsCustom(allocator, ctx, t, &dc, queue, .{ content_rect.min[0], cursor_y }, content_rect.size()[0], rect.size()[1], action);
    const content_height = cursor_y - start_y;
    details_scroll_max = @max(0.0, content_height - content_rect.size()[1] + padding);
    if (details_scroll_y > details_scroll_max) details_scroll_y = details_scroll_max;
    dc.popClip();
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

fn badgeWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 1.5;
}

fn drawBadge(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    color: colors.Color,
    t: *const theme.Theme,
) void {
    dc.drawRoundedRect(rect, t.radius.lg, .{
        .fill = colors.withAlpha(color, 0.18),
        .stroke = colors.withAlpha(color, 0.4),
        .thickness = 1.0,
    });
    const text_size = dc.measureText(label, 0.0);
    dc.drawText(
        label,
        .{ rect.min[0] + (rect.size()[0] - text_size[0]) * 0.5, rect.min[1] + (rect.size()[1] - text_size[1]) * 0.5 },
        .{ .color = color },
    );
}

fn drawSessionDetailsCustom(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    t: *const theme.Theme,
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    origin: [2]f32,
    width: f32,
    viewport_height: f32,
    action: *SessionPanelAction,
) f32 {
    var cursor_y = origin[1];
    const line_height = dc.lineHeight();

    const selected_index = resolveSelectedSessionIndex(ctx);
    if (selected_index == null) {
        dc.drawText("Select a session to see details.", .{ origin[0], cursor_y }, .{ .color = t.colors.text_secondary });
        return line_height;
    }

    const session = ctx.sessions.items[selected_index.?];
    const name = displayName(session);
    const description = session.label orelse session.kind;
    const messages = messagesForSession(ctx, session.key);

    var categories_buf: [3]components.composite.project_card.Category = undefined;
    var categories_len: usize = 0;
    if (session.kind) |kind| {
        categories_buf[categories_len] = .{ .name = kind, .variant = .primary };
        categories_len += 1;
    }
    if (ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key)) {
        categories_buf[categories_len] = .{ .name = "active", .variant = .success };
        categories_len += 1;
    }

    var artifacts_buf: [6]components.composite.project_card.Artifact = undefined;
    const artifacts = collectArtifacts(messages, &artifacts_buf);

    const project_args = components.composite.project_card.Args{
        .id = "session_project_card",
        .name = name,
        .description = description,
        .categories = categories_buf[0..categories_len],
        .recent_artifacts = artifacts,
    };
    const project_height = components.composite.project_card.measureHeight(
        allocator,
        dc,
        project_args,
        width,
    );
    components.composite.project_card.draw(
        allocator,
        dc,
        draw_context.Rect.fromMinSize(.{ origin[0], cursor_y }, .{ width, project_height }),
        project_args,
    );
    cursor_y += project_height + t.spacing.md;

    var sources_buf: [16]components.composite.source_browser.Source = undefined;
    var source_map: [16]usize = undefined;
    var sources_len: usize = 0;
    var selected_source: ?usize = null;
    for (ctx.sessions.items, 0..) |entry, idx| {
        if (sources_len >= sources_buf.len) break;
        sources_buf[sources_len] = .{
            .name = displayName(entry),
            .source_type = .local,
            .connected = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, entry.key),
        };
        source_map[sources_len] = idx;
        if (selected_index.? == idx) {
            selected_source = sources_len;
        }
        sources_len += 1;
    }
    if (selected_source == null and sources_len > 0) {
        selected_source = 0;
    }

    var files_buf: [12]components.composite.source_browser.FileEntry = undefined;
    const files = collectFiles(messages, &files_buf);
    var previews_buf: [12]AttachmentOpen = undefined;
    const previews = collectAttachmentPreviews(messages, &previews_buf);

    const source_height = std.math.clamp(viewport_height * 0.5, 260.0, 380.0);
    const source_rect = draw_context.Rect.fromMinSize(.{ origin[0], cursor_y }, .{ width, source_height });
    const source_action = components.composite.source_browser.draw(allocator, .{
        .id = "session_source_browser",
        .sources = sources_buf[0..sources_len],
        .selected_source = selected_source,
        .current_path = session.key,
        .files = files,
        .selected_file = selected_file_index,
        .rect = source_rect,
    });
    if (source_action.select_source) |src_index| {
        if (src_index < sources_len) {
            const session_index = source_map[src_index];
            action.selected_key = allocator.dupe(u8, ctx.sessions.items[session_index].key) catch null;
            selected_file_index = null;
        }
    }
    if (source_action.select_file) |file_index| {
        if (file_index < files.len) {
            selected_file_index = file_index;
        }
    }
    if (selected_file_index != last_preview_index) {
        preview_scroll_y = 0.0;
        last_preview_index = selected_file_index;
    }
    cursor_y += source_height + t.spacing.md;

    const preview_height = drawAttachmentPreviewCard(
        allocator,
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ origin[0], cursor_y }, .{ width, 0.0 }),
        previews,
        action,
    );
    cursor_y += preview_height;

    return cursor_y - origin[1];
}

fn resolveSelectedSessionIndex(ctx: *state.ClientContext) ?usize {
    if (ctx.sessions.items.len == 0) return null;
    if (ctx.current_session) |key| {
        if (findSessionIndex(ctx.sessions.items, key)) |index| return index;
    }
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

fn collectArtifacts(
    messages: []const types.ChatMessage,
    buf: []components.composite.project_card.Artifact,
) []components.composite.project_card.Artifact {
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
                    .file_type = attachment.kind,
                    .status = message.role,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn collectFiles(
    messages: []const types.ChatMessage,
    buf: []components.composite.source_browser.FileEntry,
) []components.composite.source_browser.FileEntry {
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
                    .language = attachment.kind,
                    .status = message.role,
                    .dirty = false,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn collectAttachmentPreviews(
    messages: []const types.ChatMessage,
    buf: []AttachmentOpen,
) []AttachmentOpen {
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

fn drawAttachmentPreviewCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    previews: []AttachmentOpen,
    action: *SessionPanelAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const width = rect.size()[0];
    const content_width = width - padding * 2.0;
    const preview = if (selected_file_index != null and selected_file_index.? < previews.len)
        previews[selected_file_index.?]
    else
        null;

    var height: f32 = padding + line_height + t.spacing.sm;
    if (preview == null) {
        height += line_height + padding;
        const card_rect = draw_context.Rect.fromMinSize(rect.min, .{ width, height });
        dc.drawRoundedRect(card_rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        theme.push(.heading);
        dc.drawText("Attachment Preview", .{ card_rect.min[0] + padding, card_rect.min[1] + padding }, .{ .color = t.colors.text_primary });
        theme.pop();
        dc.drawText(
            "Select a file to preview its details.",
            .{ card_rect.min[0] + padding, card_rect.min[1] + padding + line_height + t.spacing.sm },
            .{ .color = t.colors.text_secondary },
        );
        return height;
    }

    const preview_value = preview.?;
    const meta_lines: usize = 5;
    const meta_height = @as(f32, @floatFromInt(meta_lines)) * line_height + t.spacing.xs * @as(f32, @floatFromInt(meta_lines - 1));
    const preview_box_height: f32 = if (isImageAttachment(preview_value)) 220.0 else 180.0;

    var status: ?[]const u8 = null;
    var size_bytes: ?usize = null;
    var truncated = false;
    var content: ?[]const u8 = null;
    var display: []const u8 = "";
    var owns_display = false;
    var format: PreviewFormat = .text;

    if (!isImageAttachment(preview_value)) {
        if (std.mem.startsWith(u8, preview_value.url, "data:")) {
            if (preview_value.url.len > attachment_preview_limit) {
                status = "Data attachment too large to preview.";
            } else if (data_uri.decodeDataUriBytes(allocator, preview_value.url)) |bytes| {
                defer allocator.free(bytes);
                size_bytes = bytes.len;
                if (!std.unicode.utf8ValidateSlice(bytes)) {
                    status = "Binary data attachment.";
                } else {
                    const trimmed = trimPreview(bytes, text_preview_limit);
                    content = trimmed.body;
                    truncated = trimmed.truncated;
                }
            } else |_| {
                status = "Failed to decode attachment.";
            }
        } else if (isHttpUrl(preview_value.url)) {
            attachment_cache.request(preview_value.url, attachment_preview_limit);
            if (attachment_cache.get(preview_value.url)) |entry| {
                switch (entry.state) {
                    .loading => status = "Fetching remote attachment...",
                    .failed => {
                        status = if (entry.error_message) |err| err else "Attachment fetch failed.";
                    },
                    .ready => if (entry.data) |data| {
                        size_bytes = data.len;
                        const trimmed = trimPreview(data, text_preview_limit);
                        content = trimmed.body;
                        truncated = trimmed.truncated;
                    } else {
                        status = "Attachment content unavailable.";
                    },
                }
            } else {
                status = "Fetching remote attachment...";
            }
        }

        if (content) |body| {
            format = detectPreviewFormat(preview_value, body);
            display = body;
            if (format == .json and body.len <= json_preview_limit) {
                if (std.json.parseFromSlice(std.json.Value, allocator, body, .{})) |parsed| {
                    defer parsed.deinit();
                    if (std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 })) |pretty| {
                        display = pretty;
                        owns_display = true;
                    } else |_| {}
                } else |_| {}
            }
        }
    }
    defer if (owns_display) allocator.free(display);

    var status_lines: usize = 0;
    if (status != null) status_lines += 1;
    if (size_bytes != null) status_lines += 1;
    if (truncated) status_lines += 1;
    const status_height: f32 = if (status_lines > 0)
        @as(f32, @floatFromInt(status_lines)) * line_height + t.spacing.xs * @as(f32, @floatFromInt(status_lines - 1))
    else
        0.0;

    height += meta_height + t.spacing.sm;
    if (status_height > 0.0) {
        height += status_height + t.spacing.xs;
    }
    if (!isImageAttachment(preview_value)) {
        height += line_height + t.spacing.sm;
    }
    height += preview_box_height + t.spacing.sm;
    height += button_height + padding;

    const card_rect = draw_context.Rect.fromMinSize(rect.min, .{ width, height });
    dc.drawRoundedRect(card_rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = card_rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Attachment Preview", .{ card_rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.sm;

    cursor_y += drawKeyValue(dc, card_rect.min[0] + padding, cursor_y, "Name", preview_value.name, line_height, t);
    cursor_y += drawKeyValue(dc, card_rect.min[0] + padding, cursor_y, "Type", preview_value.kind, line_height, t);
    cursor_y += drawKeyValue(dc, card_rect.min[0] + padding, cursor_y, "Source", preview_value.url, line_height, t);
    cursor_y += drawKeyValue(dc, card_rect.min[0] + padding, cursor_y, "Role", preview_value.role, line_height, t);
    var ts_buf: [32]u8 = undefined;
    const ts_text = std.fmt.bufPrint(&ts_buf, "{d}", .{preview_value.timestamp}) catch "0";
    cursor_y += drawKeyValue(dc, card_rect.min[0] + padding, cursor_y, "Timestamp", ts_text, line_height, t);
    cursor_y += t.spacing.sm;

    if (status_height > 0.0) {
        cursor_y += drawPreviewMeta(dc, card_rect.min[0] + padding, cursor_y, status, size_bytes, truncated, line_height, t);
        cursor_y += t.spacing.xs;
    }

    if (!isImageAttachment(preview_value)) {
        const format_label = switch (format) {
            .json => "json",
            .markdown => "markdown",
            .log => "log",
            .text => "text",
        };
        var format_buf: [48]u8 = undefined;
        const format_text = if (owns_display and format == .json)
            std.fmt.bufPrint(&format_buf, "Format: {s} (formatted)", .{format_label}) catch "Format: json"
        else
            std.fmt.bufPrint(&format_buf, "Format: {s}", .{format_label}) catch "Format: text";
        dc.drawText(format_text, .{ card_rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        const copy_w = buttonWidth(dc, "Copy Preview", t);
        const copy_rect = draw_context.Rect.fromMinSize(
            .{ card_rect.max[0] - padding - copy_w, cursor_y - t.spacing.xs * 0.5 },
            .{ copy_w, button_height },
        );
        if (widgets.button.draw(dc, copy_rect, "Copy Preview", queue, .{ .variant = .ghost, .disabled = display.len == 0 })) {
            if (std.heap.page_allocator.dupeZ(u8, display) catch null) |copy_z| {
                defer std.heap.page_allocator.free(copy_z);
                clipboard.setTextZ(copy_z);
            }
        }
        cursor_y += line_height + t.spacing.sm;
    }

    const preview_rect = draw_context.Rect.fromMinSize(
        .{ card_rect.min[0] + padding, cursor_y },
        .{ content_width, preview_box_height },
    );
    if (isImageAttachment(preview_value)) {
        drawImagePreview(dc, preview_rect, preview_value);
    } else if (display.len > 0) {
        drawPreviewTextBox(allocator, dc, preview_rect, queue, display, format);
    } else if (status == null) {
        dc.drawText("Preview unavailable.", .{ preview_rect.min[0], preview_rect.min[1] }, .{ .color = t.colors.text_secondary });
    }
    cursor_y = preview_rect.max[1] + t.spacing.sm;

    const open_w = buttonWidth(dc, "Open in Editor", t);
    const open_rect = draw_context.Rect.fromMinSize(
        .{ card_rect.min[0] + padding, cursor_y },
        .{ open_w, button_height },
    );
    if (widgets.button.draw(dc, open_rect, "Open in Editor", queue, .{ .variant = .secondary })) {
        action.open_attachment = preview_value;
    }

    if (isHttpUrl(preview_value.url)) {
        const open_url_w = buttonWidth(dc, "Open URL", t);
        const open_url_rect = draw_context.Rect.fromMinSize(
            .{ open_rect.max[0] + t.spacing.sm, cursor_y },
            .{ open_url_w, button_height },
        );
        if (widgets.button.draw(dc, open_url_rect, "Open URL", queue, .{ .variant = .secondary })) {
            action.open_url = allocator.dupe(u8, preview_value.url) catch null;
        }
        const copy_url_w = buttonWidth(dc, "Copy URL", t);
        const copy_url_rect = draw_context.Rect.fromMinSize(
            .{ open_url_rect.max[0] + t.spacing.xs, cursor_y },
            .{ copy_url_w, button_height },
        );
        if (widgets.button.draw(dc, copy_url_rect, "Copy URL", queue, .{ .variant = .ghost })) {
            if (std.heap.page_allocator.dupeZ(u8, preview_value.url) catch null) |url_z| {
                defer std.heap.page_allocator.free(url_z);
                clipboard.setTextZ(url_z);
            }
        }
    }

    return height;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    const start = value.len - suffix.len;
    var index: usize = 0;
    while (index < suffix.len) : (index += 1) {
        if (std.ascii.toLower(value[start + index]) != suffix[index]) return false;
    }
    return true;
}

fn isImageAttachment(att: AttachmentOpen) bool {
    if (std.mem.indexOf(u8, att.kind, "image") != null) return true;
    if (std.mem.startsWith(u8, att.url, "data:image/")) return true;
    return endsWithIgnoreCase(att.url, ".png") or
        endsWithIgnoreCase(att.url, ".jpg") or
        endsWithIgnoreCase(att.url, ".jpeg") or
        endsWithIgnoreCase(att.url, ".gif") or
        endsWithIgnoreCase(att.url, ".webp");
}

fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

fn hasTokenIgnoreCase(value: []const u8, token: []const u8) bool {
    if (token.len == 0 or value.len < token.len) return false;
    var i: usize = 0;
    while (i + token.len <= value.len) : (i += 1) {
        var matches = true;
        var j: usize = 0;
        while (j < token.len) : (j += 1) {
            if (std.ascii.toLower(value[i + j]) != token[j]) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn isJsonAttachment(att: AttachmentOpen, body: ?[]const u8) bool {
    if (hasTokenIgnoreCase(att.kind, "json")) return true;
    if (endsWithIgnoreCase(att.url, ".json") or endsWithIgnoreCase(att.url, ".jsonl")) return true;
    if (body) |data| {
        const trimmed = std.mem.trimLeft(u8, data, " \t\r\n");
        if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) return true;
    }
    return false;
}

fn isMarkdownAttachment(att: AttachmentOpen, body: ?[]const u8) bool {
    if (hasTokenIgnoreCase(att.kind, "markdown")) return true;
    if (endsWithIgnoreCase(att.url, ".md") or endsWithIgnoreCase(att.url, ".markdown")) return true;
    if (body) |data| {
        return std.mem.indexOf(u8, data, "\n#") != null or std.mem.startsWith(u8, data, "#");
    }
    return false;
}

fn isLogAttachment(att: AttachmentOpen) bool {
    if (hasTokenIgnoreCase(att.kind, "log")) return true;
    if (endsWithIgnoreCase(att.url, ".log")) return true;
    return false;
}

const PreviewFormat = enum {
    json,
    markdown,
    log,
    text,
};

fn detectPreviewFormat(att: AttachmentOpen, body: []const u8) PreviewFormat {
    if (isJsonAttachment(att, body)) return .json;
    if (isMarkdownAttachment(att, body)) return .markdown;
    if (isLogAttachment(att)) return .log;
    return .text;
}

fn trimPreview(data: []const u8, max_len: usize) struct { body: []const u8, truncated: bool } {
    if (data.len <= max_len) return .{ .body = data, .truncated = false };
    return .{ .body = data[0..max_len], .truncated = true };
}

fn drawPreviewMeta(
    dc: *draw_context.DrawContext,
    x: f32,
    y: f32,
    status: ?[]const u8,
    size_bytes: ?usize,
    truncated: bool,
    line_height: f32,
    t: *const theme.Theme,
) f32 {
    var cursor_y = y;
    if (status) |note| {
        dc.drawText(note, .{ x, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height;
    }
    if (size_bytes) |size| {
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Size: {d} bytes", .{size}) catch "Size: 0 bytes";
        dc.drawText(label, .{ x, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height;
    }
    if (truncated) {
        dc.drawText("Preview truncated.", .{ x, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height;
    }
    return cursor_y - y;
}

fn drawPreviewTextBox(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    text: []const u8,
    format: PreviewFormat,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    if (format == .markdown) {
        drawMarkdownPreviewBox(allocator, dc, rect, queue, text);
        return;
    }

    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    if (format == .log) {
        buildLogLinesInto(allocator, text, &lines);
    } else {
        buildLinesInto(allocator, dc, text, rect.size()[0] - t.spacing.sm * 2.0, &lines);
    }

    const line_height = dc.lineHeight();
    const content_height = @as(f32, @floatFromInt(lines.items.len)) * line_height;
    const max_scroll = @max(0.0, content_height - rect.size()[1]);

    handleWheelScroll(queue, rect, &preview_scroll_y, max_scroll, 24.0);

    dc.pushClip(rect);
    var start_index: usize = 0;
    if (line_height > 0.0) {
        start_index = @intFromFloat(@floor(preview_scroll_y / line_height));
    }
    var y = rect.min[1] + t.spacing.xs - preview_scroll_y + @as(f32, @floatFromInt(start_index)) * line_height;
    for (lines.items[start_index..], start_index..) |line, idx| {
        const slice = text[line.start..line.end];
        if (slice.len > 0) {
            const color = if (format == .log) logLineColor(slice, t) else t.colors.text_secondary;
            dc.drawText(slice, .{ rect.min[0] + t.spacing.sm, y }, .{ .color = color });
        }
        y += line_height;
        if (y > rect.max[1]) break;
        _ = idx;
    }
    dc.popClip();

    if (preview_scroll_y > max_scroll) preview_scroll_y = max_scroll;
    if (preview_scroll_y < 0.0) preview_scroll_y = 0.0;
}

const MarkdownStyle = enum {
    normal,
    heading,
    quote,
    bullet,
    code,
    blank,
};

const RenderedLine = struct {
    text: []const u8,
    style: MarkdownStyle,
    bullet: bool,
};

fn drawMarkdownPreviewBox(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    text: []const u8,
) void {
    const t = theme.activeTheme();
    var lines = std.ArrayList(RenderedLine).empty;
    defer lines.deinit(allocator);
    buildMarkdownLinesInto(allocator, dc, text, rect.size()[0] - t.spacing.sm * 2.0, &lines);

    const body_height = dc.lineHeight();
    theme.push(.heading);
    const heading_height = dc.lineHeight();
    theme.pop();

    var total_height: f32 = 0.0;
    for (lines.items) |line| {
        total_height += lineHeight(line.style, body_height, heading_height, t);
    }

    const max_scroll = @max(0.0, total_height - rect.size()[1]);
    handleWheelScroll(queue, rect, &preview_scroll_y, max_scroll, 24.0);

    dc.pushClip(rect);
    var y = rect.min[1] + t.spacing.xs - preview_scroll_y;
    for (lines.items) |line| {
        const line_height = lineHeight(line.style, body_height, heading_height, t);
        if (y + line_height < rect.min[1]) {
            y += line_height;
            continue;
        }
        if (y > rect.max[1]) break;

        switch (line.style) {
            .blank => {},
            .heading => {
                theme.push(.heading);
                dc.drawText(line.text, .{ rect.min[0] + t.spacing.sm, y }, .{ .color = t.colors.text_primary });
                theme.pop();
            },
            .code => {
                const code_rect = draw_context.Rect.fromMinSize(
                    .{ rect.min[0] + t.spacing.xs, y },
                    .{ rect.size()[0] - t.spacing.xs * 2.0, line_height },
                );
                dc.drawRoundedRect(code_rect, t.radius.sm, .{ .fill = colors.withAlpha(t.colors.border, 0.12), .stroke = null, .thickness = 0.0 });
                dc.drawText(line.text, .{ rect.min[0] + t.spacing.sm, y }, .{ .color = t.colors.text_secondary });
            },
            .quote => {
                const bar_rect = draw_context.Rect.fromMinSize(
                    .{ rect.min[0] + t.spacing.xs, y + t.spacing.xs },
                    .{ 2.0, line_height - t.spacing.xs * 2.0 },
                );
                dc.drawRect(bar_rect, .{ .fill = colors.withAlpha(t.colors.primary, 0.5) });
                dc.drawText(line.text, .{ rect.min[0] + t.spacing.sm * 2.0, y }, .{ .color = t.colors.text_secondary });
            },
            .bullet => {
                const bullet_x = rect.min[0] + t.spacing.sm;
                if (line.bullet) {
                    const radius: f32 = 2.5;
                    const center_y = y + line_height * 0.5;
                    dc.drawRoundedRect(
                        draw_context.Rect.fromMinSize(.{ bullet_x, center_y - radius }, .{ radius * 2.0, radius * 2.0 }),
                        radius,
                        .{ .fill = t.colors.text_secondary },
                    );
                }
                dc.drawText(line.text, .{ rect.min[0] + t.spacing.sm * 2.5, y }, .{ .color = t.colors.text_secondary });
            },
            .normal => {
                dc.drawText(line.text, .{ rect.min[0] + t.spacing.sm, y }, .{ .color = t.colors.text_secondary });
            },
        }
        y += line_height;
    }
    dc.popClip();

    if (preview_scroll_y > max_scroll) preview_scroll_y = max_scroll;
    if (preview_scroll_y < 0.0) preview_scroll_y = 0.0;
}

fn lineHeight(style: MarkdownStyle, body_height: f32, heading_height: f32, t: *const theme.Theme) f32 {
    return switch (style) {
        .heading => heading_height,
        .blank => t.spacing.xs,
        else => body_height,
    };
}

fn buildMarkdownLinesInto(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
    lines: *std.ArrayList(RenderedLine),
) void {
    lines.clearRetainingCapacity();
    const t = theme.activeTheme();
    const bullet_indent = t.spacing.sm * 2.5;
    const quote_indent = t.spacing.sm * 2.0;
    const code_indent = t.spacing.sm;
    const max_lines = log_preview_lines;
    var count: usize = 0;
    var in_code_block = false;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (count >= max_lines) break;
        const trimmed = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code_block = !in_code_block;
            continue;
        }
        if (trimmed.len == 0) {
            _ = lines.append(allocator, .{ .text = "", .style = .blank, .bullet = false }) catch {};
            count += 1;
            continue;
        }

        var style: MarkdownStyle = .normal;
        var content = trimmed;
        if (in_code_block) {
            style = .code;
        } else if (std.mem.startsWith(u8, trimmed, "#")) {
            style = .heading;
            content = std.mem.trimLeft(u8, trimmed, "# ");
        } else if (std.mem.startsWith(u8, trimmed, "> ")) {
            style = .quote;
            content = trimmed[2..];
        } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "+ ")) {
            style = .bullet;
            content = trimmed[2..];
        }

        const indent = switch (style) {
            .quote => quote_indent,
            .bullet => bullet_indent,
            .code => code_indent,
            else => 0.0,
        };
        const effective_width = @max(8.0, wrap_width - indent);

        var wrapped = std.ArrayList(Line).empty;
        defer wrapped.deinit(allocator);
        buildLinesInto(allocator, dc, content, effective_width, &wrapped);
        for (wrapped.items, 0..) |segment, idx| {
            if (count >= max_lines) break;
            const slice = content[segment.start..segment.end];
            _ = lines.append(allocator, .{ .text = slice, .style = style, .bullet = style == .bullet and idx == 0 }) catch {};
            count += 1;
        }
        if (count >= max_lines) break;
    }

    if (count >= max_lines and lines.items.len > 0) {
        lines.items[lines.items.len - 1] = .{ .text = "Preview truncated.", .style = .normal, .bullet = false };
    }
}

fn drawImagePreview(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    preview: AttachmentOpen,
) void {
    const t = theme.activeTheme();
    if (preview.url.len == 0) {
        dc.drawText("Image preview unavailable.", rect.min, .{ .color = t.colors.text_secondary });
        return;
    }
    image_cache.request(preview.url);
    if (image_cache.get(preview.url)) |entry| {
        switch (entry.state) {
            .ready => {
                const tex_ref = draw_context.DrawContext.textureFromId(@as(u64, entry.texture_id));
                const w = @as(f32, @floatFromInt(entry.width));
                const h = @as(f32, @floatFromInt(entry.height));
                const aspect = if (h > 0) w / h else 1.0;
                var draw_w = @min(rect.size()[0], w);
                var draw_h = draw_w / aspect;
                if (draw_h > rect.size()[1]) {
                    draw_h = rect.size()[1];
                    draw_w = draw_h * aspect;
                }
                const offset_x = rect.min[0] + (rect.size()[0] - draw_w) * 0.5;
                const offset_y = rect.min[1] + (rect.size()[1] - draw_h) * 0.5;
                dc.drawImage(tex_ref, draw_context.Rect.fromMinSize(.{ offset_x, offset_y }, .{ draw_w, draw_h }));
            },
            .loading => {
                dc.drawText("Loading image preview...", rect.min, .{ .color = t.colors.text_secondary });
            },
            .failed => {
                dc.drawText("Image failed to load.", rect.min, .{ .color = t.colors.danger });
            },
        }
    } else {
        dc.drawText("Loading image preview...", rect.min, .{ .color = t.colors.text_secondary });
    }
}

fn drawKeyValue(
    dc: *draw_context.DrawContext,
    x: f32,
    y: f32,
    label: []const u8,
    value: []const u8,
    line_height: f32,
    t: *const theme.Theme,
) f32 {
    dc.drawText(label, .{ x, y }, .{ .color = t.colors.text_secondary });
    const label_w = dc.measureText(label, 0.0)[0];
    dc.drawText(value, .{ x + label_w + t.spacing.xs, y }, .{ .color = t.colors.text_primary });
    return line_height + t.spacing.xs;
}

fn logLineColor(line: []const u8, t: *const theme.Theme) colors.Color {
    if (hasTokenIgnoreCase(line, "error")) return t.colors.danger;
    if (hasTokenIgnoreCase(line, "warn")) return t.colors.warning;
    if (hasTokenIgnoreCase(line, "info")) return t.colors.primary;
    return t.colors.text_secondary;
}

fn buildLogLinesInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    lines: *std.ArrayList(Line),
) void {
    lines.clearRetainingCapacity();
    var start: usize = 0;
    var index: usize = 0;
    var count: usize = 0;
    while (index < text.len and count < log_preview_lines) {
        if (text[index] == '\n') {
            _ = lines.append(allocator, .{ .start = start, .end = index }) catch {};
            count += 1;
            index += 1;
            start = index;
            continue;
        }
        index += 1;
    }
    if (start < text.len and count < log_preview_lines) {
        _ = lines.append(allocator, .{ .start = start, .end = text.len }) catch {};
    }
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
