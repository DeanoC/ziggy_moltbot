const std = @import("std");
const state = @import("state.zig");
const types = @import("../protocol/types.zig");
const gateway = @import("../protocol/gateway.zig");
const messages = @import("../protocol/messages.zig");
const sessions = @import("../protocol/sessions.zig");
const chat = @import("../protocol/chat.zig");
const nodes = @import("../protocol/nodes.zig");
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
            recordSystemActivity(
                ctx,
                "system:pairing",
                "Pairing approval required",
                "Gateway pairing required before command execution can continue.",
                .warn,
                .pending,
                raw,
            ) catch {};
            return null;
        }

        if (std.mem.eql(u8, frame.value.event, "chat")) {
            handleChatEvent(ctx, frame.value.payload) catch |err| {
                logger.warn("Failed to handle chat event ({s})", .{@errorName(err)});
            };
            return null;
        }

        if (std.mem.eql(u8, frame.value.event, "exec.approval.requested")) {
            handleExecApprovalRequested(ctx, frame.value.payload) catch |err| {
                logger.warn("Failed to handle exec approval request ({s})", .{@errorName(err)});
            };
            return null;
        }

        if (std.mem.eql(u8, frame.value.event, "exec.approval.resolved")) {
            handleExecApprovalResolved(ctx, frame.value.payload) catch |err| {
                logger.warn("Failed to handle exec approval resolved ({s})", .{@errorName(err)});
            };
            return null;
        }

        if (std.mem.eql(u8, frame.value.event, "node.health.frame")) {
            handleNodeHealthFrame(ctx, frame.value.payload) catch |err| {
                logger.warn("Failed to handle node health frame ({s})", .{@errorName(err)});
            };
            return null;
        }

        if (std.mem.eql(u8, frame.value.event, "tick") or
            std.mem.eql(u8, frame.value.event, "cron") or
            std.mem.eql(u8, frame.value.event, "health"))
        {
            return null;
        }
        logger.debug("Gateway event: {s}", .{frame.value.event});
        var key_buf = std.ArrayList(u8).empty;
        defer key_buf.deinit(ctx.allocator);
        key_buf.writer(ctx.allocator).print("event:{s}", .{frame.value.event}) catch {};
        const key = if (key_buf.items.len > 0) key_buf.items else "event:unknown";
        recordSystemActivity(
            ctx,
            key,
            frame.value.event,
            "Gateway event received",
            .info,
            .info,
            raw,
        ) catch {};
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
        const history_session = ctx.findSessionForPendingHistory(response_id);
        const is_history = history_session != null;
        const is_send = ctx.pending_send_request_id != null and
            std.mem.eql(u8, ctx.pending_send_request_id.?, response_id);
        const is_nodes = ctx.pending_nodes_request_id != null and
            std.mem.eql(u8, ctx.pending_nodes_request_id.?, response_id);
        const is_node_invoke = ctx.pending_node_invoke_request_id != null and
            std.mem.eql(u8, ctx.pending_node_invoke_request_id.?, response_id);
        const is_node_describe = ctx.pending_node_describe_request_id != null and
            std.mem.eql(u8, ctx.pending_node_describe_request_id.?, response_id);
        const pending_node_command = if (is_node_invoke) ctx.pending_node_invoke_command else null;
        const is_agents_create = ctx.pending_agents_create_request_id != null and
            std.mem.eql(u8, ctx.pending_agents_create_request_id.?, response_id);
        const is_agents_update = ctx.pending_agents_update_request_id != null and
            std.mem.eql(u8, ctx.pending_agents_update_request_id.?, response_id);
        const is_agents_delete = ctx.pending_agents_delete_request_id != null and
            std.mem.eql(u8, ctx.pending_agents_delete_request_id.?, response_id);
        const is_approval_resolve = ctx.pending_approval_resolve_request_id != null and
            std.mem.eql(u8, ctx.pending_approval_resolve_request_id.?, response_id);

        if (!frame.value.ok) {
            if (is_node_invoke) {
                recordNodeInvokeFailureActivity(ctx, pending_node_command, frame.value.@"error", raw) catch {};
            } else {
                recordResponseFailureActivity(ctx, response_id, frame.value.@"error", raw) catch {};
            }

            if (is_sessions) ctx.clearPendingSessionsRequest();
            if (is_history) ctx.clearPendingHistoryById(response_id);
            if (is_send) ctx.resolvePendingSendRequest(false);
            if (is_nodes) ctx.clearPendingNodesRequest();
            if (is_node_invoke) ctx.clearPendingNodeInvokeRequest();
            if (is_node_describe) ctx.clearPendingNodeDescribeRequest();
            if (is_agents_create) ctx.clearPendingAgentsCreateRequest();
            if (is_agents_update) ctx.clearPendingAgentsUpdateRequest();
            if (is_agents_delete) ctx.clearPendingAgentsDeleteRequest();
            if (is_approval_resolve) ctx.clearPendingApprovalResolveRequest();

            if (frame.value.@"error") |err| {
                logger.err("Gateway request failed ({s}): {s}", .{ err.code, err.message });
                ctx.setError(err.message) catch {};
                if (is_nodes or is_node_invoke) {
                    ctx.setOperatorNotice(err.message) catch {};
                }
                if (is_node_describe or is_approval_resolve) {
                    ctx.setOperatorNotice(err.message) catch {};
                }
                if (is_agents_create or is_agents_update or is_agents_delete) {
                    ctx.setOperatorNotice(err.message) catch {};
                    return null;
                }
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
                if (is_agents_create or is_agents_update or is_agents_delete) {
                    ctx.setOperatorNotice("Agent request failed.") catch {};
                    return null;
                }
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

                    if (try extractGatewayMethods(ctx.allocator, payload)) |methods| {
                        ctx.setGatewayMethodsOwned(methods);
                    } else {
                        ctx.clearGatewayMethods();
                    }

                    if (extractGatewayIdentity(payload)) |identity| {
                        try ctx.setGatewayIdentity(identity.kind, identity.mode, identity.source);
                    } else {
                        ctx.clearGatewayIdentity();
                    }

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
                ctx.clearPendingHistoryById(response_id);
                const session_key = history_session.?;
                handleChatHistory(ctx, session_key, payload) catch |err| {
                    logger.warn("chat.history handling failed ({s})", .{@errorName(err)});
                };
                return null;
            }

            if (is_send) {
                ctx.resolvePendingSendRequest(true);
                return null;
            }

            if (is_nodes) {
                ctx.clearPendingNodesRequest();
                handleNodesList(ctx, payload) catch |err| {
                    logger.warn("node.list handling failed ({s})", .{@errorName(err)});
                };
                return null;
            }

            if (is_node_invoke) {
                handleNodeInvokeResponse(ctx, payload, pending_node_command, raw) catch |err| {
                    logger.warn("node.invoke handling failed ({s})", .{@errorName(err)});
                };
                ctx.clearPendingNodeInvokeRequest();
                return null;
            }

            if (is_node_describe) {
                ctx.clearPendingNodeDescribeRequest();
                handleNodeDescribeResponse(ctx, payload) catch |err| {
                    logger.warn("node.describe handling failed ({s})", .{@errorName(err)});
                };
                return null;
            }

            if (is_agents_create) {
                ctx.clearPendingAgentsCreateRequest();
                ctx.setOperatorNotice("Agent created on gateway.") catch {};
                return null;
            }

            if (is_agents_update) {
                ctx.clearPendingAgentsUpdateRequest();
                return null;
            }

            if (is_agents_delete) {
                ctx.clearPendingAgentsDeleteRequest();
                ctx.setOperatorNotice("Agent deleted on gateway.") catch {};
                return null;
            }

            if (is_approval_resolve) {
                handleExecApprovalResolveResponse(ctx, payload) catch |err| {
                    logger.warn("exec.approval.resolve handling failed ({s})", .{@errorName(err)});
                };
                return null;
            }
        }

        // Some responses may omit a payload; ensure chat.send is still resolved.
        if (is_send) {
            ctx.resolvePendingSendRequest(true);
        }
        if (is_agents_create) {
            ctx.clearPendingAgentsCreateRequest();
            ctx.setOperatorNotice("Agent created on gateway.") catch {};
        }
        if (is_agents_update) {
            ctx.clearPendingAgentsUpdateRequest();
        }
        if (is_agents_delete) {
            ctx.clearPendingAgentsDeleteRequest();
            ctx.setOperatorNotice("Agent deleted on gateway.") catch {};
        }
        return null;
    }

    logger.debug("Unhandled gateway frame: {s}", .{raw});
    return null;
}

