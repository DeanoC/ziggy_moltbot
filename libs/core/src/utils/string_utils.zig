const std = @import("std");

pub fn isBlank(value: []const u8) bool {
    for (value) |ch| {
        if (!std.ascii.isWhitespace(ch)) return false;
    }
    return true;
}

pub fn dup(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return try allocator.dupe(u8, value);
}
