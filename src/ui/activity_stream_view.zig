const std = @import("std");
const state = @import("../client/state.zig");
const draw_context = @import("draw_context.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const surface_chrome = @import("surface_chrome.zig");
const clipboard = @import("clipboard.zig");

const Tab = enum {
    activity,
    approvals,
    system,
};

const SeverityFilter = struct {
    debug: bool = false,
    info: bool = false,
    warn: bool = true,
    @"error": bool = true,
};

const SourceFilter = struct {
    tool: bool = true,
    process: bool = true,
    approval: bool = true,
    system: bool = true,
};

const ScopeFilter = struct {
    conversation: bool = true,
    background: bool = true,
};

pub const ActivityStreamAction = struct {
    open_approvals_panel: bool = false,
};

var active_tab: Tab = .activity;
var list_scroll_y: f32 = 0.0;
var list_scroll_max: f32 = 0.0;
var use_default_filter: bool = true;
var severity_filter: SeverityFilter = .{};
var source_filter: SourceFilter = .{};
var scope_filter: ScopeFilter = .{};

const max_expanded = 256;
var expanded_keys: [max_expanded]u64 = [_]u64{0} ** max_expanded;
var expanded_len: usize = 0;
var expanded_stdout: [max_expanded]u64 = [_]u64{0} ** max_expanded;
var expanded_stdout_len: usize = 0;
var expanded_stderr: [max_expanded]u64 = [_]u64{0} ** max_expanded;
var expanded_stderr_len: usize = 0;

const CardRef = struct {
    key_hash: u64,
    title: []const u8,
    summary: ?[]const u8,
    source: state.ActivitySource,
    severity: state.ActivitySeverity,
    scope: state.ActivityScope,
    status: state.ActivityStatus,
    updated_at_ms: i64,
    params: ?[]const u8,
    stdout: ?[]const u8,
    stderr: ?[]const u8,
    raw_event_json: ?[]const u8,
};

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    rect_override: ?draw_context.Rect,
) ActivityStreamAction {
    var action = ActivityStreamAction{};
    const panel_rect = rect_override orelse return action;
    const t = theme.activeTheme();
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();

    surface_chrome.drawBackground(&dc, panel_rect);
    const queue = input_router.getQueue();

    const header_h = drawHeader(&dc, panel_rect, queue, ctx, &action);
    const sep_gap = t.spacing.xs;
    const sep_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], panel_rect.min[1] + header_h + sep_gap },
        .{ panel_rect.size()[0], 1.0 },
    );
    dc.drawRect(sep_rect, .{ .fill = t.colors.divider });

    const tabs_y = sep_rect.max[1] + sep_gap;
    const tabs_h = drawTabs(&dc, panel_rect, tabs_y, queue);

    var filters_h: f32 = 0.0;
    if (active_tab != .approvals) {
        filters_h = drawFilters(&dc, panel_rect, tabs_y + tabs_h + t.spacing.xs, queue);
    }

    const list_top = tabs_y + tabs_h + t.spacing.xs + filters_h + t.spacing.xs;
    const list_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0] + t.spacing.sm, list_top },
        .{ panel_rect.size()[0] - t.spacing.sm * 2.0, panel_rect.max[1] - list_top - t.spacing.sm },
    );
    if (list_rect.size()[0] <= 0.0 or list_rect.size()[1] <= 0.0) return action;

    switch (active_tab) {
        .approvals => drawApprovalsTab(allocator, &dc, queue, list_rect, ctx),
        .activity, .system => drawActivityTab(allocator, &dc, queue, list_rect, ctx),
    }

    return action;
}

