const std = @import("std");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const draw_context = @import("../../draw_context.zig");
const input_router = @import("../../input/input_router.zig");
const input_state = @import("../../input/input_state.zig");
const widgets = @import("../../widgets/widgets.zig");
const cursor = @import("../../input/cursor.zig");

pub const SourceType = enum {
    local,
    cloud,
    git,
};

pub const Source = struct {
    name: []const u8,
    source_type: SourceType = .local,
    connected: bool = true,
};

pub const FileEntry = struct {
    name: []const u8,
    language: ?[]const u8 = null,
    status: ?[]const u8 = null,
    dirty: bool = false,
};

pub const SplitState = struct {
    size: f32 = 220.0,
    dragging: bool = false,
};

pub const Args = struct {
    id: []const u8 = "source_browser",
    sources: []const Source = &[_]Source{},
    selected_source: ?usize = null,
    current_path: []const u8 = "",
    files: []const FileEntry = &[_]FileEntry{},
    selected_file: ?usize = null,
    sections: []const Section = &[_]Section{},
    split_state: ?*SplitState = null,
    show_add_source: bool = false,
    rect: ?draw_context.Rect = null,
};

pub const Action = struct {
    select_source: ?usize = null,
    select_file: ?usize = null,
    add_source: bool = false,
};

pub const Section = struct {
    name: []const u8,
    files: []const FileEntry,
    start_index: usize,
    expanded: *bool,
};

const Line = struct {
    start: usize,
    end: usize,
};

var default_split_state = SplitState{ .size = 220.0 };

const max_scroll_states = 64;
var scroll_ids: [max_scroll_states]u64 = [_]u64{0} ** max_scroll_states;
var scroll_vals: [max_scroll_states]f32 = [_]f32{0.0} ** max_scroll_states;
var scroll_len: usize = 0;

fn scrollFor(id: []const u8, salt: u64) *f32 {
    const hash = std.hash.Wyhash.hash(0, id) ^ salt;
    var idx: usize = 0;
    while (idx < scroll_len) : (idx += 1) {
        if (scroll_ids[idx] == hash) {
            return &scroll_vals[idx];
        }
    }
    if (scroll_len < max_scroll_states) {
        scroll_ids[scroll_len] = hash;
        scroll_vals[scroll_len] = 0.0;
        scroll_len += 1;
        return &scroll_vals[scroll_len - 1];
    }
    return &scroll_vals[0];
}

fn sourceTypeLabel(source_type: SourceType) []const u8 {
    return switch (source_type) {
        .local => "local",
        .cloud => "cloud",
        .git => "git",
    };
}

fn sourceGroupLabel(source_type: SourceType) []const u8 {
    return switch (source_type) {
        .local => "Local Sources",
        .cloud => "Cloud Drives",
        .git => "Code Repos",
    };
}

pub fn draw(allocator: std.mem.Allocator, args: Args) Action {
    var action = Action{};
    const t = theme.activeTheme();
    var split_state = args.split_state orelse &default_split_state;
    if (split_state.size == 0.0) {
        split_state.size = 220.0;
    }

    const panel_rect = args.rect orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();
    dc.drawRoundedRect(panel_rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0] + padding, panel_rect.min[1] + padding },
        .{ panel_rect.size()[0] - padding * 2.0, panel_rect.size()[1] - padding * 2.0 },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) {
        return action;
    }

    const splitter_w: f32 = 6.0;
    const min_primary: f32 = 180.0;
    const min_secondary: f32 = 220.0;
    const max_primary = @max(min_primary, content_rect.size()[0] - min_secondary - splitter_w);
    split_state.size = std.math.clamp(split_state.size, min_primary, max_primary);

    const left_rect = draw_context.Rect.fromMinSize(
        content_rect.min,
        .{ split_state.size, content_rect.size()[1] },
    );
    const right_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + splitter_w, content_rect.min[1] },
        .{ content_rect.max[0] - left_rect.max[0] - splitter_w, content_rect.size()[1] },
    );

    const queue = input_router.getQueue();
    drawSourcesPane(args, &dc, left_rect, queue, &action);
    handleSplitter(&dc, content_rect, left_rect, queue, split_state, min_primary, max_primary, splitter_w);
    if (right_rect.size()[0] > 0.0) {
        drawFilesPane(args, &dc, right_rect, queue, &action);
    }

    return action;
}

