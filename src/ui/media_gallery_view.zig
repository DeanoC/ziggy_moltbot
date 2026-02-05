const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const cursor = @import("input/cursor.zig");
const image_cache = @import("image_cache.zig");
const ui_systems = @import("ui_systems.zig");
const drag_drop = @import("systems/drag_drop.zig");

const MediaItem = struct {
    name: []const u8,
    url: []const u8,
};

const FitMode = enum { fit, fill, actual, custom };

var selected_index: ?usize = null;
var split_width: f32 = 260.0;
var split_dragging = false;
var stack_height: f32 = 360.0;
var stack_dragging = false;
var gallery_scroll_y: f32 = 0.0;
var gallery_scroll_max: f32 = 0.0;
var viewer_zoom: f32 = 1.0;
var viewer_offset: [2]f32 = .{ 0.0, 0.0 };
var viewer_fit_mode: FitMode = .fit;
var pending_drop_url: ?[]const u8 = null;
var drag_preview_label: ?[]const u8 = null;
var thumb_drag_index: ?usize = null;
var thumb_drag_origin: [2]f32 = .{ 0.0, 0.0 };
var thumb_drag_started: bool = false;
var viewer_dragging: bool = false;
var viewer_drag_last: [2]f32 = .{ 0.0, 0.0 };

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext, rect_override: ?draw_context.Rect) void {
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();
    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const header = drawHeader(&dc, panel_rect);
    const sep_gap = t.spacing.xs;
    const content_top = panel_rect.min[1] + header.height + sep_gap;
    const content_height = panel_rect.max[1] - content_top;
    if (content_height <= 0.0) return;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], content_height },
    );

    var items_buf: [64]MediaItem = undefined;
    const messages = messagesForCurrentSession(ctx);
    const items = collectImages(messages, &items_buf);
    if (items.len == 0) {
        dc.drawText("No media available yet.", .{ content_rect.min[0] + t.spacing.md, content_rect.min[1] + t.spacing.md }, .{ .color = t.colors.text_secondary });
        return;
    }

    if (selected_index == null or selected_index.? >= items.len) {
        selected_index = 0;
    }
    applyPendingDrop(items);

    const use_stack = content_rect.size()[0] < 780.0;
    const queue = input_router.getQueue();
    if (use_stack) {
        drawStackedLayout(&dc, allocator, items, content_rect, queue);
    } else {
        drawSplitLayout(&dc, allocator, items, content_rect, queue);
    }
}

fn drawHeader(dc: *draw_context.DrawContext, rect: draw_context.Rect) struct { height: f32 } {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Media Gallery", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Images & Previews", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    const height = top_pad + title_height + gap + subtitle_height + top_pad;
    return .{ .height = height };
}

fn drawSplitLayout(
    dc: *draw_context.DrawContext,
    allocator: std.mem.Allocator,
    items: []const MediaItem,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) void {
    const t = theme.activeTheme();
    const gap = t.spacing.md;
    const min_left: f32 = 220.0;
    const min_right: f32 = 320.0;
    if (split_width == 0.0) {
        split_width = @min(280.0, rect.size()[0] * 0.3);
    }
    const max_left = @max(min_left, rect.size()[0] - min_right - gap);
    split_width = std.math.clamp(split_width, min_left, max_left);

    const left_rect = draw_context.Rect.fromMinSize(rect.min, .{ split_width, rect.size()[1] });
    const right_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + gap, rect.min[1] },
        .{ rect.max[0] - left_rect.max[0] - gap, rect.size()[1] },
    );

    drawGallery(dc, allocator, items, left_rect, queue);
    handleSplitResize(dc, rect, left_rect, queue, gap, min_left, max_left);
    if (right_rect.size()[0] > 0.0) {
        drawViewer(dc, items, right_rect, queue);
    }
}

