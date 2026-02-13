const std = @import("std");
const state = @import("../../client/state.zig");
const types = @import("../../protocol/types.zig");
const workspace = @import("../workspace.zig");
const debug_visibility = @import("../debug_visibility.zig");
const draw_context = @import("../draw_context.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const widgets = @import("../widgets/widgets.zig");
const clipboard = @import("../clipboard.zig");
const text_editor = @import("../widgets/text_editor.zig");
const surface_chrome = @import("../surface_chrome.zig");

pub const InboxAction = struct {
    open_approvals_panel: bool = false,
};

const Tab = enum { activity, approvals, system };
const Scope = enum { current, all };

const Source = enum { tool, process, system };
const Severity = enum { debug, info, warn, err };

const Status = enum { unknown, running, succeeded, failed };

const ActivityItem = struct {
    key_hash: u64,
    key_label: []const u8,
    title: []const u8,
    session_key: ?[]const u8 = null,
    source: Source,
    severity: Severity,
    status: Status,
    updates: u32 = 1,
    ts_ms: i64,
    msg_id: []const u8,
    content: []const u8,
};

var active_tab: Tab = .activity;
var scope: Scope = .current;

var show_debug: bool = false;
var show_info: bool = false;
var show_warn: bool = true;
var show_error: bool = true;

var show_tool: bool = true;
var show_process: bool = true;
var show_system: bool = false;

var list_scroll_y: f32 = 0.0;
var list_scroll_max: f32 = 0.0;
var selected_hash: u64 = 0;

var detail_editor: ?text_editor.TextEditor = null;
var detail_hash: u64 = 0;
var show_full_detail: bool = false;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    panel: *workspace.ControlPanel,
    rect: draw_context.Rect,
) InboxAction {
    _ = panel;

    var action: InboxAction = .{};
    const t = theme.activeTheme();

    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, rect);
    defer dc.deinit();

    surface_chrome.drawBackground(&dc, rect);
    const queue = input_router.getQueue();

    const header_h = drawHeader(&dc, rect, queue, ctx, &action);
    const sep_gap = t.spacing.xs;
    const sep_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0], rect.min[1] + header_h + sep_gap },
        .{ rect.size()[0], 1.0 },
    );
    dc.drawRect(sep_rect, .{ .fill = t.colors.divider });

    const content_top = sep_rect.max[1] + sep_gap;
    const content_h = rect.max[1] - content_top;
    if (content_h <= 0.0) return action;

    const content_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.md, content_top },
        .{ rect.size()[0] - t.spacing.md * 2.0, content_h - t.spacing.md },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) return action;

    switch (active_tab) {
        .approvals => drawApprovalsTab(&dc, content_rect, queue, ctx, &action),
        .system => drawActivityLikeTab(allocator, &dc, content_rect, queue, ctx, .system),
        .activity => drawActivityLikeTab(allocator, &dc, content_rect, queue, ctx, .activity),
    }

    return action;
}

fn drawHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    ctx: *state.ClientContext,
    action: *InboxAction,
) f32 {
    _ = action;
    const t = dc.theme;
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;

    var y = rect.min[1] + top_pad;

    theme.pushFor(t, .title);
    const title_h = dc.lineHeight();
    dc.drawText("Activity", .{ left, y }, .{ .color = t.colors.text_primary });
    theme.pop();

    y += title_h + gap;
    dc.drawText("Tools / processes / system events (aggregated)", .{ left, y }, .{ .color = t.colors.text_secondary });

    const row_h = widgets.button.defaultHeight(t, dc.lineHeight());
    const row_y = y + dc.lineHeight() + t.spacing.xs;

    // Tabs
    var approvals_buf: [64]u8 = undefined;
    const approvals_label = if (ctx.approvals.items.len > 0)
        (std.fmt.bufPrint(&approvals_buf, "Approvals {d}", .{ctx.approvals.items.len}) catch "Approvals")
    else
        "Approvals";

    const tab_labels = [_][]const u8{ "Activity", approvals_label, "System" };
    const tabs = [_]Tab{ .activity, .approvals, .system };

    var x = left;
    for (tabs, 0..) |tab, i| {
        const label = tab_labels[i];
        const w = dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
        const tab_rect = draw_context.Rect.fromMinSize(.{ x, row_y }, .{ w, row_h });
        const variant: widgets.button.Variant = if (active_tab == tab) .secondary else .ghost;
        if (widgets.button.draw(dc, tab_rect, label, queue, .{ .variant = variant })) {
            active_tab = tab;
            list_scroll_y = 0.0;
            show_full_detail = false;
        }
        x = tab_rect.max[0] + t.spacing.xs;
    }

    // Scope toggle
    const scope_label = if (scope == .current) "Scope: current" else "Scope: all";
    const scope_w = dc.measureText(scope_label, 0.0)[0] + t.spacing.sm * 2.0;
    const scope_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - t.spacing.md - scope_w, row_y },
        .{ scope_w, row_h },
    );
    if (widgets.button.draw(dc, scope_rect, scope_label, queue, .{ .variant = .ghost })) {
        scope = switch (scope) {
            .current => .all,
            .all => .current,
        };
        list_scroll_y = 0.0;
    }

    // Filter row (only relevant for Activity/System tabs)
    if (active_tab != .approvals) {
        const filter_y = row_y + row_h + t.spacing.xs;
        _ = drawFilters(dc, draw_context.Rect.fromMinSize(.{ left, filter_y }, .{ rect.size()[0] - t.spacing.md * 2.0, row_h }), queue);
        return (filter_y - (rect.min[1] + top_pad)) + row_h + top_pad;
    }

    return (row_y - (rect.min[1] + top_pad)) + row_h + top_pad;
}

