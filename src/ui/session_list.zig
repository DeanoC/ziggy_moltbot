const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const components = @import("components/components.zig");
const types = @import("../protocol/types.zig");

pub const SessionAction = struct {
    refresh: bool = false,
    new_session: bool = false,
    selected_key: ?[]u8 = null,
};

pub fn draw(
    allocator: std.mem.Allocator,
    sessions: []const types.Session,
    current_key: ?[]const u8,
    loading: bool,
) SessionAction {
    var action = SessionAction{};

    const t = theme.activeTheme();
    theme.push(.heading);
    zgui.text("Sessions", .{});
    theme.pop();
    if (components.core.button.draw("Refresh", .{ .variant = .secondary, .size = .small })) {
        action.refresh = true;
    }
    zgui.sameLine(.{ .spacing = t.spacing.sm });
    if (components.core.button.draw("New", .{ .variant = .primary, .size = .small })) {
        action.new_session = true;
    }
    if (loading) {
        zgui.sameLine(.{});
        components.core.badge.draw("Loading", .{ .variant = .primary, .filled = false, .size = .small });
    }

    zgui.separator();

    if (components.layout.scroll_area.begin(.{ .id = "SessionList", .border = true })) {
        if (sessions.len == 0) {
            zgui.textDisabled("No sessions loaded.", .{});
        }
        for (sessions, 0..) |session, index| {
            zgui.pushIntId(@intCast(index));
            const label = session.display_name orelse session.label orelse session.key;
            const selected = if (current_key) |key| std.mem.eql(u8, key, session.key) else false;
            const label_z = zgui.formatZ("{s}", .{label});
            if (zgui.selectable(label_z, .{ .selected = selected })) {
                action.selected_key = allocator.dupe(u8, session.key) catch null;
            }
            zgui.popId();
        }
    }
    components.layout.scroll_area.end();

    return action;
}
