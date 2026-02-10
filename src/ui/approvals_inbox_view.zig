const std = @import("std");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const surface_chrome = @import("surface_chrome.zig");
const operator_view = @import("operator_view.zig");
const theme_runtime = @import("theme_engine/runtime.zig");
const style_sheet = @import("theme_engine/style_sheet.zig");
const panel_chrome = @import("panel_chrome.zig");
const nav_router = @import("input/nav_router.zig");

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

var selected_approval_hash: u64 = 0;
var has_selected_approval: bool = false;

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

    surface_chrome.drawBackground(&dc, panel_rect);

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
        .resolved = ctx.approvals_resolved.items.len,
    };
    const filters_height = drawFilters(&dc, panel_rect, content_top, queue, counts);

    const list_top = content_top + filters_height + t.spacing.sm;
    const padding = t.spacing.md;
    const host_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0] + padding, list_top },
        .{ panel_rect.size()[0] - padding * 2.0, panel_rect.max[1] - padding - list_top },
    );
    if (host_rect.size()[0] <= 0.0 or host_rect.size()[1] <= 0.0) return action;

    const gap = t.spacing.md;
    const min_list_w: f32 = 240.0;
    const max_list_w: f32 = 420.0;
    const min_detail_w: f32 = 260.0;
    const list_w = std.math.clamp(host_rect.size()[0] * 0.38, min_list_w, @min(max_list_w, host_rect.size()[0] - min_detail_w - gap));
    const detail_w = @max(0.0, host_rect.size()[0] - list_w - gap);

    const list_rect = draw_context.Rect.fromMinSize(host_rect.min, .{ list_w, host_rect.size()[1] });
    const detail_rect = draw_context.Rect.fromMinSize(.{ list_rect.max[0] + gap, host_rect.min[1] }, .{ detail_w, host_rect.size()[1] });

    const selection = drawApprovalsListPane(allocator, ctx, &dc, list_rect, queue, counts);
    if (selection) |hash| {
        selected_approval_hash = hash;
        has_selected_approval = true;
    }

    if (detail_w > 1.0) {
        drawApprovalDetailPane(allocator, ctx, &dc, detail_rect, queue, &action, counts);
    }

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
    const t = dc.theme;
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.pushFor(t, .title);
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
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const pill_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);

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

fn drawApprovalsListPane(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    counts: Counts,
) ?u64 {
    _ = allocator;
    const t = theme.activeTheme();
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return null;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.sm;
    const inner = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );
    if (inner.size()[0] <= 0.0 or inner.size()[1] <= 0.0) return null;

    const list_len: usize = switch (active_filter) {
        .all => counts.pending + counts.resolved,
        .pending => counts.pending,
        .resolved => counts.resolved,
    };

    if (list_len == 0) {
        const msg = switch (active_filter) {
            .resolved => "No resolved approvals yet.",
            else => "No pending approvals.",
        };
        dc.drawText(msg, inner.min, .{ .color = t.colors.text_secondary });
        list_scroll_y = 0.0;
        list_scroll_max = 0.0;
        return null;
    }

    const row_height = dc.lineHeight() * 2.0 + t.spacing.xs * 3.0;
    const row_gap = t.spacing.xs;
    const total_height = @as(f32, @floatFromInt(list_len)) * (row_height + row_gap) - row_gap;

    list_scroll_max = @max(0.0, total_height - inner.size()[1]);
    handleWheelScroll(queue, inner, &list_scroll_y, list_scroll_max, 36.0);

    dc.pushClip(inner);
    var y = inner.min[1] - list_scroll_y;
    var clicked: ?u64 = null;

    if (active_filter == .all or active_filter == .pending) {
        for (ctx.approvals.items) |approval| {
            const row_rect = draw_context.Rect.fromMinSize(.{ inner.min[0], y }, .{ inner.size()[0], row_height });
            if (row_rect.max[1] >= inner.min[1] and row_rect.min[1] <= inner.max[1]) {
                const hash = std.hash.Wyhash.hash(0, approval.id);
                const selected = has_selected_approval and selected_approval_hash == hash;
                if (drawApprovalRow(dc, row_rect, queue, approval, selected, true)) {
                    clicked = hash;
                }
            }
            y += row_height + row_gap;
        }
    }

    if (active_filter == .all or active_filter == .resolved) {
        for (ctx.approvals_resolved.items) |approval| {
            const row_rect = draw_context.Rect.fromMinSize(.{ inner.min[0], y }, .{ inner.size()[0], row_height });
            if (row_rect.max[1] >= inner.min[1] and row_rect.min[1] <= inner.max[1]) {
                const hash = std.hash.Wyhash.hash(0, approval.id);
                const selected = has_selected_approval and selected_approval_hash == hash;
                if (drawApprovalRow(dc, row_rect, queue, approval, selected, false)) {
                    clicked = hash;
                }
            }
            y += row_height + row_gap;
        }
    }

    dc.popClip();
    return clicked;
}