fn drawFilters(dc: *draw_context.DrawContext, rect: draw_context.Rect, queue: *input_state.InputQueue) f32 {
    const t = dc.theme;
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return rect.size()[1];

    // Severity
    var x = rect.min[0];
    const box = dc.lineHeight();
    const item_h = @max(rect.size()[1], box);

    const severities = [_]struct { label: []const u8, ptr: *bool }{
        .{ .label = "debug", .ptr = &show_debug },
        .{ .label = "info", .ptr = &show_info },
        .{ .label = "warn", .ptr = &show_warn },
        .{ .label = "error", .ptr = &show_error },
    };

    for (severities) |s| {
        const w = box + t.spacing.xs + dc.measureText(s.label, 0.0)[0];
        const r = draw_context.Rect.fromMinSize(.{ x, rect.min[1] }, .{ w, item_h });
        _ = widgets.checkbox.draw(dc, r, s.label, s.ptr, queue, .{});
        x = r.max[0] + t.spacing.sm;
    }

    // Source
    const sources = [_]struct { label: []const u8, ptr: *bool }{
        .{ .label = "tool", .ptr = &show_tool },
        .{ .label = "process", .ptr = &show_process },
        .{ .label = "system", .ptr = &show_system },
    };
    for (sources) |s| {
        const w = box + t.spacing.xs + dc.measureText(s.label, 0.0)[0];
        const r = draw_context.Rect.fromMinSize(.{ x, rect.min[1] }, .{ w, item_h });
        _ = widgets.checkbox.draw(dc, r, s.label, s.ptr, queue, .{});
        x = r.max[0] + t.spacing.sm;
    }

    return item_h;
}

const ActivityMode = enum { activity, system };

fn drawActivityLikeTab(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    ctx: *state.ClientContext,
    mode: ActivityMode,
) void {
    const t = dc.theme;

    // Split list/detail.
    const gap = t.spacing.md;
    const left_w = @floor(rect.size()[0] * 0.44);
    const right_w = rect.size()[0] - left_w - gap;

    const list_rect = draw_context.Rect.fromMinSize(rect.min, .{ left_w, rect.size()[1] });
    const detail_rect = draw_context.Rect.fromMinSize(.{ rect.min[0] + left_w + gap, rect.min[1] }, .{ right_w, rect.size()[1] });

    var items = std.ArrayList(ActivityItem).empty;
    defer items.deinit(allocator);
    collectActivityItems(allocator, ctx, mode, &items) catch {};

    if (items.items.len > 1) {
        std.sort.heap(ActivityItem, items.items, {}, itemTsDesc);
    }

    // Keep selection stable.
    if (selected_hash == 0 and items.items.len > 0) {
        selected_hash = items.items[0].key_hash;
    }
    var selected_index: ?usize = null;
    for (items.items, 0..) |it, idx| {
        if (it.key_hash == selected_hash) {
            selected_index = idx;
            break;
        }
    }
    if (selected_index == null and items.items.len > 0) {
        selected_hash = items.items[0].key_hash;
        selected_index = 0;
        show_full_detail = false;
    }

    drawActivityList(dc, list_rect, queue, items.items, selected_index);
    if (detail_rect.size()[0] > 0.0) {
        const picked = if (selected_index) |idx| items.items[idx] else null;
        drawActivityDetail(allocator, dc, detail_rect, queue, picked);
    }
}

