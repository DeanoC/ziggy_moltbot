const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");
const ui_command_inbox = @import("../ui_command_inbox.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
};

var select_copy_mode: bool = false;
var show_tool_output: bool = false;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
) ChatPanelAction {
    var action = ChatPanelAction{};

    // Controls live outside the scrollable chat history so they don't disappear when we
    // auto-scroll to bottom.
    if (zgui.checkbox("Select/Copy Mode", .{ .v = &select_copy_mode })) {
        // local UI state
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    _ = zgui.checkbox("Show tool output", .{ .v = &show_tool_output });
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.beginDisabled(.{ .disabled = !select_copy_mode or !chat_view.hasSelection() });
    if (zgui.button("Copy Selection", .{})) {
        chat_view.copySelectionToClipboard(allocator);
    }
    zgui.endDisabled();
    zgui.sameLine(.{ .spacing = 8.0 });
    if (zgui.button("Copy All", .{})) {
        chat_view.copyAllToClipboard(allocator, ctx.messages.items, ctx.stream_text, inbox, show_tool_output);
    }

    zgui.separator();

    const center_avail = zgui.getContentRegionAvail();
    const style = zgui.getStyle();
    const spacing = style.item_spacing[1];
    const separator_height: f32 = 1.0 + spacing;
    const button_height = zgui.getFrameHeight();
    const input_min_box: f32 = 56.0;
    const input_min_total = input_min_box + button_height + spacing + separator_height;
    const history_min: f32 = 80.0;
    var history_height = center_avail[1] - input_min_total;
    if (history_height < 0.0) history_height = 0.0;
    if (history_height < history_min and center_avail[1] >= input_min_total + history_min) {
        history_height = history_min;
    }

    chat_view.draw(allocator, ctx.messages.items, ctx.stream_text, inbox, history_height, .{
        .select_copy_mode = select_copy_mode,
        .show_tool_output = show_tool_output,
    });
    zgui.separator();

    const input_avail = zgui.getContentRegionAvail();
    if (input_panel.draw(allocator, input_avail[0], input_avail[1])) |message| {
        action.send_message = message;
    }
    return action;
}