pub fn handleConnectionState(ctx: *state.ClientContext, new_state: state.ClientState) void {
    ctx.state = new_state;
    const severity: state.ActivitySeverity = switch (new_state) {
        .error_state => .@"error",
        .connecting, .authenticating => .info,
        .connected => .info,
        .disconnected => .debug,
    };
    var summary_buf: [64]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "Connection state: {s}", .{@tagName(new_state)}) catch "Connection state changed";
    recordSystemActivity(ctx, "system:connection", "Connection", summary, severity, .info, null) catch {};
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
            .session_id = if (row.sessionId) |id| try ctx.allocator.dupe(u8, id) else null,
        };
        filled = index + 1;
    }

    ctx.setSessionsOwned(list);
    ctx.markSessionsUpdated();
}

fn handleChatHistory(ctx: *state.ClientContext, session_key: []const u8, payload: std.json.Value) !void {
    var parsed = try messages.parsePayload(ctx.allocator, payload, chat.ChatHistoryResult);
    defer parsed.deinit();

    const items = parsed.value.messages orelse {
        logger.warn("chat.history payload missing messages", .{});
        return;
    };

    var list = std.ArrayList(types.ChatMessage).empty;
    errdefer {
        for (list.items) |*message| {
            freeChatMessageOwned(ctx.allocator, message);
        }
        list.deinit(ctx.allocator);
    }

    for (items) |item| {
        try list.append(ctx.allocator, try buildChatMessage(ctx.allocator, item));
    }

    if (ctx.findSessionState(session_key)) |state_ptr| {
        if (state_ptr.messages.items.len > 0) {
            for (state_ptr.messages.items) |existing| {
                if (!messageListHasId(list.items, existing.id)) {
                    try list.append(ctx.allocator, try cloneChatMessageExisting(ctx.allocator, existing));
                }
            }
        }
    }

    const owned = try list.toOwnedSlice(ctx.allocator);
    list.deinit(ctx.allocator);
    try ctx.setSessionMessagesOwned(session_key, owned);
    ctx.clearSessionStream(session_key);
}