fn collectActivityItems(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    mode: ActivityMode,
    out: *std.ArrayList(ActivityItem),
) !void {
    var map = std.AutoHashMap(u64, usize).init(allocator);
    defer map.deinit();

    if (scope == .current) {
        const key = ctx.current_session orelse return;
        if (ctx.findSessionState(key)) |st| {
            try collectFromMessages(allocator, &map, key, st.messages.items, mode, out);
        }
        return;
    }

    var it = ctx.session_states.iterator();
    while (it.next()) |entry| {
        try collectFromMessages(allocator, &map, entry.key_ptr.*, entry.value_ptr.messages.items, mode, out);
    }
}

fn collectFromMessages(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMap(u64, usize),
    session_key: []const u8,
    messages: []const types.ChatMessage,
    mode: ActivityMode,
    out: *std.ArrayList(ActivityItem),
) !void {
    for (messages) |msg| {
        const maybe = classifyMessage(session_key, msg, mode) orelse continue;
        if (filterReject(maybe, mode)) continue;

        if (map.get(maybe.key_hash)) |existing_idx| {
            var existing = &out.items[existing_idx];
            existing.updates += 1;
            if (maybe.ts_ms >= existing.ts_ms) {
                existing.ts_ms = maybe.ts_ms;
                existing.content = maybe.content;
                existing.msg_id = maybe.msg_id;
            }
            existing.severity = maxSeverity(existing.severity, maybe.severity);
            if (maybe.status != .unknown) existing.status = maybe.status;
        } else {
            try map.put(maybe.key_hash, out.items.len);
            try out.append(allocator, maybe);
        }
    }
}

fn classifyMessage(session_key: []const u8, msg: types.ChatMessage, mode: ActivityMode) ?ActivityItem {
    const role = msg.role;

    const tool = isToolRole(role);
    const sys = std.mem.eql(u8, role, "system") or looksLikeUiCommand(msg.content);

    if (mode == .activity and !tool) return null;
    if (mode == .system and !sys) return null;

    const source: Source = if (tool) blk: {
        if (containsIgnoreCase(role, "process")) break :blk .process;
        if (containsIgnoreCase(msg.content, "process")) break :blk .process;
        break :blk .tool;
    } else .system;

    const severity = detectSeverity(msg.content);
    const status = detectStatus(msg.content);

    const key_label = extractStableKey(msg) orelse msg.id;
    var hash: u64 = std.hash.Wyhash.hash(0, key_label);
    hash = std.hash.Wyhash.hash(hash, @tagName(source));

    const title: []const u8 = if (tool) role else "system";

    return .{
        .key_hash = hash,
        .key_label = key_label,
        .title = title,
        .session_key = session_key,
        .source = source,
        .severity = severity,
        .status = status,
        .updates = 1,
        .ts_ms = msg.timestamp,
        .msg_id = msg.id,
        .content = msg.content,
    };
}

fn filterReject(item: ActivityItem, mode: ActivityMode) bool {
    const sev_ok = switch (item.severity) {
        .debug => show_debug,
        .info => show_info,
        .warn => show_warn,
        .err => show_error,
    };
    if (!sev_ok) return true;

    if (mode == .system) {
        return item.source != .system;
    }

    const src_ok = switch (item.source) {
        .tool => show_tool,
        .process => show_process,
        .system => show_system,
    };
    if (!src_ok) return true;

    return false;
}

fn drawActivityList(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    items: []const ActivityItem,
    selected_index: ?usize,
) void {
    const t = dc.theme;
    surface_chrome.drawSurface(dc, rect);
    dc.drawRect(rect, .{ .stroke = t.colors.border, .thickness = 1.0 });

    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    const pad = t.spacing.sm;
    const inner = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + pad, rect.min[1] + pad },
        .{ rect.size()[0] - pad * 2.0, rect.size()[1] - pad * 2.0 },
    );
    if (inner.size()[0] <= 0.0 or inner.size()[1] <= 0.0) return;

    const row_h = @max(dc.lineHeight() + t.spacing.xs * 2.0, 28.0);
    const row_gap = t.spacing.xs;
    const total_h = @as(f32, @floatFromInt(items.len)) * (row_h + row_gap);
    list_scroll_max = @max(0.0, total_h - inner.size()[1]);
    handleWheelScroll(queue, rect, &list_scroll_y, list_scroll_max, 32.0);

    dc.pushClip(inner);
    defer dc.popClip();

    var y = inner.min[1] - list_scroll_y;
    for (items, 0..) |item, idx| {
        const row = draw_context.Rect.fromMinSize(.{ inner.min[0], y }, .{ inner.size()[0], row_h });
        if (row.max[1] >= inner.min[1] and row.min[1] <= inner.max[1]) {
            const selected = selected_index != null and selected_index.? == idx;
            if (drawActivityRow(dc, row, queue, item, selected)) {
                selected_hash = item.key_hash;
                show_full_detail = false;
            }
        }
        y += row_h + row_gap;
    }
}

