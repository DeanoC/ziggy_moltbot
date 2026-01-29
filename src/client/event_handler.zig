const std = @import("std");
const state = @import("state.zig");
const types = @import("../protocol/types.zig");
const gateway = @import("../protocol/gateway.zig");
const messages = @import("../protocol/messages.zig");
const sessions = @import("../protocol/sessions.zig");
const chat = @import("../protocol/chat.zig");
const requests = @import("../protocol/requests.zig");
const logger = @import("../utils/logger.zig");

pub const AuthUpdate = struct {
    device_token: []const u8,
    role: ?[]const u8 = null,
    scopes: ?[]const []const u8 = null,
    issued_at_ms: ?i64 = null,

    pub fn deinit(self: *const AuthUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.device_token);
        if (self.role) |role| {
            allocator.free(role);
        }
        if (self.scopes) |scopes| {
            for (scopes) |scope| {
                allocator.free(scope);
            }
            allocator.free(scopes);
        }
    }
};

pub fn handleRawMessage(ctx: *state.ClientContext, raw: []const u8) !?AuthUpdate {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch |err| {
        logger.warn("Unparsed server message ({s}): {s}", .{ @errorName(err), raw });
        return null;
    };
    defer parsed.deinit();

    const value = parsed.value;
    if (value != .object) {
        logger.warn("Unexpected server message (non-object): {s}", .{raw});
        return null;
    }

    const obj = value.object;
    const type_value = obj.get("type") orelse {
        logger.warn("Server message missing type: {s}", .{raw});
        return null;
    };
    if (type_value != .string) {
        logger.warn("Server message has non-string type: {s}", .{raw});
        return null;
    }

    const frame_type = type_value.string;

    if (std.mem.eql(u8, frame_type, "event")) {
        var frame = messages.parsePayload(ctx.allocator, value, gateway.GatewayEventFrame) catch |err| {
            logger.warn("Unparsed event frame ({s}): {s}", .{ @errorName(err), raw });
            return null;
        };
        defer frame.deinit();

        if (std.mem.eql(u8, frame.value.event, "connect.challenge")) {
            logger.info("Gateway connect challenge received", .{});
            return null;
        }

        if (std.mem.eql(u8, frame.value.event, "device.pair.requested")) {
            logger.warn("Gateway pairing required: {s}", .{raw});
            return null;
        }

        if (std.mem.eql(u8, frame.value.event, "chat")) {
            handleChatEvent(ctx, frame.value.payload) catch |err| {
                logger.warn("Failed to handle chat event ({s})", .{@errorName(err)});
            };
            return null;
        }

        logger.debug("Gateway event: {s}", .{frame.value.event});
        return null;
    }

    if (std.mem.eql(u8, frame_type, "res")) {
        var frame = messages.parsePayload(ctx.allocator, value, gateway.GatewayResponseFrame) catch |err| {
            logger.warn("Unparsed response frame ({s}): {s}", .{ @errorName(err), raw });
            return null;
        };
        defer frame.deinit();

        const response_id = frame.value.id;
        const is_sessions = ctx.pending_sessions_request_id != null and
            std.mem.eql(u8, ctx.pending_sessions_request_id.?, response_id);
        const is_history = ctx.pending_history_request_id != null and
            std.mem.eql(u8, ctx.pending_history_request_id.?, response_id);
        const is_send = ctx.pending_send_request_id != null and
            std.mem.eql(u8, ctx.pending_send_request_id.?, response_id);

        if (!frame.value.ok) {
            if (is_sessions) ctx.clearPendingSessionsRequest();
            if (is_history) ctx.clearPendingHistoryRequest();
            if (is_send) ctx.clearPendingSendRequest();

            if (frame.value.@"error") |err| {
                logger.err("Gateway request failed ({s}): {s}", .{ err.code, err.message });
                ctx.setError(err.message) catch {};
                if (err.details) |details| {
                    if (details == .object) {
                        if (details.object.get("requestId")) |request_id| {
                            if (request_id == .string) {
                                logger.warn("Pairing request id: {s}", .{request_id.string});
                            }
                        }
                    }
                }
            } else {
                logger.err("Gateway request failed: {s}", .{raw});
            }
            ctx.state = .error_state;
            return null;
        }

        if (frame.value.payload) |payload| {
            if (payload == .object) {
                const payload_type = payload.object.get("type");
                if (payload_type != null and payload_type.? == .string and
                    std.mem.eql(u8, payload_type.?.string, "hello-ok"))
                {
                    ctx.state = .connected;
                    logger.info("Gateway connected", .{});
                    if (try extractAuthUpdate(ctx.allocator, payload)) |update| {
                        return update;
                    }
                }
            }

            if (is_sessions) {
                ctx.clearPendingSessionsRequest();
                handleSessionsList(ctx, payload) catch |err| {
                    logger.warn("sessions.list handling failed ({s})", .{@errorName(err)});
                };
                return null;
            }

            if (is_history) {
                ctx.clearPendingHistoryRequest();
                handleChatHistory(ctx, payload) catch |err| {
                    logger.warn("chat.history handling failed ({s})", .{@errorName(err)});
                };
                return null;
            }

            if (is_send) {
                ctx.clearPendingSendRequest();
                return null;
            }
        }
        return null;
    }

    logger.debug("Unhandled gateway frame: {s}", .{raw});
    return null;
}

