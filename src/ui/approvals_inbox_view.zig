const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const operator_view = @import("operator_view.zig");

pub const ApprovalsInboxAction = struct {
    resolve_approval: ?operator_view.ExecApprovalResolveAction = null,
};

const Filter = enum {
    all,
    pending,
    resolved,
};

const BadgeVariant = enum {
    primary,
    success,
    warning,
    neutral,
};

const Line = struct {
    start: usize,
    end: usize,
};

var active_filter: Filter = .all;
var list_scroll_y: f32 = 0.0;
var list_scroll_max: f32 = 0.0;

const max_payload_scrolls = 64;
var payload_scroll_ids: [max_payload_scrolls]u64 = [_]u64{0} ** max_payload_scrolls;
var payload_scroll_vals: [max_payload_scrolls]f32 = [_]f32{0.0} ** max_payload_scrolls;
var payload_scroll_len: usize = 0;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    rect_override: ?draw_context.Rect,
) ApprovalsInboxAction {
    var action = ApprovalsInboxAction{};
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();

    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&dc, panel_rect, queue, ctx.approvals.items.len);

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

    const counts = Counts{
        .pending = ctx.approvals.items.len,
        .resolved = 0,
    };
    const filters_height = drawFilters(&dc, panel_rect, content_top, queue, counts);

    const list_top = content_top + filters_height + t.spacing.sm;
    const list_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], list_top },
        .{ panel_rect.size()[0], panel_rect.max[1] - list_top },
    );
    drawApprovalsList(allocator, ctx, &dc, list_rect, queue, &action, counts);

    return action;
}

const Counts = struct {
    pending: usize,
    resolved: usize,
};

fn drawHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    pending_count: usize,
) struct { height: f32 } {
    _ = queue;
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Approvals Needed", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Human-in-the-loop", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    var count_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&count_buf, "{d} pending", .{pending_count}) catch "0 pending";
    const badge_size = badgeSize(dc, label, t);
    const badge_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - t.spacing.md - badge_size[0], rect.min[1] + top_pad },
        badge_size,
    );
    drawBadge(dc, badge_rect, label, .primary);

    const height = top_pad + title_height + gap + subtitle_height + top_pad;
    return .{ .height = height };
}

fn drawFilters(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    start_y: f32,
    queue: *input_state.InputQueue,
    counts: Counts,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const pill_height = line_height + t.spacing.xs * 2.0;

    var all_buf: [24]u8 = undefined;
    var pending_buf: [24]u8 = undefined;
    var resolved_buf: [24]u8 = undefined;
    const all_label = std.fmt.bufPrint(&all_buf, "All ({d})", .{counts.pending + counts.resolved}) catch "All";
    const pending_label = std.fmt.bufPrint(&pending_buf, "Pending ({d})", .{counts.pending}) catch "Pending";
    const resolved_label = std.fmt.bufPrint(&resolved_buf, "Resolved ({d})", .{counts.resolved}) catch "Resolved";

    var cursor_x = rect.min[0] + padding;
    const y = start_y + t.spacing.sm;

    const all_width = pillWidth(dc, all_label, t);
    const all_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ all_width, pill_height });
    if (drawTab(dc, all_rect, all_label, active_filter == .all, queue)) {
        active_filter = .all;
    }
    cursor_x += all_width + t.spacing.sm;

    const pending_width = pillWidth(dc, pending_label, t);
    const pending_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ pending_width, pill_height });
    if (drawTab(dc, pending_rect, pending_label, active_filter == .pending, queue)) {
        active_filter = .pending;
    }
    cursor_x += pending_width + t.spacing.sm;

    const resolved_width = pillWidth(dc, resolved_label, t);
    const resolved_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ resolved_width, pill_height });
    if (drawTab(dc, resolved_rect, resolved_label, active_filter == .resolved, queue)) {
        active_filter = .resolved;
    }

    return t.spacing.sm + pill_height;
}

