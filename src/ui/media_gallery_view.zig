const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const components = @import("components/components.zig");
const image_cache = @import("image_cache.zig");
const ui_systems = @import("ui_systems.zig");
const drag_drop = @import("systems/drag_drop.zig");

const MediaItem = struct {
    name: []const u8,
    url: []const u8,
};

var selected_index: ?usize = null;
var split_state = components.layout.split_pane.SplitState{ .size = 260.0 };
var stack_split_state = components.layout.split_pane.SplitState{ .size = 360.0 };
var viewer_zoom: f32 = 1.0;
var viewer_offset: [2]f32 = .{ 0.0, 0.0 };
var viewer_fit_mode: FitMode = .fit;
var pending_drop_url: ?[]const u8 = null;
var drag_preview_label: ?[]const u8 = null;

const FitMode = enum { fit, fill, actual, custom };

pub fn draw(ctx: *state.ClientContext) void {
    const opened = zgui.beginChild("MediaGalleryView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        _ = components.layout.header_bar.begin(.{ .title = "Media Gallery", .subtitle = "Images & Previews" });
        components.layout.header_bar.end();

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        var items_buf: [64]MediaItem = undefined;
        const messages = messagesForCurrentSession(ctx);
        const items = collectImages(messages, &items_buf);
        if (items.len == 0) {
            zgui.textDisabled("No media available yet.", .{});
            zgui.endChild();
            return;
        }

        if (selected_index == null or selected_index.? >= items.len) {
            selected_index = 0;
        }
        applyPendingDrop(items);

        const avail = zgui.getContentRegionAvail();
        const use_stack = avail[0] < 780.0;
        if (use_stack) {
            drawStackedLayout(items, t);
        } else {
            drawSplitLayout(items, t);
        }
    }
    zgui.endChild();
}

fn drawSplitLayout(items: []const MediaItem, t: *const theme.Theme) void {
    const avail = zgui.getContentRegionAvail();
    if (split_state.size == 0.0) {
        split_state.size = @min(280.0, avail[0] * 0.3);
    }

    const split_args = components.layout.split_pane.Args{
        .id = "media_gallery_split",
        .axis = .vertical,
        .primary_size = split_state.size,
        .min_primary = 220.0,
        .min_secondary = 320.0,
        .border = true,
        .padded = true,
    };

    components.layout.split_pane.begin(split_args, &split_state);
    if (components.layout.split_pane.beginPrimary(split_args, &split_state)) {
        drawGallery(items, t);
    }
    components.layout.split_pane.endPrimary();
    components.layout.split_pane.handleSplitter(split_args, &split_state);
    if (components.layout.split_pane.beginSecondary(split_args, &split_state)) {
        drawViewer(items, t);
    }
    components.layout.split_pane.endSecondary();
    components.layout.split_pane.end();
}

fn drawStackedLayout(items: []const MediaItem, t: *const theme.Theme) void {
    const avail = zgui.getContentRegionAvail();
    if (stack_split_state.size == 0.0) {
        stack_split_state.size = avail[1] * 0.6;
    }
    const split_args = components.layout.split_pane.Args{
        .id = "media_gallery_stack",
        .axis = .horizontal,
        .primary_size = stack_split_state.size,
        .min_primary = 200.0,
        .min_secondary = 160.0,
        .border = true,
        .padded = true,
    };
    components.layout.split_pane.begin(split_args, &stack_split_state);
    if (components.layout.split_pane.beginPrimary(split_args, &stack_split_state)) {
        drawViewer(items, t);
    }
    components.layout.split_pane.endPrimary();
    components.layout.split_pane.handleSplitter(split_args, &stack_split_state);
    if (components.layout.split_pane.beginSecondary(split_args, &stack_split_state)) {
        drawGallery(items, t);
    }
    components.layout.split_pane.endSecondary();
    components.layout.split_pane.end();
}

fn drawGallery(items: []const MediaItem, t: *const theme.Theme) void {
    theme.push(.heading);
    zgui.text("Gallery", .{});
    theme.pop();
    zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });

    if (components.layout.scroll_area.begin(.{ .id = "MediaGalleryList", .border = true })) {
        const avail = zgui.getContentRegionAvail();
        const thumb = 72.0;
        const padding = t.spacing.sm;
        const cell = thumb + padding * 2.0;
        const columns = @max(1, @as(usize, @intFromFloat((avail[0] + padding) / (cell + padding))));

        for (items, 0..) |item, idx| {
            if (idx % columns != 0) {
                zgui.sameLine(.{ .spacing = padding });
            }
            drawThumb(item, idx, thumb, padding, t);
        }
    }
    components.layout.scroll_area.end();
}

