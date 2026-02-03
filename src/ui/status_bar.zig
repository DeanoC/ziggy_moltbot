const zgui = @import("zgui");
const state = @import("../client/state.zig");

pub fn draw(
    client_state: state.ClientState,
    is_connected: bool,
    agent_name: ?[]const u8,
    session_name: ?[]const u8,
    message_count: usize,
    last_error: ?[]const u8,
) void {
    zgui.separator();

    const status_color: [4]f32 = switch (client_state) {
        .connected => .{ 0.24, 0.8, 0.45, 1.0 },
        .connecting, .authenticating => .{ 0.95, 0.7, 0.2, 1.0 },
        .error_state => .{ 0.9, 0.3, 0.3, 1.0 },
        .disconnected => if (is_connected) .{ 0.24, 0.8, 0.45, 1.0 } else .{ 0.7, 0.7, 0.7, 1.0 },
    };

    zgui.textColored(status_color, "Status: {s}", .{@tagName(client_state)});
    zgui.sameLine(.{});
    zgui.text("Connection: {s}", .{if (is_connected) "online" else "offline"});
    zgui.sameLine(.{});
    if (agent_name) |name| {
        zgui.text("Agent: {s}", .{name});
    } else {
        zgui.text("Agent: (none)", .{});
    }
    zgui.sameLine(.{});
    if (session_name) |name| {
        zgui.text("Session: {s}", .{name});
    } else {
        zgui.text("Session: (none)", .{});
    }
    zgui.sameLine(.{});
    zgui.text("Messages: {d}", .{message_count});
    if (last_error) |err| {
        zgui.sameLine(.{});
        zgui.textColored(.{ 0.9, 0.4, 0.4, 1.0 }, "Error: {s}", .{err});
    }
}
