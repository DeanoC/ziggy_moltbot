const std = @import("std");
const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const components = @import("../components.zig");

pub const Decision = enum {
    none,
    allow_once,
    allow_always,
    deny,
};

pub const Args = struct {
    id: []const u8,
    summary: ?[]const u8 = null,
    requested_at_ms: ?i64 = null,
    payload_json: []const u8,
    can_resolve: bool = true,
};

pub fn draw(args: Args) Decision {
    var decision: Decision = .none;
    const t = theme.activeTheme();
    const title = "Approval Needed";

    if (components.layout.card.begin(.{ .title = title, .id = args.id, .elevation = .raised })) {
        if (args.summary) |summary| {
            theme.push(.heading);
            zgui.textWrapped("{s}", .{summary});
            theme.pop();
        }
        if (args.requested_at_ms) |ts| {
            var time_buf: [32]u8 = undefined;
            const label = formatRelativeTime(std.time.milliTimestamp(), ts, &time_buf);
            zgui.textDisabled("Requested {s}", .{label});
        }
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
        zgui.separator();
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
        var payload_id_buf: [96]u8 = undefined;
        const payload_id = std.fmt.bufPrint(&payload_id_buf, "ApprovalPayload_{s}", .{args.id}) catch "ApprovalPayload";
        if (components.layout.scroll_area.begin(.{ .id = payload_id, .height = 120.0, .border = true })) {
            zgui.textWrapped("{s}", .{args.payload_json});
        }
        components.layout.scroll_area.end();

        if (args.can_resolve) {
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
            if (components.core.button.draw("Approve", .{ .variant = .success, .size = .small })) {
                decision = .allow_once;
            }
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            if (components.core.button.draw("Decline", .{ .variant = .danger, .size = .small })) {
                decision = .deny;
            }
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            if (components.core.button.draw("Allow Always", .{ .variant = .secondary, .size = .small })) {
                decision = .allow_always;
            }
        } else {
            zgui.textWrapped("Missing approval id in payload.", .{});
        }
    }
    components.layout.card.end();
    return decision;
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
