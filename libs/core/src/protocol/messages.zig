const std = @import("std");

pub fn serializeMessage(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const writer = &out.writer;
    try std.json.Stringify.value(message, .{ .emit_null_optional_fields = false }, writer);
    return try out.toOwnedSlice();
}

pub fn deserializeMessage(allocator: std.mem.Allocator, json_data: []const u8, comptime T: type) !std.json.Parsed(T) {
    return try std.json.parseFromSlice(T, allocator, json_data, .{ .ignore_unknown_fields = true });
}

pub fn parsePayload(allocator: std.mem.Allocator, payload: std.json.Value, comptime T: type) !std.json.Parsed(T) {
    return try std.json.parseFromValue(T, allocator, payload, .{ .ignore_unknown_fields = true });
}
