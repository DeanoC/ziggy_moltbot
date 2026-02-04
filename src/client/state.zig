const std = @import("std");
const types = @import("../protocol/types.zig");
const update_checker = @import("update_checker.zig");

pub const ClientState = enum {
    disconnected,
    connecting,
    authenticating,
    connected,
    error_state,
};

pub const NodeDescribe = struct {
    node_id: []const u8,
    payload_json: []const u8,
    updated_at_ms: i64,
};

pub const ChatSessionState = struct {
    messages: std.ArrayList(types.ChatMessage),
    stream_text: ?[]const u8 = null,
    stream_run_id: ?[]const u8 = null,
    pending_history_request_id: ?[]const u8 = null,
    messages_loading: bool = false,
    history_loaded: bool = false,

    pub fn init() ChatSessionState {
        return .{ .messages = std.ArrayList(types.ChatMessage).empty };
    }
};

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    state: ClientState,
    current_session: ?[]const u8,
    sessions: std.ArrayList(types.Session),
    session_states: std.StringHashMap(ChatSessionState),
    current_node: ?[]const u8,
    nodes: std.ArrayList(types.Node),
    node_describes: std.ArrayList(NodeDescribe),
    approvals: std.ArrayList(types.ExecApproval),
    users: std.ArrayList(types.User),
    sessions_loading: bool = false,
    nodes_loading: bool = false,
    pending_sessions_request_id: ?[]const u8 = null,
    pending_send_request_id: ?[]const u8 = null,
    pending_nodes_request_id: ?[]const u8 = null,
    pending_node_invoke_request_id: ?[]const u8 = null,
    pending_node_describe_request_id: ?[]const u8 = null,
    pending_approval_resolve_request_id: ?[]const u8 = null,
    pending_approval_target_id: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    operator_notice: ?[]const u8 = null,
    node_result: ?[]const u8 = null,
    sessions_updated: bool = false,
    update_state: update_checker.UpdateState = .{},

    pub fn init(allocator: std.mem.Allocator) !ClientContext {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .current_session = null,
            .sessions = std.ArrayList(types.Session).empty,
            .session_states = std.StringHashMap(ChatSessionState).init(allocator),
            .current_node = null,
            .nodes = std.ArrayList(types.Node).empty,
            .node_describes = std.ArrayList(NodeDescribe).empty,
            .approvals = std.ArrayList(types.ExecApproval).empty,
            .users = std.ArrayList(types.User).empty,
            .sessions_loading = false,
            .nodes_loading = false,
            .pending_sessions_request_id = null,
            .pending_send_request_id = null,
            .pending_nodes_request_id = null,
            .pending_node_invoke_request_id = null,
            .pending_node_describe_request_id = null,
            .pending_approval_resolve_request_id = null,
            .pending_approval_target_id = null,
            .last_error = null,
            .operator_notice = null,
            .node_result = null,
            .sessions_updated = false,
            .update_state = .{},
        };
    }

    pub fn deinit(self: *ClientContext) void {
        self.update_state.deinit(self.allocator);
        if (self.current_session) |session| {
            self.allocator.free(session);
            self.current_session = null;
        }
        self.clearPendingRequests();
        self.clearError();
        self.clearOperatorNotice();
        self.clearNodeResult();
        self.clearCurrentNode();
        self.clearApprovals();
        self.clearNodeDescribes();
        for (self.sessions.items) |*session| {
            freeSession(self.allocator, session);
        }
        self.clearAllSessionStates();
        self.session_states.deinit();
        for (self.nodes.items) |*node| {
            freeNode(self.allocator, node);
        }
        for (self.users.items) |*user| {
            freeUser(self.allocator, user);
        }
        self.sessions.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.node_describes.deinit(self.allocator);
        self.approvals.deinit(self.allocator);
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

    pub fn setNodesOwned(self: *ClientContext, nodes: []types.Node) void {
        clearNodesInternal(self);
        self.nodes.deinit(self.allocator);
        self.nodes = std.ArrayList(types.Node).fromOwnedSlice(nodes);
    }

    pub fn findSessionState(self: *ClientContext, session_key: []const u8) ?*ChatSessionState {
        return self.session_states.getPtr(session_key);
    }

    pub fn getOrCreateSessionState(self: *ClientContext, session_key: []const u8) !*ChatSessionState {
        if (self.session_states.getPtr(session_key)) |state| return state;
        const key_copy = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(key_copy);
        try self.session_states.put(key_copy, ChatSessionState.init());
        return self.session_states.getPtr(key_copy).?;
    }

    pub fn clearSessionState(self: *ClientContext, session_key: []const u8) void {
        if (self.session_states.fetchRemove(session_key)) |entry| {
            var state = entry.value;
            deinitSessionState(self.allocator, &state);
            self.allocator.free(entry.key);
        }
    }

    pub fn clearAllSessionStates(self: *ClientContext) void {
        var it = self.session_states.iterator();
        while (it.next()) |entry| {
            deinitSessionState(self.allocator, entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.session_states.clearRetainingCapacity();
    }

    pub fn setSessionMessagesOwned(self: *ClientContext, session_key: []const u8, messages: []types.ChatMessage) !void {
        var state = try self.getOrCreateSessionState(session_key);
        clearMessagesInState(self.allocator, state);
        state.messages.deinit(self.allocator);
        state.messages = std.ArrayList(types.ChatMessage).fromOwnedSlice(messages);
        state.history_loaded = true;
    }

    pub fn upsertSessionMessage(self: *ClientContext, session_key: []const u8, msg: types.ChatMessage) !void {
        var state = try self.getOrCreateSessionState(session_key);
        try upsertMessageInList(self.allocator, &state.messages, msg);
    }

    pub fn upsertSessionMessageOwned(self: *ClientContext, session_key: []const u8, msg: types.ChatMessage) !void {
        var state = try self.getOrCreateSessionState(session_key);
        try upsertMessageOwnedInList(self.allocator, &state.messages, msg);
    }

    pub fn removeSessionMessageById(self: *ClientContext, session_key: []const u8, id: []const u8) bool {
        if (self.session_states.getPtr(session_key)) |state| {
            return removeMessageByIdInList(self.allocator, &state.messages, id);
        }
        return false;
    }

    pub fn setSessionStreamRunId(self: *ClientContext, session_key: []const u8, run_id: []const u8) !void {
        var state = try self.getOrCreateSessionState(session_key);
        if (state.stream_run_id) |existing| {
            if (std.mem.eql(u8, existing, run_id)) return;
            self.allocator.free(existing);
        }
        state.stream_run_id = try self.allocator.dupe(u8, run_id);
    }

    pub fn clearSessionStreamRunId(self: *ClientContext, session_key: []const u8) void {
        if (self.session_states.getPtr(session_key)) |state| {
            if (state.stream_run_id) |value| {
                self.allocator.free(value);
                state.stream_run_id = null;
            }
        }
    }

    pub fn setSessionStreamText(self: *ClientContext, session_key: []const u8, text: []const u8) !void {
        var state = try self.getOrCreateSessionState(session_key);
        if (state.stream_text) |existing| {
            self.allocator.free(existing);
        }
        state.stream_text = try self.allocator.dupe(u8, text);
    }

    pub fn clearSessionStreamText(self: *ClientContext, session_key: []const u8) void {
        if (self.session_states.getPtr(session_key)) |state| {
            if (state.stream_text) |value| {
                self.allocator.free(value);
                state.stream_text = null;
            }
        }
    }

    pub fn clearSessionStream(self: *ClientContext, session_key: []const u8) void {
        self.clearSessionStreamRunId(session_key);
        self.clearSessionStreamText(session_key);
    }

    pub fn setPendingHistoryRequestForSession(self: *ClientContext, session_key: []const u8, id: []const u8) !void {
        var state = try self.getOrCreateSessionState(session_key);
        if (state.pending_history_request_id) |pending| {
            self.allocator.free(pending);
        }
        state.pending_history_request_id = id;
        state.messages_loading = true;
    }

    pub fn clearPendingHistoryRequestForSession(self: *ClientContext, session_key: []const u8) void {
        if (self.session_states.getPtr(session_key)) |state| {
            if (state.pending_history_request_id) |pending| {
                self.allocator.free(pending);
            }
            state.pending_history_request_id = null;
            state.messages_loading = false;
        }
    }

    pub fn clearPendingHistoryById(self: *ClientContext, id: []const u8) void {
        var it = self.session_states.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (state.pending_history_request_id) |pending| {
                if (std.mem.eql(u8, pending, id)) {
                    self.allocator.free(pending);
                    state.pending_history_request_id = null;
                    state.messages_loading = false;
                    return;
                }
            }
        }
    }

    pub fn findSessionForPendingHistory(self: *ClientContext, id: []const u8) ?[]const u8 {
        var it = self.session_states.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (state.pending_history_request_id) |pending| {
                if (std.mem.eql(u8, pending, id)) return entry.key_ptr.*;
            }
        }
        return null;
    }

    pub fn markSessionsUpdated(self: *ClientContext) void {
        self.sessions_updated = true;
    }

    pub fn clearSessionsUpdated(self: *ClientContext) void {
        self.sessions_updated = false;
    }

    pub fn removeSessionByKey(self: *ClientContext, key: []const u8) bool {
        var index: usize = 0;
        while (index < self.sessions.items.len) : (index += 1) {
            if (std.mem.eql(u8, self.sessions.items[index].key, key)) {
                var removed = self.sessions.orderedRemove(index);
                freeSession(self.allocator, &removed);
                return true;
            }
        }
        return false;
    }

    pub fn upsertNodeDescribeOwned(self: *ClientContext, node_id: []const u8, payload_json: []u8) !void {
        for (self.node_describes.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.node_id, node_id)) {
                freeNodeDescribe(self.allocator, existing);
                self.node_describes.items[index] = .{
                    .node_id = try self.allocator.dupe(u8, node_id),
                    .payload_json = payload_json,
                    .updated_at_ms = std.time.milliTimestamp(),
                };
                return;
            }
        }
        try self.node_describes.append(self.allocator, .{
            .node_id = try self.allocator.dupe(u8, node_id),
            .payload_json = payload_json,
            .updated_at_ms = std.time.milliTimestamp(),
        });
    }

    pub fn removeNodeDescribeById(self: *ClientContext, node_id: []const u8) bool {
        var index: usize = 0;
        while (index < self.node_describes.items.len) : (index += 1) {
            if (std.mem.eql(u8, self.node_describes.items[index].node_id, node_id)) {
                var removed = self.node_describes.orderedRemove(index);
                freeNodeDescribe(self.allocator, &removed);
                return true;
            }
        }
        return false;
    }

    pub fn upsertApprovalOwned(self: *ClientContext, approval: types.ExecApproval) !void {
        for (self.approvals.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.id, approval.id)) {
                freeApproval(self.allocator, existing);
                self.approvals.items[index] = approval;
                return;
            }
        }
        try self.approvals.append(self.allocator, approval);
    }

    pub fn removeApprovalById(self: *ClientContext, id: []const u8) bool {
        var index: usize = 0;
        while (index < self.approvals.items.len) : (index += 1) {
            if (std.mem.eql(u8, self.approvals.items[index].id, id)) {
                var removed = self.approvals.orderedRemove(index);
                freeApproval(self.allocator, &removed);
                return true;
            }
        }
        return false;
    }

    pub fn clearMessages(self: *ClientContext) void {
        self.clearAllSessionStates();
    }

    pub fn clearNodes(self: *ClientContext) void {
        clearNodesInternal(self);
    }

    pub fn clearNodeDescribes(self: *ClientContext) void {
        for (self.node_describes.items) |*describe| {
            freeNodeDescribe(self.allocator, describe);
        }
        self.node_describes.clearRetainingCapacity();
    }

    pub fn clearApprovals(self: *ClientContext) void {
        for (self.approvals.items) |*approval| {
            freeApproval(self.allocator, approval);
        }
        self.approvals.clearRetainingCapacity();
    }

    pub fn setCurrentSession(self: *ClientContext, key: []const u8) !void {
        if (self.current_session) |session| {
            if (std.mem.eql(u8, session, key)) return;
            self.allocator.free(session);
        }
        self.current_session = try self.allocator.dupe(u8, key);
    }

    pub fn setCurrentNode(self: *ClientContext, node_id: []const u8) !void {
        if (self.current_node) |current| {
            if (std.mem.eql(u8, current, node_id)) return;
            self.allocator.free(current);
        }
        self.current_node = try self.allocator.dupe(u8, node_id);
    }

    pub fn clearCurrentNode(self: *ClientContext) void {
        if (self.current_node) |node_id| {
            self.allocator.free(node_id);
            self.current_node = null;
        }
    }

    pub fn removeMessageById(self: *ClientContext, session_key: []const u8, id: []const u8) bool {
        return self.removeSessionMessageById(session_key, id);
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

    pub fn clearAllPendingHistoryRequests(self: *ClientContext) void {
        var it = self.session_states.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (state.pending_history_request_id) |pending| {
                self.allocator.free(pending);
            }
            state.pending_history_request_id = null;
            state.messages_loading = false;
        }
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

    pub fn setPendingNodesRequest(self: *ClientContext, id: []const u8) void {
        if (self.pending_nodes_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_nodes_request_id = id;
        self.nodes_loading = true;
    }

    pub fn clearPendingNodesRequest(self: *ClientContext) void {
        if (self.pending_nodes_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_nodes_request_id = null;
        self.nodes_loading = false;
    }

    pub fn setPendingNodeInvokeRequest(self: *ClientContext, id: []const u8) void {
        if (self.pending_node_invoke_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_node_invoke_request_id = id;
    }

    pub fn clearPendingNodeInvokeRequest(self: *ClientContext) void {
        if (self.pending_node_invoke_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_node_invoke_request_id = null;
    }

    pub fn setPendingNodeDescribeRequest(self: *ClientContext, id: []const u8) void {
        if (self.pending_node_describe_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_node_describe_request_id = id;
    }

    pub fn clearPendingNodeDescribeRequest(self: *ClientContext) void {
        if (self.pending_node_describe_request_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_node_describe_request_id = null;
    }

    pub fn setPendingApprovalResolveRequest(self: *ClientContext, id: []const u8, target_id: []const u8) void {
        if (self.pending_approval_resolve_request_id) |pending| {
            self.allocator.free(pending);
        }
        if (self.pending_approval_target_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_approval_resolve_request_id = id;
        self.pending_approval_target_id = target_id;
    }

    pub fn clearPendingApprovalResolveRequest(self: *ClientContext) void {
        if (self.pending_approval_resolve_request_id) |pending| {
            self.allocator.free(pending);
        }
        if (self.pending_approval_target_id) |pending| {
            self.allocator.free(pending);
        }
        self.pending_approval_resolve_request_id = null;
        self.pending_approval_target_id = null;
    }

    pub fn clearPendingRequests(self: *ClientContext) void {
        self.clearPendingSessionsRequest();
        self.clearAllPendingHistoryRequests();
        self.clearPendingSendRequest();
        self.clearPendingNodesRequest();
        self.clearPendingNodeInvokeRequest();
        self.clearPendingNodeDescribeRequest();
        self.clearPendingApprovalResolveRequest();
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

    pub fn setOperatorNotice(self: *ClientContext, message: []const u8) !void {
        self.clearOperatorNotice();
        self.operator_notice = try self.allocator.dupe(u8, message);
    }

    pub fn clearOperatorNotice(self: *ClientContext) void {
        if (self.operator_notice) |msg| {
            self.allocator.free(msg);
            self.operator_notice = null;
        }
    }

    pub fn setNodeResultOwned(self: *ClientContext, result: []u8) void {
        self.clearNodeResult();
        self.node_result = result;
    }

    pub fn clearNodeResult(self: *ClientContext) void {
        if (self.node_result) |value| {
            self.allocator.free(value);
            self.node_result = null;
        }
    }
};

fn clearSessions(self: *ClientContext) void {
    for (self.sessions.items) |*session| {
        freeSession(self.allocator, session);
    }
    self.sessions.clearRetainingCapacity();
}

fn deinitSessionState(allocator: std.mem.Allocator, state: *ChatSessionState) void {
    clearMessagesInState(allocator, state);
    state.messages.deinit(allocator);
    if (state.stream_text) |text| allocator.free(text);
    if (state.stream_run_id) |run_id| allocator.free(run_id);
    if (state.pending_history_request_id) |pending| allocator.free(pending);
    state.stream_text = null;
    state.stream_run_id = null;
    state.pending_history_request_id = null;
    state.messages_loading = false;
    state.history_loaded = false;
}

fn clearMessagesInState(allocator: std.mem.Allocator, state: *ChatSessionState) void {
    for (state.messages.items) |*message| {
        freeChatMessage(allocator, message);
    }
    state.messages.clearRetainingCapacity();
}

fn upsertMessageInList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.ChatMessage),
    msg: types.ChatMessage,
) !void {
    for (list.items, 0..) |*existing, index| {
        if (std.mem.eql(u8, existing.id, msg.id)) {
            freeChatMessage(allocator, existing);
            list.items[index] = try cloneChatMessage(allocator, msg);
            return;
        }
    }
    try list.append(allocator, try cloneChatMessage(allocator, msg));
}

fn upsertMessageOwnedInList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.ChatMessage),
    msg: types.ChatMessage,
) !void {
    for (list.items, 0..) |*existing, index| {
        if (std.mem.eql(u8, existing.id, msg.id)) {
            freeChatMessage(allocator, existing);
            list.items[index] = msg;
            return;
        }
    }
    try list.append(allocator, msg);
}

fn removeMessageByIdInList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.ChatMessage),
    id: []const u8,
) bool {
    var index: usize = 0;
    while (index < list.items.len) : (index += 1) {
        if (std.mem.eql(u8, list.items[index].id, id)) {
            var removed = list.orderedRemove(index);
            freeChatMessage(allocator, &removed);
            return true;
        }
    }
    return false;
}

fn clearNodesInternal(self: *ClientContext) void {
    for (self.nodes.items) |*node| {
        freeNode(self.allocator, node);
    }
    self.nodes.clearRetainingCapacity();
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

fn cloneNode(allocator: std.mem.Allocator, node: types.Node) !types.Node {
    return .{
        .id = try allocator.dupe(u8, node.id),
        .display_name = if (node.display_name) |name| try allocator.dupe(u8, name) else null,
        .platform = if (node.platform) |platform| try allocator.dupe(u8, platform) else null,
        .version = if (node.version) |version| try allocator.dupe(u8, version) else null,
        .core_version = if (node.core_version) |core| try allocator.dupe(u8, core) else null,
        .ui_version = if (node.ui_version) |ui| try allocator.dupe(u8, ui) else null,
        .device_family = if (node.device_family) |family| try allocator.dupe(u8, family) else null,
        .model_identifier = if (node.model_identifier) |model| try allocator.dupe(u8, model) else null,
        .remote_ip = if (node.remote_ip) |ip| try allocator.dupe(u8, ip) else null,
        .caps = try cloneStringList(allocator, node.caps),
        .commands = try cloneStringList(allocator, node.commands),
        .path_env = if (node.path_env) |path| try allocator.dupe(u8, path) else null,
        .permissions_json = if (node.permissions_json) |perm| try allocator.dupe(u8, perm) else null,
        .connected_at_ms = node.connected_at_ms,
        .connected = node.connected,
        .paired = node.paired,
    };
}

fn freeNode(allocator: std.mem.Allocator, node: *types.Node) void {
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

fn freeNodeDescribe(allocator: std.mem.Allocator, describe: *NodeDescribe) void {
    allocator.free(describe.node_id);
    allocator.free(describe.payload_json);
}

fn freeApproval(allocator: std.mem.Allocator, approval: *types.ExecApproval) void {
    allocator.free(approval.id);
    allocator.free(approval.payload_json);
    if (approval.summary) |summary| {
        allocator.free(summary);
    }
}

fn cloneStringList(allocator: std.mem.Allocator, list: ?[]const []const u8) !?[]const []const u8 {
    const items = list orelse return null;
    if (items.len == 0) return null;
    var owned = try allocator.alloc([]const u8, items.len);
    errdefer {
        for (owned) |item| allocator.free(item);
        allocator.free(owned);
    }
    for (items, 0..) |item, index| {
        owned[index] = try allocator.dupe(u8, item);
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
