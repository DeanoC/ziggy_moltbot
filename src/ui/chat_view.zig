const zgui = @import("zgui");
const types = @import("../protocol/types.zig");

pub fn draw(messages: []const types.ChatMessage) void {
    if (zgui.beginChild("ChatHistory", .{ .h = 300.0, .child_flags = .{ .border = true } })) {
        for (messages) |msg| {
            zgui.textWrapped("[{s}] {s}", .{ msg.role, msg.content });
        }
    }
    zgui.endChild();
}
