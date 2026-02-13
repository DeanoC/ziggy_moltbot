const std = @import("std");
const state = @import("../../client/state.zig");
const chat_view = @import("../chat_view.zig");
const input_panel = @import("../input_panel.zig");
const ui_command_inbox = @import("../ui_command_inbox.zig");
const types = @import("../../protocol/types.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const session_kind = @import("../../client/session_kind.zig");
const session_keys = @import("../../client/session_keys.zig");
const draw_context = @import("../draw_context.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const cursor = @import("../input/cursor.zig");
const widgets = @import("../widgets/widgets.zig");
const workspace = @import("../workspace.zig");
const surface_chrome = @import("../surface_chrome.zig");
const session_presenter = @import("../session_presenter.zig");
const debug_visibility = @import("../debug_visibility.zig");

pub const ChatPanelAction = struct {
    send_message: ?[]u8 = null,
    select_session: ?[]u8 = null,
    select_session_id: ?[]u8 = null,
    new_chat_session_key: ?[]u8 = null,

    open_activity_panel: bool = false,
    open_approvals_panel: bool = false,
};

const HeaderAction = struct {
    picker_rect: ?draw_context.Rect = null,
    request_new_chat: bool = false,
    open_activity_panel: bool = false,
    open_approvals_panel: bool = false,
};

const SessionSelection = struct {
    key: ?[]u8 = null,
    session_id: ?[]u8 = null,
};

const CopyContextMenuAction = enum {
    none,
    copy_selection,
    copy_all,
};

fn countWarnErrorActivity(messages: []const types.ChatMessage, inbox: ?*const ui_command_inbox.UiCommandInbox) usize {
    _ = inbox;
    // Heuristic: scan recent tool messages and count warn/error-like entries.
    var count: usize = 0;
    var scanned: usize = 0;
    var idx: usize = messages.len;
    const max_scan: usize = 200;
    while (idx > 0 and scanned < max_scan) {
        idx -= 1;
        scanned += 1;
        const msg = messages[idx];
        if (!isToolRole(msg.role)) continue;
        if (looksWarnOrError(msg.content)) {
            count += 1;
        }
    }
    return count;
}

fn isToolRole(role: []const u8) bool {
    return std.mem.startsWith(u8, role, "tool") or std.mem.eql(u8, role, "toolResult");
}

fn looksWarnOrError(content: []const u8) bool {
    return containsIgnoreCase(content, "error") or
        containsIgnoreCase(content, "failed") or
        containsIgnoreCase(content, "exception") or
        containsIgnoreCase(content, "warning") or
        containsIgnoreCase(content, "warn");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

pub fn draw(
    allocator: std.mem.Allocator,
    panel_state: *workspace.ChatPanel,
    agent_id: []const u8,
    session_key: ?[]const u8,
    session_state: ?*const state.ChatSessionState,
    agent_icon: []const u8,
    agent_name: []const u8,
    sessions: []const types.Session,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    pending_approvals_count: usize,
    rect_override: ?draw_context.Rect,
) ChatPanelAction {
    var action = ChatPanelAction{};
    const t = theme.activeTheme();

    normalizeSelectedSessionId(allocator, panel_state, session_key, sessions);

    const status_text: []const u8 = if (session_state) |st| blk: {
        if (st.messages_loading) break :blk "loading";
        if (st.stream_run_id != null) break :blk "replying";
        if (st.awaiting_reply) break :blk "waiting";
        break :blk "";
    } else "";
    const is_busy = status_text.len > 0;
    const busy_phase: u8 = if (is_busy)
        @intCast(@mod(@divTrunc(std.time.milliTimestamp(), 320), 4))
    else
        0;
    var composer_status_buf: [80]u8 = undefined;
    const composer_status_text: ?[]const u8 = if (is_busy) blk: {
        const dots = switch (busy_phase) {
            0 => "",
            1 => ".",
            2 => "..",
            else => "...",
        };
        break :blk std.fmt.bufPrint(&composer_status_buf, "Thinking{s}", .{dots}) catch "Thinking";
    } else if (status_text.len > 0) blk: {
        break :blk switch (status_text[0]) {
            'l' => "Loading",
            'r' => "Replying",
            'w' => "Waiting",
            else => status_text,
        };
    } else null;

    const has_session = session_key != null;
    const messages = if (session_state) |state_val| state_val.messages.items else &[_]types.ChatMessage{};
    const stream_text = if (session_state) |state_val| state_val.stream_text else null;

    const debug_tier = debug_visibility.current_tier;
    const show_tool_output = debug_visibility.showToolOutput(debug_tier);
    const activity_warn_error_count = countWarnErrorActivity(messages, inbox);

    const has_selection_select = chat_view.hasSelectCopySelection(&panel_state.view);
    const has_selection_custom = chat_view.hasSelection(&panel_state.view);
    const has_selection = if (panel_state.select_copy_mode) has_selection_select else has_selection_custom;
    const panel_rect = rect_override orelse return action;
    var panel_ctx = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer panel_ctx.deinit();
    surface_chrome.drawBackground(&panel_ctx, panel_rect);

    const queue = input_router.getQueue();

    const header_width = panel_rect.size()[0];
    const row_height = panel_ctx.lineHeight();
    const control_height = @max(row_height, 20.0);
    const top_pad = t.spacing.xs;
    const bottom_pad = t.spacing.xs;
    const header_height = top_pad + control_height + bottom_pad;
    const header_rect = draw_context.Rect.fromMinSize(panel_rect.min, .{ header_width, header_height });
    const header_action = drawHeader(
        &panel_ctx,
        header_rect,
        queue,
        agent_id,
        agent_icon,
        agent_name,
        status_text,
        is_busy,
        busy_phase,
        sessions,
        session_key,
        panel_state.selected_session_id,
        has_session,
        &panel_state.select_copy_mode,
        debug_tier,
        activity_warn_error_count,
        pending_approvals_count,
        &panel_state.session_picker_open,
        control_height,
    );

    const separator_h: f32 = 1.0;
    const separator_gap = t.spacing.xs;
    const separator_block = separator_h + separator_gap * 2.0;

    var cursor_y = header_rect.max[1];
    const sep1_y = cursor_y + separator_gap;
    const sep1_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], sep1_y }, .{ panel_rect.size()[0], separator_h });
    panel_ctx.drawRect(sep1_rect, .{ .fill = t.colors.divider });
    const content_top_y = sep1_rect.max[1] + separator_gap;
    cursor_y = content_top_y;

    const remaining = @max(0.0, panel_rect.max[1] - content_top_y);
    const available_for_history_input = if (remaining > separator_block) remaining - separator_block else 0.0;
    const min_history_height: f32 = 96.0;
    const min_input_height: f32 = 92.0;

    var ratio = panel_state.composer_ratio;
    if (!(ratio > 0.05 and ratio < 0.95)) {
        ratio = 0.24;
    }

    var max_input_height = if (available_for_history_input > min_history_height)
        available_for_history_input - min_history_height
    else
        available_for_history_input;
    if (max_input_height < 0.0) max_input_height = 0.0;

    var input_height = available_for_history_input * ratio;
    const min_input_bound = @min(min_input_height, max_input_height);
    if (max_input_height > 0.0) {
        input_height = std.math.clamp(input_height, min_input_bound, max_input_height);
    } else {
        input_height = 0.0;
    }
    var history_height = @max(0.0, available_for_history_input - input_height);

    const splitter_hit_height: f32 = @max(10.0, t.spacing.sm * 2.0);
    var splitter_center_y = content_top_y + history_height + separator_gap;
    var splitter_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], splitter_center_y - splitter_hit_height * 0.5 },
        .{ panel_rect.size()[0], splitter_hit_height },
    );

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and splitter_rect.contains(md.pos)) {
                    panel_state.composer_split_dragging = true;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    panel_state.composer_split_dragging = false;
                }
            },
            else => {},
        }
    }

    const splitter_hover = splitter_rect.contains(queue.state.mouse_pos);
    if (splitter_hover or panel_state.composer_split_dragging) {
        cursor.set(.resize_ns);
    }

    if (panel_state.composer_split_dragging and available_for_history_input > 0.0) {
        const min_history = @min(min_history_height, available_for_history_input);
        const max_history = @max(min_history, available_for_history_input - @min(min_input_height, available_for_history_input));
        history_height = std.math.clamp(queue.state.mouse_pos[1] - content_top_y, min_history, max_history);
        input_height = @max(0.0, available_for_history_input - history_height);
        panel_state.composer_ratio = if (available_for_history_input > 0.0) input_height / available_for_history_input else ratio;
        splitter_center_y = content_top_y + history_height + separator_gap;
        splitter_rect = draw_context.Rect.fromMinSize(
            .{ panel_rect.min[0], splitter_center_y - splitter_hit_height * 0.5 },
            .{ panel_rect.size()[0], splitter_hit_height },
        );
    } else {
        panel_state.composer_ratio = ratio;
    }

    const history_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], cursor_y }, .{ panel_rect.size()[0], history_height });
    if (panel_state.select_copy_mode) {
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
                .select_copy_mode = panel_state.select_copy_mode,
                .show_tool_output = show_tool_output,
                .assistant_label = agent_name,
                .debug_tier = debug_tier,
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
                .select_copy_mode = panel_state.select_copy_mode,
                .show_tool_output = show_tool_output,
                .assistant_label = agent_name,
                .debug_tier = debug_tier,
            },
        );
    }

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button != .right) continue;
                if (history_rect.contains(mu.pos)) {
                    panel_state.copy_context_menu_open = true;
                    panel_state.copy_context_menu_anchor = mu.pos;
                } else {
                    panel_state.copy_context_menu_open = false;
                }
            },
            else => {},
        }
    }

    cursor_y = history_rect.max[1];
    const sep2_y = cursor_y + separator_gap;
    const sep2_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], sep2_y }, .{ panel_rect.size()[0], separator_h });
    const divider_color = if (splitter_hover or panel_state.composer_split_dragging)
        colors.withAlpha(t.colors.primary, 0.65)
    else
        t.colors.divider;
    panel_ctx.drawRect(sep2_rect, .{ .fill = divider_color });
    cursor_y = sep2_rect.max[1] + separator_gap;

    const composer_rect = draw_context.Rect.fromMinSize(.{ panel_rect.min[0], cursor_y }, .{ panel_rect.size()[0], input_height });

    // Allow typing even when no session is selected; disable Send until a session is chosen.
    if (composer_rect.size()[1] > 0.0) {
        if (is_busy) {
            drawBusyComposerAccent(&panel_ctx, composer_rect);
        }
        if (input_panel.draw(allocator, &panel_ctx, composer_rect, queue, true, has_session, composer_status_text)) |message| {
            action.send_message = message;
        }
    }

    if (panel_state.copy_context_menu_open) {
        const menu_action = drawCopyContextMenu(
            &panel_ctx,
            queue,
            panel_rect,
            has_session,
            has_selection,
            &panel_state.copy_context_menu_open,
            panel_state.copy_context_menu_anchor,
        );
        switch (menu_action) {
            .copy_selection => {
                if (panel_state.select_copy_mode) {
                    chat_view.copySelectCopySelectionToClipboard(allocator, &panel_state.view);
                } else {
                    chat_view.copySelectionToClipboard(allocator, &panel_state.view, messages, stream_text, inbox, show_tool_output);
                }
                panel_state.copy_context_menu_open = false;
            },
            .copy_all => {
                chat_view.copyAllToClipboard(allocator, messages, stream_text, inbox, show_tool_output);
                panel_state.copy_context_menu_open = false;
            },
            .none => {},
        }
    }

    if (panel_state.session_picker_open) {
        if (header_action.picker_rect) |picker_rect| {
            const selection = drawSessionPicker(
                allocator,
                &panel_ctx,
                queue,
                sessions,
                agent_id,
                session_key,
                panel_state.selected_session_id,
                picker_rect,
                &panel_state.show_system_sessions,
            );
            if (selection.key) |key| {
                action.select_session = key;
                action.select_session_id = selection.session_id;
                clearSelectedSessionId(allocator, panel_state);
                if (action.select_session_id) |sid| {
                    panel_state.selected_session_id = allocator.dupe(u8, sid) catch null;
                }
                panel_state.session_picker_open = false;
            } else {
                if (selection.session_id) |sid| allocator.free(sid);
                for (queue.events.items) |evt| {
                    switch (evt) {
                        .mouse_down => |md| {
                            if (md.button != .left) continue;
                            if (picker_rect.contains(md.pos)) continue;
                            const menu_rect = pickerMenuRect(&panel_ctx, picker_rect);
                            if (!menu_rect.contains(md.pos)) {
                                panel_state.session_picker_open = false;
                            }
                        },
                        else => {},
                    }
                }
            }
        } else {
            panel_state.session_picker_open = false;
        }
    }

    if (header_action.request_new_chat) {
        clearSelectedSessionId(allocator, panel_state);
        action.new_chat_session_key = resolveNewChatSessionKey(allocator, sessions, agent_id, session_key);
    }

    action.open_activity_panel = header_action.open_activity_panel;
    action.open_approvals_panel = header_action.open_approvals_panel;

    return action;
}

