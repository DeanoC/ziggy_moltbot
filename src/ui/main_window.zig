const zgui = @import("zgui");
const state = @import("../client/state.zig");
const chat_view = @import("chat_view.zig");
const input_panel = @import("input_panel.zig");
const settings_view = @import("settings_view.zig");
const status_bar = @import("status_bar.zig");

pub fn draw(ctx: *state.ClientContext) void {
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

        _ = input_panel.draw();
        zgui.separator();

        settings_view.draw();
        status_bar.draw(ctx.state, ctx.current_session, ctx.messages.items.len);
    }
    zgui.end();
}