fn drawApprovalsList(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *ApprovalsInboxAction,
    counts: Counts,
) void {
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    if (active_filter == .resolved) {
        dc.drawText("No resolved approvals yet.", rect.min, .{ .color = t.colors.text_secondary });
        return;
    }

    if (counts.pending == 0) {
        dc.drawText("No pending approvals.", rect.min, .{ .color = t.colors.text_secondary });
        return;
    }

    const card_gap = t.spacing.md;
    var total_height: f32 = 0.0;
    for (ctx.approvals.items) |approval| {
        total_height += approvalCardHeight(allocator, dc, rect.size()[0], approval.summary, approval.payload_json, approval.can_resolve) + card_gap;
    }

    list_scroll_max = @max(0.0, total_height - rect.size()[1]);
    handleWheelScroll(queue, rect, &list_scroll_y, list_scroll_max, 36.0);

    dc.pushClip(rect);
    var cursor_y = rect.min[1] - list_scroll_y;
    for (ctx.approvals.items, 0..) |approval, idx| {
        const height = approvalCardHeight(allocator, dc, rect.size()[0], approval.summary, approval.payload_json, approval.can_resolve);
        const card_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0], cursor_y },
            .{ rect.size()[0], height },
        );
        if (card_rect.max[1] >= rect.min[1] and card_rect.min[1] <= rect.max[1]) {
            const decision = drawApprovalCard(allocator, dc, card_rect, queue, approval);
            if (decision != .none) {
                const id_copy = allocator.dupe(u8, approval.id) catch null;
                if (id_copy) |value| {
                    action.resolve_approval = operator_view.ExecApprovalResolveAction{
                        .request_id = value,
                        .decision = switch (decision) {
                            .allow_once => .allow_once,
                            .allow_always => .allow_always,
                            .deny => .deny,
                            .none => unreachable,
                        },
                    };
                }
            }
        }
        cursor_y += height + card_gap;
        _ = idx;
    }
    dc.popClip();
}

const ApprovalDecision = enum {
    none,
    allow_once,
    allow_always,
    deny,
};

fn drawApprovalCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    approval: types.ExecApproval,
) ApprovalDecision {
    const t = theme.activeTheme();
    const padding = t.spacing.md;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Approval Needed", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += dc.lineHeight();

    if (approval.summary) |summary| {
        cursor_y += t.spacing.xs;
        _ = drawWrappedText(allocator, dc, summary, .{ rect.min[0] + padding, cursor_y }, rect.size()[0] - padding * 2.0, t.colors.text_primary);
        cursor_y += measureWrappedTextHeight(allocator, dc, summary, rect.size()[0] - padding * 2.0);
    }

    if (approval.requested_at_ms) |ts| {
        var time_buf: [32]u8 = undefined;
        const label = formatRelativeTime(std.time.milliTimestamp(), ts, &time_buf);
        cursor_y += t.spacing.xs;
        dc.drawText(label, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += dc.lineHeight();
    }

    cursor_y += t.spacing.xs;
    dc.drawRect(draw_context.Rect.fromMinSize(.{ rect.min[0] + padding, cursor_y }, .{ rect.size()[0] - padding * 2.0, 1.0 }), .{ .fill = t.colors.divider });
    cursor_y += t.spacing.xs;

    const payload_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, 120.0 },
    );
    drawPayloadBox(allocator, dc, payload_rect, queue, approval.id, approval.payload_json);
    cursor_y = payload_rect.max[1] + t.spacing.sm;

    var decision: ApprovalDecision = .none;
    if (approval.can_resolve) {
        const button_height = dc.lineHeight() + t.spacing.xs * 2.0;
        const approve_w = buttonWidth(dc, "Approve", t);
        const decline_w = buttonWidth(dc, "Decline", t);
        const allow_w = buttonWidth(dc, "Allow Always", t);
        var cursor_x = rect.min[0] + padding;

        const approve_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ approve_w, button_height });
        if (widgets.button.draw(dc, approve_rect, "Approve", queue, .{ .variant = .primary })) {
            decision = .allow_once;
        }
        cursor_x += approve_w + t.spacing.sm;

        const decline_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ decline_w, button_height });
        if (widgets.button.draw(dc, decline_rect, "Decline", queue, .{ .variant = .secondary })) {
            decision = .deny;
        }
        cursor_x += decline_w + t.spacing.sm;

        const allow_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ allow_w, button_height });
        if (widgets.button.draw(dc, allow_rect, "Allow Always", queue, .{ .variant = .secondary })) {
            decision = .allow_always;
        }
    } else {
        dc.drawText("Missing approval id in payload.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    }

    return decision;
}

fn drawPayloadBox(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    id: []const u8,
    text: []const u8,
) void {
    const t = theme.activeTheme();
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, rect.size()[0] - t.spacing.sm * 2.0, &lines);

    const line_height = dc.lineHeight();
    const content_height = @as(f32, @floatFromInt(lines.items.len)) * line_height;
    const scroll_ptr = payloadScrollFor(id);
    const max_scroll = @max(0.0, content_height - rect.size()[1]);

    handleWheelScroll(queue, rect, scroll_ptr, max_scroll, 24.0);

    dc.pushClip(rect);
    var start_index: usize = 0;
    if (line_height > 0.0) {
        start_index = @intFromFloat(@floor(scroll_ptr.* / line_height));
    }
    var y = rect.min[1] + t.spacing.xs - scroll_ptr.* + @as(f32, @floatFromInt(start_index)) * line_height;
    for (lines.items[start_index..], start_index..) |line, idx| {
        const slice = text[line.start..line.end];
        if (slice.len > 0) {
            dc.drawText(slice, .{ rect.min[0] + t.spacing.sm, y }, .{ .color = t.colors.text_secondary });
        }
        y += line_height;
        if (y > rect.max[1]) break;
        _ = idx;
    }
    dc.popClip();

    if (scroll_ptr.* > max_scroll) scroll_ptr.* = max_scroll;
    if (scroll_ptr.* < 0.0) scroll_ptr.* = 0.0;
}

