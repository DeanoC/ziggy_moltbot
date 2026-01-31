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

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    state: ClientState,
    current_session: ?[]const u8,
    history_session: ?[]const u8,
    stream_run_id: ?[]const u8,
    sessions: std.ArrayList(types.Session),
    messages: std.ArrayList(types.ChatMessage),
    current_node: ?[]const u8,
    nodes: std.ArrayList(types.Node),
    node_describes: std.ArrayList(NodeDescribe),
    approvals: std.ArrayList(types.ExecApproval),
    users: std.ArrayList(types.User),
    stream_text: ?[]const u8 = null,
    sessions_loading: bool = false,
    messages_loading: bool = false,
    nodes_loading: bool = false,
    pending_sessions_request_id: ?[]const u8 = null,
    pending_history_request_id: ?[]const u8 = null,
    pending_send_request_id: ?[]const u8 = null,
    pending_nodes_request_id: ?[]const u8 = null,
    pending_node_invoke_request_id: ?[]const u8 = null,
    pending_node_describe_request_id: ?[]const u8 = null,
    pending_approval_resolve_request_id: ?[]const u8 = null,
    pending_approval_target_id: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    operator_notice: ?[]const u8 = null,
    node_result: ?[]const u8 = null,
    update_state: update_checker.UpdateState = .{},

    pub fn init(allocator: std.mem.Allocator) !ClientContext {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .current_session = null,
            .history_session = null,
            .stream_run_id = null,
            .sessions = std.ArrayList(types.Session).empty,
            .messages = std.ArrayList(types.ChatMessage).empty,
            .current_node = null,
            .nodes = std.ArrayList(types.Node).empty,
            .node_describes = std.ArrayList(NodeDescribe).empty,
            .approvals = std.ArrayList(types.ExecApproval).empty,
            .users = std.ArrayList(types.User).empty,
            .stream_text = null,
            .sessions_loading = false,
            .messages_loading = false,
            .nodes_loading = false,
            .pending_sessions_request_id = null,
            .pending_history_request_id = null,
            .pending_send_request_id = null,
            .pending_nodes_request_id = null,
            .pending_node_invoke_request_id = null,
            .pending_node_describe_request_id = null,
            .pending_approval_resolve_request_id = null,
            .pending_approval_target_id = null,
            .last_error = null,
            .operator_notice = null,
            .node_result = null,
            .update_state = .{},
        };
    }

    pub fn deinit(self: *ClientContext) void {
        self.update_state.deinit(self.allocator);
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
        self.clearOperatorNotice();
        self.clearNodeResult();
        self.clearCurrentNode();
        self.clearApprovals();
        self.clearNodeDescribes();
        for (self.sessions.items) |*session| {
            freeSession(self.allocator, session);
        }
        for (self.messages.items) |*message| {
            freeChatMessage(self.allocator, message);
        }
        for (self.nodes.items) |*node| {
            freeNode(self.allocator, node);
        }
        for (self.users.items) |*user| {
            freeUser(self.allocator, user);
        }
        self.sessions.deinit(self.allocator);
        self.messages.deinit(self.allocator);
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

    pub fn setMessagesOwned(self: *ClientContext, messages: []types.ChatMessage) void {
        clearMessagesInternal(self);
        self.messages.deinit(self.allocator);
        self.messages = std.ArrayList(types.ChatMessage).fromOwnedSlice(messages);
    }

    pub fn setNodesOwned(self: *ClientContext, nodes: []types.Node) void {
        clearNodesInternal(self);
        self.nodes.deinit(self.allocator);
        self.nodes = std.ArrayList(types.Node).fromOwnedSlice(nodes);
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
        clearMessagesInternal(self);
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
        self.clearPendingHistoryRequest();
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

fn clearMessagesInternal(self: *ClientContext) void {
    for (self.messages.items) |*message| {
        freeChatMessage(self.allocator, message);
    }
    self.messages.clearRetainingCapacity();
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
        .caps = try cloneStringList(allocator, node.caps),
        .commands = try cloneStringList(allocator, node.commands),
        .connected = node.connected,
        .paired = node.paired,
    };
}

fn freeNode(allocator: std.mem.Allocator, node: *types.Node) void {
    allocator.free(node.id);
    if (node.display_name) |name| allocator.free(name);
    if (node.platform) |platform| allocator.free(platform);
    if (node.version) |version| allocator.free(version);
    freeStringList(allocator, node.caps);
    freeStringList(allocator, node.commands);
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