fn drawHeader(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    agent_id: []const u8,
    agent_icon: []const u8,
    agent_name: []const u8,
    status_text: []const u8,
    is_busy: bool,
    busy_phase: u8,
    sessions: []const types.Session,
    session_key: ?[]const u8,
    current_session_id: ?[]const u8,
    has_session: bool,
    select_copy_mode_ref: *bool,
    debug_tier: debug_visibility.DebugVisibilityTier,
    activity_warn_error_count: usize,
    pending_approvals_count: usize,
    session_picker_open_ref: *bool,
    control_height: f32,
) HeaderAction {
    const t = ctx.theme;
    _ = agent_id;
    _ = agent_icon;
    _ = agent_name;
    _ = status_text;
    _ = is_busy;
    _ = busy_phase;
    ctx.pushClip(rect);
    defer ctx.popClip();

    const top_pad = t.spacing.xs;
    const start_x = rect.min[0] + t.spacing.sm;
    const start_y = rect.min[1] + top_pad;
    const row_h = @max(ctx.lineHeight(), control_height);

    const picker_w_desired = std.math.clamp(rect.size()[0] * 0.34, 180.0, 360.0);
    const picker_w_min: f32 = 96.0;
    const picker_h = @max(control_height, row_h);
    const new_label = "New Chat";
    const new_w = ctx.measureText(new_label, 0.0)[0] + t.spacing.sm * 2.0;
    const right_bound = rect.max[0] - t.spacing.sm;

    const controls_y = start_y;
    const box_size = @min(control_height, row_h);
    const checkbox_spacing = t.spacing.xs;
    const item_spacing = t.spacing.xs;

    const gap = t.spacing.sm;

    // Left-side controls: Raw selection + debug visibility tier + Activity/Approvals badges.
    const select_label = "Raw";
    const select_width = box_size + checkbox_spacing + ctx.measureText(select_label, 0.0)[0];

    var vis_buf: [48]u8 = undefined;
    const vis_label = std.fmt.bufPrint(&vis_buf, "Vis: {s}", .{debug_tier.label()}) catch "Vis";
    const vis_w = ctx.measureText(vis_label, 0.0)[0] + t.spacing.sm * 2.0;

    var activity_buf: [48]u8 = undefined;
    const activity_label: []const u8 = if (activity_warn_error_count > 0)
        (std.fmt.bufPrint(&activity_buf, "Activity {d}", .{activity_warn_error_count}) catch "Activity")
    else
        "Activity";
    const activity_w = ctx.measureText(activity_label, 0.0)[0] + t.spacing.sm * 2.0;

    var approvals_buf: [56]u8 = undefined;
    const approvals_label: []const u8 = if (pending_approvals_count > 0)
        (std.fmt.bufPrint(&approvals_buf, "Approvals {d}", .{pending_approvals_count}) catch "Approvals")
    else
        "Approvals";
    const approvals_w = ctx.measureText(approvals_label, 0.0)[0] + t.spacing.sm * 2.0;

    const reserve_right: f32 = picker_w_min;

    var show_raw = true;
    var show_vis = true;
    var show_activity = true;
    var show_approvals = true;

    // Hide left-side controls progressively on narrow widths.
    const desired_all = select_width + item_spacing + vis_w + item_spacing + activity_w + item_spacing + approvals_w;
    if (start_x + desired_all + gap + reserve_right > right_bound) {
        show_approvals = false;
    }
    const desired_no_approvals = select_width + item_spacing + vis_w + item_spacing + activity_w;
    if (start_x + desired_no_approvals + gap + reserve_right > right_bound) {
        show_activity = false;
    }
    const desired_no_activity = select_width + item_spacing + vis_w;
    if (start_x + desired_no_activity + gap + reserve_right > right_bound) {
        show_vis = false;
    }
    if (start_x + select_width + gap + reserve_right > right_bound) {
        show_raw = false;
        show_vis = false;
        show_activity = false;
        show_approvals = false;
    }

    var open_activity_panel = false;
    var open_approvals_panel = false;

    var controls_end = start_x;
    if (show_raw) {
        const select_rect = draw_context.Rect.fromMinSize(.{ controls_end, controls_y }, .{ select_width, control_height });
        _ = widgets.checkbox.draw(ctx, select_rect, select_label, select_copy_mode_ref, queue, .{ .disabled = !has_session });
        controls_end = select_rect.max[0];
    }

    if (show_vis) {
        const vis_rect = draw_context.Rect.fromMinSize(.{ controls_end + item_spacing, start_y - t.spacing.xs * 0.2 }, .{ vis_w, picker_h });
        if (widgets.button.draw(ctx, vis_rect, vis_label, queue, .{ .variant = .secondary })) {
            debug_visibility.current_tier = debug_visibility.cycle(debug_visibility.current_tier);
        }
        controls_end = vis_rect.max[0];
    }

    if (show_activity) {
        const act_rect = draw_context.Rect.fromMinSize(.{ controls_end + item_spacing, start_y - t.spacing.xs * 0.2 }, .{ activity_w, picker_h });
        if (widgets.button.draw(ctx, act_rect, activity_label, queue, .{ .variant = .secondary })) {
            open_activity_panel = true;
        }
        controls_end = act_rect.max[0];
    }

    if (show_approvals) {
        const appr_rect = draw_context.Rect.fromMinSize(.{ controls_end + item_spacing, start_y - t.spacing.xs * 0.2 }, .{ approvals_w, picker_h });
        if (widgets.button.draw(ctx, appr_rect, approvals_label, queue, .{ .variant = .secondary })) {
            open_approvals_panel = true;
        }
        controls_end = appr_rect.max[0];
    }

    var right_cursor = right_bound;

    var picker_rect_opt: ?draw_context.Rect = null;
    var request_new_chat = false;
    const available = right_cursor - (controls_end + gap);
    if (available >= 64.0) {
        var picker_available = available;
        var show_new = false;
        if (available >= picker_w_min + t.spacing.xs + new_w) {
            show_new = true;
            picker_available -= new_w + t.spacing.xs;
        }

        if (picker_available >= 64.0) {
            const picker_w = @max(64.0, @min(picker_w_desired, picker_available));
            const picker_x = right_cursor - picker_w;
            const picker_rect = draw_context.Rect.fromMinSize(.{ picker_x, start_y - t.spacing.xs * 0.2 }, .{ picker_w, picker_h });

            var picker_label_buf: [160]u8 = undefined;
            const picker_label = resolveCurrentSessionLabel(sessions, session_key, current_session_id, &picker_label_buf);
            const picker_text_max = @max(0.0, picker_rect.size()[0] - t.spacing.sm * 2.0 - ctx.measureText(" v", 0.0)[0]);
            var fitted_picker_buf: [192]u8 = undefined;
            const fitted_picker = fitTextEnd(ctx, picker_label, picker_text_max, &fitted_picker_buf);
            var button_label_buf: [224]u8 = undefined;
            const button_label = if (fitted_picker.len > 0)
                std.fmt.bufPrint(&button_label_buf, "{s} v", .{fitted_picker}) catch "v"
            else
                "v";
            if (widgets.button.draw(ctx, picker_rect, button_label, queue, .{ .variant = .secondary })) {
                session_picker_open_ref.* = !session_picker_open_ref.*;
            }
            picker_rect_opt = picker_rect;

            right_cursor = picker_rect.min[0] - t.spacing.xs;
            if (show_new and right_cursor - new_w >= controls_end + gap) {
                const new_button_rect = draw_context.Rect.fromMinSize(
                    .{ right_cursor - new_w, start_y - t.spacing.xs * 0.2 },
                    .{ new_w, picker_h },
                );
                if (widgets.button.draw(ctx, new_button_rect, new_label, queue, .{ .variant = .secondary })) {
                    request_new_chat = true;
                }
            }
        }
    }

    return .{
        .picker_rect = picker_rect_opt,
        .request_new_chat = request_new_chat,
        .open_activity_panel = open_activity_panel,
        .open_approvals_panel = open_approvals_panel,
    };
}