fn drawHeader(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    ctx: *state.ClientContext,
    action: *ActivityStreamAction,
) f32 {
    const t = dc.theme;
    const left = rect.min[0] + t.spacing.sm;
    const top = rect.min[1] + t.spacing.xs;

    theme.pushFor(t, .title);
    const title_h = dc.lineHeight();
    dc.drawText("Activity Stream", .{ left, top }, .{ .color = t.colors.text_primary });
    theme.pop();

    var approvals_buf: [32]u8 = undefined;
    const approvals_label = std.fmt.bufPrint(&approvals_buf, "Approvals {d}", .{ctx.approvals.items.len}) catch "Approvals";
    var activity_buf: [32]u8 = undefined;
    const activity_label = std.fmt.bufPrint(&activity_buf, "Warnings {d}", .{ctx.activityWarnErrorCount()}) catch "Warnings";

    const badge_h = dc.lineHeight() + t.spacing.xs;
    const approvals_w = dc.measureText(approvals_label, 0.0)[0] + t.spacing.sm * 1.6;
    const activity_w = dc.measureText(activity_label, 0.0)[0] + t.spacing.sm * 1.6;

    const right = rect.max[0] - t.spacing.sm;
    const activity_rect = draw_context.Rect.fromMinSize(.{ right - activity_w, top }, .{ activity_w, badge_h });
    const approvals_rect = draw_context.Rect.fromMinSize(.{ activity_rect.min[0] - t.spacing.xs - approvals_w, top }, .{ approvals_w, badge_h });

    drawBadge(dc, activity_rect, activity_label, if (ctx.activityWarnErrorCount() > 0) .warning else .neutral);
    if (widgets.button.draw(dc, approvals_rect, approvals_label, queue, .{
        .variant = if (ctx.approvals.items.len > 0) .primary else .secondary,
    })) {
        action.open_approvals_panel = true;
    }

    return title_h + t.spacing.sm;
}

fn drawTabs(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    y: f32,
    queue: *input_state.InputQueue,
) f32 {
    const t = dc.theme;
    const labels = [_]struct { tab: Tab, text: []const u8 }{
        .{ .tab = .activity, .text = "Activity" },
        .{ .tab = .approvals, .text = "Approvals" },
        .{ .tab = .system, .text = "System" },
    };

    var x = rect.min[0] + t.spacing.sm;
    const h = @max(dc.lineHeight() + t.spacing.xs * 2.0, 28.0);
    for (labels) |entry| {
        const w = dc.measureText(entry.text, 0.0)[0] + t.spacing.sm * 2.0;
        const r = draw_context.Rect.fromMinSize(.{ x, y }, .{ w, h });
        if (widgets.button.draw(dc, r, entry.text, queue, .{
            .variant = if (active_tab == entry.tab) .primary else .secondary,
        })) {
            active_tab = entry.tab;
        }
        x += w + t.spacing.xs;
    }
    return h;
}

fn drawFilters(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    y: f32,
    queue: *input_state.InputQueue,
) f32 {
    const t = dc.theme;
    const line_h = @max(dc.lineHeight(), 18.0);
    const row_h = line_h + t.spacing.xs;
    var cursor_y = y;
    var x = rect.min[0] + t.spacing.sm;

    const default_label = if (use_default_filter) "Default filter: warn/error/actionable" else "Custom filters";
    const default_w = dc.measureText(default_label, 0.0)[0] + t.spacing.sm * 2.0;
    const default_rect = draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ default_w, row_h });
    if (widgets.button.draw(dc, default_rect, default_label, queue, .{ .variant = if (use_default_filter) .primary else .secondary })) {
        use_default_filter = !use_default_filter;
    }

    cursor_y += row_h + t.spacing.xs;
    x = rect.min[0] + t.spacing.sm;

    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 96, row_h }), "debug", &severity_filter.debug, queue, .{});
    x += 96 + t.spacing.xs;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 80, row_h }), "info", &severity_filter.info, queue, .{});
    x += 80 + t.spacing.xs;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 86, row_h }), "warn", &severity_filter.warn, queue, .{});
    x += 86 + t.spacing.xs;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 86, row_h }), "error", &severity_filter.@"error", queue, .{});

    cursor_y += row_h + t.spacing.xs;
    x = rect.min[0] + t.spacing.sm;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 80, row_h }), "tool", &source_filter.tool, queue, .{});
    x += 80 + t.spacing.xs;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 96, row_h }), "process", &source_filter.process, queue, .{});
    x += 96 + t.spacing.xs;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 102, row_h }), "approval", &source_filter.approval, queue, .{});
    x += 102 + t.spacing.xs;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 92, row_h }), "system", &source_filter.system, queue, .{});

    cursor_y += row_h + t.spacing.xs;
    x = rect.min[0] + t.spacing.sm;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 148, row_h }), "conversation", &scope_filter.conversation, queue, .{});
    x += 148 + t.spacing.xs;
    _ = widgets.checkbox.draw(dc, draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ 132, row_h }), "background", &scope_filter.background, queue, .{});

    return (cursor_y + row_h) - y;
}

