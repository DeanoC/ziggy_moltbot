const std = @import("std");
const state = @import("../../client/state.zig");
const workspace = @import("../workspace.zig");
const draw_context = @import("../draw_context.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const widgets = @import("../widgets/widgets.zig");

pub const InboxAction = struct {};

const Severity = enum { info, warning, danger };
const Status = enum { unread, read };

const Item = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
    severity: Severity,
    status: Status,
    created_at_ms: i64,
};

const Filter = enum { all, unread, read };

var active_filter: Filter = .all;
var list_scroll_y: f32 = 0.0;
var list_scroll_max: f32 = 0.0;
var selected_index: usize = 0;

// Since items are placeholder/mock and returned as const, keep a tiny local override
// for interactive toggling (read/unread) until the real data/store lands.
var mock_status_overrides: [16]?Status = [_]?Status{null} ** 16;

// Minimal placeholder for actions like Archive/Delete. Hidden items are removed from
// the list until the underlying store exists.
var mock_hidden_overrides: [16]bool = [_]bool{false} ** 16;

var search_editor: ?widgets.text_editor.TextEditor = null;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    panel: *workspace.ControlPanel,
    rect: draw_context.Rect,
) InboxAction {
    _ = ctx;
    _ = panel;

    const action: InboxAction = .{};
    const t = theme.activeTheme();

    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, rect);
    defer dc.deinit();

    dc.drawRect(rect, .{ .fill = t.colors.background });
    const queue = input_router.getQueue();

    const header_h = drawHeader(&dc, rect, queue);

    const content_y = rect.min[1] + header_h + t.spacing.sm;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.md, content_y },
        .{ rect.size()[0] - t.spacing.md * 2.0, rect.max[1] - content_y - t.spacing.md },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) return action;

    const split_gap = t.spacing.md;
    const left_w = @floor(content_rect.size()[0] * 0.42);
    const right_w = content_rect.size()[0] - left_w - split_gap;

    const list_rect = draw_context.Rect.fromMinSize(content_rect.min, .{ left_w, content_rect.size()[1] });
    const detail_rect = draw_context.Rect.fromMinSize(
        .{ content_rect.min[0] + left_w + split_gap, content_rect.min[1] },
        .{ right_w, content_rect.size()[1] },
    );

    const items = mockItems();

    const search = drawSearch(allocator, &dc, list_rect, queue);
    const query = std.mem.trim(u8, editorText(search_editor), " \t\n");

    const counts = computeCounts(items, query);

    const prev_filter = active_filter;
    const filters_rect = draw_context.Rect.fromMinSize(
        .{ list_rect.min[0], list_rect.min[1] + search.height + t.spacing.sm },
        .{ list_rect.size()[0], 0.0 },
    );
    const filters_h = drawFilters(&dc, filters_rect, queue, counts);

    // Keyboard shortcuts: left/right cycles filter.
    for (queue.events.items) |evt| {
        if (evt == .key_down and !evt.key_down.repeat) {
            switch (evt.key_down.key) {
                .left_arrow => {
                    active_filter = switch (active_filter) {
                        .all => .read,
                        .unread => .all,
                        .read => .unread,
                    };
                },
                .right_arrow => {
                    active_filter = switch (active_filter) {
                        .all => .unread,
                        .unread => .read,
                        .read => .all,
                    };
                },
                else => {},
            }
        }
    }

    if (active_filter != prev_filter or search.changed) {
        list_scroll_y = 0.0;
    }

    var visible = std.ArrayList(usize).empty;
    defer visible.deinit(allocator);
    for (items, 0..) |it, idx| {
        if (isHidden(idx)) continue;
        if (!matchesQuery(it, query)) continue;
        if (!matchesFilter(idx, it)) continue;
        _ = visible.append(allocator, idx) catch {};
    }

    if (visible.items.len > 1) {
        std.sort.heap(usize, visible.items, items, itemCreatedDesc);
    }

    // Ensure selection stays on a visible item.
    if (visible.items.len > 0) {
        var is_visible = false;
        for (visible.items) |idx| {
            if (idx == selected_index) {
                is_visible = true;
                break;
            }
        }
        if (!is_visible) selected_index = visible.items[0];
    }

    handleListKeys(queue, visible.items);

    // Keyboard shortcuts: enter / a toggles read/unread for the selected mock item.
    for (queue.events.items) |evt| {
        if (evt == .key_down and !evt.key_down.repeat) {
            switch (evt.key_down.key) {
                .enter, .a => {
                    if (selected_index < items.len) toggleMockRead(selected_index, items[selected_index].status);
                },
                else => {},
            }
        }
    }

    const reserved_h = search.height + t.spacing.sm + filters_h + t.spacing.sm;
    const list_body = draw_context.Rect.fromMinSize(
        .{ list_rect.min[0], list_rect.min[1] + reserved_h },
        .{ list_rect.size()[0], list_rect.size()[1] - reserved_h },
    );

    drawList(&dc, list_body, queue, items, visible.items);
    drawDetail(allocator, &dc, detail_rect, queue, items);

    return action;
}