fn drawStackedLayout(
    dc: *draw_context.DrawContext,
    allocator: std.mem.Allocator,
    items: []const MediaItem,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) void {
    const t = theme.activeTheme();
    const gap = t.spacing.md;
    const min_top: f32 = 200.0;
    const min_bottom: f32 = 160.0;
    if (stack_height == 0.0) {
        stack_height = rect.size()[1] * 0.6;
    }
    const max_top = @max(min_top, rect.size()[1] - min_bottom - gap);
    stack_height = std.math.clamp(stack_height, min_top, max_top);

    const top_rect = draw_context.Rect.fromMinSize(rect.min, .{ rect.size()[0], stack_height });
    const bottom_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0], top_rect.max[1] + gap },
        .{ rect.size()[0], rect.max[1] - top_rect.max[1] - gap },
    );

    drawViewer(dc, items, top_rect, queue);
    handleStackResize(dc, rect, top_rect, queue, gap, min_top, max_top);
    if (bottom_rect.size()[1] > 0.0) {
        drawGallery(dc, allocator, items, bottom_rect, queue);
    }
}

fn drawGallery(
    dc: *draw_context.DrawContext,
    allocator: std.mem.Allocator,
    items: []const MediaItem,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) void {
    _ = allocator;
    const t = theme.activeTheme();
    drawContainer(dc, rect);

    const padding = t.spacing.sm;
    const left = rect.min[0] + padding;
    var cursor_y = rect.min[1] + padding;

    theme.push(.heading);
    dc.drawText("Gallery", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const line_height = dc.lineHeight();
    cursor_y += line_height + t.spacing.xs;

    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) return;

    const thumb = 72.0;
    const cell_padding = t.spacing.sm;
    const cell = thumb + cell_padding * 2.0;
    const columns = @max(1, @as(usize, @intFromFloat((list_rect.size()[0] + cell_padding) / (cell + cell_padding))));
    const rows = (items.len + columns - 1) / columns;
    const total_height = @as(f32, @floatFromInt(rows)) * (cell + cell_padding);
    gallery_scroll_max = @max(0.0, total_height - list_rect.size()[1]);
    handleWheelScroll(queue, list_rect, &gallery_scroll_y, gallery_scroll_max, 32.0);

    if (!queue.state.mouse_down_left) {
        thumb_drag_index = null;
        thumb_drag_started = false;
    }
    for (queue.events.items) |evt| {
        if (evt == .mouse_up) {
            thumb_drag_index = null;
            thumb_drag_started = false;
        }
    }

    dc.pushClip(list_rect);
    var idx: usize = 0;
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < columns) : (col += 1) {
            if (idx >= items.len) break;
            const x = list_rect.min[0] + @as(f32, @floatFromInt(col)) * (cell + cell_padding);
            const y = list_rect.min[1] + @as(f32, @floatFromInt(row)) * (cell + cell_padding) - gallery_scroll_y;
            const cell_rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ cell, cell });
            if (cell_rect.max[1] >= list_rect.min[1] and cell_rect.min[1] <= list_rect.max[1]) {
                drawThumb(dc, items[idx], idx, cell_rect, thumb, cell_padding, queue);
            }
            idx += 1;
        }
    }
    dc.popClip();
}

