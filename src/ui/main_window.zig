const std = @import("std");
const zgui = @import("zgui");
const builtin = @import("builtin");
const state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const chat_view = @import("chat_view.zig");
const input_panel = @import("input_panel.zig");
const session_list = @import("session_list.zig");
const settings_view = @import("settings_view.zig");
const status_bar = @import("status_bar.zig");

pub const UiAction = struct {
    send_message: ?[]u8 = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    refresh_sessions: bool = false,
    select_session: ?[]u8 = null,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
};

var safe_insets: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };

pub fn setSafeInsets(left: f32, top: f32, right: f32, bottom: f32) void {
    safe_insets = .{ left, top, right, bottom };
}

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    is_connected: bool,
    app_version: []const u8,
) UiAction {
    var action = UiAction{};

    const display = zgui.io.getDisplaySize();
    if (display[0] > 0.0 and display[1] > 0.0) {
        const left = safe_insets[0];
        const top = safe_insets[1];
        const right = safe_insets[2];
        const bottom = safe_insets[3];
        const width = @max(1.0, display[0] - left - right);
        const extra_bottom: f32 = if (builtin.abi == .android) 24.0 else 0.0;
        const height = @max(1.0, display[1] - top - bottom - extra_bottom);
        zgui.setNextWindowPos(.{ .x = left, .y = top, .cond = .always });
        zgui.setNextWindowSize(.{ .w = width, .h = height, .cond = .always });
    }

    const compact_header = builtin.abi == .android or (display[1] > 0.0 and display[1] < 720.0);
    var flags = zgui.WindowFlags{ .no_collapse = true, .no_saved_settings = true };
    if (compact_header) {
        flags.no_title_bar = true;
        flags.no_scrollbar = true;
        flags.no_scroll_with_mouse = true;
    }

    if (zgui.begin("ZiggyStarClaw", .{ .flags = flags })) {
        if (!compact_header) {
            zgui.text("ZiggyStarClaw and the Lobsters From Mars", .{});
            zgui.separator();
        }

        const style = zgui.getStyle();
        const spacing_x = style.item_spacing[0];
        const spacing_y = style.item_spacing[1];
        const avail = zgui.getContentRegionAvail();
        const status_height = zgui.getFrameHeightWithSpacing();
        const usable_h = @max(1.0, avail[1] - status_height - spacing_y);
        const left_width: f32 = if (builtin.abi == .android) 220.0 else 240.0;
        const right_width: f32 = if (builtin.abi == .android) 360.0 else 320.0;
        const min_center_width: f32 = 160.0;
        const compact_layout = avail[0] < left_width + right_width + spacing_x * 2.0 + min_center_width;

        if (compact_layout) {
            const total_h = usable_h;
            const sessions_h = @min(200.0, total_h * 0.25);
            const settings_h = @min(220.0, total_h * 0.3);
            const chat_h = @max(140.0, total_h - sessions_h - settings_h - spacing_y * 2.0);

            if (zgui.beginChild("LeftPanel", .{ .w = avail[0], .h = sessions_h, .child_flags = .{ .border = true } })) {
                const sessions_action = session_list.draw(
                    allocator,
                    ctx.sessions.items,
                    ctx.current_session,
                    ctx.sessions_loading,
                );
                action.refresh_sessions = sessions_action.refresh;
                action.select_session = sessions_action.selected_key;
            }
            zgui.endChild();

            if (zgui.beginChild("CenterPanel", .{ .w = avail[0], .h = chat_h, .child_flags = .{ .border = true } })) {
                const center_avail = zgui.getContentRegionAvail();
                const input_height: f32 = 88.0;
                const history_height = @max(80.0, center_avail[1] - input_height - spacing_y);
                chat_view.draw(allocator, ctx.messages.items, ctx.stream_text, history_height);
                zgui.separator();
                if (input_panel.draw(allocator)) |message| {
                    action.send_message = message;
                }
            }
            zgui.endChild();

            if (zgui.beginChild("RightPanel", .{ .w = avail[0], .h = settings_h, .child_flags = .{ .border = true } })) {
                const settings_action = settings_view.draw(
                    allocator,
                    cfg,
                    ctx.state,
                    is_connected,
                    &ctx.update_state,
                    app_version,
                );
                action.connect = settings_action.connect;
                action.disconnect = settings_action.disconnect;
                action.save_config = settings_action.save;
                action.clear_saved = settings_action.clear_saved;
                action.config_updated = settings_action.config_updated;
                action.check_updates = settings_action.check_updates;
                action.open_release = settings_action.open_release;
                action.download_update = settings_action.download_update;
            }
            zgui.endChild();
        } else {
            const center_width = @max(min_center_width, avail[0] - left_width - right_width - spacing_x * 2.0);

            if (zgui.beginChild("LeftPanel", .{ .w = left_width, .h = usable_h, .child_flags = .{ .border = true } })) {
                const sessions_action = session_list.draw(
                    allocator,
                    ctx.sessions.items,
                    ctx.current_session,
                    ctx.sessions_loading,
                );
                action.refresh_sessions = sessions_action.refresh;
                action.select_session = sessions_action.selected_key;
            }
            zgui.endChild();

            zgui.sameLine(.{});

            if (zgui.beginChild("CenterPanel", .{ .w = center_width, .h = usable_h, .child_flags = .{ .border = true } })) {
                const center_avail = zgui.getContentRegionAvail();
                const input_height: f32 = 96.0;
                const history_height = @max(80.0, center_avail[1] - input_height - spacing_y);
                chat_view.draw(allocator, ctx.messages.items, ctx.stream_text, history_height);
                zgui.separator();
                if (input_panel.draw(allocator)) |message| {
                    action.send_message = message;
                }
            }
            zgui.endChild();

            zgui.sameLine(.{});

            if (zgui.beginChild("RightPanel", .{ .w = right_width, .h = usable_h, .child_flags = .{ .border = true } })) {
                const settings_action = settings_view.draw(
                    allocator,
                    cfg,
                    ctx.state,
                    is_connected,
                    &ctx.update_state,
                    app_version,
                );
                action.connect = settings_action.connect;
                action.disconnect = settings_action.disconnect;
                action.save_config = settings_action.save;
                action.clear_saved = settings_action.clear_saved;
                action.config_updated = settings_action.config_updated;
                action.check_updates = settings_action.check_updates;
                action.open_release = settings_action.open_release;
                action.download_update = settings_action.download_update;
            }
            zgui.endChild();
        }

        status_bar.draw(ctx.state, is_connected, ctx.current_session, ctx.messages.items.len, ctx.last_error);
    }
    zgui.end();

    return action;
}

pub fn syncSettings(cfg: config.Config) void {
    settings_view.syncFromConfig(cfg);
}
