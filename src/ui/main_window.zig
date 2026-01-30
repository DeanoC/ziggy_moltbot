const std = @import("std");
const zgui = @import("zgui");
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
};

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    is_connected: bool,
) UiAction {
    var action = UiAction{};

    const display = zgui.io.getDisplaySize();
    if (display[0] > 0.0 and display[1] > 0.0) {
        zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, .cond = .always });
        zgui.setNextWindowSize(.{ .w = display[0], .h = display[1], .cond = .always });
    }

    if (zgui.begin("MoltBot Client", .{ .flags = .{ .no_collapse = true, .no_saved_settings = true } })) {
        zgui.text("MoltBot Zig Client (ImGui)", .{});
        zgui.separator();

        const style = zgui.getStyle();
        const spacing_x = style.item_spacing[0];
        const spacing_y = style.item_spacing[1];
        const avail = zgui.getContentRegionAvail();
        const left_width: f32 = 240.0;
        const right_width: f32 = 320.0;
        const min_center_width: f32 = 160.0;
        const compact_layout = avail[0] < left_width + right_width + spacing_x * 2.0 + min_center_width;

        if (compact_layout) {
            const total_h = avail[1];
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
                const settings_action = settings_view.draw(allocator, cfg, ctx.state, is_connected);
                action.connect = settings_action.connect;
                action.disconnect = settings_action.disconnect;
                action.save_config = settings_action.save;
                action.clear_saved = settings_action.clear_saved;
                action.config_updated = settings_action.config_updated;
            }
            zgui.endChild();
        } else {
            const center_width = @max(min_center_width, avail[0] - left_width - right_width - spacing_x * 2.0);

            if (zgui.beginChild("LeftPanel", .{ .w = left_width, .child_flags = .{ .border = true } })) {
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

            if (zgui.beginChild("CenterPanel", .{ .w = center_width, .child_flags = .{ .border = true } })) {
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

            if (zgui.beginChild("RightPanel", .{ .w = right_width, .child_flags = .{ .border = true } })) {
                const settings_action = settings_view.draw(allocator, cfg, ctx.state, is_connected);
                action.connect = settings_action.connect;
                action.disconnect = settings_action.disconnect;
                action.save_config = settings_action.save;
                action.clear_saved = settings_action.clear_saved;
                action.config_updated = settings_action.config_updated;
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