fn drawSourcesPane(
    args: Args,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *Action,
) void {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Sources", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += line_height + t.spacing.sm;

    const add_height = if (args.show_add_source) button_height + t.spacing.sm else 0.0;
    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding - add_height },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) {
        return;
    }

    dc.drawRoundedRect(list_rect, t.radius.sm, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });
    const inner_rect = draw_context.Rect.fromMinSize(
        .{ list_rect.min[0] + padding, list_rect.min[1] + padding },
        .{ list_rect.size()[0] - padding * 2.0, list_rect.size()[1] - padding * 2.0 },
    );

    var content_height: f32 = 0.0;
    var last_type: ?SourceType = null;
    const row_height = line_height + t.spacing.xs * 2.0;
    const row_gap = t.spacing.xs;
    for (args.sources) |source| {
        if (last_type == null or last_type.? != source.source_type) {
            if (last_type != null) {
                content_height += t.spacing.xs;
            }
            content_height += line_height + t.spacing.xs;
            content_height += 1.0 + t.spacing.xs;
            last_type = source.source_type;
        }
        content_height += row_height + row_gap;
    }
    if (args.sources.len == 0) {
        content_height = line_height;
    }

    const scroll_ptr = scrollFor(args.id, 0x51504E);
    const max_scroll = @max(0.0, content_height - inner_rect.size()[1]);
    handleWheelScroll(queue, inner_rect, scroll_ptr, max_scroll, 28.0);

    dc.pushClip(inner_rect);
    var y = inner_rect.min[1] - scroll_ptr.*;
    last_type = null;
    if (args.sources.len == 0) {
        dc.drawText("No sources available.", .{ inner_rect.min[0], y }, .{ .color = t.colors.text_secondary });
    } else {
        for (args.sources, 0..) |source, idx| {
            if (last_type == null or last_type.? != source.source_type) {
                if (last_type != null) {
                    y += t.spacing.xs;
                }
                dc.drawText(sourceGroupLabel(source.source_type), .{ inner_rect.min[0], y }, .{ .color = t.colors.text_secondary });
                y += line_height + t.spacing.xs;
                dc.drawRect(draw_context.Rect.fromMinSize(.{ inner_rect.min[0], y }, .{ inner_rect.size()[0], 1.0 }), .{ .fill = t.colors.divider });
                y += 1.0 + t.spacing.xs;
                last_type = source.source_type;
            }

            const row_rect = draw_context.Rect.fromMinSize(.{ inner_rect.min[0], y }, .{ inner_rect.size()[0], row_height });
            if (row_rect.max[1] >= inner_rect.min[1] and row_rect.min[1] <= inner_rect.max[1]) {
                const selected = args.selected_source != null and args.selected_source.? == idx;
                var label_buf: [196]u8 = undefined;
                const status = if (source.connected) "connected" else "offline";
                const label = std.fmt.bufPrint(
                    &label_buf,
                    "{s} ({s}, {s})",
                    .{ source.name, sourceTypeLabel(source.source_type), status },
                ) catch source.name;
                if (drawSourceRow(dc, row_rect, label, selected, queue)) {
                    action.select_source = idx;
                }
            }
            y += row_height + row_gap;
        }
    }
    dc.popClip();

    if (scroll_ptr.* > max_scroll) scroll_ptr.* = max_scroll;
    if (scroll_ptr.* < 0.0) scroll_ptr.* = 0.0;

    if (args.show_add_source) {
        const button_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, rect.max[1] - padding - button_height },
            .{ buttonWidth(dc, "+ Add Source", t), button_height },
        );
        if (widgets.button.draw(dc, button_rect, "+ Add Source", queue, .{ .variant = .secondary })) {
            action.add_source = true;
        }
    }
}