const SelectedApproval = struct {
    approval: *const types.ExecApproval,
    is_pending: bool,
};

fn findSelectedApproval(ctx: *state.ClientContext, hash: u64) ?SelectedApproval {
    for (ctx.approvals.items) |*approval| {
        if (std.hash.Wyhash.hash(0, approval.id) == hash) {
            return .{ .approval = approval, .is_pending = true };
        }
    }
    for (ctx.approvals_resolved.items) |*approval| {
        if (std.hash.Wyhash.hash(0, approval.id) == hash) {
            return .{ .approval = approval, .is_pending = false };
        }
    }
    return null;
}

fn resolveSelectedApproval(ctx: *state.ClientContext, counts: Counts) ?SelectedApproval {
    if (has_selected_approval) {
        if (findSelectedApproval(ctx, selected_approval_hash)) |found| {
            if (active_filter == .pending and !found.is_pending) {
                // fallthrough
            } else if (active_filter == .resolved and found.is_pending) {
                // fallthrough
            } else {
                return found;
            }
        }
    }

    const pick_pending = active_filter == .pending or active_filter == .all;
    const pick_resolved = active_filter == .resolved or active_filter == .all;

    if (pick_pending and counts.pending > 0) {
        const first = &ctx.approvals.items[0];
        selected_approval_hash = std.hash.Wyhash.hash(0, first.id);
        has_selected_approval = true;
        return .{ .approval = first, .is_pending = true };
    }
    if (pick_resolved and counts.resolved > 0) {
        const first = &ctx.approvals_resolved.items[0];
        selected_approval_hash = std.hash.Wyhash.hash(0, first.id);
        has_selected_approval = true;
        return .{ .approval = first, .is_pending = false };
    }

    return null;
}

fn drawApprovalDetailPane(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    action: *ApprovalsInboxAction,
    counts: Counts,
) void {
    const t = dc.theme;
    if (rect.size()[0] <= 0.0 or rect.size()[1] <= 0.0) return;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    const padding = t.spacing.md;
    const inner = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, rect.min[1] + padding },
        .{ rect.size()[0] - padding * 2.0, rect.size()[1] - padding * 2.0 },
    );
    if (inner.size()[0] <= 0.0 or inner.size()[1] <= 0.0) return;

    const selected = resolveSelectedApproval(ctx, counts) orelse {
        dc.drawText("Select an approval.", inner.min, .{ .color = t.colors.text_secondary });
        return;
    };

    const decision = drawApprovalCard(allocator, dc, inner, queue, ctx, selected.approval.*, selected.is_pending);
    if (decision != .none) {
        const id_copy = allocator.dupe(u8, selected.approval.id) catch null;
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

const ApprovalDecision = enum {
    none,
    allow_once,
    allow_always,
    deny,
};

fn drawApprovalRow(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    approval: types.ExecApproval,
    selected: bool,
    is_pending: bool,
) bool {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);

    const bg = if (selected)
        colors.withAlpha(t.colors.primary, 0.12)
    else if (hovered)
        colors.withAlpha(t.colors.primary, 0.06)
    else
        colors.withAlpha(t.colors.surface, 0.0);

    if (selected or hovered) {
        dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = bg });
    }

    const padding = t.spacing.xs;
    const text_x = rect.min[0] + padding;
    var cursor_y = rect.min[1] + padding;

    const title = approval.summary orelse approval.id;
    dc.drawText(title, .{ text_x, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += dc.lineHeight();

    var meta_buf: [256]u8 = undefined;
    const who = approval.requested_by orelse "unknown";
    const ts = if (is_pending) approval.requested_at_ms else approval.resolved_at_ms orelse approval.requested_at_ms;
    const rel = if (ts) |val| blk: {
        var time_buf: [32]u8 = undefined;
        break :blk formatRelativeTime(std.time.milliTimestamp(), val, &time_buf);
    } else "";

    const meta = if (!is_pending) blk: {
        const decision = if (approval.decision) |d| decisionLabel(d) else "resolved";
        break :blk std.fmt.bufPrint(&meta_buf, "{s} · {s}", .{ decision, rel }) catch decision;
    } else blk: {
        break :blk std.fmt.bufPrint(&meta_buf, "{s} · {s}", .{ who, rel }) catch who;
    };
    dc.drawText(meta, .{ text_x, cursor_y }, .{ .color = t.colors.text_secondary });

    const badge_label = if (is_pending) "pending" else if (approval.decision) |d| decisionBadgeLabel(d) else "resolved";
    const badge_variant: BadgeVariant = if (is_pending) .warning else if (approval.decision) |d| decisionBadgeVariant(d) else .neutral;

    const badge_size = badgeSize(dc, badge_label, t);
    const badge_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - badge_size[0] - padding, rect.min[1] + padding },
        badge_size,
    );
    drawBadge(dc, badge_rect, badge_label, badge_variant);

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

    return clicked;
}

