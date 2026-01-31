const std = @import("std");

pub const TextBuffer = struct {
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !TextBuffer {
        var list = std.ArrayList(u8).empty;
        try list.ensureTotalCapacity(allocator, text.len + 1);
        list.appendSliceAssumeCapacity(text);
        list.appendAssumeCapacity(0);
        return .{ .data = list };
    }

    pub fn deinit(self: *TextBuffer, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    pub fn set(self: *TextBuffer, allocator: std.mem.Allocator, text: []const u8) !void {
        self.data.clearRetainingCapacity();
        try self.data.ensureTotalCapacity(allocator, text.len + 1);
        self.data.appendSliceAssumeCapacity(text);
        self.data.appendAssumeCapacity(0);
    }

    pub fn ensureCapacity(self: *TextBuffer, allocator: std.mem.Allocator, min_len: usize) !void {
        const desired = min_len + 1;
        if (self.data.items.len < desired) {
            try self.data.ensureTotalCapacity(allocator, desired);
            const extra = desired - self.data.items.len;
            if (extra > 0) {
                try self.data.appendNTimes(allocator, 0, extra);
            }
        }
    }

    pub fn syncFromInput(self: *TextBuffer) void {
        const len = std.mem.indexOfScalar(u8, self.data.items, 0) orelse self.data.items.len;
        if (len < self.data.items.len) {
            self.data.items.len = len + 1;
            return;
        }
        if (self.data.capacity > self.data.items.len) {
            self.data.appendAssumeCapacity(0);
        }
    }

    pub fn asZ(self: *TextBuffer) [:0]u8 {
        if (self.data.items.len == 0) return @constCast(empty_z[0.. :0]);
        if (self.data.items.len == 1) return @constCast(empty_z[0.. :0]);
        const end = self.data.items.len - 1;
        return self.data.items[0..end :0];
    }

    pub fn slice(self: *const TextBuffer) []const u8 {
        if (self.data.items.len == 0) return "";
        if (self.data.items.len == 1) return "";
        return self.data.items[0 .. self.data.items.len - 1];
    }

    const empty_z = [_:0]u8{};
};