fn handleNodesList(ctx: *state.ClientContext, payload: std.json.Value) !void {
    var parsed = try messages.parsePayload(ctx.allocator, payload, nodes.NodeListResult);
    defer parsed.deinit();

    const items = parsed.value.nodes orelse {
        logger.warn("node.list payload missing nodes", .{});
        return;
    };

    const list = try ctx.allocator.alloc(types.Node, items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*node| {
            freeNodeOwned(ctx.allocator, node);
        }
        ctx.allocator.free(list);
    }

    for (items, 0..) |item, index| {
        list[index] = .{
            .id = try ctx.allocator.dupe(u8, item.nodeId),
            .display_name = if (item.displayName) |name| try ctx.allocator.dupe(u8, name) else null,
            .platform = if (item.platform) |platform| try ctx.allocator.dupe(u8, platform) else null,
            .version = if (item.version) |version| try ctx.allocator.dupe(u8, version) else null,
            .core_version = if (item.coreVersion) |core| try ctx.allocator.dupe(u8, core) else null,
            .ui_version = if (item.uiVersion) |ui| try ctx.allocator.dupe(u8, ui) else null,
            .device_family = if (item.deviceFamily) |family| try ctx.allocator.dupe(u8, family) else null,
            .model_identifier = if (item.modelIdentifier) |model| try ctx.allocator.dupe(u8, model) else null,
            .remote_ip = if (item.remoteIp) |ip| try ctx.allocator.dupe(u8, ip) else null,
            .caps = try dupStringList(ctx.allocator, item.caps),
            .commands = try dupStringList(ctx.allocator, item.commands),
            .path_env = if (item.pathEnv) |path| try ctx.allocator.dupe(u8, path) else null,
            .permissions_json = if (item.permissions) |perm| try stringifyJsonValue(ctx.allocator, perm) else null,
            .connected_at_ms = item.connectedAtMs,
            .connected = item.connected,
            .paired = item.paired,
        };
        filled = index + 1;
    }

    ctx.setNodesOwned(list);
    if (ctx.current_node) |node_id| {
        if (!nodeListHasId(ctx.nodes.items, node_id)) {
            ctx.clearCurrentNode();
        }
    }
}

fn handleNodeInvokeResponse(
    ctx: *state.ClientContext,
    payload: std.json.Value,
    command: ?[]const u8,
    raw: []const u8,
) !void {
    const rendered = try stringifyJsonValue(ctx.allocator, payload);
    ctx.setNodeResultOwned(rendered);
    recordNodeInvokeActivity(ctx, command, payload, raw) catch {};
    ctx.clearOperatorNotice();
}

fn handleNodeDescribeResponse(ctx: *state.ClientContext, payload: std.json.Value) !void {
    const node_id = extractNodeId(payload) orelse ctx.current_node;
    const rendered = try stringifyJsonValue(ctx.allocator, payload);
    if (node_id) |id| {
        try ctx.upsertNodeDescribeOwned(id, rendered);
    } else {
        ctx.setNodeResultOwned(rendered);
    }
    ctx.clearOperatorNotice();
}

fn handleExecApprovalResolveResponse(ctx: *state.ClientContext, payload: std.json.Value) !void {
    _ = payload;
    if (ctx.pending_approval_target_id) |target_id| {
        ctx.markApprovalResolvedOwned(
            target_id,
            ctx.pending_approval_decision,
            "local",
            std.time.milliTimestamp(),
        ) catch {};
        const denied = if (ctx.pending_approval_decision) |decision|
            std.mem.eql(u8, decision, "deny")
        else
            false;
        recordApprovalActivity(
            ctx,
            target_id,
            if (denied) "deny" else "approved",
            if (denied) .denied else .approved,
            if (denied) .warn else .info,
            null,
        ) catch {};
    }
    ctx.clearPendingApprovalResolveRequest();
    ctx.clearOperatorNotice();
}

fn handleExecApprovalRequested(ctx: *state.ClientContext, payload: ?std.json.Value) !void {
    const value = payload orelse return;
    const rendered = try stringifyJsonValue(ctx.allocator, value);
    errdefer ctx.allocator.free(rendered);

    var extracted = extractApprovalInfo(ctx.allocator, value);
    errdefer {
        if (extracted.id) |id| ctx.allocator.free(id);
        if (extracted.summary) |summary| ctx.allocator.free(summary);
        if (extracted.requested_by) |who| ctx.allocator.free(who);
    }
    const approval_id = extracted.id orelse try requests.makeRequestId(ctx.allocator);
    const summary = extracted.summary;
    const requested_at = extracted.requested_at_ms;
    const requested_by = extracted.requested_by;
    const can_resolve = extracted.id != null;

    const approval = types.ExecApproval{
        .id = approval_id,
        .payload_json = rendered,
        .summary = summary,
        .requested_at_ms = requested_at,
        .requested_by = requested_by,
        .resolved_at_ms = null,
        .resolved_by = null,
        .decision = null,
        .can_resolve = can_resolve,
    };
    errdefer {
        ctx.allocator.free(approval.id);
        ctx.allocator.free(approval.payload_json);
        if (approval.summary) |text| ctx.allocator.free(text);
        if (approval.requested_by) |who| ctx.allocator.free(who);
        if (approval.resolved_by) |who| ctx.allocator.free(who);
        if (approval.decision) |decision| ctx.allocator.free(decision);
    }
    extracted.id = null;
    extracted.summary = null;
    extracted.requested_by = null;
    try ctx.upsertApprovalOwned(approval);

    recordApprovalActivity(ctx, approval_id, summary orelse "Approval requested", .pending, .warn, rendered) catch {};

    if (!can_resolve) {
        ctx.setOperatorNotice("Approval request missing id; cannot resolve automatically.") catch {};
    }
}