fn drawThumb(
    dc: *draw_context.DrawContext,
    item: MediaItem,
    idx: usize,
    rect: draw_context.Rect,
    thumb: f32,
    padding: f32,
    queue: *input_state.InputQueue,
) void {
    const t = theme.activeTheme();
    const selected = selected_index != null and selected_index.? == idx;

    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and rect.contains(md.pos)) {
                    thumb_drag_index = idx;
                    thumb_drag_origin = md.pos;
                    thumb_drag_started = false;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos) and !(thumb_drag_index == idx and thumb_drag_started)) {
                    clicked = true;
                }
            },
            else => {},
        }
    }

    if (clicked) {
        selected_index = idx;
        viewer_fit_mode = .fit;
        viewer_zoom = 1.0;
        viewer_offset = .{ 0.0, 0.0 };
    }

    if (thumb_drag_index == idx and queue.state.mouse_down_left) {
        const dx = queue.state.mouse_pos[0] - thumb_drag_origin[0];
        const dy = queue.state.mouse_pos[1] - thumb_drag_origin[1];
        if (!thumb_drag_started and (dx * dx + dy * dy) > 9.0) {
            const sys = ui_systems.get();
            if (sys.drag_drop.active_drag == null) {
                drag_preview_label = item.name;
                sys.drag_drop.beginDrag(.{
                    .source_id = item.url,
                    .data_type = "image",
                    .preview_fn = drawDragPreview,
                });
                thumb_drag_started = true;
            }
        }
    }

    const hovered = rect.contains(queue.state.mouse_pos);
    const base = if (selected) t.colors.primary else t.colors.surface;
    const bg = colors.withAlpha(base, if (selected) 0.18 else if (hovered) 0.12 else 0.08);
    const border_alpha: f32 = if (selected) 0.8 else if (hovered) 0.6 else 0.4;
    dc.drawRoundedRect(rect, t.radius.sm, .{
        .fill = bg,
        .stroke = colors.withAlpha(t.colors.border, border_alpha),
        .thickness = 1.0,
    });

    const inner = .{ rect.min[0] + padding, rect.min[1] + padding };
    image_cache.request(item.url);
    if (image_cache.get(item.url)) |entry| {
        if (entry.state == .ready) {
            const tex_ref = draw_context.DrawContext.textureFromId(@as(u64, entry.texture_id));
            const w = @as(f32, @floatFromInt(entry.width));
            const h = @as(f32, @floatFromInt(entry.height));
            const aspect = if (h > 0) w / h else 1.0;
            var draw_w = thumb;
            var draw_h = thumb;
            if (aspect >= 1.0) {
                draw_h = thumb / aspect;
            } else {
                draw_w = thumb * aspect;
            }
            const centered = .{
                inner[0] + (thumb - draw_w) * 0.5,
                inner[1] + (thumb - draw_h) * 0.5,
            };
            dc.drawImage(tex_ref, draw_context.Rect.fromMinSize(centered, .{ draw_w, draw_h }));
        } else {
            dc.drawText("Loading", .{ inner[0], inner[1] + thumb * 0.4 }, .{ .color = t.colors.text_secondary });
        }
    } else {
        dc.drawText("Loading", .{ inner[0], inner[1] + thumb * 0.4 }, .{ .color = t.colors.text_secondary });
    }
}

fn drawViewer(dc: *draw_context.DrawContext, items: []const MediaItem, rect: draw_context.Rect, queue: *input_state.InputQueue) void {
    const t = theme.activeTheme();
    drawContainer(dc, rect);

    const padding = t.spacing.sm;
    const left = rect.min[0] + padding;
    var cursor_y = rect.min[1] + padding;

    theme.push(.heading);
    dc.drawText("Viewer", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const line_height = dc.lineHeight();
    cursor_y += line_height + t.spacing.xs;

    const controls_height = drawViewerControls(dc, queue, .{ left, cursor_y });
    cursor_y += controls_height + t.spacing.sm;

    const viewer_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding },
    );
    if (viewer_rect.size()[0] <= 0.0 or viewer_rect.size()[1] <= 0.0) return;

    const selected = if (selected_index != null and selected_index.? < items.len)
        items[selected_index.?]
    else
        items[0];

    drawViewerArea(dc, selected, viewer_rect, queue);
}