fn drawThumb(item: MediaItem, idx: usize, thumb: f32, padding: f32, t: *const theme.Theme) void {
    const cursor = zgui.getCursorScreenPos();
    const size = thumb + padding * 2.0;
    const is_selected = selected_index != null and selected_index.? == idx;

    const id_z = zgui.formatZ("##media_thumb_{d}", .{idx});
    _ = zgui.invisibleButton(id_z, .{ .w = size, .h = size });
    if (zgui.isItemClicked(.left)) {
        selected_index = idx;
        viewer_fit_mode = .fit;
        viewer_zoom = 1.0;
        viewer_offset = .{ 0.0, 0.0 };
    }
    if (zgui.isItemActive() and zgui.isMouseDragging(.left, 2.0)) {
        const sys = ui_systems.get();
        if (sys.drag_drop.active_drag == null) {
            drag_preview_label = item.name;
            sys.drag_drop.beginDrag(.{
                .source_id = item.url,
                .data_type = "image",
                .preview_fn = drawDragPreview,
            });
        }
    }

    const draw_list = zgui.getWindowDrawList();
    const base = if (is_selected) t.colors.primary else t.colors.surface;
    const bg = colors.withAlpha(base, if (is_selected) 0.18 else 0.08);
    draw_list.addRectFilled(.{
        .pmin = cursor,
        .pmax = .{ cursor[0] + size, cursor[1] + size },
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = t.radius.sm,
    });
    draw_list.addRect(.{
        .pmin = cursor,
        .pmax = .{ cursor[0] + size, cursor[1] + size },
        .col = zgui.colorConvertFloat4ToU32(colors.withAlpha(t.colors.border, if (is_selected) 0.8 else 0.4)),
        .rounding = t.radius.sm,
    });

    image_cache.request(item.url);
    const inner = .{ cursor[0] + padding, cursor[1] + padding };
    if (image_cache.get(item.url)) |entry| {
        if (entry.state == .ready) {
            const tex_id: zgui.TextureIdent = @enumFromInt(@as(u64, entry.texture_id));
            const tex_ref = zgui.TextureRef{ .tex_data = null, .tex_id = tex_id };
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
            const draw_list2 = zgui.getWindowDrawList();
            draw_list2.addImage(tex_ref, .{
                .pmin = centered,
                .pmax = .{ centered[0] + draw_w, centered[1] + draw_h },
            });
        } else {
            draw_list.addText(.{ inner[0], inner[1] + thumb * 0.4 }, zgui.colorConvertFloat4ToU32(t.colors.text_secondary), "Loading", .{});
        }
    } else {
        draw_list.addText(.{ inner[0], inner[1] + thumb * 0.4 }, zgui.colorConvertFloat4ToU32(t.colors.text_secondary), "Loading", .{});
    }

    zgui.dummy(.{ .w = 0.0, .h = 0.0 });
}

fn drawViewer(items: []const MediaItem, t: *const theme.Theme) void {
    if (components.layout.card.begin(.{ .title = "Viewer", .id = "media_viewer" })) {
        const selected = if (selected_index != null and selected_index.? < items.len)
            items[selected_index.?]
        else
            items[0];

        drawViewerControls(t);
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });

        const viewer_id = zgui.formatZ("##media_viewer_area", .{});
        if (zgui.beginChild(viewer_id, .{ .h = 0.0, .child_flags = .{ .border = true } })) {
            drawViewerArea(selected, t);
        }
        zgui.endChild();
    }
    components.layout.card.end();
}

fn drawViewerControls(t: *const theme.Theme) void {
    if (components.core.button.draw("Fit", .{ .variant = .secondary, .size = .small })) {
        viewer_fit_mode = .fit;
        viewer_offset = .{ 0.0, 0.0 };
    }
    zgui.sameLine(.{ .spacing = t.spacing.sm });
    if (components.core.button.draw("Fill", .{ .variant = .secondary, .size = .small })) {
        viewer_fit_mode = .fill;
        viewer_offset = .{ 0.0, 0.0 };
    }
    zgui.sameLine(.{ .spacing = t.spacing.sm });
    if (components.core.button.draw("1:1", .{ .variant = .secondary, .size = .small })) {
        viewer_fit_mode = .actual;
        viewer_zoom = 1.0;
        viewer_offset = .{ 0.0, 0.0 };
    }
    zgui.sameLine(.{ .spacing = t.spacing.sm });
    if (components.core.button.draw("-", .{ .variant = .ghost, .size = .small })) {
        viewer_zoom = std.math.clamp(viewer_zoom / 1.2, 0.2, 6.0);
        viewer_fit_mode = .custom;
    }
    zgui.sameLine(.{ .spacing = t.spacing.xs });
    if (components.core.button.draw("+", .{ .variant = .ghost, .size = .small })) {
        viewer_zoom = std.math.clamp(viewer_zoom * 1.2, 0.2, 6.0);
        viewer_fit_mode = .custom;
    }
    zgui.sameLine(.{ .spacing = t.spacing.sm });
    if (components.core.button.draw("Reset", .{ .variant = .ghost, .size = .small })) {
        viewer_fit_mode = .fit;
        viewer_zoom = 1.0;
        viewer_offset = .{ 0.0, 0.0 };
    }
}