fn handleExecApprovalResolved(ctx: *state.ClientContext, payload: ?std.json.Value) !void {
    const value = payload orelse return;
    const id = extractApprovalId(value) orelse return;

    const decision = extractApprovalDecision(value);
    const resolved_by = extractApprovalResolvedBy(value);
    const resolved_at_ms = extractApprovalResolvedAtMs(value);

    // This will also remove the pending approval when present.
    try ctx.markApprovalResolvedOwned(id, decision, resolved_by, resolved_at_ms);

    const status: state.ActivityStatus = if (decision) |d|
        if (std.mem.eql(u8, d, "deny")) .denied else .approved
    else
        .approved;
    const summary = if (decision) |d| d else "resolved";
    recordApprovalActivity(ctx, id, summary, status, if (status == .denied) .warn else .info, null) catch {};
}

fn handleChatEvent(ctx: *state.ClientContext, payload: ?std.json.Value) !void {
    const value = payload orelse return;
    var parsed = try messages.parsePayload(ctx.allocator, value, chat.ChatEventPayload);
    defer parsed.deinit();

    const event = parsed.value;
    const session_key = event.sessionKey;
    _ = try ctx.getOrCreateSessionState(session_key);

    if (std.mem.eql(u8, event.state, "delta")) {
        const text = if (event.message) |message_val|
            extractChatTextValue(ctx.allocator, message_val)
        else
            null;
        defer if (text) |value_text| ctx.allocator.free(value_text);
        if (text == null) return;

        if (ctx.findSessionState(session_key)) |state_ptr| {
            state_ptr.awaiting_reply = true;
            if (state_ptr.stream_run_id == null or !std.mem.eql(u8, state_ptr.stream_run_id.?, event.runId)) {
                try ctx.setSessionStreamRunId(session_key, event.runId);
            }
        }

        var msg = try buildStreamMessage(ctx.allocator, event.runId, text.?);
        errdefer freeChatMessageOwned(ctx.allocator, &msg);
        ctx.upsertSessionMessageOwned(session_key, msg) catch |err| {
            logger.warn("Failed to upsert stream message ({s})", .{@errorName(err)});
            freeChatMessageOwned(ctx.allocator, &msg);
        };
        recordChatRunActivity(ctx, event.runId, session_key, .running, .info, "Assistant streaming…") catch {};
        return;
    }

    var had_stream = false;
    if (ctx.findSessionState(session_key)) |state_ptr| {
        had_stream = state_ptr.stream_run_id != null and std.mem.eql(u8, state_ptr.stream_run_id.?, event.runId);
    }
    if (had_stream) {
        ctx.clearSessionStreamRunId(session_key);
    }
    ctx.clearSessionStreamText(session_key);
    if (ctx.findSessionState(session_key)) |state_ptr| {
        state_ptr.awaiting_reply = false;
    }

    if (std.mem.eql(u8, event.state, "error")) {
        if (event.errorMessage) |msg| {
            ctx.setError(msg) catch {};
            recordChatRunActivity(ctx, event.runId, session_key, .failed, .@"error", msg) catch {};
        } else {
            recordChatRunActivity(ctx, event.runId, session_key, .failed, .@"error", "Run failed") catch {};
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
            _ = ctx.removeSessionMessageById(session_key, stream_id);
        }
        const role_for_activity = parsed_msg.value.role;
        const content_for_activity = message.content;
        const upsert_ok = blk: {
            ctx.upsertSessionMessageOwned(session_key, message) catch |err| {
                logger.warn("Failed to upsert chat message ({s})", .{@errorName(err)});
                freeChatMessageOwned(ctx.allocator, &message);
                break :blk false;
            };
            break :blk true;
        };
        if (upsert_ok) {
            recordChatRunActivity(ctx, event.runId, session_key, .succeeded, .info, "Run completed") catch {};
            recordChatMessageActivity(ctx, event.runId, session_key, role_for_activity, content_for_activity) catch {};
        }
    }
}

const GatewayIdentitySignal = struct {
    kind: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

fn extractGatewayIdentity(payload: std.json.Value) ?GatewayIdentitySignal {
    if (payload != .object) return null;
    const payload_obj = payload.object;

    var identity_obj: ?std.json.ObjectMap = null;

    if (payload_obj.get("server")) |server_val| {
        if (server_val == .object) {
            if (server_val.object.get("identity")) |identity_val| {
                if (identity_val == .object) {
                    identity_obj = identity_val.object;
                }
            }
        }
    }

    if (identity_obj == null) {
        if (payload_obj.get("identity")) |identity_val| {
            if (identity_val == .object) {
                identity_obj = identity_val.object;
            }
        }
    }

    const obj = identity_obj orelse return null;
    return GatewayIdentitySignal{
        .kind = if (obj.get("kind")) |value| if (value == .string) value.string else null else null,
        .mode = if (obj.get("mode")) |value| if (value == .string) value.string else null else null,
        .source = if (obj.get("source")) |value| if (value == .string) value.string else null else null,
    };
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

fn extractGatewayMethods(allocator: std.mem.Allocator, payload: std.json.Value) !?[][]u8 {
    if (payload != .object) return null;
    const features_val = payload.object.get("features") orelse return null;
    if (features_val != .object) return null;
    const methods_val = features_val.object.get("methods") orelse return null;
    if (methods_val != .array) return null;

    var list = std.ArrayList([]u8).empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item);
        }
        list.deinit(allocator);
    }

    for (methods_val.array.items) |item| {
        if (item != .string) continue;
        try list.append(allocator, try allocator.dupe(u8, item.string));
    }

    const owned = try list.toOwnedSlice(allocator);
    list.deinit(allocator);
    return owned;
}

