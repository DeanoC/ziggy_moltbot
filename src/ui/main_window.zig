const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const chat_view = @import("chat_view.zig");
const input_panel = @import("input_panel.zig");
const settings_view = @import("settings_view.zig");
const status_bar = @import("status_bar.zig");

pub const UiAction = struct {
    send_message: ?[]u8 = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    config_updated: bool = false,
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

        chat_view.draw(ctx.messages.items);
        zgui.separator();

        if (input_panel.draw(allocator)) |message| {
            action.send_message = message;
        }
        zgui.separator();

        const settings_action = settings_view.draw(allocator, cfg, ctx.state, is_connected);
        action.connect = settings_action.connect;
        action.disconnect = settings_action.disconnect;
        action.save_config = settings_action.save;
        action.config_updated = settings_action.config_updated;
        status_bar.draw(ctx.state, is_connected, ctx.current_session, ctx.messages.items.len);
    }
    zgui.end();

    return action;
}