fn drawApprovalsTab(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    list_rect: draw_context.Rect,
    ctx: *state.ClientContext,
) void {
    _ = allocator;
    const t = dc.theme;
    dc.drawRoundedRect(list_rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var y = list_rect.min[1] + t.spacing.sm;
    const x = list_rect.min[0] + t.spacing.sm;
    if (ctx.approvals.items.len == 0 and ctx.approvals_resolved.items.len == 0) {
        dc.drawText("No approvals yet.", .{ x, y }, .{ .color = t.colors.text_secondary });
        return;
    }

    if (ctx.approvals.items.len > 0) {
        dc.drawText("Pending", .{ x, y }, .{ .color = t.colors.text_primary });
        y += dc.lineHeight() + t.spacing.xs;
        for (ctx.approvals.items) |approval| {
            var row_buf: [256]u8 = undefined;
            const row = std.fmt.bufPrint(&row_buf, "• {s}", .{approval.summary orelse approval.id}) catch "• approval";
            dc.drawText(row, .{ x, y }, .{ .color = t.colors.warning });
            y += dc.lineHeight();
            if (y > list_rect.max[1]) return;
        }
    }

    if (ctx.approvals_resolved.items.len > 0) {
        y += t.spacing.sm;
        dc.drawText("Resolved", .{ x, y }, .{ .color = t.colors.text_primary });
        y += dc.lineHeight() + t.spacing.xs;
        for (ctx.approvals_resolved.items) |approval| {
            var row_buf: [320]u8 = undefined;
            const decision = approval.decision orelse "resolved";
            const row = std.fmt.bufPrint(&row_buf, "• {s} ({s})", .{ approval.summary orelse approval.id, decision }) catch "• resolved";
            dc.drawText(row, .{ x, y }, .{ .color = t.colors.text_secondary });
            y += dc.lineHeight();
            if (y > list_rect.max[1]) return;
        }
    }

    _ = queue;
}

fn drawActivityTab(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    list_rect: draw_context.Rect,
    ctx: *state.ClientContext,
) void {
    const t = dc.theme;
    dc.drawRoundedRect(list_rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var refs = std.ArrayList(CardRef).empty;
    defer refs.deinit(allocator);

    var idx: usize = ctx.activity.items.len;
    while (idx > 0) {
        idx -= 1;
        const entry = ctx.activity.items[idx];
        if (!matchesTab(entry.source)) continue;
        if (!matchesFilters(entry)) continue;
        refs.append(allocator, .{
            .key_hash = std.hash.Wyhash.hash(0, entry.key),
            .title = entry.title,
            .summary = entry.summary,
            .source = entry.source,
            .severity = entry.severity,
            .scope = entry.scope,
            .status = entry.status,
            .updated_at_ms = entry.updated_at_ms,
            .params = entry.params,
            .stdout = entry.stdout,
            .stderr = entry.stderr,
            .raw_event_json = entry.raw_event_json,
        }) catch return;
    }

    if (refs.items.len == 0) {
        dc.drawText("No activity matching current filters.", .{ list_rect.min[0] + t.spacing.sm, list_rect.min[1] + t.spacing.sm }, .{ .color = t.colors.text_secondary });
        return;
    }

    var total_h: f32 = 0.0;
    for (refs.items) |entry| {
        total_h += cardHeight(dc, entry) + t.spacing.xs;
    }
    list_scroll_max = @max(0.0, total_h - (list_rect.size()[1] - t.spacing.sm * 2.0));
    widgets.kinetic_scroll.apply(queue, list_rect, &list_scroll_y, list_scroll_max, 30.0);

    const inner = draw_context.Rect.fromMinSize(
        .{ list_rect.min[0] + t.spacing.sm, list_rect.min[1] + t.spacing.sm },
        .{ list_rect.size()[0] - t.spacing.sm * 2.0, list_rect.size()[1] - t.spacing.sm * 2.0 },
    );

    dc.pushClip(inner);
    var y = inner.min[1] - list_scroll_y;
    for (refs.items) |entry| {
        const h = cardHeight(dc, entry);
        const card_rect = draw_context.Rect.fromMinSize(.{ inner.min[0], y }, .{ inner.size()[0], h });
        if (card_rect.max[1] >= inner.min[1] and card_rect.min[1] <= inner.max[1]) {
            drawCard(allocator, dc, queue, ctx, card_rect, entry);
        }
        y += h + t.spacing.xs;
    }
    dc.popClip();
}

fn cardHeight(dc: *draw_context.DrawContext, entry: CardRef) f32 {
    const t = dc.theme;
    var h = dc.lineHeight() * 2.0 + t.spacing.sm * 2.0;
    if (isExpanded(expanded_keys[0..expanded_len], entry.key_hash)) {
        h += dc.lineHeight() * 2.0 + t.spacing.xs * 2.0;
        if (entry.stdout != null) h += @min(dc.lineHeight() * 6.0, dc.lineHeight() * 2.0 + t.spacing.xs * 2.0);
        if (entry.stderr != null) h += @min(dc.lineHeight() * 6.0, dc.lineHeight() * 2.0 + t.spacing.xs * 2.0);
        if (entry.raw_event_json != null and entry.raw_event_json.?.len > 0 and entry.summary != null) h += dc.lineHeight() + t.spacing.xs;
    }
    return h;
}

fn drawCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    ctx: *state.ClientContext,
    rect: draw_context.Rect,
    entry: CardRef,
) void {
    const t = dc.theme;
    const hover = rect.contains(queue.state.mouse_pos);
    const fill = if (hover) colors.withAlpha(t.colors.primary, 0.06) else colors.withAlpha(t.colors.surface, 0.0);
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = fill, .stroke = colors.withAlpha(t.colors.border, 0.5), .thickness = 1.0 });

    var y = rect.min[1] + t.spacing.xs;
    const x = rect.min[0] + t.spacing.sm;
    dc.drawText(entry.title, .{ x, y }, .{ .color = t.colors.text_primary });

    const badge_text = statusLabel(entry.status);
    const badge_w = dc.measureText(badge_text, 0.0)[0] + t.spacing.sm * 1.5;
    const badge_rect = draw_context.Rect.fromMinSize(.{ rect.max[0] - t.spacing.sm - badge_w, y }, .{ badge_w, dc.lineHeight() + t.spacing.xs });
    drawBadge(dc, badge_rect, badge_text, badgeVariant(entry.severity, entry.status));

    y += dc.lineHeight() + t.spacing.xs;
    const summary = entry.summary orelse "(no summary)";
    dc.drawText(summary, .{ x, y }, .{ .color = t.colors.text_secondary });

    const expanded = isExpanded(expanded_keys[0..expanded_len], entry.key_hash);
    const details_label = if (expanded) "Hide details" else "Show details";
    const details_w = dc.measureText(details_label, 0.0)[0] + t.spacing.sm * 2.0;
    const details_rect = draw_context.Rect.fromMinSize(.{
        x,
        rect.max[1] - t.spacing.xs - (dc.lineHeight() + t.spacing.xs),
    }, .{ details_w, dc.lineHeight() + t.spacing.xs });
    if (widgets.button.draw(dc, details_rect, details_label, queue, .{ .variant = .secondary })) {
        toggleExpanded(&expanded_keys, &expanded_len, entry.key_hash);
    }

    if (!expanded) return;

    var detail_y = y + dc.lineHeight() + t.spacing.xs;

    if (entry.params) |params| {
        dc.drawText("params:", .{ x, detail_y }, .{ .color = t.colors.text_secondary });
        detail_y += dc.lineHeight();
        dc.drawText(params, .{ x, detail_y }, .{ .color = t.colors.text_secondary });
        detail_y += dc.lineHeight() + t.spacing.xs;
    }

    if (entry.stdout) |stdout| {
        const full = isExpanded(expanded_stdout[0..expanded_stdout_len], entry.key_hash);
        const shown = if (full) stdout else shorten(stdout, 800);
        dc.drawText("stdout:", .{ x, detail_y }, .{ .color = t.colors.text_secondary });
        detail_y += dc.lineHeight();
        dc.drawText(shown, .{ x, detail_y }, .{ .color = t.colors.text_secondary });
        detail_y += dc.lineHeight();
        if (!full and stdout.len > shown.len) {
            const more_label = "show more";
            const more_w = dc.measureText(more_label, 0.0)[0] + t.spacing.sm * 1.5;
            const more_rect = draw_context.Rect.fromMinSize(.{ x, detail_y }, .{ more_w, dc.lineHeight() + t.spacing.xs });
            if (widgets.button.draw(dc, more_rect, more_label, queue, .{ .variant = .secondary })) {
                toggleExpanded(&expanded_stdout, &expanded_stdout_len, entry.key_hash);
            }
            detail_y += dc.lineHeight() + t.spacing.xs;
        }
    }

    if (entry.stderr) |stderr| {
        const full = isExpanded(expanded_stderr[0..expanded_stderr_len], entry.key_hash);
        const shown = if (full) stderr else shorten(stderr, 800);
        dc.drawText("stderr:", .{ x, detail_y }, .{ .color = t.colors.warning });
        detail_y += dc.lineHeight();
        dc.drawText(shown, .{ x, detail_y }, .{ .color = t.colors.warning });
        detail_y += dc.lineHeight();
        if (!full and stderr.len > shown.len) {
            const more_label = "show more";
            const more_w = dc.measureText(more_label, 0.0)[0] + t.spacing.sm * 1.5;
            const more_rect = draw_context.Rect.fromMinSize(.{ x, detail_y }, .{ more_w, dc.lineHeight() + t.spacing.xs });
            if (widgets.button.draw(dc, more_rect, more_label, queue, .{ .variant = .secondary })) {
                toggleExpanded(&expanded_stderr, &expanded_stderr_len, entry.key_hash);
            }
            detail_y += dc.lineHeight() + t.spacing.xs;
        }
    }

    if (ctx.debug_visibility_tier == .deep_debug and entry.raw_event_json) |json| {
        const copy_label = "Copy raw event JSON";
        const copy_w = dc.measureText(copy_label, 0.0)[0] + t.spacing.sm * 2.0;
        const copy_rect = draw_context.Rect.fromMinSize(.{ x, detail_y }, .{ copy_w, dc.lineHeight() + t.spacing.xs });
        if (widgets.button.draw(dc, copy_rect, copy_label, queue, .{ .variant = .secondary })) {
            var buf = allocator.alloc(u8, json.len + 1) catch return;
            defer allocator.free(buf);
            @memcpy(buf[0..json.len], json);
            buf[json.len] = 0;
            clipboard.setTextZ(buf[0..json.len :0]);
        }
    }
}

