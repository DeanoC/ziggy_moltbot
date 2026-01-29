const zgui = @import("zgui");
const state = @import("../client/state.zig");

pub fn draw(client_state: state.ClientState, session_name: ?[]const u8, message_count: usize) void {
    zgui.separator();
    zgui.text("Status: {s}", .{@tagName(client_state)});
    zgui.sameLine(.{});
    if (session_name) |name| {
        zgui.text("Session: {s}", .{name});
    } else {
        zgui.text("Session: (none)", .{});
    }
    zgui.sameLine(.{});
    zgui.text("Messages: {d}", .{message_count});
}
