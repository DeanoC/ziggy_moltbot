const std = @import("std");
const zgui = @import("zgui");
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

    zgui.text("Sessions", .{});
    if (zgui.button("Refresh", .{})) {
        action.refresh = true;
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    if (zgui.button("New", .{})) {
        action.new_session = true;
    }
    if (loading) {
        zgui.sameLine(.{});
        zgui.textDisabled("Loading...", .{});
    }

    zgui.separator();

    if (zgui.beginChild("SessionList", .{ .child_flags = .{ .border = true } })) {
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
    zgui.endChild();

    return action;
}