fn buildChatMessage(allocator: std.mem.Allocator, msg: chat.ChatHistoryMessage) !types.ChatMessage {
    const id = if (msg.id) |value| try allocator.dupe(u8, value) else try requests.makeRequestId(allocator);
    errdefer allocator.free(id);
    const role = try allocator.dupe(u8, msg.role);
    errdefer allocator.free(role);
    const content = try extractChatText(allocator, msg);
    errdefer allocator.free(content);
    const attachments = if (msg.attachments) |items| try buildChatAttachments(allocator, items) else null;
    errdefer {
        if (attachments) |list| {
            for (list) |*attachment| {
                allocator.free(attachment.kind);
                allocator.free(attachment.url);
                if (attachment.name) |name| allocator.free(name);
            }
            allocator.free(list);
        }
    }
    return .{
        .id = id,
        .role = role,
        .content = content,
        .timestamp = msg.timestamp orelse std.time.milliTimestamp(),
        .attachments = attachments,
    };
}

fn buildChatAttachments(
    allocator: std.mem.Allocator,
    attachments: []chat.ChatAttachment,
) ![]types.ChatAttachment {
    const list = try allocator.alloc(types.ChatAttachment, attachments.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*attachment| {
            allocator.free(attachment.kind);
            allocator.free(attachment.url);
            if (attachment.name) |name| allocator.free(name);
        }
        allocator.free(list);
    }
    for (attachments, 0..) |attachment, index| {
        list[index] = .{
            .kind = try allocator.dupe(u8, attachment.kind),
            .url = try allocator.dupe(u8, attachment.url),
            .name = if (attachment.name) |name| try allocator.dupe(u8, name) else null,
        };
        filled = index + 1;
    }
    return list;
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

fn messageListHasId(list: []const types.ChatMessage, id: []const u8) bool {
    for (list) |msg| {
        if (std.mem.eql(u8, msg.id, id)) return true;
    }
    return false;
}

fn cloneAttachmentExisting(allocator: std.mem.Allocator, attachment: types.ChatAttachment) !types.ChatAttachment {
    return .{
        .kind = try allocator.dupe(u8, attachment.kind),
        .url = try allocator.dupe(u8, attachment.url),
        .name = if (attachment.name) |name| try allocator.dupe(u8, name) else null,
    };
}

fn cloneChatMessageExisting(allocator: std.mem.Allocator, msg: types.ChatMessage) !types.ChatMessage {
    var attachments_copy: ?[]types.ChatAttachment = null;
    if (msg.attachments) |attachments| {
        const list = try allocator.alloc(types.ChatAttachment, attachments.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |*attachment| {
                allocator.free(attachment.kind);
                allocator.free(attachment.url);
                if (attachment.name) |name| allocator.free(name);
            }
            allocator.free(list);
        }
        for (attachments, 0..) |attachment, index| {
            list[index] = try cloneAttachmentExisting(allocator, attachment);
            filled = index + 1;
        }
        attachments_copy = list;
    }

    return .{
        .id = try allocator.dupe(u8, msg.id),
        .role = try allocator.dupe(u8, msg.role),
        .content = try allocator.dupe(u8, msg.content),
        .timestamp = msg.timestamp,
        .attachments = attachments_copy,
        .local_state = msg.local_state,
    };
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

fn freeNodeOwned(allocator: std.mem.Allocator, node: *types.Node) void {
    allocator.free(node.id);
    if (node.display_name) |name| allocator.free(name);
    if (node.platform) |platform| allocator.free(platform);
    if (node.version) |version| allocator.free(version);
    if (node.core_version) |core| allocator.free(core);
    if (node.ui_version) |ui| allocator.free(ui);
    if (node.device_family) |family| allocator.free(family);
    if (node.model_identifier) |model| allocator.free(model);
    if (node.remote_ip) |ip| allocator.free(ip);
    freeStringList(allocator, node.caps);
    freeStringList(allocator, node.commands);
    if (node.path_env) |path| allocator.free(path);
    if (node.permissions_json) |perm| allocator.free(perm);
}

fn freeSessionOwned(allocator: std.mem.Allocator, session: *types.Session) void {
    allocator.free(session.key);
    if (session.display_name) |name| allocator.free(name);
    if (session.label) |label| allocator.free(label);
    if (session.kind) |kind| allocator.free(kind);
    if (session.session_id) |id| allocator.free(id);
}

fn dupStringList(allocator: std.mem.Allocator, list: ?[]const []const u8) !?[]const []const u8 {
    const items = list orelse return null;
    if (items.len == 0) return null;
    const owned = try allocator.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |item| allocator.free(item);
        allocator.free(owned);
    }
    for (items, 0..) |item, index| {
        owned[index] = try allocator.dupe(u8, item);
        filled = index + 1;
    }
    return owned;
}

fn freeStringList(allocator: std.mem.Allocator, list: ?[]const []const u8) void {
    if (list) |items| {
        for (items) |item| {
            allocator.free(item);
        }
        allocator.free(items);
    }
}

fn nodeListHasId(list: []const types.Node, id: []const u8) bool {
    for (list) |node| {
        if (std.mem.eql(u8, node.id, id)) return true;
    }
    return false;
}

fn handleNodeHealthFrame(ctx: *state.ClientContext, payload: ?std.json.Value) !void {
    if (payload == null) return;
    const value = payload.?;
    if (value != .object) return;
    const obj = value.object;
    const node_id_val = obj.get("nodeId") orelse return;
    if (node_id_val != .string) return;

    const node_id = node_id_val.string;
    const rendered = try stringifyJsonValue(ctx.allocator, value);
    try ctx.upsertNodeHealthOwned(node_id, rendered);
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, writer);
    return try out.toOwnedSlice();
}

const ApprovalInfo = struct {
    id: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    requested_at_ms: ?i64 = null,
    requested_by: ?[]const u8 = null,
};