pub fn handleConnectionState(ctx: *state.ClientContext, new_state: state.ClientState) void {
    ctx.state = new_state;
}

fn handleSessionsList(ctx: *state.ClientContext, payload: std.json.Value) !void {
    var parsed = try messages.parsePayload(ctx.allocator, payload, sessions.SessionsListResult);
    defer parsed.deinit();

    const rows = parsed.value.sessions orelse {
        logger.warn("sessions.list payload missing sessions", .{});
        return;
    };

    const list = try ctx.allocator.alloc(types.Session, rows.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*session| {
            freeSessionOwned(ctx.allocator, session);
        }
        ctx.allocator.free(list);
    }

    for (rows, 0..) |row, index| {
        list[index] = .{
            .key = try ctx.allocator.dupe(u8, row.key),
            .display_name = if (row.displayName) |name| try ctx.allocator.dupe(u8, name) else null,
            .label = if (row.label) |label| try ctx.allocator.dupe(u8, label) else null,
            .kind = if (row.kind) |kind| try ctx.allocator.dupe(u8, kind) else null,
            .updated_at = row.updatedAt,
        };
        filled = index + 1;
    }

    ctx.setSessionsOwned(list);
    selectPreferredSession(ctx);
}

fn handleChatHistory(ctx: *state.ClientContext, payload: std.json.Value) !void {
    var parsed = try messages.parsePayload(ctx.allocator, payload, chat.ChatHistoryResult);
    defer parsed.deinit();

    const items = parsed.value.messages orelse {
        logger.warn("chat.history payload missing messages", .{});
        return;
    };

    const list = try ctx.allocator.alloc(types.ChatMessage, items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*message| {
            freeChatMessageOwned(ctx.allocator, message);
        }
        ctx.allocator.free(list);
    }

    for (items, 0..) |item, index| {
        list[index] = try buildChatMessage(ctx.allocator, item);
        filled = index + 1;
    }

    ctx.setMessagesOwned(list);
    if (ctx.current_session) |session| {
        ctx.setHistorySession(session) catch {};
    }
    ctx.clearStreamText();
    ctx.clearStreamRunId();
}

fn selectPreferredSession(ctx: *state.ClientContext) void {
    if (ctx.sessions.items.len == 0) return;

    if (ctx.current_session != null) return;

    var best_index: usize = 0;
    var best_updated: i64 = -1;
    for (ctx.sessions.items, 0..) |session, index| {
        const updated = session.updated_at orelse 0;
        if (updated > best_updated) {
            best_updated = updated;
            best_index = index;
        }
    }

    const chosen = ctx.sessions.items[best_index].key;
        ctx.setCurrentSession(chosen) catch |err| {
        logger.warn("Failed to select session: {}", .{err});
        return;
    };
    ctx.clearMessages();
    ctx.clearStreamText();
    ctx.clearStreamRunId();
    ctx.clearPendingHistoryRequest();
    ctx.clearHistorySession();
}

fn handleChatEvent(ctx: *state.ClientContext, payload: ?std.json.Value) !void {
    const value = payload orelse return;
    var parsed = try messages.parsePayload(ctx.allocator, value, chat.ChatEventPayload);
    defer parsed.deinit();

    const event = parsed.value;
    if (ctx.current_session) |session| {
        if (!std.mem.eql(u8, session, event.sessionKey)) return;
    }

    if (std.mem.eql(u8, event.state, "delta")) {
        const text = if (event.message) |message_val|
            extractChatTextValue(ctx.allocator, message_val)
        else
            null;
        defer if (text) |value_text| ctx.allocator.free(value_text);
        if (text == null) return;

        if (ctx.stream_run_id == null or !std.mem.eql(u8, ctx.stream_run_id.?, event.runId)) {
            try ctx.setStreamRunId(event.runId);
        }

        var msg = try buildStreamMessage(ctx.allocator, event.runId, text.?);
        errdefer freeChatMessageOwned(ctx.allocator, &msg);
        ctx.upsertMessageOwned(msg) catch |err| {
            logger.warn("Failed to upsert stream message ({s})", .{@errorName(err)});
            freeChatMessageOwned(ctx.allocator, &msg);
        };
        return;
    }

    const had_stream = ctx.stream_run_id != null and std.mem.eql(u8, ctx.stream_run_id.?, event.runId);
    if (had_stream) {
        ctx.clearStreamRunId();
    }
    ctx.clearStreamText();

    if (std.mem.eql(u8, event.state, "error")) {
        if (event.errorMessage) |msg| {
            ctx.setError(msg) catch {};
        }
        return;
    }

    if (event.message) |message_val| {
        var parsed_msg = messages.parsePayload(ctx.allocator, message_val, chat.ChatHistoryMessage) catch |err| {
            logger.warn("Failed to parse chat message ({s})", .{@errorName(err)});
            return;
        };
        defer parsed_msg.deinit();
        var message = buildChatMessage(ctx.allocator, parsed_msg.value) catch |err| {
            logger.warn("Failed to build chat message ({s})", .{@errorName(err)});
            return;
        };
        if (had_stream) {
            const stream_id = try makeStreamId(ctx.allocator, event.runId);
            defer ctx.allocator.free(stream_id);
            _ = ctx.removeMessageById(stream_id);
        }
        ctx.upsertMessageOwned(message) catch |err| {
            logger.warn("Failed to upsert chat message ({s})", .{@errorName(err)});
            freeChatMessageOwned(ctx.allocator, &message);
        };
    }
}

