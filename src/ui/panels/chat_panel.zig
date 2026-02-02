const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");
const ui_command_inbox = @import("../ui_command_inbox.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
};

var show_tool_output: bool = false;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
) ChatPanelAction {
    var action = ChatPanelAction{};
    const center_avail = zgui.getContentRegionAvail();
    const style = zgui.getStyle();
    const spacing = style.item_spacing[1];
    const separator_height: f32 = 1.0 + spacing;
    const input_height: f32 = 80.0 + zgui.getFrameHeight() + spacing * 3.0 + separator_height;
    const history_height = @max(80.0, center_avail[1] - input_height);
    // Tool output toggle lives here (always visible), but is a simple local UI state.
    _ = zgui.checkbox("Show tool output", .{ .v = &show_tool_output });
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textDisabled("(toolResult/tool*)", .{});
    chat_view.draw(allocator, ctx.messages.items, ctx.stream_text, inbox, history_height, show_tool_output);
    zgui.separator();

    const input_avail = zgui.getContentRegionAvail();
    if (input_panel.draw(allocator, input_avail[0], input_avail[1] - zgui.getFrameHeightWithSpacing())) |message| {
        action.send_message = message;
    }
    return action;
}
