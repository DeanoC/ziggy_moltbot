const std = @import("std");

pub fn toJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const writer = &out.writer;
    try std.json.Stringify.value(value, .{}, writer);
    return try out.toOwnedSlice();
}

pub fn parseFromSlice(allocator: std.mem.Allocator, json_data: []const u8, comptime T: type) !std.json.Parsed(T) {
    return try std.json.parseFromSlice(T, allocator, json_data, .{});
}