fn drawViewerArea(item: MediaItem, t: *const theme.Theme) void {
    const draw_list = zgui.getWindowDrawList();
    const cursor = zgui.getCursorScreenPos();
    const avail = zgui.getContentRegionAvail();
    const sys = ui_systems.get();
    sys.drag_drop.registerDropTarget(.{
        .id = "media_viewer",
        .bounds = .{
            .min = cursor,
            .max = .{ cursor[0] + avail[0], cursor[1] + avail[1] },
        },
        .accepts = &[_][]const u8{ "image" },
        .on_drop = handleDrop,
    }) catch {};

    draw_list.addRectFilled(.{
        .pmin = cursor,
        .pmax = .{ cursor[0] + avail[0], cursor[1] + avail[1] },
        .col = zgui.colorConvertFloat4ToU32(colors.withAlpha(t.colors.surface, 0.4)),
    });

    _ = zgui.invisibleButton("##media_viewer_input", .{ .w = avail[0], .h = avail[1] });
    if (zgui.isItemActive()) {
        const drag = zgui.getMouseDragDelta(.left, .{ .lock_threshold = 0.0 });
        viewer_offset[0] += drag[0];
        viewer_offset[1] += drag[1];
        zgui.resetMouseDragDelta(.left);
    }

    image_cache.request(item.url);
    if (image_cache.get(item.url)) |entry| {
        if (entry.state == .ready) {
            const tex_id: zgui.TextureIdent = @enumFromInt(@as(u64, entry.texture_id));
            const tex_ref = zgui.TextureRef{ .tex_data = null, .tex_id = tex_id };
            const w = @as(f32, @floatFromInt(entry.width));
            const h = @as(f32, @floatFromInt(entry.height));
            const size = computeDrawSize(.{ w, h }, avail);
            const overflow = .{
                @max(0.0, size[0] - avail[0]),
                @max(0.0, size[1] - avail[1]),
            };
            viewer_offset[0] = std.math.clamp(viewer_offset[0], -overflow[0] * 0.5, overflow[0] * 0.5);
            viewer_offset[1] = std.math.clamp(viewer_offset[1], -overflow[1] * 0.5, overflow[1] * 0.5);

            const origin = .{
                cursor[0] + (avail[0] - size[0]) * 0.5 + viewer_offset[0],
                cursor[1] + (avail[1] - size[1]) * 0.5 + viewer_offset[1],
            };
            draw_list.addImage(tex_ref, .{
                .pmin = origin,
                .pmax = .{ origin[0] + size[0], origin[1] + size[1] },
            });
        } else {
            draw_list.addText(.{ cursor[0] + 12.0, cursor[1] + 12.0 }, zgui.colorConvertFloat4ToU32(t.colors.text_secondary), "Loading image...", .{});
        }
    } else {
        draw_list.addText(.{ cursor[0] + 12.0, cursor[1] + 12.0 }, zgui.colorConvertFloat4ToU32(t.colors.text_secondary), "Loading image...", .{});
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

fn drawDragPreview(pos: [2]f32) void {
    const label = drag_preview_label orelse "Media";
    const t = theme.activeTheme();
    const draw_list = zgui.getForegroundDrawList();
    const padding = t.spacing.xs;
    const text_size = zgui.calcTextSize(label, .{});
    const rect = .{
        .min = .{ pos[0] + 12.0, pos[1] + 12.0 },
        .max = .{ pos[0] + 12.0 + text_size[0] + padding * 2.0, pos[1] + 12.0 + text_size[1] + padding * 2.0 },
    };
    draw_list.addRectFilled(.{
        .pmin = rect.min,
        .pmax = rect.max,
        .col = zgui.colorConvertFloat4ToU32(colors.withAlpha(t.colors.surface, 0.95)),
        .rounding = t.radius.sm,
    });
    draw_list.addRect(.{
        .pmin = rect.min,
        .pmax = rect.max,
        .col = zgui.colorConvertFloat4ToU32(colors.withAlpha(t.colors.border, 0.8)),
        .rounding = t.radius.sm,
    });
    draw_list.addText(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        zgui.colorConvertFloat4ToU32(t.colors.text_primary),
        "{s}",
        .{label},
    );
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
