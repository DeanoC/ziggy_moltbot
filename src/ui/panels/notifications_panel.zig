const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const types = @import("../../protocol/types.zig");

pub const NotificationsPanelAction = struct {
    refresh: bool = false,
};

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext) NotificationsPanelAction {
    _ = allocator;
    var action = NotificationsPanelAction{};

    zgui.text("Notifications", .{});
    if (zgui.button("Refresh Sessions", .{})) {
        action.refresh = true;
    }

    zgui.separator();

    if (ctx.sessions.items.len == 0) {
        zgui.textDisabled("No sessions loaded.", .{});
        return action;
    }

    var indices = std.ArrayList(usize).empty;
    defer indices.deinit(ctx.allocator);

    for (ctx.sessions.items, 0..) |session, index| {
        if (!isNotificationSession(session)) continue;
        indices.append(ctx.allocator, index) catch {};
    }

    if (indices.items.len == 0) {
        zgui.textDisabled("No notification sessions.", .{});
        return action;
    }

    std.sort.heap(usize, indices.items, ctx.sessions.items, sessionUpdatedDesc);

    const now_ms = std.time.milliTimestamp();
    for (indices.items) |idx| {
        const session = ctx.sessions.items[idx];
        zgui.pushIntId(@intCast(idx));
        defer zgui.popId();

        const label = session.display_name orelse session.label orelse session.key;
        zgui.text("{s}", .{label});
        zgui.sameLine(.{ .spacing = 12.0 });
        renderRelativeTime(now_ms, session.updated_at);
        zgui.textDisabled("{s}", .{session.key});
        zgui.separator();
    }

    return action;
}

fn sessionUpdatedDesc(sessions: []const types.Session, a: usize, b: usize) bool {
    const updated_a = sessions[a].updated_at orelse 0;
    const updated_b = sessions[b].updated_at orelse 0;
    return updated_a > updated_b;
}

fn renderRelativeTime(now_ms: i64, updated_at: ?i64) void {
    const ts = updated_at orelse 0;
    if (ts <= 0) {
        zgui.textDisabled("never", .{});
        return;
    }
    const delta_ms = if (now_ms > ts) now_ms - ts else 0;
    const seconds = @as(u64, @intCast(@divTrunc(delta_ms, 1000)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;

    if (seconds < 60) {
        zgui.textDisabled("{d}s ago", .{seconds});
        return;
    }
    if (minutes < 60) {
        zgui.textDisabled("{d}m ago", .{minutes});
        return;
    }
    if (hours < 24) {
        zgui.textDisabled("{d}h ago", .{hours});
        return;
    }
    zgui.textDisabled("{d}d ago", .{days});
}

fn isNotificationSession(session: types.Session) bool {
    const kind = session.kind orelse return false;
    return std.ascii.eqlIgnoreCase(kind, "cron") or std.ascii.eqlIgnoreCase(kind, "heartbeat");
}
