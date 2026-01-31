const std = @import("std");
const state = @import("../../client/state.zig");
const session_list = @import("../session_list.zig");

pub const SessionPanelAction = session_list.SessionAction;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
) SessionPanelAction {
    return session_list.draw(
        allocator,
        ctx.sessions.items,
        ctx.current_session,
        ctx.sessions_loading,
    );
}
