const std = @import("std");

pub fn UndoRedoStack(comptime T: type) type {
    return struct {
        const Self = @This();

        undo_stack: std.ArrayList(Command),
        redo_stack: std.ArrayList(Command),
        max_history: usize,
        allocator: std.mem.Allocator,
        cleanup: ?CleanupFn = null,

        pub const Command = struct {
            name: []const u8,
            state_before: T,
            state_after: T,
        };

        pub const CleanupFn = *const fn (*T, std.mem.Allocator) void;

        pub fn init(allocator: std.mem.Allocator, max_history: usize, cleanup: ?CleanupFn) Self {
            return .{
                .undo_stack = .empty,
                .redo_stack = .empty,
                .max_history = max_history,
                .allocator = allocator,
                .cleanup = cleanup,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.undo_stack.deinit(self.allocator);
            self.redo_stack.deinit(self.allocator);
        }

        pub fn execute(self: *Self, command: Command) !void {
            self.redo_stack.clearRetainingCapacity();
            try self.undo_stack.append(self.allocator, command);
            while (self.undo_stack.items.len > self.max_history) {
                const removed = self.undo_stack.orderedRemove(0);
                self.cleanupCommand(removed);
            }
        }

        pub fn undo(self: *Self) ?T {
            if (self.undo_stack.items.len == 0) return null;
            const command = self.undo_stack.pop() orelse return null;
            self.redo_stack.append(self.allocator, command) catch return null;
            return command.state_before;
        }

        pub fn redo(self: *Self) ?T {
            if (self.redo_stack.items.len == 0) return null;
            const command = self.redo_stack.pop() orelse return null;
            self.undo_stack.append(self.allocator, command) catch return null;
            return command.state_after;
        }

        pub fn canUndo(self: *Self) bool {
            return self.undo_stack.items.len > 0;
        }

        pub fn canRedo(self: *Self) bool {
            return self.redo_stack.items.len > 0;
        }

        pub fn clear(self: *Self) void {
            if (self.cleanup) |cleanup| {
                for (self.undo_stack.items) |*cmd| {
                    cleanup(&cmd.state_before, self.allocator);
                    cleanup(&cmd.state_after, self.allocator);
                }
                for (self.redo_stack.items) |*cmd| {
                    cleanup(&cmd.state_before, self.allocator);
                    cleanup(&cmd.state_after, self.allocator);
                }
            }
            self.undo_stack.clearRetainingCapacity();
            self.redo_stack.clearRetainingCapacity();
        }

        fn cleanupCommand(self: *Self, cmd: Command) void {
            if (self.cleanup) |cleanup| {
                var before = cmd.state_before;
                var after = cmd.state_after;
                cleanup(&before, self.allocator);
                cleanup(&after, self.allocator);
            }
        }
    };
}