fn drawViewerControls(dc: *draw_context.DrawContext, queue: *input_state.InputQueue, pos: [2]f32) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    var cursor_x = pos[0];
    const cursor_y = pos[1];

    const labels = [_][]const u8{ "Fit", "Fill", "1:1", "-", "+", "Reset" };
    var widths: [labels.len]f32 = undefined;
    var idx: usize = 0;
    while (idx < labels.len) : (idx += 1) {
        widths[idx] = buttonWidth(dc, labels[idx], t);
    }

    if (drawButton(dc, queue, .{ cursor_x, cursor_y }, widths[0], button_height, labels[0], .secondary)) {
        viewer_fit_mode = .fit;
        viewer_offset = .{ 0.0, 0.0 };
    }
    cursor_x += widths[0] + t.spacing.sm;
    if (drawButton(dc, queue, .{ cursor_x, cursor_y }, widths[1], button_height, labels[1], .secondary)) {
        viewer_fit_mode = .fill;
        viewer_offset = .{ 0.0, 0.0 };
    }
    cursor_x += widths[1] + t.spacing.sm;
    if (drawButton(dc, queue, .{ cursor_x, cursor_y }, widths[2], button_height, labels[2], .secondary)) {
        viewer_fit_mode = .actual;
        viewer_zoom = 1.0;
        viewer_offset = .{ 0.0, 0.0 };
    }
    cursor_x += widths[2] + t.spacing.sm;
    if (drawButton(dc, queue, .{ cursor_x, cursor_y }, widths[3], button_height, labels[3], .ghost)) {
        viewer_zoom = std.math.clamp(viewer_zoom / 1.2, 0.2, 6.0);
        viewer_fit_mode = .custom;
    }
    cursor_x += widths[3] + t.spacing.xs;
    if (drawButton(dc, queue, .{ cursor_x, cursor_y }, widths[4], button_height, labels[4], .ghost)) {
        viewer_zoom = std.math.clamp(viewer_zoom * 1.2, 0.2, 6.0);
        viewer_fit_mode = .custom;
    }
    cursor_x += widths[4] + t.spacing.sm;
    if (drawButton(dc, queue, .{ cursor_x, cursor_y }, widths[5], button_height, labels[5], .ghost)) {
        viewer_fit_mode = .fit;
        viewer_zoom = 1.0;
        viewer_offset = .{ 0.0, 0.0 };
    }

    return button_height;
}

fn drawButton(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    height: f32,
    label: []const u8,
    variant: widgets.button.Variant,
) bool {
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    return widgets.button.draw(dc, rect, label, queue, .{ .variant = variant });
}

fn drawViewerArea(dc: *draw_context.DrawContext, item: MediaItem, rect: draw_context.Rect, queue: *input_state.InputQueue) void {
    const t = theme.activeTheme();

    const sys = ui_systems.get();
    sys.drag_drop.registerDropTarget(.{
        .id = "media_viewer",
        .bounds = .{ .min = rect.min, .max = rect.max },
        .accepts = &[_][]const u8{ "image" },
        .on_drop = handleDrop,
    }) catch {};

    dc.drawRect(rect, .{ .fill = colors.withAlpha(t.colors.surface, 0.4) });

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and rect.contains(md.pos)) {
                    viewer_dragging = true;
                    viewer_drag_last = md.pos;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    viewer_dragging = false;
                }
            },
            else => {},
        }
    }

    if (viewer_dragging and queue.state.mouse_down_left) {
        const delta = .{
            queue.state.mouse_pos[0] - viewer_drag_last[0],
            queue.state.mouse_pos[1] - viewer_drag_last[1],
        };
        viewer_offset[0] += delta[0];
        viewer_offset[1] += delta[1];
        viewer_drag_last = queue.state.mouse_pos;
    }

    image_cache.request(item.url);
    if (image_cache.get(item.url)) |entry| {
        if (entry.state == .ready) {
            const tex_ref = draw_context.DrawContext.textureFromId(@as(u64, entry.texture_id));
            const w = @as(f32, @floatFromInt(entry.width));
            const h = @as(f32, @floatFromInt(entry.height));
            const size = computeDrawSize(.{ w, h }, rect.size());
            const overflow = .{
                @max(0.0, size[0] - rect.size()[0]),
                @max(0.0, size[1] - rect.size()[1]),
            };
            viewer_offset[0] = std.math.clamp(viewer_offset[0], -overflow[0] * 0.5, overflow[0] * 0.5);
            viewer_offset[1] = std.math.clamp(viewer_offset[1], -overflow[1] * 0.5, overflow[1] * 0.5);

            const origin = .{
                rect.min[0] + (rect.size()[0] - size[0]) * 0.5 + viewer_offset[0],
                rect.min[1] + (rect.size()[1] - size[1]) * 0.5 + viewer_offset[1],
            };
            dc.drawImage(tex_ref, draw_context.Rect.fromMinSize(origin, size));
        } else {
            dc.drawText("Loading image...", .{ rect.min[0] + 12.0, rect.min[1] + 12.0 }, .{ .color = t.colors.text_secondary });
        }
    } else {
        dc.drawText("Loading image...", .{ rect.min[0] + 12.0, rect.min[1] + 12.0 }, .{ .color = t.colors.text_secondary });
    }
}