fn drawActivityRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    item: ActivityItem,
    selected: bool,
) bool {
    const t = dc.theme;
    const hovered = rect.contains(queue.state.mouse_pos);

    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    if (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging) clicked = true;
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

    const left = rect.min[0] + t.spacing.sm;
    var right = rect.max[0] - t.spacing.sm;

    // Updates badge
    if (item.updates > 1) {
        var buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "x{d}", .{item.updates}) catch "x";
        const w = badgeWidth(dc, label, t);
        const brect = draw_context.Rect.fromMinSize(
            .{ right - w, rect.min[1] + t.spacing.xs * 0.5 },
            .{ w, rect.size()[1] - t.spacing.xs },
        );
        drawBadge(dc, brect, label, t.colors.text_secondary, t);
        right = brect.min[0] - t.spacing.xs;
    }

    // Severity badge
    const sev_label = severityLabel(item.severity);
    const sev_color = severityColor(item.severity, t);
    const sev_w = badgeWidth(dc, sev_label, t);
    if (right - sev_w > left + 20.0) {
        const srect = draw_context.Rect.fromMinSize(
            .{ right - sev_w, rect.min[1] + t.spacing.xs * 0.5 },
            .{ sev_w, rect.size()[1] - t.spacing.xs },
        );
        drawBadge(dc, srect, sev_label, sev_color, t);
        right = srect.min[0] - t.spacing.xs;
    }

    var label_buf: [256]u8 = undefined;
    const label = formatRowLabel(&label_buf, item);
    const max_w = @max(0.0, right - left);
    var fit_buf: [256]u8 = undefined;
    const fit = fitTextEnd(dc, label, max_w, &fit_buf);
    dc.drawText(fit, .{ left, rect.min[1] + t.spacing.xs }, .{ .color = t.colors.text_primary });

    return clicked;
}

fn formatRowLabel(buf: []u8, item: ActivityItem) []const u8 {
    const src = @tagName(item.source);
    if (item.session_key) |sk| {
        const short = if (sk.len > 22) sk[0..22] else sk;
        return std.fmt.bufPrint(buf, "{s} · {s} · {s}", .{ item.title, src, short }) catch item.title;
    }
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ item.title, src }) catch item.title;
}