fn matchesTab(source: state.ActivitySource) bool {
    return switch (active_tab) {
        .activity => source != .system,
        .system => source == .system,
        .approvals => source == .approval,
    };
}

fn matchesFilters(entry: state.ActivityEntry) bool {
    if (use_default_filter) {
        const actionable = entry.status == .pending or entry.status == .failed or entry.status == .denied;
        return actionable or entry.severity == .warn or entry.severity == .@"error";
    }

    const severity_ok = switch (entry.severity) {
        .debug => severity_filter.debug,
        .info => severity_filter.info,
        .warn => severity_filter.warn,
        .@"error" => severity_filter.@"error",
    };
    if (!severity_ok) return false;

    const source_ok = switch (entry.source) {
        .tool => source_filter.tool,
        .process => source_filter.process,
        .approval => source_filter.approval,
        .system => source_filter.system,
    };
    if (!source_ok) return false;

    const scope_ok = switch (entry.scope) {
        .conversation => scope_filter.conversation,
        .background => scope_filter.background,
    };
    return scope_ok;
}

fn drawBadge(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    variant: BadgeVariant,
) void {
    const t = dc.theme;
    const base = switch (variant) {
        .neutral => t.colors.text_secondary,
        .info => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
    };
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = colors.withAlpha(base, 0.14), .stroke = colors.withAlpha(base, 0.45), .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs * 0.5 }, .{ .color = base });
}

