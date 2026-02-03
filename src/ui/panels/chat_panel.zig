const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");
const ui_command_inbox = @import("../ui_command_inbox.zig");
const types = @import("../../protocol/types.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
};

var select_copy_mode: bool = false;
var show_tool_output: bool = false;

pub fn draw(
    allocator: std.mem.Allocator,
    session_key: ?[]const u8,
    session_state: ?*const state.ChatSessionState,
    agent_icon: []const u8,
    agent_name: []const u8,
    session_label: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
) ChatPanelAction {
    var action = ChatPanelAction{};

    if (session_key) |key| {
        const label = session_label orelse key;
        zgui.text("{s} {s} — {s}", .{ agent_icon, agent_name, label });
    } else {
        zgui.textDisabled("No session selected.", .{});
    }
    zgui.separator();

    // Controls live outside the scrollable chat history so they don't disappear when we
    // auto-scroll to bottom.
    const has_session = session_key != null;
    zgui.beginDisabled(.{ .disabled = !has_session });
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
        const messages = if (session_state) |state_val| state_val.messages.items else &[_]types.ChatMessage{};
        const stream_text = if (session_state) |state_val| state_val.stream_text else null;
        chat_view.copyAllToClipboard(allocator, messages, stream_text, inbox, show_tool_output);
    }
    zgui.endDisabled();

    zgui.separator();

    const center_avail = zgui.getContentRegionAvail();
    const style = zgui.getStyle();
    const spacing = style.item_spacing[1];
    const separator_height: f32 = 1.0 + spacing;
    const input_height: f32 = 80.0 + zgui.getFrameHeight() + spacing * 3.0 + separator_height;
    const history_height = @max(80.0, center_avail[1] - input_height);

    const messages = if (session_state) |state_val| state_val.messages.items else &[_]types.ChatMessage{};
    const stream_text = if (session_state) |state_val| state_val.stream_text else null;
    chat_view.draw(allocator, messages, stream_text, inbox, history_height, .{
        .select_copy_mode = select_copy_mode,
        .show_tool_output = show_tool_output,
    });
    zgui.separator();

    const input_avail = zgui.getContentRegionAvail();
    zgui.beginDisabled(.{ .disabled = !has_session });
    if (input_panel.draw(allocator, input_avail[0], input_avail[1] - zgui.getFrameHeightWithSpacing())) |message| {
        action.send_message = message;
    }
    zgui.endDisabled();
    return action;
}
