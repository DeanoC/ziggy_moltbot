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
    sessions: std.ArrayList(types.Session),
    messages: std.ArrayList(types.ChatMessage),
    users: std.ArrayList(types.User),

    pub fn init(allocator: std.mem.Allocator) !ClientContext {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .current_session = null,
            .sessions = std.ArrayList(types.Session).empty,
            .messages = std.ArrayList(types.ChatMessage).empty,
            .users = std.ArrayList(types.User).empty,
        };
    }

    pub fn deinit(self: *ClientContext) void {
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
};

fn clearSessions(self: *ClientContext) void {
    for (self.sessions.items) |*session| {
        freeSession(self.allocator, session);
    }
    self.sessions.clearRetainingCapacity();
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
        .id = try allocator.dupe(u8, session.id),
        .name = try allocator.dupe(u8, session.name),
        .created_at = session.created_at,
    };
}

fn freeSession(allocator: std.mem.Allocator, session: *types.Session) void {
    allocator.free(session.id);
    allocator.free(session.name);
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
