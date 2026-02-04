const std = @import("std");

pub const SessionKeyParts = struct {
    agent_id: []const u8,
    label: []const u8,
};

pub fn parse(key: []const u8) ?SessionKeyParts {
    const prefix = "agent:";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const rest = key[prefix.len..];
    const colon_index = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (colon_index == 0) return null;
    if (colon_index + 1 >= rest.len) return null;
    const agent_id = rest[0..colon_index];
    const label = rest[colon_index + 1 ..];
    if (label.len == 0) return null;
    return .{ .agent_id = agent_id, .label = label };
}

pub fn isAgentIdValid(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

pub fn buildChatSessionKey(allocator: std.mem.Allocator, agent_id: []const u8) ![]u8 {
    const requests = @import("../protocol/requests.zig");
    const suffix = try requests.makeRequestId(allocator);
    defer allocator.free(suffix);
    return try std.fmt.allocPrint(allocator, "agent:{s}:chat-{s}", .{ agent_id, suffix });
}