fn drawSessionPicker(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    sessions: []const types.Session,
    agent_id: []const u8,
    current_session: ?[]const u8,
    current_session_id: ?[]const u8,
    picker_rect: draw_context.Rect,
    show_system_ref: *bool,
) SessionSelection {
    const t = ctx.theme;
    const menu_rect = pickerMenuRect(ctx, picker_rect);
    ctx.drawRoundedRect(menu_rect, t.radius.sm, .{
        .fill = t.colors.surface,
        .stroke = t.colors.border,
        .thickness = 1.0,
    });

    const padding = t.spacing.xs;
    var cursor_y = menu_rect.min[1] + padding;

    const toggle_label = "Show system sessions";
    const toggle_width = ctx.lineHeight() + t.spacing.xs + ctx.measureText(toggle_label, 0.0)[0];
    const toggle_height = @max(ctx.lineHeight(), 20.0);
    const toggle_rect = draw_context.Rect.fromMinSize(.{ menu_rect.min[0] + padding, cursor_y }, .{ toggle_width, toggle_height });
    _ = widgets.checkbox.draw(ctx, toggle_rect, toggle_label, show_system_ref, queue, .{});
    cursor_y += toggle_height + t.spacing.xs;

    var indices = std.ArrayList(usize).empty;
    defer indices.deinit(allocator);

    for (sessions, 0..) |session, idx| {
        if (!session_presenter.includeForAgent(session, agent_id, show_system_ref.*)) continue;
        indices.append(allocator, idx) catch {};
    }
    if (indices.items.len > 1) {
        std.sort.heap(usize, indices.items, sessions, session_presenter.updatedDesc);
    }

    const heading_h = ctx.lineHeight() + t.spacing.xs * 0.5;
    const group_gap = t.spacing.xs;
    const row_h = ctx.lineHeight() * 2.0 + t.spacing.xs;
    const row_gap = t.spacing.xs * 0.5;
    const menu_bottom = menu_rect.max[1] - padding;

    var groups = std.ArrayList([]const u8).empty;
    defer groups.deinit(allocator);
    groups.append(allocator, "main") catch {};

    var main_key_buf: [192]u8 = undefined;
    const main_key = std.fmt.bufPrint(&main_key_buf, "agent:{s}:main", .{agent_id}) catch "agent:main:main";
    var main_present = false;
    for (indices.items) |idx| {
        if (std.mem.eql(u8, sessions[idx].key, main_key)) {
            main_present = true;
            break;
        }
    }

    for (indices.items) |idx| {
        const bucket = session_presenter.bucketKey(sessions[idx]);
        var exists = false;
        for (groups.items) |existing| {
            if (std.mem.eql(u8, existing, bucket)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            groups.append(allocator, bucket) catch {};
        }
    }

    var ordinal: usize = 0;
    outer: for (groups.items) |bucket| {
        if (cursor_y + heading_h > menu_bottom) break :outer;

        var heading_buf: [128]u8 = undefined;
        const heading = session_presenter.bucketLabelFromKey(bucket, &heading_buf);
        ctx.drawText(
            heading,
            .{ menu_rect.min[0] + padding, cursor_y },
            .{ .color = t.colors.text_secondary },
        );
        cursor_y += heading_h;

        var drew_row = false;
        if (std.ascii.eqlIgnoreCase(bucket, "main") and !main_present) {
            if (cursor_y + row_h > menu_bottom) break :outer;
            const row_rect = draw_context.Rect.fromMinSize(
                .{ menu_rect.min[0] + padding, cursor_y },
                .{ menu_rect.size()[0] - padding * 2.0, row_h },
            );
            const selected = current_session != null and std.mem.eql(u8, current_session.?, main_key) and current_session_id == null;
            if (drawPickerTextRow(ctx, queue, row_rect, "Current", "Latest", selected)) {
                return .{
                    .key = allocator.dupe(u8, main_key) catch null,
                    .session_id = null,
                };
            }
            cursor_y += row_h + row_gap;
            drew_row = true;
        }

        var selected_for_key = false;
        for (indices.items) |idx| {
            const session = sessions[idx];
            if (!std.mem.eql(u8, session_presenter.bucketKey(session), bucket)) continue;
            if (cursor_y + row_h > menu_bottom) break :outer;

            const row_rect = draw_context.Rect.fromMinSize(
                .{ menu_rect.min[0] + padding, cursor_y },
                .{ menu_rect.size()[0] - padding * 2.0, row_h },
            );
            const selected = blk: {
                if (current_session == null or !std.mem.eql(u8, current_session.?, session.key)) break :blk false;
                if (current_session_id) |sid| {
                    break :blk session.session_id != null and std.mem.eql(u8, session.session_id.?, sid);
                }
                if (!selected_for_key) {
                    selected_for_key = true;
                    break :blk true;
                }
                break :blk false;
            };
            const clicked = drawPickerRow(ctx, queue, row_rect, session, agent_id, ordinal, selected);
            if (clicked.key != null) {
                return clicked;
            }
            ordinal += 1;
            cursor_y += row_h + row_gap;
            drew_row = true;
        }

        if (drew_row and cursor_y + group_gap <= menu_bottom) {
            cursor_y += group_gap;
        }
    }

    return .{};
}

fn drawPickerRow(
    ctx: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    session: types.Session,
    agent_id: []const u8,
    ordinal: usize,
    selected: bool,
) SessionSelection {
    _ = agent_id;
    _ = ordinal;
    var label_buf: [64]u8 = undefined;
    const primary = session_presenter.sessionIdentifierLabel(session, &label_buf) orelse "Current";
    var rel_buf: [48]u8 = undefined;
    const rel = session_presenter.relativeTimeLabel(std.time.milliTimestamp(), session.updated_at, &rel_buf);
    var secondary_buf: [64]u8 = undefined;
    const secondary = if (session_kind.isAutomationSession(session))
        (if (std.mem.eql(u8, rel, "never")) "System" else std.fmt.bufPrint(&secondary_buf, "System • {s}", .{rel}) catch "System")
    else
        rel;

    if (drawPickerTextRow(ctx, queue, rect, primary, secondary, selected)) {
        return .{
            .key = ctx.allocator.dupe(u8, session.key) catch null,
            .session_id = if (session.session_id) |id| ctx.allocator.dupe(u8, id) catch null else null,
        };
    }
    return .{};
}

fn drawPickerTextRow(
    ctx: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    primary: []const u8,
    secondary: []const u8,
    selected: bool,
) bool {
    const t = ctx.theme;
    const hovered = rect.contains(queue.state.mouse_pos);
    if (selected or hovered) {
        const base = if (selected) t.colors.primary else t.colors.surface;
        const alpha: f32 = if (selected) 0.12 else 0.08;
        ctx.drawRoundedRect(rect, t.radius.sm, .{ .fill = .{ base[0], base[1], base[2], alpha } });
    }

    const left = rect.min[0] + t.spacing.xs;
    const text_max = @max(0.0, rect.size()[0] - t.spacing.xs * 2.0);
    var primary_fit_buf: [80]u8 = undefined;
    var secondary_fit_buf: [80]u8 = undefined;
    const primary_fit = fitTextEnd(ctx, primary, text_max, &primary_fit_buf);
    const secondary_fit = fitTextEnd(ctx, secondary, text_max, &secondary_fit_buf);
    ctx.drawText(primary_fit, .{ left, rect.min[1] + t.spacing.xs * 0.2 }, .{ .color = t.colors.text_primary });
    ctx.drawText(secondary_fit, .{ left, rect.min[1] + ctx.lineHeight() + t.spacing.xs * 0.2 }, .{ .color = t.colors.text_secondary });

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    if (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging) {
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn resolveCurrentSessionLabel(
    sessions: []const types.Session,
    session_key: ?[]const u8,
    current_session_id: ?[]const u8,
    label_buf: []u8,
) []const u8 {
    if (session_key == null) return "Select session";
    if (current_session_id) |sid| {
        const trimmed = std.mem.trim(u8, sid, " \t\r\n");
        if (trimmed.len > 0) {
            for (sessions) |session| {
                if (!std.mem.eql(u8, session.key, session_key.?)) continue;
                if (session.session_id) |row_sid| {
                    if (std.mem.eql(u8, std.mem.trim(u8, row_sid, " \t\r\n"), trimmed)) {
                        var sid_buf: [32]u8 = undefined;
                        const short_sid = shortenSessionId(trimmed, &sid_buf);
                        return std.fmt.bufPrint(label_buf, "Session {s}", .{short_sid}) catch "Session";
                    }
                }
            }
        }
    }
    return session_presenter.bucketLabelFromKey(session_presenter.bucketKeyForSessionKey(session_key.?), label_buf);
}

fn shortenSessionId(session_id: []const u8, buf: []u8) []const u8 {
    if (session_id.len <= 12) return session_id;
    return std.fmt.bufPrint(buf, "{s}...", .{session_id[0..8]}) catch session_id;
}

fn clearSelectedSessionId(allocator: std.mem.Allocator, panel_state: *workspace.ChatPanel) void {
    if (panel_state.selected_session_id) |sid| allocator.free(sid);
    panel_state.selected_session_id = null;
}

fn normalizeSelectedSessionId(
    allocator: std.mem.Allocator,
    panel_state: *workspace.ChatPanel,
    session_key: ?[]const u8,
    sessions: []const types.Session,
) void {
    const selected = panel_state.selected_session_id orelse return;
    const key = session_key orelse {
        clearSelectedSessionId(allocator, panel_state);
        return;
    };

    const trimmed_selected = std.mem.trim(u8, selected, " \t\r\n");
    var valid = false;
    for (sessions) |session| {
        if (!std.mem.eql(u8, session.key, key)) continue;
        if (session.session_id) |row_sid| {
            if (std.mem.eql(u8, std.mem.trim(u8, row_sid, " \t\r\n"), trimmed_selected)) {
                valid = true;
                break;
            }
        }
    }
    if (!valid) {
        clearSelectedSessionId(allocator, panel_state);
    }
}

fn resolveNewChatSessionKey(
    allocator: std.mem.Allocator,
    sessions: []const types.Session,
    agent_id: []const u8,
    current_session: ?[]const u8,
) ?[]u8 {
    if (current_session) |key| {
        return allocator.dupe(u8, key) catch null;
    }

    var best_main: ?[]const u8 = null;
    var best_any: ?[]const u8 = null;
    var best_any_updated: i64 = -1;
    for (sessions) |session| {
        if (!session_presenter.includeForAgent(session, agent_id, false)) continue;
        if (session_keys.parse(session.key)) |parts| {
            if (std.ascii.eqlIgnoreCase(parts.label, "main")) {
                best_main = session.key;
            }
        }
        const updated = session.updated_at orelse 0;
        if (best_any == null or updated > best_any_updated) {
            best_any = session.key;
            best_any_updated = updated;
        }
    }

    if (best_main) |key| return allocator.dupe(u8, key) catch null;
    if (best_any) |key| return allocator.dupe(u8, key) catch null;
    return session_keys.buildMainSessionKey(allocator, agent_id) catch null;
}

fn pickerMenuRect(ctx: *draw_context.DrawContext, picker_rect: draw_context.Rect) draw_context.Rect {
    const t = ctx.theme;
    const w = std.math.clamp(picker_rect.size()[0] + 80.0, 260.0, 460.0);
    const h = std.math.clamp(ctx.lineHeight() * 8.5, 190.0, 340.0);
    const x = picker_rect.max[0] - w;
    const y = picker_rect.max[1] + t.spacing.xs;
    return draw_context.Rect.fromMinSize(.{ x, y }, .{ w, h });
}

fn drawBusyComposerAccent(ctx: *draw_context.DrawContext, composer_rect: draw_context.Rect) void {
    if (composer_rect.size()[0] <= 8.0 or composer_rect.size()[1] <= 8.0) return;

    const t = ctx.theme;
    const cycle_ms: i64 = 1400;
    const phase_ms: i64 = @mod(std.time.milliTimestamp(), cycle_ms);
    const phase = @as(f32, @floatFromInt(phase_ms)) / @as(f32, @floatFromInt(cycle_ms));

    const bar_w = std.math.clamp(composer_rect.size()[0] * 0.28, 60.0, 180.0);
    const travel = @max(0.0, composer_rect.size()[0] - bar_w);
    const bar_x = composer_rect.min[0] + travel * phase;
    const bar_h: f32 = 2.0;
    const bar_y = composer_rect.min[1] + 1.0;

    const pulse = if (phase < 0.5) phase * 2.0 else (1.0 - phase) * 2.0;
    const track_color = .{
        t.colors.primary[0],
        t.colors.primary[1],
        t.colors.primary[2],
        0.10,
    };
    const bar_color = .{
        t.colors.primary[0],
        t.colors.primary[1],
        t.colors.primary[2],
        0.30 + pulse * 0.45,
    };

    const track_rect = draw_context.Rect.fromMinSize(.{ composer_rect.min[0], bar_y }, .{ composer_rect.size()[0], bar_h });
    const bar_rect = draw_context.Rect.fromMinSize(.{ bar_x, bar_y }, .{ bar_w, bar_h });
    ctx.drawRoundedRect(track_rect, 1.0, .{ .fill = track_color });
    ctx.drawRoundedRect(bar_rect, 1.0, .{ .fill = bar_color });
}

fn fitTextEnd(
    ctx: *draw_context.DrawContext,
    text: []const u8,
    max_width: f32,
    buf: []u8,
) []const u8 {
    if (text.len == 0) return "";
    if (max_width <= 0.0) return "";
    if (ctx.measureText(text, 0.0)[0] <= max_width) return text;

    const ellipsis = "...";
    const ellipsis_w = ctx.measureText(ellipsis, 0.0)[0];
    if (ellipsis_w > max_width) return "";
    if (buf.len <= ellipsis.len) return ellipsis;

    var low: usize = 0;
    var high: usize = @min(text.len, buf.len - ellipsis.len - 1);
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const candidate = std.fmt.bufPrint(buf, "{s}{s}", .{ text[0..mid], ellipsis }) catch ellipsis;
        const w = ctx.measureText(candidate, 0.0)[0];
        if (w <= max_width) {
            best = mid;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    if (best == 0) return ellipsis;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ text[0..best], ellipsis }) catch ellipsis;
}

fn drawCopyContextMenu(
    ctx: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    panel_rect: draw_context.Rect,
    has_session: bool,
    has_selection: bool,
    open_ref: *bool,
    anchor: [2]f32,
) CopyContextMenuAction {
    const t = ctx.theme;

    const menu_padding = t.spacing.xs;
    const row_height = @max(ctx.lineHeight() + t.spacing.xs, 22.0);
    const label_padding = t.spacing.sm;
    const label_copy = "Copy Selection";
    const label_all = "Copy All";
    const row_width = @max(
        ctx.measureText(label_copy, 0.0)[0],
        ctx.measureText(label_all, 0.0)[0],
    ) + label_padding * 2.0;
    const menu_width = row_width + menu_padding * 2.0;
    const menu_height = row_height * 2.0 + menu_padding * 2.0;

    const min_x = panel_rect.min[0] + 2.0;
    const min_y = panel_rect.min[1] + 2.0;
    const max_x = @max(min_x, panel_rect.max[0] - menu_width - 2.0);
    const max_y = @max(min_y, panel_rect.max[1] - menu_height - 2.0);
    const menu_x = std.math.clamp(anchor[0], min_x, max_x);
    const menu_y = std.math.clamp(anchor[1], min_y, max_y);
    const menu_rect = draw_context.Rect.fromMinSize(.{ menu_x, menu_y }, .{ menu_width, menu_height });

    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if ((md.button == .left or md.button == .right) and !menu_rect.contains(md.pos)) {
                    open_ref.* = false;
                    return .none;
                }
            },
            else => {},
        }
    }

    ctx.drawRoundedRect(menu_rect, t.radius.sm, .{
        .fill = t.colors.surface,
        .stroke = t.colors.border,
        .thickness = 1.0,
    });

    const selection_enabled = has_session and has_selection;
    const all_enabled = has_session;
    const rows = [_]struct {
        label: []const u8,
        enabled: bool,
        action: CopyContextMenuAction,
    }{
        .{ .label = label_copy, .enabled = selection_enabled, .action = .copy_selection },
        .{ .label = label_all, .enabled = all_enabled, .action = .copy_all },
    };

    var y = menu_rect.min[1] + menu_padding;
    for (rows) |row| {
        const row_rect = draw_context.Rect.fromMinSize(
            .{ menu_rect.min[0] + menu_padding, y },
            .{ row_width, row_height },
        );
        const hovered = row_rect.contains(queue.state.mouse_pos);
        if (hovered) {
            const alpha: f32 = if (row.enabled) 0.12 else 0.06;
            ctx.drawRoundedRect(row_rect, t.radius.sm, .{
                .fill = colors.withAlpha(t.colors.primary, alpha),
            });
        }

        const text_color = if (row.enabled)
            t.colors.text_primary
        else
            colors.withAlpha(t.colors.text_secondary, 0.8);
        ctx.drawText(row.label, .{ row_rect.min[0] + label_padding, row_rect.min[1] + t.spacing.xs * 0.25 }, .{ .color = text_color });

        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_up => |mu| {
                    if (mu.button != .left) continue;
                    if (!row.enabled) continue;
                    if (row_rect.contains(mu.pos) and (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging)) {
                        return row.action;
                    }
                },
                else => {},
            }
        }
        y += row_height;
    }

    return .none;
}
