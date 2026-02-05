const std = @import("std");
const state = @import("../../client/state.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");
const ui_command_inbox = @import("../ui_command_inbox.zig");
const types = @import("../../protocol/types.zig");
const theme = @import("../theme.zig");
const draw_context = @import("../draw_context.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const widgets = @import("../widgets/widgets.zig");
const workspace = @import("../workspace.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
};

const HeaderAction = struct {
    copy_selection: bool = false,
    copy_all: bool = false,
};

var select_copy_mode: bool = false;
var show_tool_output: bool = false;

pub fn draw(
    allocator: std.mem.Allocator,
    panel_state: *workspace.ChatPanel,
    session_key: ?[]const u8,
    session_state: ?*const state.ChatSessionState,
    agent_icon: []const u8,
    agent_name: []const u8,
    session_label: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    rect_override: ?draw_context.Rect,
) ChatPanelAction {
    var action = ChatPanelAction{};
    const t = theme.activeTheme();

    var subtitle_buf: [256]u8 = undefined;
    const subtitle = if (session_key) |key| blk: {
        const label = session_label orelse key;
        break :blk std.fmt.bufPrint(
            &subtitle_buf,
            "{s} {s} — {s}",
            .{ agent_icon, agent_name, label },
        ) catch label;
    } else "No session selected.";

    const has_session = session_key != null;
    const messages = if (session_state) |state_val| state_val.messages.items else &[_]types.ChatMessage{};
    const stream_text = if (session_state) |state_val| state_val.stream_text else null;
    const has_selection_select = chat_view.hasSelectCopySelection(&panel_state.view);
    const has_selection_custom = chat_view.hasSelection(&panel_state.view);

    const panel_rect = rect_override orelse return action;
    var panel_ctx = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer panel_ctx.deinit();
    panel_ctx.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();

    const header_width = panel_rect.size()[0];
    const title = "Chat";
    theme.push(.title);
    const title_height = panel_ctx.lineHeight();
    theme.pop();
    const subtitle_height = panel_ctx.lineHeight();
    const control_height = @max(subtitle_height, 20.0);
    const top_pad = t.spacing.xs;
    const title_gap = t.spacing.xs * 0.5;
    const controls_gap = t.spacing.xs;
    const bottom_pad = t.spacing.xs;
    const header_height = top_pad + title_height + title_gap + subtitle_height + controls_gap + control_height + bottom_pad;
    const header_rect = draw_context.Rect.fromMinSize(panel_rect.min, .{ header_width, header_height });
    const header_action = drawHeader(
        &panel_ctx,
        header_rect,
        queue,
        title,
        subtitle,
        has_session,
        &select_copy_mode,
        &show_tool_output,
        has_selection_select,
        has_selection_custom,
        control_height,
    );
    if (header_action.copy_selection) {
        if (select_copy_mode) {
            chat_view.copySelectCopySelectionToClipboard(allocator, &panel_state.view);
        } else {
            chat_view.copySelectionToClipboard(allocator, &panel_state.view, messages, stream_text, inbox, show_tool_output);
        }
    }
    if (header_action.copy_all) {
        chat_view.copyAllToClipboard(allocator, messages, stream_text, inbox, show_tool_output);
    }

    const separator_h: f32 = 1.0;
    const separator_gap = t.spacing.xs;
    const separator_block = separator_h + separator_gap * 2.0;

    var cursor_y = header_rect.max[1];
    const sep1_y = cursor_y + separator_gap;
    const sep1_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], sep1_y }, .{ panel_rect.size()[0], separator_h });
    panel_ctx.drawRect(sep1_rect, .{ .fill = t.colors.divider });
    cursor_y = sep1_rect.max[1] + separator_gap;

    const remaining = @max(0.0, panel_rect.max[1] - cursor_y);
    const available_for_history_input = if (remaining > separator_block) remaining - separator_block else 0.0;
    const min_input_height: f32 = 160.0;
    const desired_input_height = @min(available_for_history_input, @max(min_input_height, available_for_history_input * 0.4));
    const input_height = @max(0.0, desired_input_height);
    const history_height = @max(0.0, available_for_history_input - input_height);

    const history_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], cursor_y }, .{ panel_rect.size()[0], history_height });
    if (select_copy_mode) {
        chat_view.drawSelectCopy(
            allocator,
            &panel_ctx,
            history_rect,
            queue,
            &panel_state.view,
            session_key,
            messages,
            stream_text,
            inbox,
            .{
                .select_copy_mode = select_copy_mode,
                .show_tool_output = show_tool_output,
            },
        );
    } else {
        chat_view.drawCustom(
            allocator,
            &panel_ctx,
            history_rect,
            queue,
            &panel_state.view,
            session_key,
            messages,
            stream_text,
            inbox,
            .{
                .select_copy_mode = select_copy_mode,
                .show_tool_output = show_tool_output,
            },
        );
    }

    cursor_y = history_rect.max[1];
    const sep2_y = cursor_y + separator_gap;
    const sep2_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], sep2_y }, .{ panel_rect.size()[0], separator_h });
    panel_ctx.drawRect(sep2_rect, .{ .fill = t.colors.divider });
    cursor_y = sep2_rect.max[1] + separator_gap;

    const input_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], cursor_y }, .{ panel_rect.size()[0], input_height });
    if (input_panel.draw(allocator, &panel_ctx, input_rect, queue, has_session)) |message| {
        action.send_message = message;
    }

    return action;
}

