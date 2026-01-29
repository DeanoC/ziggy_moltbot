const std = @import("std");
const types = @import("../protocol/types.zig");

pub const ClientState = enum {
    disconnected,
    connecting,
    authenticating,
    connected,
    error_state,
};

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    state: ClientState,
    current_session: ?[]const u8,
    history_session: ?[]const u8,
    stream_run_id: ?[]const u8,
    sessions: std.ArrayList(types.Session),
    messages: std.ArrayList(types.ChatMessage),
    users: std.ArrayList(types.User),
    stream_text: ?[]const u8 = null,
    sessions_loading: bool = false,
    messages_loading: bool = false,
    pending_sessions_request_id: ?[]const u8 = null,
    pending_history_request_id: ?[]const u8 = null,
    pending_send_request_id: ?[]const u8 = null,
    last_error: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) !ClientContext {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .current_session = null,
            .history_session = null,
            .stream_run_id = null,
            .sessions = std.ArrayList(types.Session).empty,
            .messages = std.ArrayList(types.ChatMessage).empty,
            .users = std.ArrayList(types.User).empty,
            .stream_text = null,
            .sessions_loading = false,
            .messages_loading = false,
            .pending_sessions_request_id = null,
            .pending_history_request_id = null,
            .pending_send_request_id = null,
            .last_error = null,
        };
    }

    pub fn deinit(self: *ClientContext) void {
        if (self.current_session) |session| {
            self.allocator.free(session);
            self.current_session = null;
        }
        if (self.history_session) |session| {
            self.allocator.free(session);
            self.history_session = null;
        }
        self.clearStreamRunId();
        self.clearStreamText();
        self.clearPendingRequests();
        self.clearError();
        for (self.sessions.items) |*session| {
            freeSession(self.allocator, session);
        }
        for (self.messages.items) |*message| {
            freeChatMessage(self.allocator, message);
        }
        for (self.users.items) |*user| {
            freeUser(self.allocator, user);
        }
        self.sessions.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.users.deinit(self.allocator);
    }

    pub fn setSessions(self: *ClientContext, sessions: []const types.Session) !void {
        clearSessions(self);
        try self.sessions.ensureTotalCapacity(self.allocator, sessions.len);
        for (sessions) |session| {
            self.sessions.appendAssumeCapacity(try cloneSession(self.allocator, session));
        }
    }

    pub fn setSessionsOwned(self: *ClientContext, sessions: []types.Session) void {
        clearSessions(self);
        self.sessions.deinit(self.allocator);
        self.sessions = std.ArrayList(types.Session).fromOwnedSlice(sessions);
    }

    pub fn setMessagesOwned(self: *ClientContext, messages: []types.ChatMessage) void {
        clearMessagesInternal(self);
        self.messages.deinit(self.allocator);
        self.messages = std.ArrayList(types.ChatMessage).fromOwnedSlice(messages);
    }

    pub fn clearMessages(self: *ClientContext) void {
        clearMessagesInternal(self);
    }

    pub fn upsertMessage(self: *ClientContext, msg: types.ChatMessage) !void {
        for (self.messages.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.id, msg.id)) {
                freeChatMessage(self.allocator, existing);
                self.messages.items[index] = try cloneChatMessage(self.allocator, msg);
                return;
            }
        }
        try self.messages.append(self.allocator, try cloneChatMessage(self.allocator, msg));
    }

    pub fn upsertMessageOwned(self: *ClientContext, msg: types.ChatMessage) !void {
        for (self.messages.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.id, msg.id)) {
                freeChatMessage(self.allocator, existing);
                self.messages.items[index] = msg;
                return;
            }
        }
        try self.messages.append(self.allocator, msg);
    }

    pub fn setCurrentSession(self: *ClientContext, key: []const u8) !void {
        if (self.current_session) |session| {
            if (std.mem.eql(u8, session, key)) return;
            self.allocator.free(session);
        }
        self.current_session = try self.allocator.dupe(u8, key);
        self.clearHistorySession();
    }

    pub fn clearHistorySession(self: *ClientContext) void {
        if (self.history_session) |session| {
            self.allocator.free(session);
            self.history_session = null;
        }
    }

    pub fn setHistorySession(self: *ClientContext, key: []const u8) !void {
        self.clearHistorySession();
        self.history_session = try self.allocator.dupe(u8, key);
    }

    pub fn setStreamRunId(self: *ClientContext, run_id: []const u8) !void {
        self.clearStreamRunId();
        self.stream_run_id = try self.allocator.dupe(u8, run_id);
    }

    pub fn clearStreamRunId(self: *ClientContext) void {
        if (self.stream_run_id) |run_id| {
            self.allocator.free(run_id);
            self.stream_run_id = null;
        }
    }

    pub fn setStreamText(self: *ClientContext, text: []const u8) !void {
        self.clearStreamText();
        self.stream_text = try self.allocator.dupe(u8, text);
    }

    pub fn clearStreamText(self: *ClientContext) void {
        if (self.stream_text) |text| {
            self.allocator.free(text);
            self.stream_text = null;
        }
    }

    pub fn removeMessageById(self: *ClientContext, id: []const u8) bool {
        var index: usize = 0;
        while (index < self.messages.items.len) : (index += 1) {
            if (std.mem.eql(u8, self.messages.items[index].id, id)) {
                var removed = self.messages.orderedRemove(index);
                freeChatMessage(self.allocator, &removed);
                return true;
            }
        }
        return false;
    }

    pub fn setPendingSessionsRequest(self: *ClientContext, id: []const u8) void {
        if (self.pending_sessions_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_sessions_request_id = id;
        self.sessions_loading = true;
    }

    pub fn clearPendingSessionsRequest(self: *ClientContext) void {
        if (self.pending_sessions_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_sessions_request_id = null;
        self.sessions_loading = false;
    }

    pub fn setPendingHistoryRequest(self: *ClientContext, id: []const u8) void {
        if (self.pending_history_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_history_request_id = id;
        self.messages_loading = true;
    }

    pub fn clearPendingHistoryRequest(self: *ClientContext) void {
        if (self.pending_history_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_history_request_id = null;
        self.messages_loading = false;
    }

    pub fn setPendingSendRequest(self: *ClientContext, id: []const u8) void {
        if (self.pending_send_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_send_request_id = id;
    }

    pub fn clearPendingSendRequest(self: *ClientContext) void {
        if (self.pending_send_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_send_request_id = null;
    }

    pub fn clearPendingRequests(self: *ClientContext) void {
        self.clearPendingSessionsRequest();
        self.clearPendingHistoryRequest();
        self.clearPendingSendRequest();
    }

    pub fn setError(self: *ClientContext, message: []const u8) !void {
        self.clearError();
        self.last_error = try self.allocator.dupe(u8, message);
    }

    pub fn clearError(self: *ClientContext) void {
        if (self.last_error) |msg| {
            self.allocator.free(msg);
            self.last_error = null;
        }
    }
};

fn clearSessions(self: *ClientContext) void {
    for (self.sessions.items) |*session| {
        freeSession(self.allocator, session);
    }
    self.sessions.clearRetainingCapacity();
}

fn clearMessagesInternal(self: *ClientContext) void {
    for (self.messages.items) |*message| {
        freeChatMessage(self.allocator, message);
    }
    self.messages.clearRetainingCapacity();
}

fn cloneAttachment(allocator: std.mem.Allocator, attachment: types.ChatAttachment) !types.ChatAttachment {
    return .{
        .kind = try allocator.dupe(u8, attachment.kind),
        .url = try allocator.dupe(u8, attachment.url),
        .name = if (attachment.name) |name| try allocator.dupe(u8, name) else null,
    };
}

fn freeAttachment(allocator: std.mem.Allocator, attachment: *types.ChatAttachment) void {
    allocator.free(attachment.kind);
    allocator.free(attachment.url);
    if (attachment.name) |name| {
        allocator.free(name);
    }
}

fn cloneChatMessage(allocator: std.mem.Allocator, msg: types.ChatMessage) !types.ChatMessage {
    var cloned: types.ChatMessage = .{
        .id = try allocator.dupe(u8, msg.id),
        .role = try allocator.dupe(u8, msg.role),
        .content = try allocator.dupe(u8, msg.content),
        .timestamp = msg.timestamp,
        .attachments = null,
    };
    if (msg.attachments) |attachments| {
        var list = try allocator.alloc(types.ChatAttachment, attachments.len);
        for (attachments, 0..) |attachment, index| {
            list[index] = try cloneAttachment(allocator, attachment);
        }
        cloned.attachments = list;
    }
    return cloned;
}

fn freeChatMessage(allocator: std.mem.Allocator, msg: *types.ChatMessage) void {
    allocator.free(msg.id);
    allocator.free(msg.role);
    allocator.free(msg.content);
    if (msg.attachments) |attachments| {
        for (attachments) |*attachment| {
            freeAttachment(allocator, attachment);
        }
        allocator.free(attachments);
    }
}

fn cloneSession(allocator: std.mem.Allocator, session: types.Session) !types.Session {
    return .{
        .key = try allocator.dupe(u8, session.key),
        .display_name = if (session.display_name) |name| try allocator.dupe(u8, name) else null,
        .label = if (session.label) |label| try allocator.dupe(u8, label) else null,
        .kind = if (session.kind) |kind| try allocator.dupe(u8, kind) else null,
        .updated_at = session.updated_at,
    };
}

fn freeSession(allocator: std.mem.Allocator, session: *types.Session) void {
    allocator.free(session.key);
    if (session.display_name) |name| {
        allocator.free(name);
    }
    if (session.label) |label| {
        allocator.free(label);
    }
    if (session.kind) |kind| {
        allocator.free(kind);
    }
}

fn cloneUser(allocator: std.mem.Allocator, user: types.User) !types.User {
    return .{
        .id = try allocator.dupe(u8, user.id),
        .name = try allocator.dupe(u8, user.name),
    };
}

fn freeUser(allocator: std.mem.Allocator, user: *types.User) void {
    allocator.free(user.id);
    allocator.free(user.name);
}