fn drawHeader(dc: *draw_context.DrawContext, rect: draw_context.Rect, queue: *input_state.InputQueue) f32 {
    const t = theme.activeTheme();
    const top = rect.min[1] + t.spacing.md;
    const left = rect.min[0] + t.spacing.md;

    theme.push(.title);
    const title_h = dc.lineHeight();
    dc.drawText("Inbox (mock)", .{ left, top }, .{ .color = t.colors.text_primary });
    theme.pop();

    const btn_h = dc.lineHeight() + t.spacing.xs * 2.0;
    const btn_label = "Reset";
    const btn_w = dc.measureText(btn_label, 0.0)[0] + t.spacing.sm * 2.0;
    const btn_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - t.spacing.md - btn_w, top },
        .{ btn_w, btn_h },
    );
    if (widgets.button.draw(dc, btn_rect, btn_label, queue, .{ .variant = .ghost })) {
        resetMockState();
    }

    const subtitle_y = top + title_h + t.spacing.xs;
    dc.drawText("Placeholder data + basic shell (list/search/filters/detail/actions)", .{ left, subtitle_y }, .{ .color = t.colors.text_secondary });

    return t.spacing.md + title_h + t.spacing.xs + dc.lineHeight() + t.spacing.sm;
}

const Counts = struct {
    total: usize,
    unread: usize,
    read: usize,
};

fn computeCounts(items: []const Item, query: []const u8) Counts {
    var c: Counts = .{ .total = 0, .unread = 0, .read = 0 };
    for (items, 0..) |it, idx| {
        if (isHidden(idx)) continue;
        if (!matchesQuery(it, query)) continue;
        c.total += 1;
        switch (effectiveStatus(idx, it.status)) {
            .unread => c.unread += 1,
            .read => c.read += 1,
        }
    }
    return c;
}

const SearchRowResult = struct {
    height: f32,
    changed: bool,
};

fn drawSearch(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
) SearchRowResult {
    const t = theme.activeTheme();
    const line_h = dc.lineHeight();
    const input_h = widgets.text_input.defaultHeight(line_h);

    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) {
        return .{ .height = input_h, .changed = false };
    }

    const editor = ensureEditor(&search_editor, allocator);
    const gap = t.spacing.xs;
    const clear_label = "Clear";
    const clear_w = dc.measureText(clear_label, 0.0)[0] + t.spacing.sm * 2.0;

    const min_input_w: f32 = 80.0;
    const can_show_clear = rect.size()[0] > min_input_w + gap + clear_w;
    const has_query = std.mem.trim(u8, editor.slice(), " \t\n").len > 0;

    const input_w = if (can_show_clear) rect.size()[0] - clear_w - gap else rect.size()[0];
    const input_rect = draw_context.Rect.fromMinSize(rect.min, .{ input_w, input_h });
    const action = widgets.text_input.draw(editor, allocator, dc, input_rect, queue, .{
        .placeholder = "Search...",
    });

    var changed = action.changed;

    if (can_show_clear) {
        const clear_rect = draw_context.Rect.fromMinSize(.{ input_rect.max[0] + gap, rect.min[1] }, .{ clear_w, input_h });
        const clicked = widgets.button.draw(dc, clear_rect, clear_label, queue, .{
            .variant = .ghost,
            .disabled = !has_query,
        });
        if (clicked) {
            editor.clear();
            changed = true;
        }
    }

    return .{ .height = input_h, .changed = changed };
}

