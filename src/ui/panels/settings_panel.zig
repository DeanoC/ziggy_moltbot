const std = @import("std");
const state = @import("../../client/state.zig");
const config = @import("../../client/config.zig");
const update_checker = @import("../../client/update_checker.zig");
const settings_view = @import("../settings_view.zig");

pub const SettingsPanelAction = settings_view.SettingsAction;

pub fn draw(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    client_state: state.ClientState,
    is_connected: bool,
    update_state: *update_checker.UpdateState,
    app_version: []const u8,
) SettingsPanelAction {
    return settings_view.draw(
        allocator,
        cfg,
        client_state,
        is_connected,
        update_state,
        app_version,
    );
}
