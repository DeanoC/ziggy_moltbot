const zgui = @import("zgui");
const state = @import("../client/state.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");

pub fn draw(
    client_state: state.ClientState,
    is_connected: bool,
    agent_name: ?[]const u8,
    session_name: ?[]const u8,
    message_count: usize,
    last_error: ?[]const u8,
) void {
    const t = theme.activeTheme();
    const spacing = t.spacing.sm;
    const label = t.colors.text_secondary;
    const value = t.colors.text_primary;
    const status_variant: components.core.badge.Variant = switch (client_state) {
        .connected => .success,
        .connecting, .authenticating => .warning,
        .error_state => .danger,
        .disconnected => if (is_connected) .success else .neutral,
    };
    const connection_variant: components.core.badge.Variant = if (is_connected) .success else .neutral;

    zgui.textColored(label, "Status:", .{});
    zgui.sameLine(.{ .spacing = spacing });
    components.core.badge.draw(@tagName(client_state), .{
        .variant = status_variant,
        .filled = true,
        .size = .small,
    });
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textColored(label, "Connection:", .{});
    zgui.sameLine(.{ .spacing = spacing });
    components.core.badge.draw(if (is_connected) "online" else "offline", .{
        .variant = connection_variant,
        .filled = true,
        .size = .small,
    });
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textColored(label, "Agent:", .{});
    zgui.sameLine(.{ .spacing = spacing });
    if (agent_name) |name| {
        zgui.textColored(value, "{s}", .{name});
    } else {
        zgui.textColored(label, "(none)", .{});
    }
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textColored(label, "Session:", .{});
    zgui.sameLine(.{ .spacing = spacing });
    if (session_name) |name| {
        zgui.textColored(value, "{s}", .{name});
    } else {
        zgui.textColored(label, "(none)", .{});
    }
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textColored(label, "Messages:", .{});
    zgui.sameLine(.{ .spacing = spacing });
    zgui.textColored(value, "{d}", .{message_count});
    if (last_error) |err| {
        zgui.sameLine(.{ .spacing = spacing });
        zgui.textColored(t.colors.danger, "Error: {s}", .{err});
    }
}
