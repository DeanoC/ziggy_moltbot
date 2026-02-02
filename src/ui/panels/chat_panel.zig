const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");
const ui_command_inbox = @import("../ui_command_inbox.zig");
const components = @import("../components/components.zig");
const theme = @import("../theme.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
};

var select_copy_mode: bool = false;
var show_tool_output: bool = false;
var split_state = components.layout.split_pane.SplitState{ .size = 0.0 };

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
) ChatPanelAction {
    var action = ChatPanelAction{};

    const t = theme.activeTheme();
    if (components.layout.header_bar.begin(.{ .title = "Chat" })) {
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        _ = zgui.checkbox("Select/Copy Mode", .{ .v = &select_copy_mode });
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        _ = zgui.checkbox("Show tool output", .{ .v = &show_tool_output });
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        zgui.beginDisabled(.{ .disabled = !select_copy_mode or !chat_view.hasSelection() });
        if (components.core.button.draw("Copy Selection", .{ .variant = .secondary, .size = .small })) {
            chat_view.copySelectionToClipboard(allocator);
        }
        zgui.endDisabled();
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (components.core.button.draw("Copy All", .{ .variant = .secondary, .size = .small })) {
            chat_view.copyAllToClipboard(allocator, ctx.messages.items, ctx.stream_text, inbox, show_tool_output);
        }
        components.layout.header_bar.end();
    }

    zgui.separator();

    const center_avail = zgui.getContentRegionAvail();
    if (split_state.size == 0.0) {
        split_state.size = center_avail[1] * 0.7;
    }
    components.layout.split_pane.begin(.{
        .id = "chat_split",
        .axis = .horizontal,
        .primary_size = split_state.size,
        .min_primary = 160.0,
        .min_secondary = 120.0,
        .border = false,
        .padded = false,
    }, &split_state);
    if (components.layout.split_pane.beginPrimary(.{
        .id = "chat_split",
        .axis = .horizontal,
    }, &split_state)) {
        chat_view.draw(allocator, ctx.messages.items, ctx.stream_text, inbox, center_avail[1], .{
            .select_copy_mode = select_copy_mode,
            .show_tool_output = show_tool_output,
        });
    }
    components.layout.split_pane.endPrimary();
    components.layout.split_pane.handleSplitter(.{
        .id = "chat_split",
        .axis = .horizontal,
    }, &split_state);
    if (components.layout.split_pane.beginSecondary(.{
        .id = "chat_split",
        .axis = .horizontal,
    }, &split_state)) {
        const input_avail = zgui.getContentRegionAvail();
        if (input_panel.draw(allocator, input_avail[0], input_avail[1])) |message| {
            action.send_message = message;
        }
    }
    components.layout.split_pane.endSecondary();
    components.layout.split_pane.end();
    return action;
}