fn drawFilesPane(
    args: Args,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *Action,
) void {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    var cursor_y = rect.min[1] + padding;

    if (args.current_path.len > 0) {
        const label = "Project Files ▾";
        const button_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ buttonWidth(dc, label, t), button_height },
        );
        _ = widgets.button.draw(dc, button_rect, label, queue, .{ .variant = .secondary });
        const path_x = button_rect.max[0] + t.spacing.sm;
        dc.drawText(args.current_path, .{ path_x, cursor_y + t.spacing.xs }, .{ .color = t.colors.text_secondary });
        cursor_y += button_height + t.spacing.sm;
    }

    const list_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, rect.max[1] - cursor_y - padding },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) {
        return;
    }
    dc.drawRoundedRect(list_rect, t.radius.sm, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    const inner_rect = draw_context.Rect.fromMinSize(
        .{ list_rect.min[0] + padding, list_rect.min[1] + padding },
        .{ list_rect.size()[0] - padding * 2.0, list_rect.size()[1] - padding * 2.0 },
    );

    const row_height = line_height + t.spacing.xs * 2.0;
    const row_gap = t.spacing.xs;
    var content_height: f32 = 0.0;
    if (args.sections.len > 0) {
        for (args.sections, 0..) |section, idx| {
            _ = idx;
            content_height += row_height;
            if (section.expanded.*) {
                content_height += @as(f32, @floatFromInt(section.files.len)) * (row_height + row_gap);
            }
            content_height += t.spacing.xs;
        }
    } else if (args.files.len == 0) {
        content_height = line_height;
    } else {
        content_height = @as(f32, @floatFromInt(args.files.len)) * (row_height + row_gap);
    }

    const scroll_ptr = scrollFor(args.id, 0xF11E5);
    const max_scroll = @max(0.0, content_height - inner_rect.size()[1]);
    handleWheelScroll(queue, inner_rect, scroll_ptr, max_scroll, 28.0);

    dc.pushClip(inner_rect);
    var y = inner_rect.min[1] - scroll_ptr.*;
    if (args.sections.len > 0) {
        for (args.sections) |section| {
            const header_rect = draw_context.Rect.fromMinSize(.{ inner_rect.min[0], y }, .{ inner_rect.size()[0], row_height });
            if (header_rect.max[1] >= inner_rect.min[1] and header_rect.min[1] <= inner_rect.max[1]) {
                if (drawSectionHeader(dc, header_rect, section, queue)) {
                    section.expanded.* = !section.expanded.*;
                }
            }
            y += row_height;
            if (section.expanded.*) {
                for (section.files, 0..) |file, idx| {
                    const row_rect = draw_context.Rect.fromMinSize(.{ inner_rect.min[0], y }, .{ inner_rect.size()[0], row_height });
                    if (row_rect.max[1] >= inner_rect.min[1] and row_rect.min[1] <= inner_rect.max[1]) {
                        const global_index = section.start_index + idx;
                        const selected = args.selected_file != null and args.selected_file.? == global_index;
                        if (drawFileRow(dc, row_rect, file, selected, queue)) {
                            action.select_file = global_index;
                        }
                    }
                    y += row_height + row_gap;
                }
            }
            y += t.spacing.xs;
        }
    } else if (args.files.len == 0) {
        dc.drawText("No files in this source.", .{ inner_rect.min[0], y }, .{ .color = t.colors.text_secondary });
    } else {
        for (args.files, 0..) |file, idx| {
            const row_rect = draw_context.Rect.fromMinSize(.{ inner_rect.min[0], y }, .{ inner_rect.size()[0], row_height });
            if (row_rect.max[1] >= inner_rect.min[1] and row_rect.min[1] <= inner_rect.max[1]) {
                const selected = args.selected_file != null and args.selected_file.? == idx;
                if (drawFileRow(dc, row_rect, file, selected, queue)) {
                    action.select_file = idx;
                }
            }
            y += row_height + row_gap;
        }
    }
    dc.popClip();

    if (scroll_ptr.* > max_scroll) scroll_ptr.* = max_scroll;
    if (scroll_ptr.* < 0.0) scroll_ptr.* = 0.0;
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

    const icon_size = rect.size()[1] - t.spacing.xs * 2.0;
    const icon_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs },
        .{ icon_size, icon_size },
    );
    dc.drawRoundedRect(icon_rect, 2.0, .{ .fill = colors.withAlpha(t.colors.primary, 0.18) });

    const text_pos = .{ icon_rect.max[0] + t.spacing.sm, rect.min[1] + t.spacing.xs };
    dc.drawText(label, text_pos, .{ .color = t.colors.text_primary });

    return clicked;
}