fn extractApprovalInfo(allocator: std.mem.Allocator, value: std.json.Value) ApprovalInfo {
    var info = ApprovalInfo{};
    if (value != .object) return info;
    const obj = value.object;
    if (obj.get("id")) |id_val| {
        if (id_val == .string) {
            info.id = allocator.dupe(u8, id_val.string) catch null;
        }
    } else if (obj.get("requestId")) |id_val| {
        if (id_val == .string) {
            info.id = allocator.dupe(u8, id_val.string) catch null;
        }
    }

    var request_obj: ?std.json.ObjectMap = null;
    if (obj.get("request")) |req_val| {
        if (req_val == .object) {
            request_obj = req_val.object;
        }
    }

    const command = if (request_obj) |req| blk: {
        if (req.get("command")) |cmd_val| {
            if (cmd_val == .string) break :blk cmd_val.string;
        }
        break :blk null;
    } else if (obj.get("command")) |cmd_val| if (cmd_val == .string) cmd_val.string else null else null;

    const node_id = if (request_obj) |req| blk: {
        if (req.get("nodeId")) |node_val| {
            if (node_val == .string) break :blk node_val.string;
        }
        break :blk null;
    } else if (obj.get("nodeId")) |node_val| if (node_val == .string) node_val.string else null else null;

    const resolved_path = if (request_obj) |req| blk: {
        if (req.get("resolvedPath")) |path_val| {
            if (path_val == .string) break :blk path_val.string;
        }
        break :blk null;
    } else if (obj.get("resolvedPath")) |path_val| if (path_val == .string) path_val.string else null else null;

    const host = if (request_obj) |req| blk: {
        if (req.get("host")) |host_val| {
            if (host_val == .string) break :blk host_val.string;
        }
        break :blk null;
    } else if (obj.get("host")) |host_val| if (host_val == .string) host_val.string else null else null;

    const cwd = if (request_obj) |req| blk: {
        if (req.get("cwd")) |cwd_val| {
            if (cwd_val == .string) break :blk cwd_val.string;
        }
        break :blk null;
    } else if (obj.get("cwd")) |cwd_val| if (cwd_val == .string) cwd_val.string else null else null;

    const requested_by = if (request_obj) |req| blk: {
        if (req.get("requestedBy")) |val| if (val == .string) break :blk val.string;
        if (req.get("requestedByName")) |val| if (val == .string) break :blk val.string;
        if (req.get("sessionKey")) |val| if (val == .string) break :blk val.string;
        if (req.get("clientId")) |val| if (val == .string) break :blk val.string;
        if (req.get("actor")) |actor| {
            if (actor == .object) {
                if (actor.object.get("displayName")) |name| if (name == .string) break :blk name.string;
                if (actor.object.get("name")) |name| if (name == .string) break :blk name.string;
                if (actor.object.get("id")) |name| if (name == .string) break :blk name.string;
            }
        }
        break :blk null;
    } else blk: {
        if (obj.get("requestedBy")) |val| if (val == .string) break :blk val.string;
        if (obj.get("requestedByName")) |val| if (val == .string) break :blk val.string;
        if (obj.get("sessionKey")) |val| if (val == .string) break :blk val.string;
        if (obj.get("clientId")) |val| if (val == .string) break :blk val.string;
        if (obj.get("actor")) |actor| {
            if (actor == .object) {
                if (actor.object.get("displayName")) |name| if (name == .string) break :blk name.string;
                if (actor.object.get("name")) |name| if (name == .string) break :blk name.string;
                if (actor.object.get("id")) |name| if (name == .string) break :blk name.string;
            }
        }
        break :blk null;
    };

    if (requested_by) |who| {
        info.requested_by = allocator.dupe(u8, who) catch null;
    } else if (node_id) |fallback| {
        info.requested_by = allocator.dupe(u8, fallback) catch null;
    }

    if (command != null or node_id != null) {
        const command_text = command orelse "unknown";
        const context_text = resolved_path orelse host orelse cwd orelse node_id;
        if (context_text) |ctx_text| {
            info.summary = std.fmt.allocPrint(allocator, "{s} · {s}", .{ ctx_text, command_text }) catch null;
        } else {
            info.summary = allocator.dupe(u8, command_text) catch null;
        }
    }

    if (obj.get("createdAtMs")) |ts_val| {
        if (ts_val == .integer) info.requested_at_ms = ts_val.integer;
    } else if (obj.get("requestedAtMs")) |ts_val| {
        if (ts_val == .integer) info.requested_at_ms = ts_val.integer;
    } else if (obj.get("ts")) |ts_val| {
        if (ts_val == .integer) info.requested_at_ms = ts_val.integer;
    }

    return info;
}

fn extractApprovalId(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const obj = value.object;
    if (obj.get("id")) |id_val| {
        if (id_val == .string) return id_val.string;
    }
    if (obj.get("requestId")) |id_val| {
        if (id_val == .string) return id_val.string;
    }
    return null;
}

