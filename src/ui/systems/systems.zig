const std = @import("std");
const drag_drop = @import("drag_drop.zig");
const keyboard = @import("keyboard.zig");

pub const Systems = struct {
    drag_drop: drag_drop.DragDropManager,
    keyboard: keyboard.KeyboardManager,

    pub fn init(allocator: std.mem.Allocator) Systems {
        return .{
            .drag_drop = drag_drop.DragDropManager.init(allocator),
            .keyboard = keyboard.KeyboardManager.init(allocator),
        };
    }

    pub fn deinit(self: *Systems) void {
        self.drag_drop.deinit();
        self.keyboard.deinit();
    }

    pub fn beginFrame(self: *Systems) void {
        self.drag_drop.beginFrame();
        self.keyboard.beginFrame();
    }
};