fn drawFilters(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    counts: Counts,
) f32 {
    const t = theme.activeTheme();
    const line_h = dc.lineHeight();
    const pill_h = line_h + t.spacing.xs * 2.0;

    var all_buf: [32]u8 = undefined;
    var unread_buf: [32]u8 = undefined;
    var read_buf: [32]u8 = undefined;
    const all_label = std.fmt.bufPrint(&all_buf, "All ({d})", .{counts.total}) catch "All";
    const unread_label = std.fmt.bufPrint(&unread_buf, "Unread ({d})", .{counts.unread}) catch "Unread";
    const read_label = std.fmt.bufPrint(&read_buf, "Read ({d})", .{counts.read}) catch "Read";

    var cursor_x = rect.min[0];
    const y = rect.min[1];

    const all_w = tabWidth(dc, all_label, t);
    const all_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ all_w, pill_h });
    if (drawTab(dc, all_rect, all_label, active_filter == .all, queue)) active_filter = .all;
    cursor_x += all_w + t.spacing.xs;

    const unread_w = tabWidth(dc, unread_label, t);
    const unread_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ unread_w, pill_h });
    if (drawTab(dc, unread_rect, unread_label, active_filter == .unread, queue)) active_filter = .unread;
    cursor_x += unread_w + t.spacing.xs;

    const read_w = tabWidth(dc, read_label, t);
    const read_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ read_w, pill_h });
    if (drawTab(dc, read_rect, read_label, active_filter == .read, queue)) active_filter = .read;

    return pill_h;
}

fn handleListKeys(queue: *input_state.InputQueue, visible_indices: []const usize) void {
    if (visible_indices.len == 0) return;

    // Find current selection position within visible list.
    var cur_pos: usize = 0;
    for (visible_indices, 0..) |idx, pos| {
        if (idx == selected_index) {
            cur_pos = pos;
            break;
        }
    }

    for (queue.events.items) |evt| {
        if (evt == .key_down and !evt.key_down.repeat) {
            switch (evt.key_down.key) {
                .up_arrow => {
                    if (cur_pos > 0) cur_pos -= 1;
                },
                .down_arrow => {
                    if (cur_pos + 1 < visible_indices.len) cur_pos += 1;
                },
                .page_up => {
                    const step: usize = 8;
                    cur_pos = if (cur_pos > step) cur_pos - step else 0;
                },
                .page_down => {
                    const step: usize = 8;
                    cur_pos = @min(visible_indices.len - 1, cur_pos + step);
                },
                .home => cur_pos = 0,
                .end => cur_pos = visible_indices.len - 1,
                else => {},
            }
        }
    }

    selected_index = visible_indices[cur_pos];
}

fn drawList(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    items: []const Item,
    visible_indices: []const usize,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    if (visible_indices.len == 0) {
        dc.drawText("No items.", rect.min, .{ .color = t.colors.text_secondary });
        return;
    }

    const card_gap = t.spacing.sm;
    const card_h = dc.lineHeight() * 2.0 + t.spacing.sm * 2.0;
    const total_h = (@as(f32, @floatFromInt(visible_indices.len)) * (card_h + card_gap)) - card_gap;

    list_scroll_max = @max(0.0, total_h - rect.size()[1]);
    handleWheelScroll(queue, rect, &list_scroll_y, list_scroll_max, 36.0);

    dc.pushClip(rect);
    var y = rect.min[1] - list_scroll_y;

    for (visible_indices) |item_idx| {
        const it = items[item_idx];
        const card_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], card_h });
        if (card_rect.max[1] >= rect.min[1] and card_rect.min[1] <= rect.max[1]) {
            const is_selected = selected_index == item_idx;
            if (drawItemCard(dc, card_rect, queue, item_idx, it, is_selected)) {
                selected_index = item_idx;
            }
        }
        y += card_h + card_gap;
    }

    dc.popClip();

    if (list_scroll_y > list_scroll_max) list_scroll_y = list_scroll_max;
    if (list_scroll_y < 0.0) list_scroll_y = 0.0;
}