fn drawActivityDetail(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    item_opt: ?ActivityItem,
) void {
    const t = dc.theme;
    surface_chrome.drawSurface(dc, rect);
    dc.drawRect(rect, .{ .stroke = t.colors.border, .thickness = 1.0 });

    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    const pad = t.spacing.md;
    var y = rect.min[1] + pad;
    const x = rect.min[0] + pad;

    if (item_opt == null) {
        dc.drawText("No activity selected.", .{ x, y }, .{ .color = t.colors.text_secondary });
        return;
    }

    const item = item_opt.?;

    theme.pushFor(t, .heading);
    dc.drawText(item.title, .{ x, y }, .{ .color = t.colors.text_primary });
    theme.pop();
    y += dc.lineHeight() + t.spacing.xs;

    var meta_buf: [256]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s} · {s} · {s}", .{ @tagName(item.source), severityLabel(item.severity), @tagName(item.status) }) catch "";
    dc.drawText(meta, .{ x, y }, .{ .color = t.colors.text_secondary });
    y += dc.lineHeight() + t.spacing.sm;

    var btn_x = x;
    const btn_h = widgets.button.defaultHeight(t, dc.lineHeight());

    const max_preview: usize = 8192;
    const truncated = item.content.len > max_preview and !show_full_detail;

    if (truncated) {
        const label = "Show more";
        const w = dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
        const brect = draw_context.Rect.fromMinSize(.{ btn_x, y }, .{ w, btn_h });
        if (widgets.button.draw(dc, brect, label, queue, .{ .variant = .secondary })) {
            show_full_detail = true;
        }
        btn_x = brect.max[0] + t.spacing.sm;
    } else if (item.content.len > max_preview and show_full_detail) {
        const label = "Show less";
        const w = dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
        const brect = draw_context.Rect.fromMinSize(.{ btn_x, y }, .{ w, btn_h });
        if (widgets.button.draw(dc, brect, label, queue, .{ .variant = .ghost })) {
            show_full_detail = false;
        }
        btn_x = brect.max[0] + t.spacing.sm;
    }

    const can_copy_raw = debug_visibility.current_tier == .deep_debug and looksLikeJson(item.content);
    if (can_copy_raw) {
        const label = "Copy raw JSON";
        const w = dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
        const brect = draw_context.Rect.fromMinSize(.{ btn_x, y }, .{ w, btn_h });
        if (widgets.button.draw(dc, brect, label, queue, .{ .variant = .secondary })) {
            const z = std.heap.page_allocator.dupeZ(u8, item.content) catch null;
            if (z) |zbuf| {
                clipboard.setTextZ(zbuf);
                std.heap.page_allocator.free(zbuf);
            }
        }
        btn_x = brect.max[0] + t.spacing.sm;
    }

    y += btn_h + t.spacing.sm;

    const content_rect = draw_context.Rect.fromMinSize(
        .{ x, y },
        .{ rect.max[0] - x - pad, rect.max[1] - y - pad },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) return;

    ensureDetailEditor(allocator);
    const shown = if (truncated) item.content[0..max_preview] else item.content;
    const hash = std.hash.Wyhash.hash(0, shown);
    if (hash != detail_hash) {
        if (detail_editor) |*ed| {
            ed.setText(allocator, shown);
        }
        detail_hash = hash;
    }

    if (detail_editor) |*ed| {
        _ = ed.draw(allocator, dc, content_rect, queue, .{ .read_only = true });
    }
}

fn ensureDetailEditor(allocator: std.mem.Allocator) void {
    if (detail_editor == null) {
        detail_editor = text_editor.TextEditor.init(allocator) catch null;
        detail_hash = 0;
    }
}

fn drawApprovalsTab(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    ctx: *state.ClientContext,
    action: *InboxAction,
) void {
    const t = dc.theme;
    surface_chrome.drawSurface(dc, rect);
    dc.drawRect(rect, .{ .stroke = t.colors.border, .thickness = 1.0 });

    const pad = t.spacing.md;
    var y = rect.min[1] + pad;
    const x = rect.min[0] + pad;

    theme.pushFor(t, .heading);
    dc.drawText("Approvals", .{ x, y }, .{ .color = t.colors.text_primary });
    theme.pop();
    y += dc.lineHeight() + t.spacing.sm;

    if (ctx.approvals.items.len == 0) {
        dc.drawText("No pending approvals.", .{ x, y }, .{ .color = t.colors.text_secondary });
        return;
    }

    const open_label = "Open Approvals panel";
    const open_w = dc.measureText(open_label, 0.0)[0] + t.spacing.sm * 2.0;
    const btn_h = widgets.button.defaultHeight(t, dc.lineHeight());
    const open_rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ open_w, btn_h });
    if (widgets.button.draw(dc, open_rect, open_label, queue, .{ .variant = .secondary })) {
        action.open_approvals_panel = true;
    }
    y += btn_h + t.spacing.sm;

    dc.drawText("Pending approvals (summary):", .{ x, y }, .{ .color = t.colors.text_secondary });
    y += dc.lineHeight() + t.spacing.xs;

    const max_rows: usize = 20;
    var shown: usize = 0;
    for (ctx.approvals.items) |appr| {
        if (shown >= max_rows) break;
        const summary = appr.summary orelse appr.id;
        var fit_buf: [256]u8 = undefined;
        const fit = fitTextEnd(dc, summary, rect.size()[0] - pad * 2.0, &fit_buf);
        dc.drawText(fit, .{ x, y }, .{ .color = t.colors.text_primary });
        y += dc.lineHeight() + t.spacing.xs;
        shown += 1;
    }

    if (ctx.approvals.items.len > max_rows) {
        var more_buf: [64]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "…and {d} more", .{ctx.approvals.items.len - max_rows}) catch "…";
        dc.drawText(more, .{ x, y }, .{ .color = t.colors.text_secondary });
    }
}

fn itemTsDesc(_: void, a: ActivityItem, b: ActivityItem) bool {
    return a.ts_ms > b.ts_ms;
}

