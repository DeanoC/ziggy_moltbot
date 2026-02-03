const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const types = @import("../../protocol/types.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");
const ui_command_inbox = @import("../ui_command_inbox.zig");
const components = @import("../components/components.zig");
const theme = @import("../theme.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
    refresh_sessions: bool = false,
    new_session: bool = false,
    select_session: ?[]u8 = null,
};

var select_copy_mode: bool = false;
var show_tool_output: bool = false;
var input_split_state = components.layout.split_pane.SplitState{ .size = 0.0 };
var threads_split_state = components.layout.split_pane.SplitState{ .size = 0.0 };

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
    const show_threads = center_avail[0] > 640.0;
    if (threads_split_state.size == 0.0) {
        threads_split_state.size = @min(260.0, center_avail[0] * 0.28);
    }

    if (show_threads) {
        components.layout.split_pane.begin(.{
            .id = "chat_threads",
            .axis = .vertical,
            .primary_size = threads_split_state.size,
            .min_primary = 200.0,
            .min_secondary = 260.0,
            .border = false,
            .padded = false,
        }, &threads_split_state);
        if (components.layout.split_pane.beginPrimary(.{
            .id = "chat_threads",
            .axis = .vertical,
        }, &threads_split_state)) {
            drawThreadList(allocator, ctx, &action);
        }
        components.layout.split_pane.endPrimary();
        components.layout.split_pane.handleSplitter(.{
            .id = "chat_threads",
            .axis = .vertical,
        }, &threads_split_state);
        if (components.layout.split_pane.beginSecondary(.{
            .id = "chat_threads",
            .axis = .vertical,
        }, &threads_split_state)) {
            drawChatMain(allocator, ctx, inbox, &action);
        }
        components.layout.split_pane.endSecondary();
        components.layout.split_pane.end();
    } else {
        drawChatMain(allocator, ctx, inbox, &action);
    }
    return action;
}

fn drawChatMain(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    action: *ChatPanelAction,
) void {
    const avail = zgui.getContentRegionAvail();
    if (input_split_state.size == 0.0) {
        input_split_state.size = avail[1] * 0.7;
    }
    components.layout.split_pane.begin(.{
        .id = "chat_split",
        .axis = .horizontal,
        .primary_size = input_split_state.size,
        .min_primary = 160.0,
        .min_secondary = 120.0,
        .border = false,
        .padded = false,
    }, &input_split_state);
    if (components.layout.split_pane.beginPrimary(.{
        .id = "chat_split",
        .axis = .horizontal,
    }, &input_split_state)) {
        chat_view.draw(allocator, ctx.messages.items, ctx.stream_text, inbox, avail[1], .{
            .select_copy_mode = select_copy_mode,
            .show_tool_output = show_tool_output,
        });
    }
    components.layout.split_pane.endPrimary();
    components.layout.split_pane.handleSplitter(.{
        .id = "chat_split",
        .axis = .horizontal,
    }, &input_split_state);
    if (components.layout.split_pane.beginSecondary(.{
        .id = "chat_split",
        .axis = .horizontal,
    }, &input_split_state)) {
        const input_avail = zgui.getContentRegionAvail();
        if (input_panel.draw(allocator, input_avail[0], input_avail[1])) |message| {
            action.send_message = message;
        }
    }
    components.layout.split_pane.endSecondary();
    components.layout.split_pane.end();
}

fn drawThreadList(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    action: *ChatPanelAction,
) void {
    const t = theme.activeTheme();
    theme.push(.heading);
    zgui.text("Threads", .{});
    theme.pop();

    zgui.beginDisabled(.{ .disabled = ctx.sessions_loading });
    if (components.core.button.draw("Refresh", .{ .variant = .secondary, .size = .small })) {
        action.refresh_sessions = true;
    }
    zgui.sameLine(.{ .spacing = t.spacing.sm });
    if (components.core.button.draw("New", .{ .variant = .primary, .size = .small })) {
        action.new_session = true;
    }
    zgui.endDisabled();

    if (ctx.sessions_loading) {
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        components.core.badge.draw("Loading", .{ .variant = .primary, .filled = false, .size = .small });
    }

    zgui.separator();
    zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });

    if (components.layout.scroll_area.begin(.{ .id = "ChatThreadsList", .border = true })) {
        if (ctx.sessions.items.len == 0) {
            zgui.textDisabled("No threads yet.", .{});
        } else {
            for (ctx.sessions.items, 0..) |session, idx| {
                zgui.pushIntId(@intCast(idx));
                defer zgui.popId();
                const selected = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key);
                const label = displayName(session);
                if (components.data.list_item.draw(.{ .label = label, .selected = selected, .id = session.key })) {
                    action.select_session = allocator.dupe(u8, session.key) catch null;
                }
            }
        }
    }
    components.layout.scroll_area.end();
}

fn displayName(session: types.Session) []const u8 {
    return session.display_name orelse session.label orelse session.key;
}