fn drawDetail(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    items: []const Item,
) void {
    const t = theme.activeTheme();

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const pad = t.spacing.md;
    var cursor_y = rect.min[1] + pad;

    if (items.len == 0 or selected_index >= items.len) {
        dc.drawText("Select an item", .{ rect.min[0] + pad, cursor_y }, .{ .color = t.colors.text_secondary });
        return;
    }

    const it = items[selected_index];

    theme.push(.heading);
    dc.drawText(it.title, .{ rect.min[0] + pad, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += dc.lineHeight() + t.spacing.xs;

    const meta_color = t.colors.text_secondary;
    var buf: [96]u8 = undefined;
    var time_buf: [32]u8 = undefined;
    const sev = severityLabel(it.severity);
    const st = effectiveStatus(selected_index, it.status);
    const status = if (st == .unread) "unread" else "read";
    const when = formatRelativeTime(std.time.milliTimestamp(), it.created_at_ms, &time_buf);
    const meta = std.fmt.bufPrint(&buf, "{s} · {s} · {s}", .{ sev, status, when }) catch "";
    dc.drawText(meta, .{ rect.min[0] + pad, cursor_y }, .{ .color = meta_color });
    cursor_y += dc.lineHeight() + t.spacing.sm;

    const btn_h = dc.lineHeight() + t.spacing.xs * 2.0;
    const btn_gap = t.spacing.xs;
    const mark_label = if (st == .unread) "Mark read" else "Mark unread";
    const archive_label = "Archive";
    const delete_label = "Delete";

    const max_row_w = rect.max[0] - (rect.min[0] + pad);
    const mark_w = dc.measureText(mark_label, 0.0)[0] + t.spacing.sm * 2.0;
    const archive_w = dc.measureText(archive_label, 0.0)[0] + t.spacing.sm * 2.0;
    const delete_w = dc.measureText(delete_label, 0.0)[0] + t.spacing.sm * 2.0;

    var row_y = cursor_y;
    var x = rect.min[0] + pad;

    const single_row = (mark_w + btn_gap + archive_w + btn_gap + delete_w) <= max_row_w;

    const mark_rect = draw_context.Rect.fromMinSize(.{ x, row_y }, .{ mark_w, btn_h });
    if (widgets.button.draw(dc, mark_rect, mark_label, queue, .{ .variant = .secondary })) {
        toggleMockRead(selected_index, it.status);
    }

    if (single_row) {
        x += mark_w + btn_gap;
        const archive_rect = draw_context.Rect.fromMinSize(.{ x, row_y }, .{ archive_w, btn_h });
        if (widgets.button.draw(dc, archive_rect, archive_label, queue, .{ .variant = .ghost })) {
            hideMockItem(selected_index);
        }

        x += archive_w + btn_gap;
        const delete_rect = draw_context.Rect.fromMinSize(.{ x, row_y }, .{ delete_w, btn_h });
        if (widgets.button.draw(dc, delete_rect, delete_label, queue, .{ .variant = .ghost })) {
            hideMockItem(selected_index);
        }

        cursor_y += btn_h + t.spacing.sm;
    } else {
        cursor_y += btn_h + btn_gap;
        row_y = cursor_y;
        x = rect.min[0] + pad;

        const archive_rect = draw_context.Rect.fromMinSize(.{ x, row_y }, .{ archive_w, btn_h });
        if (widgets.button.draw(dc, archive_rect, archive_label, queue, .{ .variant = .ghost })) {
            hideMockItem(selected_index);
        }

        x += archive_w + btn_gap;
        const delete_rect = draw_context.Rect.fromMinSize(.{ x, row_y }, .{ delete_w, btn_h });
        if (widgets.button.draw(dc, delete_rect, delete_label, queue, .{ .variant = .ghost })) {
            hideMockItem(selected_index);
        }

        cursor_y += btn_h + t.spacing.sm;
    }

    dc.drawText("Tip: Enter/a toggles read/unread. Archive/Delete are mock (hide from list).", .{ rect.min[0] + pad, cursor_y }, .{ .color = meta_color });
    cursor_y += dc.lineHeight() + t.spacing.sm;

    const body_w = rect.size()[0] - pad * 2.0;
    _ = drawWrappedText(allocator, dc, it.body, .{ rect.min[0] + pad, cursor_y }, body_w, t.colors.text_primary);
}

fn drawItemCard(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    item_index: usize,
    it: Item,
    selected: bool,
) bool {
    const t = theme.activeTheme();

    const hovered = rect.contains(queue.state.mouse_pos);
    var clicked = false;
    for (queue.events.items) |evt| {
        if (evt == .mouse_up) {
            const mu = evt.mouse_up;
            if (mu.button == .left and rect.contains(mu.pos)) clicked = true;
        }
    }

    const stroke = if (selected) t.colors.primary else t.colors.border;
    const fill_base = if (selected) t.colors.primary else t.colors.surface;
    const fill = colors.withAlpha(fill_base, if (selected) 0.10 else if (hovered) 0.06 else 0.0);
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = fill, .stroke = stroke, .thickness = 1.0 });

    const pad = t.spacing.sm;
    var x = rect.min[0] + pad;
    var y = rect.min[1] + pad;

    const dot_r = 4.0;
    const dot = draw_context.Rect.fromMinSize(.{ x, y + 2.0 }, .{ dot_r * 2.0, dot_r * 2.0 });
    dc.drawRoundedRect(dot, dot_r, .{ .fill = severityColor(t, it.severity), .stroke = null, .thickness = 0.0 });
    x += dot.size()[0] + t.spacing.sm;

    const status = effectiveStatus(item_index, it.status);
    const title_color = if (status == .unread) t.colors.text_primary else t.colors.text_secondary;
    dc.drawText(it.title, .{ x, y }, .{ .color = title_color });
    y += dc.lineHeight() + t.spacing.xs;

    var meta_buf: [96]u8 = undefined;
    var time_buf: [32]u8 = undefined;
    const when = formatRelativeTime(std.time.milliTimestamp(), it.created_at_ms, &time_buf);
    const meta = std.fmt.bufPrint(
        &meta_buf,
        "{s} · {s} · {s}",
        .{ severityLabel(it.severity), if (status == .unread) "unread" else "read", when },
    ) catch "";
    dc.drawText(meta, .{ x, y }, .{ .color = t.colors.text_secondary });

    return clicked;
}

