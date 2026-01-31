const std = @import("std");
const types = @import("../protocol/types.zig");
const panel_manager = @import("panel_manager.zig");
const ui_command = @import("ui_command.zig");

pub const UiCommandInbox = struct {
    processed_ids: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) UiCommandInbox {
        return .{ .processed_ids = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *UiCommandInbox, allocator: std.mem.Allocator) void {
        var it = self.processed_ids.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.processed_ids.deinit();
    }

    pub fn clear(self: *UiCommandInbox, allocator: std.mem.Allocator) void {
        var it = self.processed_ids.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.processed_ids.clearRetainingCapacity();
    }

    pub fn collectFromMessages(
        self: *UiCommandInbox,
        allocator: std.mem.Allocator,
        messages: []const types.ChatMessage,
        manager: *panel_manager.PanelManager,
    ) void {
        for (messages) |msg| {
            if (self.processed_ids.contains(msg.id)) continue;
            if (!std.mem.eql(u8, msg.role, "assistant")) continue;
            const cmd = ui_command.parse(allocator, msg.content) catch null;
            if (cmd == null) continue;

            var owned = cmd.?;
            manager.applyUiCommand(owned) catch {};
            owned.deinit(allocator);

            const id_copy = allocator.dupe(u8, msg.id) catch continue;
            self.processed_ids.put(id_copy, {}) catch allocator.free(id_copy);
        }
    }

    pub fn isCommandMessage(self: *const UiCommandInbox, msg_id: []const u8) bool {
        return self.processed_ids.contains(msg_id);
    }
};