fn drawApprovalCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    ctx: *state.ClientContext,
    approval: types.ExecApproval,
    is_pending: bool,
) ApprovalDecision {
    nav_router.pushScope(std.hash.Wyhash.hash(0, approval.id));
    defer nav_router.popScope();

    const t = dc.theme;
    const padding = t.spacing.md;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    // Header + status badge
    theme.pushFor(t, .heading);
    dc.drawText("Execution Approval", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const status_label = if (is_pending)
        "pending"
    else if (approval.decision) |d|
        decisionBadgeLabel(d)
    else
        "resolved";
    const status_variant: BadgeVariant = if (is_pending)
        .warning
    else if (approval.decision) |d|
        decisionBadgeVariant(d)
    else
        .neutral;

    const status_size = badgeSize(dc, status_label, t);
    const status_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - padding - status_size[0], cursor_y },
        status_size,
    );
    drawBadge(dc, status_rect, status_label, status_variant);

    cursor_y += dc.lineHeight();

    // Summary
    if (approval.summary) |summary| {
        cursor_y += t.spacing.xs;
        _ = drawWrappedText(
            allocator,
            dc,
            summary,
            .{ rect.min[0] + padding, cursor_y },
            rect.size()[0] - padding * 2.0,
            t.colors.text_primary,
        );
        cursor_y += measureWrappedTextHeight(allocator, dc, summary, rect.size()[0] - padding * 2.0);
    }

    // Audit trail
    cursor_y += t.spacing.xs;
    var audit_buf: [256]u8 = undefined;
    const who = approval.requested_by orelse "unknown";
    const requested_rel = if (approval.requested_at_ms) |ts| blk: {
        var time_buf: [32]u8 = undefined;
        break :blk formatRelativeTime(std.time.milliTimestamp(), ts, &time_buf);
    } else "";
    const requested_line = std.fmt.bufPrint(&audit_buf, "Requested: {s} · {s}", .{ who, requested_rel }) catch who;
    dc.drawText(requested_line, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += dc.lineHeight();

    if (!is_pending) {
        const decision_label = if (approval.decision) |d| decisionLabel(d) else "resolved";
        const resolver = approval.resolved_by orelse "unknown";
        const resolved_rel = if (approval.resolved_at_ms) |ts| blk: {
            var time_buf: [32]u8 = undefined;
            break :blk formatRelativeTime(std.time.milliTimestamp(), ts, &time_buf);
        } else "";

        var resolved_buf: [256]u8 = undefined;
        const resolved_line = std.fmt.bufPrint(&resolved_buf, "Resolved: {s} by {s} · {s}", .{ decision_label, resolver, resolved_rel }) catch decision_label;
        dc.drawText(resolved_line, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += dc.lineHeight();
    } else if (ctx.pending_approval_target_id != null and std.mem.eql(u8, ctx.pending_approval_target_id.?, approval.id)) {
        dc.drawText("Resolving...", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += dc.lineHeight();
    }

    cursor_y += t.spacing.xs;
    dc.drawRect(
        draw_context.Rect.fromMinSize(
            .{ rect.min[0] + padding, cursor_y },
            .{ rect.size()[0] - padding * 2.0, 1.0 },
        ),
        .{ .fill = t.colors.divider },
    );
    cursor_y += t.spacing.xs;

    const payload_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ rect.size()[0] - padding * 2.0, 160.0 },
    );
    drawPayloadBox(allocator, dc, payload_rect, queue, approval.id, approval.payload_json);
    cursor_y = payload_rect.max[1] + t.spacing.sm;

    // Resolve actions
    var decision: ApprovalDecision = .none;
    if (!is_pending) {
        dc.drawText("This approval is already resolved.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        return decision;
    }

    if (approval.can_resolve) {
        const disabled = ctx.pending_approval_resolve_request_id != null;
        const button_height = widgets.button.defaultHeight(t, dc.lineHeight());
        const approve_w = buttonWidth(dc, "Approve", t);
        const decline_w = buttonWidth(dc, "Decline", t);
        const allow_w = buttonWidth(dc, "Allow Always", t);
        var cursor_x = rect.min[0] + padding;

        const approve_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ approve_w, button_height });
        if (widgets.button.draw(dc, approve_rect, "Approve", queue, .{ .variant = .primary, .disabled = disabled })) {
            decision = .allow_once;
        }
        cursor_x += approve_w + t.spacing.sm;

        const decline_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ decline_w, button_height });
        if (widgets.button.draw(dc, decline_rect, "Decline", queue, .{ .variant = .secondary, .disabled = disabled })) {
            decision = .deny;
        }
        cursor_x += decline_w + t.spacing.sm;

        const allow_rect = draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ allow_w, button_height });
        if (widgets.button.draw(dc, allow_rect, "Allow Always", queue, .{ .variant = .secondary, .disabled = disabled })) {
            decision = .allow_always;
        }
    } else {
        dc.drawText("Missing approval id in payload.", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    }

    return decision;
}