fn extractApprovalDecision(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const obj = value.object;
    if (obj.get("decision")) |val| {
        if (val == .string) return val.string;
    }
    if (obj.get("result")) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn extractApprovalResolvedBy(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const obj = value.object;

    if (obj.get("resolvedBy")) |val| {
        if (val == .string) return val.string;
    }
    if (obj.get("operator")) |val| {
        if (val == .object) {
            const op = val.object;
            if (op.get("displayName")) |name| if (name == .string) return name.string;
            if (op.get("name")) |name| if (name == .string) return name.string;
            if (op.get("id")) |id_val| if (id_val == .string) return id_val.string;
        }
    }

    if (obj.get("client")) |val| {
        if (val == .object) {
            const client = val.object;
            if (client.get("displayName")) |name| if (name == .string) return name.string;
            if (client.get("id")) |id_val| if (id_val == .string) return id_val.string;
        }
    }

    return null;
}

fn extractApprovalResolvedAtMs(value: std.json.Value) ?i64 {
    if (value != .object) return null;
    const obj = value.object;
    if (obj.get("resolvedAtMs")) |val| {
        if (val == .integer) return val.integer;
    }
    if (obj.get("ts")) |val| {
        if (val == .integer) return val.integer;
    }
    if (obj.get("createdAtMs")) |val| {
        if (val == .integer) return val.integer;
    }
    return null;
}

fn extractNodeId(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const obj = value.object;
    if (obj.get("nodeId")) |node_val| {
        if (node_val == .string) return node_val.string;
    }
    if (obj.get("node")) |node_val| {
        if (node_val == .object) {
            if (node_val.object.get("nodeId")) |inner| {
                if (inner == .string) return inner.string;
            }
            if (node_val.object.get("id")) |inner| {
                if (inner == .string) return inner.string;
            }
        }
    }
    return null;
}

const ActivityInput = struct {
    key: []const u8,
    title: []const u8,
    summary: ?[]const u8 = null,
    source: state.ActivitySource,
    severity: state.ActivitySeverity,
    scope: state.ActivityScope = .background,
    status: state.ActivityStatus = .info,
    run_id: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    process_session_id: ?[]const u8 = null,
    conversation_session: ?[]const u8 = null,
    params: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    raw_event_json: ?[]const u8 = null,
};

fn appendActivity(ctx: *state.ClientContext, input: ActivityInput) !void {
    const now = std.time.milliTimestamp();
    const entry = state.ActivityEntry{
        .key = try ctx.allocator.dupe(u8, input.key),
        .title = try ctx.allocator.dupe(u8, input.title),
        .summary = if (input.summary) |value| try dupClipped(ctx.allocator, value, 4096, 80) else null,
        .source = input.source,
        .severity = input.severity,
        .scope = input.scope,
        .status = input.status,
        .run_id = if (input.run_id) |value| try ctx.allocator.dupe(u8, value) else null,
        .tool_call_id = if (input.tool_call_id) |value| try ctx.allocator.dupe(u8, value) else null,
        .process_session_id = if (input.process_session_id) |value| try ctx.allocator.dupe(u8, value) else null,
        .conversation_session = if (input.conversation_session) |value| try ctx.allocator.dupe(u8, value) else null,
        .started_at_ms = now,
        .updated_at_ms = now,
        .update_count = 1,
        .last_running_notice_ms = 0,
        .params = if (input.params) |value| try dupClipped(ctx.allocator, value, 16_384, 240) else null,
        .stdout = if (input.stdout) |value| try dupClipped(ctx.allocator, value, 24_576, 280) else null,
        .stderr = if (input.stderr) |value| try dupClipped(ctx.allocator, value, 24_576, 280) else null,
        .raw_event_json = if (input.raw_event_json) |value| try dupClipped(ctx.allocator, value, 32_768, 480) else null,
    };
    errdefer freeActivityOwned(ctx.allocator, &entry);

    try ctx.upsertActivityOwned(entry);
}

fn freeActivityOwned(allocator: std.mem.Allocator, entry: *const state.ActivityEntry) void {
    allocator.free(entry.key);
    allocator.free(entry.title);
    if (entry.summary) |value| allocator.free(value);
    if (entry.run_id) |value| allocator.free(value);
    if (entry.tool_call_id) |value| allocator.free(value);
    if (entry.process_session_id) |value| allocator.free(value);
    if (entry.conversation_session) |value| allocator.free(value);
    if (entry.params) |value| allocator.free(value);
    if (entry.stdout) |value| allocator.free(value);
    if (entry.stderr) |value| allocator.free(value);
    if (entry.raw_event_json) |value| allocator.free(value);
}

fn dupClipped(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize, max_lines: usize) ![]u8 {
    const total_lines = countLines(text);
    const needs_clip = text.len > max_bytes or total_lines > max_lines;
    if (!needs_clip) {
        return allocator.dupe(u8, text);
    }

    var line_count: usize = 0;
    var end_index: usize = 0;
    while (end_index < text.len and end_index < max_bytes) : (end_index += 1) {
        if (text[end_index] == '\n') {
            line_count += 1;
            if (line_count >= max_lines) {
                end_index += 1;
                break;
            }
        }
    }

    const clipped = text[0..@min(end_index, text.len)];
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\n… [truncated preview: showing {d}/{d} bytes, {d}/{d} lines]",
        .{ clipped, clipped.len, text.len, @min(line_count, max_lines), total_lines },
    );
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var lines: usize = 1;
    for (text) |ch| {
        if (ch == '\n') lines += 1;
    }
    return lines;
}

fn recordSystemActivity(
    ctx: *state.ClientContext,
    key: []const u8,
    title: []const u8,
    summary: ?[]const u8,
    severity: state.ActivitySeverity,
    status: state.ActivityStatus,
    raw: ?[]const u8,
) !void {
    try appendActivity(ctx, .{
        .key = key,
        .title = title,
        .summary = summary,
        .source = .system,
        .severity = severity,
        .scope = .background,
        .status = status,
        .raw_event_json = raw,
    });
}