fn maxSeverity(a: Severity, b: Severity) Severity {
    return if (@intFromEnum(b) > @intFromEnum(a)) b else a;
}

fn detectSeverity(content: []const u8) Severity {
    if (containsIgnoreCase(content, "error") or containsIgnoreCase(content, "failed") or containsIgnoreCase(content, "exception")) return .err;
    if (containsIgnoreCase(content, "warning") or containsIgnoreCase(content, "warn")) return .warn;
    if (containsIgnoreCase(content, "debug")) return .debug;
    return .info;
}

fn detectStatus(content: []const u8) Status {
    if (containsIgnoreCase(content, "running")) return .running;
    if (containsIgnoreCase(content, "succeeded") or containsIgnoreCase(content, "success")) return .succeeded;
    if (containsIgnoreCase(content, "failed") or containsIgnoreCase(content, "error")) return .failed;
    return .unknown;
}

fn extractStableKey(msg: types.ChatMessage) ?[]const u8 {
    const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] != '{') return null;

    return extractJsonStringField(trimmed, "toolCallId") orelse
        extractJsonStringField(trimmed, "tool_call_id") orelse
        extractJsonStringField(trimmed, "runId") orelse
        extractJsonStringField(trimmed, "run_id") orelse
        extractJsonStringField(trimmed, "sessionId") orelse
        extractJsonStringField(trimmed, "session_id") orelse
        extractJsonStringField(trimmed, "session") orelse
        extractJsonStringField(trimmed, "id");
}

fn extractJsonStringField(json: []const u8, field: []const u8) ?[]const u8 {
    // Extremely small, permissive JSON string field extractor.
    // Looks for: "field" : "value"
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{field}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;

    var i = pos + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"') {
            return json[start..i];
        }
        // NOTE: doesn't handle escaped quotes.
    }
    return null;
}

fn looksLikeUiCommand(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len < 10) return false;
    if (trimmed[0] != '{') return false;
    return containsIgnoreCase(trimmed, "\"type\"") and containsIgnoreCase(trimmed, "OpenPanel");
}

fn looksLikeJson(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
}

fn isToolRole(role: []const u8) bool {
    return std.mem.startsWith(u8, role, "tool") or std.mem.eql(u8, role, "toolResult");
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

fn severityLabel(sev: Severity) []const u8 {
    return switch (sev) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

fn severityColor(sev: Severity, t: *const theme.Theme) colors.Color {
    return switch (sev) {
        .debug => t.colors.text_secondary,
        .info => t.colors.primary,
        .warn => t.colors.warning,
        .err => t.colors.danger,
    };
}

fn handleWheelScroll(queue: *input_state.InputQueue, rect: draw_context.Rect, scroll_y: *f32, max: f32, step: f32) void {
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_wheel => |mw| {
                if (!rect.contains(queue.state.mouse_pos)) continue;
                scroll_y.* -= mw.delta[1] * step;
                if (scroll_y.* < 0.0) scroll_y.* = 0.0;
                if (scroll_y.* > max) scroll_y.* = max;
            },
            else => {},
        }
    }
}

fn badgeWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return dc.measureText(label, 0.0)[0] + t.spacing.xs * 2.0;
}

fn drawBadge(dc: *draw_context.DrawContext, rect: draw_context.Rect, label: []const u8, color: colors.Color, t: *const theme.Theme) void {
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(color, 0.14), .stroke = colors.withAlpha(color, 0.45), .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs * 0.2 }, .{ .color = color });
}

fn fitTextEnd(dc: *draw_context.DrawContext, text: []const u8, max_width: f32, buf: []u8) []const u8 {
    if (text.len == 0) return "";
    if (max_width <= 0.0) return "";
    if (dc.measureText(text, 0.0)[0] <= max_width) return text;

    const ellipsis = "...";
    const ellipsis_w = dc.measureText(ellipsis, 0.0)[0];
    if (ellipsis_w > max_width) return "";
    if (buf.len <= ellipsis.len) return ellipsis;

    var low: usize = 0;
    var high: usize = @min(text.len, buf.len - ellipsis.len - 1);
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const candidate = std.fmt.bufPrint(buf, "{s}{s}", .{ text[0..mid], ellipsis }) catch ellipsis;
        const w = dc.measureText(candidate, 0.0)[0];
        if (w <= max_width) {
            best = mid;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    if (best == 0) return ellipsis;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ text[0..best], ellipsis }) catch ellipsis;
}