fn decisionLabel(decision: []const u8) []const u8 {
    if (std.mem.eql(u8, decision, "allow-once")) return "allowed once";
    if (std.mem.eql(u8, decision, "allow-always")) return "allowed always";
    if (std.mem.eql(u8, decision, "deny")) return "denied";
    return decision;
}

fn decisionBadgeLabel(decision: []const u8) []const u8 {
    if (std.mem.eql(u8, decision, "allow-once")) return "allowed";
    if (std.mem.eql(u8, decision, "allow-always")) return "allowed";
    if (std.mem.eql(u8, decision, "deny")) return "denied";
    return decision;
}

fn decisionBadgeVariant(decision: []const u8) BadgeVariant {
    if (std.mem.eql(u8, decision, "deny")) return .warning;
    return .success;
}

fn drawPayloadBox(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    id: []const u8,
    text: []const u8,
) void {
    const t = dc.theme;
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
    widgets.kinetic_scroll.apply(queue, rect, scroll_y, max_scroll, step);
}

fn drawTab(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    active: bool,
    queue: *input_state.InputQueue,
) bool {
    const t = dc.theme;
    const ss = theme_runtime.getStyleSheet();
    const tab_style = ss.tabs;
    const nav_state = nav_router.get();
    const nav_id = if (nav_state != null) nav_router.makeWidgetId(@returnAddress(), "approvals_inbox.tab", label) else 0;
    if (nav_state) |navp| navp.registerItem(dc.allocator, nav_id, rect);
    const nav_active = if (nav_state) |navp| navp.isActive() else false;
    const focused = if (nav_state) |navp| navp.isFocusedId(nav_id) else false;

    const allow_hover = theme_runtime.allowHover(queue);
    const hovered = (allow_hover and rect.contains(queue.state.mouse_pos)) or (nav_active and focused);
    const pressed = rect.contains(queue.state.mouse_pos) and queue.state.mouse_down_left and queue.state.pointer_kind != .nav;
    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    if (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging) {
                        clicked = true;
                    }
                }
            },
            else => {},
        }
    }
    if (!clicked and nav_active and focused) {
        clicked = nav_router.wasActivated(queue, nav_id);
    }

    const custom =
        tab_style.radius != null or tab_style.fill != null or tab_style.text != null or tab_style.border != null or
        tab_style.underline != null or tab_style.underline_thickness != null or
        tab_style.states.hover.isSet() or tab_style.states.pressed.isSet() or tab_style.states.focused.isSet() or
        tab_style.states.disabled.isSet() or tab_style.states.active.isSet() or tab_style.states.active_hover.isSet();

    if (!custom) {
        const base = if (active) t.colors.primary else t.colors.surface;
        const alpha: f32 = if (active) 0.18 else if (hovered) 0.1 else 0.0;
        const fill = colors.withAlpha(base, alpha);
        const border = colors.withAlpha(t.colors.border, if (active) 0.6 else 0.3);
        dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = fill, .stroke = border, .thickness = 1.0 });

        const text_color = if (active) t.colors.primary else t.colors.text_secondary;
        const text_size = dc.measureText(label, 0.0);
        const text_pos = .{ rect.min[0] + (rect.size()[0] - text_size[0]) * 0.5, rect.min[1] + (rect.size()[1] - text_size[1]) * 0.5 };
        dc.drawText(label, text_pos, .{ .color = text_color });
    } else {
        const transparent: colors.Color = .{ 0.0, 0.0, 0.0, 0.0 };
        const radius = tab_style.radius orelse t.radius.lg;
        var fill: ?style_sheet.Paint = tab_style.fill;
        var text_color: colors.Color = tab_style.text orelse t.colors.text_secondary;
        var border_color: colors.Color = tab_style.border orelse colors.withAlpha(t.colors.border, 0.3);
        var underline_color: colors.Color = tab_style.underline orelse transparent;

        if (active) {
            if (tab_style.states.active.isSet()) {
                const st = tab_style.states.active;
                if (st.fill) |v| fill = v;
                if (st.text) |v| text_color = v;
                if (st.border) |v| border_color = v;
                if (st.underline) |v| underline_color = v;
            } else {
                text_color = tab_style.text orelse t.colors.primary;
                underline_color = tab_style.underline orelse t.colors.primary;
                if (fill == null) fill = style_sheet.Paint{ .solid = colors.withAlpha(t.colors.primary, 0.10) };
            }
        }

        if (focused and tab_style.states.focused.isSet()) {
            const st = tab_style.states.focused;
            if (st.fill) |v| fill = v;
            if (st.text) |v| text_color = v;
            if (st.border) |v| border_color = v;
            if (st.underline) |v| underline_color = v;
        }
        if (hovered and tab_style.states.hover.isSet()) {
            const st = tab_style.states.hover;
            if (st.fill) |v| fill = v;
            if (st.text) |v| text_color = v;
            if (st.border) |v| border_color = v;
            if (st.underline) |v| underline_color = v;
        }
        if (pressed and tab_style.states.pressed.isSet()) {
            const st = tab_style.states.pressed;
            if (st.fill) |v| fill = v;
            if (st.text) |v| text_color = v;
            if (st.border) |v| border_color = v;
            if (st.underline) |v| underline_color = v;
        }
        if (active and hovered and tab_style.states.active_hover.isSet()) {
            const st = tab_style.states.active_hover;
            if (st.fill) |v| fill = v;
            if (st.text) |v| text_color = v;
            if (st.border) |v| border_color = v;
            if (st.underline) |v| underline_color = v;
        }

        if (fill) |paint| {
            panel_chrome.drawPaintRoundedRect(dc, rect, radius, paint);
        } else if (hovered) {
            dc.drawRoundedRect(rect, radius, .{ .fill = colors.withAlpha(t.colors.primary, 0.06) });
        }
        if (border_color[3] > 0.001) {
            dc.drawRoundedRect(rect, radius, .{ .fill = null, .stroke = border_color, .thickness = 1.0 });
        }

        const text_size = dc.measureText(label, 0.0);
        const text_pos = .{ rect.min[0] + (rect.size()[0] - text_size[0]) * 0.5, rect.min[1] + (rect.size()[1] - text_size[1]) * 0.5 };
        dc.drawText(label, text_pos, .{ .color = text_color });

        const th = tab_style.underline_thickness orelse 2.0;
        if (underline_color[3] > 0.001 and th > 0.0) {
            dc.drawLine(.{ rect.min[0], rect.max[1] }, .{ rect.max[0], rect.max[1] }, th, underline_color);
        }
    }

    if (focused) {
        widgets.focus_ring.draw(dc, rect, t.radius.lg);
    }

    return clicked;
}

fn drawBadge(dc: *draw_context.DrawContext, rect: draw_context.Rect, label: []const u8, variant: BadgeVariant) void {
    const t = dc.theme;
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
    const t = dc.theme;
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
