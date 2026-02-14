const std = @import("std");

extern fn molt_storage_get(key: [*:0]const u8) ?[*:0]u8;
extern fn molt_storage_set(key: [*:0]const u8, value: [*:0]const u8) void;
extern fn molt_storage_remove(key: [*:0]const u8) void;
extern fn free(ptr: ?*anyopaque) void;

pub fn get(allocator: std.mem.Allocator, key: [:0]const u8) !?[]u8 {
    const raw_ptr = molt_storage_get(key.ptr) orelse return null;
    defer free(raw_ptr);
    const raw = std.mem.span(raw_ptr);
    if (raw.len == 0) return null;
    return try allocator.dupe(u8, raw);
}

pub fn set(allocator: std.mem.Allocator, key: [:0]const u8, value: []const u8) !void {
    const z_buf = try std.mem.concat(allocator, u8, &.{ value, "\x00" });
    defer allocator.free(z_buf);
    const z: [:0]const u8 = z_buf[0..value.len :0];
    molt_storage_set(key.ptr, z.ptr);
}

pub fn remove(key: [:0]const u8) void {
    molt_storage_remove(key.ptr);
}
