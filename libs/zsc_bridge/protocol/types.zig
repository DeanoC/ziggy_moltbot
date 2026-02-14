const std = @import("std");

pub const ChatAttachment = struct {
    kind: []const u8,
    url: []const u8,
    name: ?[]const u8 = null,
};

pub const LocalChatMessageState = enum {
    sending,
    failed,
};

pub const ChatMessage = struct {
    id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp: i64,
    attachments: ?[]ChatAttachment = null,

    // Client-only metadata (not provided by the gateway). Useful for optimistic UI.
    local_state: ?LocalChatMessageState = null,
};

pub const Session = struct {
    key: []const u8,
    display_name: ?[]const u8 = null,
    label: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    updated_at: ?i64 = null,
    session_id: ?[]const u8 = null,
};

pub const SessionListResult = struct {
    sessions: ?[]Session = null,
};

pub const Node = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    version: ?[]const u8 = null,
    core_version: ?[]const u8 = null,
    ui_version: ?[]const u8 = null,
    device_family: ?[]const u8 = null,
    model_identifier: ?[]const u8 = null,
    remote_ip: ?[]const u8 = null,
    caps: ?[]const []const u8 = null,
    commands: ?[]const []const u8 = null,
    path_env: ?[]const u8 = null,
    permissions_json: ?[]const u8 = null,
    connected_at_ms: ?i64 = null,
    connected: ?bool = null,
    paired: ?bool = null,
};

pub const WorkboardItem = struct {
    id: []const u8,
    kind: ?[]const u8 = null,
    status: ?[]const u8 = null,
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    cron_key: ?[]const u8 = null,
    created_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
    due_at_ms: ?i64 = null,
    payload_json: ?[]const u8 = null,
};

pub const ExecApproval = struct {
    id: []const u8,
    payload_json: []const u8,

    // Human-facing summary derived from payload.
    summary: ?[]const u8 = null,

    // Audit trail (best-effort extraction from gateway payloads).
    requested_at_ms: ?i64 = null,
    requested_by: ?[]const u8 = null,

    resolved_at_ms: ?i64 = null,
    resolved_by: ?[]const u8 = null,
    decision: ?[]const u8 = null,

    // Whether this client can resolve automatically (requires a stable id).
    can_resolve: bool = false,
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