fn extractAuthUpdate(allocator: std.mem.Allocator, payload: std.json.Value) !?AuthUpdate {
    if (payload != .object) return null;
    const auth_val = payload.object.get("auth") orelse return null;
    if (auth_val != .object) return null;
    const auth_obj = auth_val.object;
    const token_val = auth_obj.get("deviceToken") orelse return null;
    if (token_val != .string) return null;

    const token = try allocator.dupe(u8, token_val.string);
    const role = if (auth_obj.get("role")) |role_val| blk: {
        if (role_val == .string) break :blk try allocator.dupe(u8, role_val.string);
        break :blk null;
    } else null;

    var scopes_list: ?[]const []const u8 = null;
    if (auth_obj.get("scopes")) |scopes_val| {
        if (scopes_val == .array) {
            const items = scopes_val.array.items;
            var list = std.ArrayList([]const u8).empty;
            errdefer {
                for (list.items) |item| {
                    allocator.free(item);
                }
                list.deinit(allocator);
            }
            for (items) |item| {
                if (item != .string) continue;
                try list.append(allocator, try allocator.dupe(u8, item.string));
            }
            scopes_list = try list.toOwnedSlice(allocator);
            list.deinit(allocator);
        }
    }

    return AuthUpdate{
        .device_token = token,
        .role = role,
        .scopes = scopes_list,
        .issued_at_ms = if (auth_obj.get("issuedAtMs")) |issued_val|
            if (issued_val == .integer) issued_val.integer else null
        else
            null,
    };
}

fn buildChatMessage(allocator: std.mem.Allocator, msg: chat.ChatHistoryMessage) !types.ChatMessage {
    const id = if (msg.id) |value| try allocator.dupe(u8, value) else try requests.makeRequestId(allocator);
    errdefer allocator.free(id);
    const role = try allocator.dupe(u8, msg.role);
    errdefer allocator.free(role);
    const content = try extractChatText(allocator, msg);
    errdefer allocator.free(content);
    return .{
        .id = id,
        .role = role,
        .content = content,
        .timestamp = msg.timestamp orelse std.time.milliTimestamp(),
        .attachments = null,
    };
}

fn buildStreamMessage(allocator: std.mem.Allocator, run_id: []const u8, content: []const u8) !types.ChatMessage {
    const id = try makeStreamId(allocator, run_id);
    errdefer allocator.free(id);
    const role = try allocator.dupe(u8, "assistant");
    errdefer allocator.free(role);
    const text = try allocator.dupe(u8, content);
    errdefer allocator.free(text);
    return .{
        .id = id,
        .role = role,
        .content = text,
        .timestamp = std.time.milliTimestamp(),
        .attachments = null,
    };
}

fn makeStreamId(allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stream:{s}", .{run_id});
}

fn extractChatTextValue(allocator: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    var parsed = messages.parsePayload(allocator, value, chat.ChatHistoryMessage) catch return null;
    defer parsed.deinit();
    return extractChatText(allocator, parsed.value) catch null;
}

fn extractChatText(allocator: std.mem.Allocator, msg: chat.ChatHistoryMessage) ![]const u8 {
    if (msg.content) |content| {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(allocator);
        var first = true;
        for (content) |item| {
            if (!std.mem.eql(u8, item.type, "text")) continue;
            if (item.text) |text| {
                if (!first) {
                    try list.appendSlice(allocator, "\n");
                }
                try list.appendSlice(allocator, text);
                first = false;
            }
        }
        if (list.items.len > 0) {
            return list.toOwnedSlice(allocator);
        }
    }

    if (msg.text) |text| {
        return allocator.dupe(u8, text);
    }

    return allocator.dupe(u8, "");
}

fn freeSessionOwned(allocator: std.mem.Allocator, session: *types.Session) void {
    allocator.free(session.key);
    if (session.display_name) |name| allocator.free(name);
    if (session.label) |label| allocator.free(label);
    if (session.kind) |kind| allocator.free(kind);
}

fn freeChatMessageOwned(allocator: std.mem.Allocator, msg: *types.ChatMessage) void {
    allocator.free(msg.id);
    allocator.free(msg.role);
    allocator.free(msg.content);
    if (msg.attachments) |attachments| {
        for (attachments) |*attachment| {
            allocator.free(attachment.kind);
            allocator.free(attachment.url);
            if (attachment.name) |name| allocator.free(name);
        }
        allocator.free(attachments);
    }
}