fn drawHeader(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    title: []const u8,
    subtitle: []const u8,
    has_session: bool,
    select_copy_mode_ref: *bool,
    show_tool_output_ref: *bool,
    has_selection_select: bool,
    has_selection_custom: bool,
    control_height: f32,
) HeaderAction {
    const t = theme.activeTheme();
    const top_pad = t.spacing.xs;
    const title_gap = t.spacing.xs * 0.5;
    const controls_gap = t.spacing.xs;
    const start_x = rect.min[0] + t.spacing.sm;
    const start_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = ctx.lineHeight();
    ctx.drawText(title, .{ start_x, start_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    const body_height = ctx.lineHeight();

    const subtitle_y = start_y + title_height + title_gap;
    ctx.drawText(subtitle, .{ start_x, subtitle_y }, .{ .color = t.colors.text_secondary });

    const controls_y = subtitle_y + body_height + controls_gap;
    var cursor_x = start_x;
    const box_size = @min(control_height, body_height);
    const checkbox_spacing = t.spacing.xs;
    const item_spacing = t.spacing.xs;

    const select_label = "Select/Copy Mode";
    const select_width = box_size + checkbox_spacing + ctx.measureText(select_label, 0.0)[0];
    const select_rect = draw_context.Rect.fromMinSize(.{ cursor_x, controls_y }, .{ select_width, control_height });
    _ = widgets.checkbox.draw(ctx, select_rect, select_label, select_copy_mode_ref, queue, .{ .disabled = !has_session });
    cursor_x += select_width + item_spacing;

    const tool_label = "Show tool output";
    const tool_width = box_size + checkbox_spacing + ctx.measureText(tool_label, 0.0)[0];
    const tool_rect = draw_context.Rect.fromMinSize(.{ cursor_x, controls_y }, .{ tool_width, control_height });
    _ = widgets.checkbox.draw(ctx, tool_rect, tool_label, show_tool_output_ref, queue, .{ .disabled = !has_session });
    cursor_x += tool_width + item_spacing;

    const has_selection = if (select_copy_mode_ref.*) has_selection_select else has_selection_custom;

    const copy_label = "Copy Selection";
    const copy_width = ctx.measureText(copy_label, 0.0)[0] + t.spacing.sm * 2.0;
    const copy_rect = draw_context.Rect.fromMinSize(.{ cursor_x, controls_y }, .{ copy_width, control_height });
    const copy_clicked = widgets.button.draw(ctx, copy_rect, copy_label, queue, .{
        .disabled = !has_session or !has_selection,
        .variant = .secondary,
    });
    cursor_x += copy_width + item_spacing;

    const all_label = "Copy All";
    const all_width = ctx.measureText(all_label, 0.0)[0] + t.spacing.sm * 2.0;
    const all_rect = draw_context.Rect.fromMinSize(.{ cursor_x, controls_y }, .{ all_width, control_height });
    const all_clicked = widgets.button.draw(ctx, all_rect, all_label, queue, .{
        .disabled = !has_session,
        .variant = .secondary,
    });

    return .{
        .copy_selection = copy_clicked,
        .copy_all = all_clicked,
    };
}