fn effectiveStatus(index: usize, base: Status) Status {
    if (index < mock_status_overrides.len) {
        if (mock_status_overrides[index]) |st| return st;
    }
    return base;
}

fn toggleMockRead(index: usize, base: Status) void {
    if (index >= mock_status_overrides.len) return;
    const cur = effectiveStatus(index, base);
    mock_status_overrides[index] = switch (cur) {
        .unread => .read,
        .read => .unread,
    };
}

fn isHidden(index: usize) bool {
    if (index < mock_hidden_overrides.len) return mock_hidden_overrides[index];
    return false;
}

fn hideMockItem(index: usize) void {
    if (index >= mock_hidden_overrides.len) return;
    mock_hidden_overrides[index] = true;
    // Keep status override coherent if we're "deleting" the mock item.
    if (index < mock_status_overrides.len) mock_status_overrides[index] = null;
}

fn resetMockState() void {
    active_filter = .all;
    list_scroll_y = 0.0;
    list_scroll_max = 0.0;
    selected_index = 0;
    mock_status_overrides = [_]?Status{null} ** mock_status_overrides.len;
    mock_hidden_overrides = [_]bool{false} ** mock_hidden_overrides.len;

    if (search_editor) |*ed| {
        ed.clear();
    }
}

fn ensureEditor(slot: *?widgets.text_editor.TextEditor, allocator: std.mem.Allocator) *widgets.text_editor.TextEditor {
    if (slot.* == null) {
        slot.* = widgets.text_editor.TextEditor.init(allocator) catch unreachable;
    }
    return &slot.*.?;
}

fn editorText(editor: ?widgets.text_editor.TextEditor) []const u8 {
    if (editor) |value| {
        return value.slice();
    }
    return "";
}

fn itemCreatedDesc(items: []const Item, a: usize, b: usize) bool {
    return items[a].created_at_ms > items[b].created_at_ms;
}

fn matchesQuery(it: Item, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsIgnoreCase(it.title, query) or containsIgnoreCase(it.body, query) or containsIgnoreCase(it.id, query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }

    return false;
}

fn matchesFilter(index: usize, it: Item) bool {
    const st = effectiveStatus(index, it.status);
    return switch (active_filter) {
        .all => true,
        .unread => st == .unread,
        .read => st == .read,
    };
}

fn severityLabel(sev: Severity) []const u8 {
    return switch (sev) {
        .info => "info",
        .warning => "warning",
        .danger => "danger",
    };
}

fn severityColor(t: *const theme.Theme, sev: Severity) colors.Color {
    return switch (sev) {
        .info => t.colors.primary,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
    };
}

fn tabWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn drawTab(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    active: bool,
    queue: *input_state.InputQueue,
) bool {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);
    var clicked = false;
    for (queue.events.items) |evt| {
        if (evt == .mouse_up) {
            const mu = evt.mouse_up;
            if (mu.button == .left and rect.contains(mu.pos)) clicked = true;
        }
    }

    const base = if (active) t.colors.primary else t.colors.surface;
    const alpha: f32 = if (active) 0.18 else if (hovered) 0.10 else 0.0;
    const fill = colors.withAlpha(base, alpha);
    const border = colors.withAlpha(t.colors.border, if (active) 0.6 else 0.3);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = fill, .stroke = border, .thickness = 1.0 });

    const text_color = if (active) t.colors.primary else t.colors.text_secondary;
    const text_size = dc.measureText(label, 0.0);
    const text_pos = .{ rect.min[0] + (rect.size()[0] - text_size[0]) * 0.5, rect.min[1] + (rect.size()[1] - text_size[1]) * 0.5 };
    dc.drawText(label, text_pos, .{ .color = text_color });

    return clicked;
}

