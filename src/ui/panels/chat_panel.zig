const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
};

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
) ChatPanelAction {
    var action = ChatPanelAction{};
    const center_avail = zgui.getContentRegionAvail();
    const input_height: f32 = 88.0;
    const history_height = @max(80.0, center_avail[1] - input_height - zgui.getStyle().item_spacing[1]);
    chat_view.draw(allocator, ctx.messages.items, ctx.stream_text, history_height);
    zgui.separator();
    if (input_panel.draw(allocator)) |message| {
        action.send_message = message;
    }
    return action;
}