const BadgeVariant = enum {
    neutral,
    info,
    success,
    warning,
    danger,
};

fn badgeVariant(severity: state.ActivitySeverity, status: state.ActivityStatus) BadgeVariant {
    if (status == .failed or status == .denied) return .danger;
    if (status == .pending) return .warning;
    return switch (severity) {
        .debug => .neutral,
        .info => .info,
        .warn => .warning,
        .@"error" => .danger,
    };
}

fn statusLabel(status: state.ActivityStatus) []const u8 {
    return switch (status) {
        .running => "running",
        .succeeded => "ok",
        .failed => "failed",
        .pending => "pending",
        .approved => "approved",
        .denied => "denied",
        .info => "info",
    };
}

fn shorten(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

fn isExpanded(set: []const u64, key: u64) bool {
    for (set) |item| {
        if (item == key) return true;
    }
    return false;
}

fn toggleExpanded(buf: *[max_expanded]u64, len: *usize, key: u64) void {
    var idx: usize = 0;
    while (idx < len.*) : (idx += 1) {
        if (buf[idx] != key) continue;
        var tail = idx + 1;
        while (tail < len.*) : (tail += 1) {
            buf[tail - 1] = buf[tail];
        }
        len.* -= 1;
        return;
    }
    if (len.* < max_expanded) {
        buf[len.*] = key;
        len.* += 1;
    }
}