fn computeDrawSize(image: [2]f32, container: [2]f32) [2]f32 {
    const scale = switch (viewer_fit_mode) {
        .fit => blk: {
            const sx = container[0] / image[0];
            const sy = container[1] / image[1];
            break :blk @min(sx, sy);
        },
        .fill => blk: {
            const sx = container[0] / image[0];
            const sy = container[1] / image[1];
            break :blk @max(sx, sy);
        },
        .actual => 1.0,
        .custom => viewer_zoom,
    };
    return .{ image[0] * scale, image[1] * scale };
}

fn handleDrop(payload: drag_drop.DragPayload) void {
    pending_drop_url = payload.source_id;
}

fn applyPendingDrop(items: []const MediaItem) void {
    if (pending_drop_url) |url| {
        for (items, 0..) |item, idx| {
            if (std.mem.eql(u8, item.url, url)) {
                selected_index = idx;
                viewer_fit_mode = .fit;
                viewer_zoom = 1.0;
                viewer_offset = .{ 0.0, 0.0 };
                break;
            }
        }
        pending_drop_url = null;
    }
}

fn drawDragPreview(dc: *draw_context.DrawContext, pos: [2]f32) void {
    const label = drag_preview_label orelse "Media";
    draw_context.drawOverlayLabel(dc, label, pos);
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

fn handleStackResize(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    top_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    gap: f32,
    min_top: f32,
    max_top: f32,
) void {
    const t = theme.activeTheme();
    const divider_h: f32 = 6.0;
    const divider_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0], top_rect.max[1] + gap * 0.5 - divider_h * 0.5 },
        .{ rect.size()[0], divider_h },
    );
    const hover = divider_rect.contains(queue.state.mouse_pos);
    if (hover) {
        cursor.set(.resize_ns);
    }
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and divider_rect.contains(md.pos)) {
                    stack_dragging = true;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    stack_dragging = false;
                }
            },
            else => {},
        }
    }
    if (stack_dragging) {
        const target = queue.state.mouse_pos[1] - rect.min[1];
        stack_height = std.math.clamp(target, min_top, max_top);
    }
    const divider = draw_context.Rect.fromMinSize(
        .{ rect.min[0], top_rect.max[1] + gap * 0.5 - 1.0 },
        .{ rect.size()[0], 2.0 },
    );
    const alpha: f32 = if (hover or stack_dragging) 0.25 else 0.12;
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

fn drawContainer(dc: *draw_context.DrawContext, rect: draw_context.Rect) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.md, .{
        .fill = t.colors.surface,
        .stroke = t.colors.border,
        .thickness = 1.0,
    });
}

fn buttonWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    const text_w = dc.measureText(label, 0.0)[0];
    return text_w + t.spacing.sm * 2.0;
}

fn messagesForCurrentSession(ctx: *state.ClientContext) []const types.ChatMessage {
    if (ctx.current_session) |session_key| {
        if (ctx.findSessionState(session_key)) |session_state| {
            return session_state.messages.items;
        }
    }
    return &[_]types.ChatMessage{};
}

fn collectImages(messages: []const types.ChatMessage, buf: []MediaItem) []MediaItem {
    var len: usize = 0;
    var index: usize = messages.len;
    while (index > 0 and len < buf.len) : (index -= 1) {
        const message = messages[index - 1];
        if (message.attachments) |attachments| {
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                if (!isImageAttachment(attachment)) continue;
                const name = attachment.name orelse attachment.url;
                buf[len] = .{ .name = name, .url = attachment.url };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn isImageAttachment(att: types.ChatAttachment) bool {
    if (std.mem.indexOf(u8, att.kind, "image") != null) return true;
    if (std.mem.startsWith(u8, att.url, "data:image/")) return true;
    return endsWithIgnoreCase(att.url, ".png") or
        endsWithIgnoreCase(att.url, ".jpg") or
        endsWithIgnoreCase(att.url, ".jpeg") or
        endsWithIgnoreCase(att.url, ".gif") or
        endsWithIgnoreCase(att.url, ".webp");
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
