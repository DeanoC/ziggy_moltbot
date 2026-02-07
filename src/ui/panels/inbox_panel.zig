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
    const counts = computeCounts(items);

    const filters_h = drawFilters(&dc, list_rect, queue, counts);
    const list_body = draw_context.Rect.fromMinSize(
        .{ list_rect.min[0], list_rect.min[1] + filters_h + t.spacing.sm },
        .{ list_rect.size()[0], list_rect.size()[1] - filters_h - t.spacing.sm },
    );

    drawList(&dc, list_body, queue, items);
    drawDetail(allocator, &dc, detail_rect, items);

    return action;
}

fn drawHeader(dc: *draw_context.DrawContext, rect: draw_context.Rect, queue: *input_state.InputQueue) f32 {
    _ = queue;
    const t = theme.activeTheme();
    const top = rect.min[1] + t.spacing.md;
    const left = rect.min[0] + t.spacing.md;

    theme.push(.title);
    const title_h = dc.lineHeight();
    dc.drawText("Inbox (mock)", .{ left, top }, .{ .color = t.colors.text_primary });
    theme.pop();

    const subtitle_y = top + title_h + t.spacing.xs;
    dc.drawText("Placeholder data + basic shell (list/filters/detail)", .{ left, subtitle_y }, .{ .color = t.colors.text_secondary });

    return t.spacing.md + title_h + t.spacing.xs + dc.lineHeight() + t.spacing.sm;
}

const Counts = struct {
    total: usize,
    unread: usize,
    read: usize,
};

fn computeCounts(items: []const Item) Counts {
    var c: Counts = .{ .total = items.len, .unread = 0, .read = 0 };
    for (items) |it| {
        switch (it.status) {
            .unread => c.unread += 1,
            .read => c.read += 1,
        }
    }
    return c;
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

fn drawList(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    items: []const Item,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    var visible = std.ArrayList(usize).empty;
    defer visible.deinit(dc.allocator);

    for (items, 0..) |it, idx| {
        if (!matchesFilter(it)) continue;
        _ = visible.append(dc.allocator, idx) catch {};
    }

    if (visible.items.len == 0) {
        dc.drawText("No items.", rect.min, .{ .color = t.colors.text_secondary });
        return;
    }

    const card_gap = t.spacing.sm;
    const card_h = dc.lineHeight() * 2.0 + t.spacing.sm * 2.0;
    const total_h = (@as(f32, @floatFromInt(visible.items.len)) * (card_h + card_gap)) - card_gap;

    list_scroll_max = @max(0.0, total_h - rect.size()[1]);
    handleWheelScroll(queue, rect, &list_scroll_y, list_scroll_max, 36.0);

    dc.pushClip(rect);
    var y = rect.min[1] - list_scroll_y;

    for (visible.items, 0..) |item_idx, vis_idx| {
        const it = items[item_idx];
        const card_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], y }, .{ rect.size()[0], card_h });
        if (card_rect.max[1] >= rect.min[1] and card_rect.min[1] <= rect.max[1]) {
            const is_selected = selected_index == item_idx;
            if (drawItemCard(dc, card_rect, queue, it, is_selected)) {
                selected_index = item_idx;
            }
        }
        y += card_h + card_gap;
        _ = vis_idx;
    }

    dc.popClip();

    if (list_scroll_y > list_scroll_max) list_scroll_y = list_scroll_max;
    if (list_scroll_y < 0.0) list_scroll_y = 0.0;
}

fn drawDetail(allocator: std.mem.Allocator, dc: *draw_context.DrawContext, rect: draw_context.Rect, items: []const Item) void {
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
    var buf: [64]u8 = undefined;
    const sev = severityLabel(it.severity);
    const status = if (it.status == .unread) "unread" else "read";
    const meta = std.fmt.bufPrint(&buf, "{s} · {s}", .{ sev, status }) catch "";
    dc.drawText(meta, .{ rect.min[0] + pad, cursor_y }, .{ .color = meta_color });
    cursor_y += dc.lineHeight() + t.spacing.sm;

    const body_w = rect.size()[0] - pad * 2.0;
    _ = drawWrappedText(allocator, dc, it.body, .{ rect.min[0] + pad, cursor_y }, body_w, t.colors.text_primary);
}

fn drawItemCard(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
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

    const title_color = if (it.status == .unread) t.colors.text_primary else t.colors.text_secondary;
    dc.drawText(it.title, .{ x, y }, .{ .color = title_color });
    y += dc.lineHeight() + t.spacing.xs;

    var meta_buf: [64]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s} · {s}", .{ severityLabel(it.severity), if (it.status == .unread) "unread" else "read" }) catch "";
    dc.drawText(meta, .{ x, y }, .{ .color = t.colors.text_secondary });

    return clicked;
}

fn matchesFilter(it: Item) bool {
    return switch (active_filter) {
        .all => true,
        .unread => it.status == .unread,
        .read => it.status == .read,
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
    };
}
