const std = @import("std");
const types = @import("../protocol/types.zig");
const panel_manager = @import("panel_manager.zig");
const ui_command = @import("ui_command.zig");

pub const UiCommandInbox = struct {
    processed_ids: std.StringHashMap(void),
    session_cursors: std.StringHashMap(SessionCursor),
    fallback_cursor: SessionCursor = .{},

    pub fn init(allocator: std.mem.Allocator) UiCommandInbox {
        return .{
            .processed_ids = std.StringHashMap(void).init(allocator),
            .session_cursors = std.StringHashMap(SessionCursor).init(allocator),
        };
    }

    pub fn deinit(self: *UiCommandInbox, allocator: std.mem.Allocator) void {
        var it = self.processed_ids.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.processed_ids.deinit();
        var cursor_it = self.session_cursors.iterator();
        while (cursor_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.session_cursors.deinit();
    }

    pub fn clear(self: *UiCommandInbox, allocator: std.mem.Allocator) void {
        var it = self.processed_ids.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.processed_ids.clearRetainingCapacity();
        var cursor_it = self.session_cursors.iterator();
        while (cursor_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.session_cursors.clearRetainingCapacity();
    }

    const SessionCursor = struct {
        last_len: usize = 0,
        last_last_id_hash: u64 = 0,
    };

    pub fn collectFromMessages(
        self: *UiCommandInbox,
        allocator: std.mem.Allocator,
        session_key: []const u8,
        messages: []const types.ChatMessage,
        manager: *panel_manager.PanelManager,
    ) void {
        const cursor = ensureCursor(self, allocator, session_key);
        var start_index: usize = 0;
        if (cursor.last_len > 0 and cursor.last_len <= messages.len) {
            const prev_last = messages[cursor.last_len - 1].id;
            const prev_last_hash = std.hash.Wyhash.hash(0, prev_last);
            if (prev_last_hash == cursor.last_last_id_hash) {
                start_index = cursor.last_len;
            }
        }

        for (messages[start_index..]) |msg| {
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

        if (messages.len > 0) {
            cursor.last_len = messages.len;
            cursor.last_last_id_hash = std.hash.Wyhash.hash(0, messages[messages.len - 1].id);
        } else {
            cursor.last_len = 0;
            cursor.last_last_id_hash = 0;
        }
    }

    pub fn isCommandMessage(self: *const UiCommandInbox, msg_id: []const u8) bool {
        return self.processed_ids.contains(msg_id);
    }

    fn ensureCursor(
        self: *UiCommandInbox,
        allocator: std.mem.Allocator,
        session_key: []const u8,
    ) *SessionCursor {
        if (self.session_cursors.getPtr(session_key)) |cursor| return cursor;
        const key_copy = allocator.dupe(u8, session_key) catch {
            return &self.fallback_cursor;
        };
        self.session_cursors.put(key_copy, .{}) catch allocator.free(key_copy);
        return self.session_cursors.getPtr(key_copy) orelse &self.fallback_cursor;
    }
};