fn drawSectionHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    section: Section,
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
        dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(t.colors.primary, 0.08) });
    }

    const caret = if (section.expanded.*) "v" else ">";
    var label_buf: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s} {s}", .{ caret, section.name }) catch section.name;
    dc.drawText(label, .{ rect.min[0], rect.min[1] + t.spacing.xs }, .{ .color = t.colors.text_primary });
    return clicked;
}

fn drawFileRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    file: FileEntry,
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
    const text_pos = .{ icon_rect.max[0] + t.spacing.sm, rect.min[1] + t.spacing.xs };
    dc.drawText(name, text_pos, .{ .color = t.colors.text_primary });

    if (file.status) |status| {
        if (std.ascii.eqlIgnoreCase(status, "indexed")) {
            drawCheckmark(dc, t, rect, rect.size()[1]);
        } else {
            drawStatusBadge(dc, t, status, rect, rect.size()[1]);
        }
    }

    _ = file.dirty;
    return clicked;
}

fn drawStatusBadge(
    dc: *draw_context.DrawContext,
    t: *const theme.Theme,
    label: []const u8,
    rect: draw_context.Rect,
    row_height: f32,
) void {
    const label_size = dc.measureText(label, 0.0);
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    const badge_size = .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
    const x = rect.max[0] - badge_size[0] - t.spacing.sm;
    const y = rect.min[1] + (row_height - badge_size[1]) * 0.5;
    const variant = if (std.ascii.eqlIgnoreCase(label, "indexed"))
        t.colors.success
    else if (std.ascii.eqlIgnoreCase(label, "pending"))
        t.colors.warning
    else
        t.colors.primary;
    const bg = colors.withAlpha(variant, 0.18);
    const border = colors.withAlpha(variant, 0.4);
    const badge_rect = draw_context.Rect.fromMinSize(.{ x, y }, badge_size);
    dc.drawRoundedRect(badge_rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(label, .{ x + padding[0], y + padding[1] }, .{ .color = variant });
}

fn drawCheckmark(
    dc: *draw_context.DrawContext,
    t: *const theme.Theme,
    rect: draw_context.Rect,
    row_height: f32,
) void {
    const size = row_height * 0.35;
    const x = rect.max[0] - size - t.spacing.sm;
    const y = rect.min[1] + (row_height - size) * 0.5;
    const color = t.colors.success;
    dc.drawLine(.{ x, y + size * 0.6 }, .{ x + size * 0.4, y + size }, 2.0, color);
    dc.drawLine(.{ x + size * 0.4, y + size }, .{ x + size, y }, 2.0, color);
}

fn handleSplitter(
    dc: *draw_context.DrawContext,
    content_rect: draw_context.Rect,
    left_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    split_state: *SplitState,
    min_primary: f32,
    max_primary: f32,
    splitter_w: f32,
) void {
    const t = theme.activeTheme();
    const splitter_rect = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0], content_rect.min[1] },
        .{ splitter_w, content_rect.size()[1] },
    );
    const hover = splitter_rect.contains(queue.state.mouse_pos);
    if (hover) {
        cursor.set(.resize_ew);
    }

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and splitter_rect.contains(md.pos)) {
                    split_state.dragging = true;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    split_state.dragging = false;
                }
            },
            else => {},
        }
    }

    if (split_state.dragging) {
        const target = queue.state.mouse_pos[0] - content_rect.min[0];
        split_state.size = std.math.clamp(target, min_primary, max_primary);
    }

    const divider = draw_context.Rect.fromMinSize(
        .{ left_rect.max[0] + splitter_w * 0.5 - 1.0, content_rect.min[1] },
        .{ 2.0, content_rect.size()[1] },
    );
    const alpha: f32 = if (hover or split_state.dragging) 0.25 else 0.12;
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
