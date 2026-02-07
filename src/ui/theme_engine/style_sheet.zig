const std = @import("std");

/// Minimal style sheet v1.
/// Parsed but not yet wired into all widgets; it exists so theme packs can carry component styles.
pub const StyleSheet = struct {
    allocator: std.mem.Allocator,
    raw_json: []u8,

    pub fn initEmpty(allocator: std.mem.Allocator) StyleSheet {
        return .{ .allocator = allocator, .raw_json = &[_]u8{} };
    }

    pub fn deinit(self: *StyleSheet) void {
        if (self.raw_json.len > 0) self.allocator.free(self.raw_json);
    }
};