fn payloadScrollFor(id: []const u8) *f32 {
    const hash = std.hash.Wyhash.hash(0, id);
    var idx: usize = 0;
    while (idx < payload_scroll_len) : (idx += 1) {
        if (payload_scroll_ids[idx] == hash) {
            return &payload_scroll_vals[idx];
        }
    }
    if (payload_scroll_len < max_payload_scrolls) {
        payload_scroll_ids[payload_scroll_len] = hash;
        payload_scroll_vals[payload_scroll_len] = 0.0;
        payload_scroll_len += 1;
        return &payload_scroll_vals[payload_scroll_len - 1];
    }
    return &payload_scroll_vals[0];
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
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    clicked = true;
                }
            },
            else => {},
        }
    }

    const base = if (active) t.colors.primary else t.colors.surface;
    const alpha: f32 = if (active) 0.18 else if (hovered) 0.1 else 0.0;
    const fill = colors.withAlpha(base, alpha);
    const border = colors.withAlpha(t.colors.border, if (active) 0.6 else 0.3);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = fill, .stroke = border, .thickness = 1.0 });

    const text_color = if (active) t.colors.primary else t.colors.text_secondary;
    const text_size = dc.measureText(label, 0.0);
    const text_pos = .{ rect.min[0] + (rect.size()[0] - text_size[0]) * 0.5, rect.min[1] + (rect.size()[1] - text_size[1]) * 0.5 };
    dc.drawText(label, text_pos, .{ .color = text_color });

    return clicked;
}

fn drawBadge(dc: *draw_context.DrawContext, rect: draw_context.Rect, label: []const u8, variant: BadgeVariant) void {
    const t = theme.activeTheme();
    const base = badgeColor(t, variant);
    const bg = colors.withAlpha(base, 0.18);
    const border = colors.withAlpha(base, 0.4);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs * 0.5 }, .{ .color = base });
}

fn badgeColor(t: *const theme.Theme, variant: BadgeVariant) colors.Color {
    return switch (variant) {
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .neutral => t.colors.text_secondary,
    };
}

fn badgeSize(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) [2]f32 {
    const text_size = dc.measureText(label, 0.0);
    return .{ text_size[0] + t.spacing.xs * 2.0, text_size[1] + t.spacing.xs };
}

fn pillWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn approvalCardHeight(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    width: f32,
    summary: ?[]const u8,
    payload: []const u8,
    can_resolve: bool,
) f32 {
    _ = payload;
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    var height: f32 = padding * 2.0;
    height += dc.lineHeight();

    if (summary) |text| {
        height += t.spacing.xs;
        height += measureWrappedTextHeight(allocator, dc, text, width - padding * 2.0);
    }

    height += t.spacing.xs + dc.lineHeight();
    height += t.spacing.xs + 1.0 + t.spacing.xs;
    height += 120.0 + t.spacing.sm;

    if (can_resolve) {
        height += dc.lineHeight() + t.spacing.xs * 2.0;
    } else {
        height += dc.lineHeight();
    }

    return height;
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