const Line = struct { start: usize, end: usize };

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

fn buildLinesInto(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
    lines: *std.ArrayList(Line),
) void {
    _ = allocator;
    lines.clearRetainingCapacity();
    const effective_wrap = if (wrap_width <= 1.0) 10_000.0 else wrap_width;
    var line_start: usize = 0;
    var line_width: f32 = 0.0;
    var last_space: ?usize = null;
    var index: usize = 0;

    while (index < text.len) {
        const ch = text[index];
        if (ch == '\n') {
            _ = lines.append(dc.allocator, .{ .start = line_start, .end = index }) catch {};
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
                _ = lines.append(dc.allocator, .{ .start = line_start, .end = last_space.? - 1 }) catch {};
                index = last_space.?;
            } else {
                _ = lines.append(dc.allocator, .{ .start = line_start, .end = index }) catch {};
            }
            line_start = index;
            line_width = 0.0;
            last_space = null;
            continue;
        }

        line_width += char_w;
        index = next;
    }

    _ = lines.append(dc.allocator, .{ .start = line_start, .end = text.len }) catch {};
}

fn nextCharIndex(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const first = text[index];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const next = index + @as(usize, len);
    return if (next > text.len) text.len else next;
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

fn mockItems() []const Item {
    const now = std.time.milliTimestamp();
    return &[_]Item{
        .{ .id = "evt_001", .title = "Gateway restarted", .body = "The OpenClaw gateway restarted successfully.\n\nThis is placeholder content for the Inbox MVP shell.", .severity = .info, .status = .read, .created_at_ms = now - 1000 * 60 * 25 },
        .{ .id = "evt_002", .title = "Node offline: living-room", .body = "Last heartbeat exceeded threshold.\n\nIn the real inbox, this would include actions (e.g. retry/wake/ping).", .severity = .warning, .status = .unread, .created_at_ms = now - 1000 * 60 * 5 },
        .{ .id = "evt_003", .title = "Supermemory 401 (auth)", .body = "Plugin returned HTTP 401 for request /search.\n\nIn production, this should dedupe and surface remediation hints.", .severity = .danger, .status = .unread, .created_at_ms = now - 1000 * 60 * 2 },
        .{ .id = "evt_004", .title = "New release available", .body = "A newer ZiggyStarClaw build is available for download.\n\nIn a real inbox, this would link to release notes.", .severity = .info, .status = .unread, .created_at_ms = now - 1000 * 60 * 52 },
        .{ .id = "evt_005", .title = "Disk space low: /safe", .body = "Storage usage is above 90%.\n\nSuggested next step: prune caches / old artifacts (mock).", .severity = .warning, .status = .unread, .created_at_ms = now - 1000 * 60 * 80 },
        .{ .id = "evt_006", .title = "Agent crash: worker-7", .body = "An agent session terminated unexpectedly.\n\nIn production, this should include a crash log attachment.", .severity = .danger, .status = .read, .created_at_ms = now - 1000 * 60 * 60 * 3 },
        .{ .id = "evt_007", .title = "Node battery low: kitchen-tablet", .body = "Battery reported at 12%.\n\nIn a real inbox, this could offer a 'snooze' action.", .severity = .warning, .status = .read, .created_at_ms = now - 1000 * 60 * 12 },
        .{ .id = "evt_008", .title = "Config saved", .body = "Configuration changes were written successfully.", .severity = .info, .status = .read, .created_at_ms = now - 1000 * 60 * 60 * 26 },
    };
}

fn formatRelativeTime(now_ms: i64, ts_ms: i64, buf: []u8) []const u8 {
    const delta_ms = if (now_ms > ts_ms) now_ms - ts_ms else 0;
    const seconds = @as(u64, @intCast(@divTrunc(delta_ms, 1000)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;

    if (seconds < 60) {
        return std.fmt.bufPrint(buf, "{d}s ago", .{seconds}) catch "just now";
    }
    if (minutes < 60) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "today";
    }
    if (hours < 24) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "today";
    }
    return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "days ago";
}
