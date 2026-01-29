const std = @import("std");
const state = @import("state.zig");
const constants = @import("../protocol/constants.zig");
const messages = @import("../protocol/messages.zig");
const types = @import("../protocol/types.zig");

pub fn handleRawMessage(ctx: *state.ClientContext, raw: []const u8) !void {
    var envelope = try messages.deserializeMessage(ctx.allocator, raw, types.MessageEnvelope);
    defer envelope.deinit();

    const kind = envelope.value.kind;

    if (std.mem.eql(u8, kind, constants.event.session_list)) {
        var payload = try messages.parsePayload(ctx.allocator, envelope.value.payload, types.SessionListResult);
        defer payload.deinit();
        try ctx.setSessions(payload.value.sessions);
        return;
    }

    if (std.mem.eql(u8, kind, constants.event.message_new) or
        std.mem.eql(u8, kind, constants.event.message_update))
    {
        var payload = try messages.parsePayload(ctx.allocator, envelope.value.payload, types.ChatMessage);
        defer payload.deinit();
        try ctx.upsertMessage(payload.value);
        return;
    }

    if (std.mem.eql(u8, kind, constants.event.error_event)) {
        var payload = try messages.parsePayload(ctx.allocator, envelope.value.payload, types.ErrorEvent);
        defer payload.deinit();
        std.log.err("Server error: {s}", .{payload.value.message});
        ctx.state = .error_state;
        return;
    }

    std.log.debug("Unhandled event kind: {s}", .{kind});
}

pub fn handleConnectionState(ctx: *state.ClientContext, new_state: state.ClientState) void {
    ctx.state = new_state;
}
