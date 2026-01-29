const std = @import("std");

pub const ChatAttachment = struct {
    kind: []const u8,
    url: []const u8,
    name: ?[]const u8 = null,
};

pub const ChatMessage = struct {
    id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp: i64,
    attachments: ?[]ChatAttachment = null,
};

pub const Session = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,
};

pub const SessionListResult = struct {
    sessions: []Session,
};

pub const User = struct {
    id: []const u8,
    name: []const u8,
};

pub const ErrorEvent = struct {
    message: []const u8,
    code: ?[]const u8 = null,
};

pub const MessageEnvelope = struct {
    kind: []const u8,
    payload: std.json.Value,
};
