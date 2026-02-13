const std = @import("std");
const state = @import("state.zig");
const types = @import("../protocol/types.zig");
const ziggy = @import("ziggy-core");
const gateway = ziggy.protocol.gateway;
const messages = ziggy.protocol.messages;
const sessions = @import("../protocol/sessions.zig");
const chat = ziggy.protocol.chat;
const nodes = @import("../protocol/nodes.zig");
const workboard = @import("../protocol/workboard.zig");
const requests = ziggy.protocol.requests;
const logger = ziggy.utils.logger;

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
        const is_workboard = ctx.pending_workboard_request_id != null and
            std.mem.eql(u8, ctx.pending_workboard_request_id.?, response_id);
        const is_node_invoke = ctx.pending_node_invoke_request_id != null and
            std.mem.eql(u8, ctx.pending_node_invoke_request_id.?, response_id);
        const is_node_describe = ctx.pending_node_describe_request_id != null and
            std.mem.eql(u8, ctx.pending_node_describe_request_id.?, response_id);
        const is_agents_create = ctx.pending_agents_create_request_id != null and
            std.mem.eql(u8, ctx.pending_agents_create_request_id.?, response_id);
        const is_agents_update = ctx.pending_agents_update_request_id != null and
            std.mem.eql(u8, ctx.pending_agents_update_request_id.?, response_id);
        const is_agents_delete = ctx.pending_agents_delete_request_id != null and
            std.mem.eql(u8, ctx.pending_agents_delete_request_id.?, response_id);
        const is_approval_resolve = ctx.pending_approval_resolve_request_id != null and
            std.mem.eql(u8, ctx.pending_approval_resolve_request_id.?, response_id);

        if (!frame.value.ok) {
            if (is_sessions) ctx.clearPendingSessionsRequest();
            if (is_history) ctx.clearPendingHistoryById(response_id);
            if (is_send) ctx.resolvePendingSendRequest(false);
            if (is_nodes) ctx.clearPendingNodesRequest();
            if (is_workboard) ctx.clearPendingWorkboardRequest();
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

            if (is_workboard) {
                ctx.clearPendingWorkboardRequest();
                handleWorkboardList(ctx, payload) catch |err| {
                    logger.warn("workboard.list handling failed ({s})", .{@errorName(err)});
                };
                return null;
            }

            if (is_node_invoke) {
                ctx.clearPendingNodeInvokeRequest();
                handleNodeInvokeResponse(ctx, payload) catch |err| {
                    logger.warn("node.invoke handling failed ({s})", .{@errorName(err)});
                };
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

        // Some responses may omit a payload; ensure pending request IDs are still resolved.
        if (is_send) {
            ctx.resolvePendingSendRequest(true);
        }
        if (is_workboard) {
            ctx.clearPendingWorkboardRequest();
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

fn handleWorkboardList(ctx: *state.ClientContext, payload: std.json.Value) !void {
    var parsed = try messages.parsePayload(ctx.allocator, payload, workboard.WorkboardListResult);
    defer parsed.deinit();

    const items = parsed.value.items orelse parsed.value.rows orelse parsed.value.work orelse {
        logger.warn("workboard.list payload missing items", .{});
        return;
    };

    const list = try ctx.allocator.alloc(types.WorkboardItem, items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |*item| {
            freeWorkboardItemOwned(ctx.allocator, item);
        }
        ctx.allocator.free(list);
    }

    for (items, 0..) |item, index| {
        list[index] = .{
            .id = try ctx.allocator.dupe(u8, item.id),
            .kind = if (item.kind) |value| try ctx.allocator.dupe(u8, value) else null,
            .status = if (item.status) |value| try ctx.allocator.dupe(u8, value) else null,
            .title = if (item.title) |value| try ctx.allocator.dupe(u8, value) else null,
            .summary = if (item.summary) |value| try ctx.allocator.dupe(u8, value) else null,
            .owner = if (item.owner) |value| try ctx.allocator.dupe(u8, value) else null,
            .agent_id = if (item.agentId) |value| try ctx.allocator.dupe(u8, value) else null,
            .parent_id = if (item.parentId) |value| try ctx.allocator.dupe(u8, value) else null,
            .cron_key = if (item.cronKey) |value| try ctx.allocator.dupe(u8, value) else null,
            .created_at_ms = item.createdAtMs,
            .updated_at_ms = item.updatedAtMs,
            .due_at_ms = item.dueAtMs,
            .payload_json = if (item.payload) |value| try stringifyJsonValue(ctx.allocator, value) else null,
        };
        filled = index + 1;
    }

    ctx.setWorkboardItemsOwned(list);
}

fn handleNodeInvokeResponse(ctx: *state.ClientContext, payload: std.json.Value) !void {
    const rendered = try stringifyJsonValue(ctx.allocator, payload);
    ctx.setNodeResultOwned(rendered);
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
        ctx.upsertSessionMessageOwned(session_key, message) catch |err| {
            logger.warn("Failed to upsert chat message ({s})", .{@errorName(err)});
            freeChatMessageOwned(ctx.allocator, &message);
        };
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

fn freeWorkboardItemOwned(allocator: std.mem.Allocator, item: *types.WorkboardItem) void {
    allocator.free(item.id);
    if (item.kind) |value| allocator.free(value);
    if (item.status) |value| allocator.free(value);
    if (item.title) |value| allocator.free(value);
    if (item.summary) |value| allocator.free(value);
    if (item.owner) |value| allocator.free(value);
    if (item.agent_id) |value| allocator.free(value);
    if (item.parent_id) |value| allocator.free(value);
    if (item.cron_key) |value| allocator.free(value);
    if (item.payload_json) |value| allocator.free(value);
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
