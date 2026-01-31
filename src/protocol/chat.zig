const std = @import("std");

pub const ChatHistoryParams = struct {
    sessionKey: []const u8,
    limit: ?u32 = null,
};

pub const ChatSendParams = struct {
    sessionKey: []const u8,
    message: []const u8,
    thinking: ?[]const u8 = null,
    deliver: ?bool = null,
    attachments: ?[]const std.json.Value = null,
    timeoutMs: ?u32 = null,
    idempotencyKey: []const u8,
};

pub const ChatAttachment = struct {
    kind: []const u8,
    url: []const u8,
    name: ?[]const u8 = null,
};

pub const ChatContentItem = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
};

pub const ChatHistoryMessage = struct {
    id: ?[]const u8 = null,
    role: []const u8,
    content: ?[]ChatContentItem = null,
    text: ?[]const u8 = null,
    timestamp: ?i64 = null,
    attachments: ?[]ChatAttachment = null,
};

pub const ChatHistoryResult = struct {
    messages: ?[]ChatHistoryMessage = null,
    thinkingLevel: ?[]const u8 = null,
};

pub const ChatEventPayload = struct {
    runId: []const u8,
    sessionKey: []const u8,
    seq: i64,
    state: []const u8,
    message: ?std.json.Value = null,
    errorMessage: ?[]const u8 = null,
};
