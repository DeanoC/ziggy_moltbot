const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");
const operator_view = @import("operator_view.zig");

pub const ApprovalsInboxAction = struct {
    resolve_approval: ?operator_view.ExecApprovalResolveAction = null,
};

const Filter = enum {
    all,
    pending,
    resolved,
};

var active_filter: Filter = .all;

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext) ApprovalsInboxAction {
    var action = ApprovalsInboxAction{};
    const opened = zgui.beginChild("ApprovalsInboxView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        const header_open = components.layout.header_bar.begin(.{
            .title = "Approvals Needed",
            .subtitle = "Human-in-the-loop",
            .show_notifications = true,
            .notification_count = ctx.approvals.items.len,
        });
        if (header_open) {
            var count_buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&count_buf, "{d} pending", .{ctx.approvals.items.len}) catch "0 pending";
            components.core.badge.draw(label, .{ .variant = .primary, .filled = false, .size = .small });
        }
        components.layout.header_bar.end();

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        const pending_count = ctx.approvals.items.len;
        const resolved_count: usize = 0;
        const all_count = pending_count + resolved_count;
        var all_buf: [24]u8 = undefined;
        var pending_buf: [24]u8 = undefined;
        var resolved_buf: [24]u8 = undefined;
        const all_label = std.fmt.bufPrint(&all_buf, "All ({d})", .{all_count}) catch "All";
        const pending_label = std.fmt.bufPrint(&pending_buf, "Pending ({d})", .{pending_count}) catch "Pending";
        const resolved_label = std.fmt.bufPrint(&resolved_buf, "Resolved ({d})", .{resolved_count}) catch "Resolved";
        const all_label_z = zgui.formatZ("{s}", .{all_label});
        const pending_label_z = zgui.formatZ("{s}", .{pending_label});
        const resolved_label_z = zgui.formatZ("{s}", .{resolved_label});

        if (components.core.tab_bar.begin("ApprovalsFilters")) {
            if (components.core.tab_bar.beginItem(all_label_z)) {
                active_filter = .all;
                components.core.tab_bar.endItem();
            }
            if (components.core.tab_bar.beginItem(pending_label_z)) {
                active_filter = .pending;
                components.core.tab_bar.endItem();
            }
            if (components.core.tab_bar.beginItem(resolved_label_z)) {
                active_filter = .resolved;
                components.core.tab_bar.endItem();
            }
            components.core.tab_bar.end();
        }

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        if (components.layout.scroll_area.begin(.{ .id = "ApprovalsInboxList", .border = false })) {
            if (active_filter == .resolved) {
                zgui.textDisabled("No resolved approvals yet.", .{});
            } else if (ctx.approvals.items.len == 0) {
                zgui.textDisabled("No pending approvals.", .{});
            } else {
                for (ctx.approvals.items, 0..) |approval, idx| {
                    zgui.pushIntId(@intCast(idx));
                    defer zgui.popId();
                    const decision = components.data.approval_card.draw(.{
                        .id = approval.id,
                        .summary = approval.summary,
                        .requested_at_ms = approval.requested_at_ms,
                        .payload_json = approval.payload_json,
                        .can_resolve = approval.can_resolve,
                    });
                    const id_copy = switch (decision) {
                        .none => null,
                        else => allocator.dupe(u8, approval.id) catch null,
                    };
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
                    if (idx + 1 < ctx.approvals.items.len) {
                        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });
                    }
                }
            }
        }
        components.layout.scroll_area.end();
    }
    zgui.endChild();
    return action;
}