fn recordApprovalActivity(
    ctx: *state.ClientContext,
    approval_id: []const u8,
    summary: []const u8,
    status: state.ActivityStatus,
    severity: state.ActivitySeverity,
    raw_json: ?[]const u8,
) !void {
    var key_buf: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "approval:{s}", .{approval_id}) catch "approval";
    try appendActivity(ctx, .{
        .key = key,
        .title = "Execution approval",
        .summary = summary,
        .source = .approval,
        .severity = severity,
        .scope = .background,
        .status = status,
        .tool_call_id = approval_id,
        .raw_event_json = raw_json,
    });
}

fn recordChatRunActivity(
    ctx: *state.ClientContext,
    run_id: []const u8,
    session_key: []const u8,
    status: state.ActivityStatus,
    severity: state.ActivitySeverity,
    summary: []const u8,
) !void {
    var key_buf: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "run:{s}", .{run_id}) catch "run";
    try appendActivity(ctx, .{
        .key = key,
        .title = "Chat run",
        .summary = summary,
        .source = .tool,
        .severity = severity,
        .scope = .conversation,
        .status = status,
        .run_id = run_id,
        .conversation_session = session_key,
    });
}

fn recordChatMessageActivity(
    ctx: *state.ClientContext,
    run_id: []const u8,
    session_key: []const u8,
    role: []const u8,
    content: []const u8,
) !void {
    if (!std.mem.startsWith(u8, role, "tool") and !std.mem.eql(u8, role, "toolResult")) return;

    const lower_failed = containsCaseInsensitive(content, "failed") or
        containsCaseInsensitive(content, "error") or
        containsCaseInsensitive(content, "denied") or
        containsCaseInsensitive(content, "exit code") or
        containsCaseInsensitive(content, "\"ok\":false") or
        containsCaseInsensitive(content, "\"status\":\"failed\"");

    var key_buf: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "run:{s}:tool", .{run_id}) catch "run:tool";
    try appendActivity(ctx, .{
        .key = key,
        .title = "Tool output",
        .summary = content,
        .source = .tool,
        .severity = if (lower_failed) .warn else .info,
        .scope = .conversation,
        .status = if (lower_failed) .failed else .succeeded,
        .run_id = run_id,
        .conversation_session = session_key,
        .stdout = content,
    });
}

fn recordResponseFailureActivity(
    ctx: *state.ClientContext,
    response_id: []const u8,
    err: ?gateway.GatewayError,
    raw: []const u8,
) !void {
    var key_buf: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "response:{s}", .{response_id}) catch "response:error";
    const summary = if (err) |e| e.message else "Gateway request failed";
    try appendActivity(ctx, .{
        .key = key,
        .title = "Gateway response",
        .summary = summary,
        .source = .system,
        .severity = .@"error",
        .scope = .background,
        .status = .failed,
        .raw_event_json = raw,
    });
}

fn recordNodeInvokeFailureActivity(
    ctx: *state.ClientContext,
    command: ?[]const u8,
    err: ?gateway.GatewayError,
    raw: []const u8,
) !void {
    const cmd = command orelse "node.invoke";
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "node.invoke:{s}", .{cmd}) catch "node.invoke";
    const summary = if (err) |e| e.message else "Node invoke failed";
    try appendActivity(ctx, .{
        .key = key,
        .title = cmd,
        .summary = summary,
        .source = if (std.mem.startsWith(u8, cmd, "process.")) .process else .tool,
        .severity = .@"error",
        .scope = .background,
        .status = .failed,
        .raw_event_json = raw,
    });
}

fn recordNodeInvokeActivity(
    ctx: *state.ClientContext,
    command: ?[]const u8,
    payload: std.json.Value,
    raw: []const u8,
) !void {
    const cmd = command orelse "node.invoke";
    const source: state.ActivitySource = if (std.mem.startsWith(u8, cmd, "process.")) .process else .tool;

    var key_buf: [256]u8 = undefined;
    var process_id: ?[]const u8 = null;
    if (payload == .object) {
        if (payload.object.get("processId")) |pid| {
            if (pid == .string) {
                process_id = pid.string;
            }
        }
    }

    const key = if (process_id) |pid|
        std.fmt.bufPrint(&key_buf, "process:{s}", .{pid}) catch "process"
    else
        std.fmt.bufPrint(&key_buf, "node.invoke:{s}", .{cmd}) catch "node.invoke";

    const status = parseNodeInvokeStatus(payload);
    const severity: state.ActivitySeverity = switch (status) {
        .failed, .denied => .warn,
        else => .info,
    };

    const stdout = extractPayloadString(payload, "stdout");
    const stderr = extractPayloadString(payload, "stderr");
    const summary = if (extractPayloadString(payload, "status")) |s| s else cmd;

    try appendActivity(ctx, .{
        .key = key,
        .title = cmd,
        .summary = summary,
        .source = source,
        .severity = severity,
        .scope = .background,
        .status = status,
        .process_session_id = process_id,
        .stdout = stdout,
        .stderr = stderr,
        .raw_event_json = raw,
    });
}

fn parseNodeInvokeStatus(payload: std.json.Value) state.ActivityStatus {
    const status_raw = extractPayloadString(payload, "status") orelse return .succeeded;
    if (std.ascii.eqlIgnoreCase(status_raw, "running")) return .running;
    if (std.ascii.eqlIgnoreCase(status_raw, "pending")) return .pending;
    if (std.ascii.eqlIgnoreCase(status_raw, "failed") or std.ascii.eqlIgnoreCase(status_raw, "error")) return .failed;
    if (std.ascii.eqlIgnoreCase(status_raw, "denied")) return .denied;
    return .succeeded;
}

fn extractPayloadString(payload: std.json.Value, key: []const u8) ?[]const u8 {
    if (payload != .object) return null;
    if (payload.object.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}
