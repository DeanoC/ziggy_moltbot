const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui/main_window.zig");
const input_router = @import("ui/input/input_router.zig");
const operator_view = @import("ui/operator_view.zig");
const theme = @import("ui/theme.zig");
const panel_manager = @import("ui/panel_manager.zig");
const workspace_store = @import("ui/workspace_store.zig");
const workspace = @import("ui/workspace.zig");
const ui_command_inbox = @import("ui/ui_command_inbox.zig");
const image_cache = @import("ui/image_cache.zig");
const attachment_cache = @import("ui/attachment_cache.zig");
const client_state = @import("client/state.zig");
const agent_registry = @import("client/agent_registry.zig");
const session_keys = @import("client/session_keys.zig");
const config = @import("client/config.zig");
const app_state = @import("client/app_state.zig");
const event_handler = @import("client/event_handler.zig");
const websocket_client = @import("openclaw_transport.zig").websocket;
const update_checker = @import("client/update_checker.zig");
const build_options = @import("build_options");
const logger = @import("utils/logger.zig");
const requests = @import("protocol/requests.zig");
const sessions_proto = @import("protocol/sessions.zig");
const chat_proto = @import("protocol/chat.zig");
const nodes_proto = @import("protocol/nodes.zig");
const approvals_proto = @import("protocol/approvals.zig");
const types = @import("protocol/types.zig");
const sdl = @import("platform/sdl3.zig").c;
const input_backend = @import("ui/input/input_backend.zig");
const sdl_input_backend = @import("ui/input/sdl_input_backend.zig");
const text_input_backend = @import("ui/input/text_input_backend.zig");

const webgpu_renderer = @import("client/renderer.zig");
const font_system = @import("ui/font_system.zig");

const icon = @cImport({
    @cInclude("icon_loader.h");
});

const startup_log_path = "ziggystarclaw_startup.log";

fn setWindowIcon(window: *sdl.SDL_Window) void {
    const icon_png = @embedFile("icons/ZiggyStarClaw_Icon.png");
    var width: c_int = 0;
    var height: c_int = 0;
    const pixels = icon.zsc_load_icon_rgba_from_memory(icon_png.ptr, @intCast(icon_png.len), &width, &height);
    if (pixels == null or width <= 0 or height <= 0) return;
    defer icon.zsc_free_icon(pixels);
    const pitch: c_int = width * 4;
    const surface = sdl.SDL_CreateSurfaceFrom(width, height, sdl.SDL_PIXELFORMAT_RGBA32, pixels, pitch);
    if (surface == null) return;
    defer sdl.SDL_DestroySurface(surface);
    _ = sdl.SDL_SetWindowIcon(window, surface);
}

fn logSurfaceBackend(window: *sdl.SDL_Window) void {
    const props = sdl.SDL_GetWindowProperties(window);
    const win32 = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
    const cocoa = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
    const wayland_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
    const wayland_surface = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
    const x11_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null);
    const x11_window = sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);

    var backend: []const u8 = "unknown";
    if (win32 != null) {
        backend = "win32";
    } else if (cocoa != null) {
        backend = "cocoa";
    } else if (wayland_display != null or wayland_surface != null) {
        backend = "wayland";
    } else if (x11_display != null or x11_window != 0) {
        backend = "x11";
    }
    logger.info("WebGPU surface backend: {s}", .{backend});
}

fn openUrl(allocator: std.mem.Allocator, url: []const u8) void {
    // On Android, prefer SDL's platform integration.
    const buf = allocator.alloc(u8, url.len + 1) catch return;
    defer allocator.free(buf);
    @memcpy(buf[0..url.len], url);
    buf[url.len] = 0;
    if (!sdl.SDL_OpenURL(@ptrCast(buf.ptr))) {
        logger.warn("Failed to open URL: {s}", .{url});
    }
}

fn openPath(allocator: std.mem.Allocator, path: []const u8) void {
    _ = allocator;
    _ = path;
    logger.warn("openPath not supported on Android", .{});
}

fn installUpdate(allocator: std.mem.Allocator, archive_path: []const u8) bool {
    _ = allocator;
    _ = archive_path;
    return false;
}

const MessageQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayList([]u8) = .empty,

    pub fn push(self: *MessageQueue, allocator: std.mem.Allocator, message: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, message);
    }

    pub fn drain(self: *MessageQueue) std.ArrayList([]u8) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = self.items;
        self.items = .empty;
        return out;
    }

    pub fn deinit(self: *MessageQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |message| {
            allocator.free(message);
        }
        self.items.deinit(allocator);
        self.items = .empty;
    }
};

const ReadLoop = struct {
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    queue: *MessageQueue,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_receive_ms: i64 = 0,
    last_payload_len: usize = 0,
};

const ConnectJob = struct {
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    error_msg: ?[]u8 = null,

    const Status = enum(u8) { idle = 0, running = 1, success = 2, failed = 3 };

    fn start(self: *ConnectJob) !bool {
        if (self.status.load(.monotonic) == @intFromEnum(Status.running)) return false;
        if (self.thread != null) return false;
        self.cancel_requested.store(false, .monotonic);
        self.clearError();
        self.status.store(@intFromEnum(Status.running), .monotonic);
        self.thread = try std.Thread.spawn(.{}, connectThreadMain, .{self});
        return true;
    }

    fn requestCancel(self: *ConnectJob) void {
        self.cancel_requested.store(true, .monotonic);
    }

    fn isRunning(self: *ConnectJob) bool {
        return self.status.load(.monotonic) == @intFromEnum(Status.running);
    }

    fn takeResult(self: *ConnectJob) ?struct { ok: bool, err: ?[]u8, canceled: bool } {
        const status = self.status.load(.monotonic);
        if (status == @intFromEnum(Status.idle) or status == @intFromEnum(Status.running)) return null;
        if (self.thread) |handle| {
            handle.join();
            self.thread = null;
        }
        const ok = status == @intFromEnum(Status.success);
        self.status.store(@intFromEnum(Status.idle), .monotonic);
        const canceled = self.cancel_requested.load(.monotonic);
        self.cancel_requested.store(false, .monotonic);
        self.mutex.lock();
        const err_msg = self.error_msg;
        self.error_msg = null;
        self.mutex.unlock();
        return .{ .ok = ok, .err = err_msg, .canceled = canceled };
    }

    fn setError(self: *ConnectJob, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
        }
        self.error_msg = self.allocator.dupe(u8, message) catch null;
    }

    fn clearError(self: *ConnectJob) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
            self.error_msg = null;
        }
    }
};

fn connectThreadMain(job: *ConnectJob) void {
    const result = job.ws_client.connect();
    if (result) |_| {
        job.status.store(@intFromEnum(ConnectJob.Status.success), .monotonic);
    } else |err| {
        job.setError(@errorName(err));
        job.status.store(@intFromEnum(ConnectJob.Status.failed), .monotonic);
    }
}

fn readLoopMain(loop: *ReadLoop) void {
    loop.running.store(true, .monotonic);
    defer loop.running.store(false, .monotonic);
    loop.ws_client.setReadTimeout(250);
    while (!loop.stop.load(.monotonic)) {
        const payload = loop.ws_client.receive() catch |err| {
            if (err == error.NotConnected or err == error.Closed) {
                return;
            }
            if (err == error.ReadFailed) {
                const now_ms = std.time.milliTimestamp();
                const last_ms = loop.last_receive_ms;
                const delta = if (last_ms > 0) now_ms - last_ms else -1;
                logger.warn(
                    "WebSocket receive failed (thread) connected={} last_payload_len={} last_payload_age_ms={d}",
                    .{ loop.ws_client.is_connected, loop.last_payload_len, delta },
                );
                loop.ws_client.disconnect();
                return;
            }
            logger.err("WebSocket receive failed (thread): {}", .{err});
            loop.ws_client.disconnect();
            return;
        } orelse continue;

        loop.last_receive_ms = std.time.milliTimestamp();
        loop.last_payload_len = payload.len;
        if (loop.stop.load(.monotonic)) {
            loop.allocator.free(payload);
            return;
        }
        loop.queue.push(loop.allocator, payload) catch {
            loop.allocator.free(payload);
            return;
        };
    }
}

fn startReadThread(loop: *ReadLoop, thread: *?std.Thread) !void {
    if (thread.* != null) return;
    loop.stop.store(false, .monotonic);
    thread.* = try std.Thread.spawn(.{}, readLoopMain, .{loop});
}

fn stopReadThread(loop: *ReadLoop, thread: *?std.Thread) void {
    if (thread.*) |handle| {
        loop.stop.store(true, .monotonic);
        handle.join();
        thread.* = null;
        loop.ws_client.disconnect();
    }
}

fn makeNewSessionKey(allocator: std.mem.Allocator, agent_id: []const u8) ![]u8 {
    return try session_keys.buildChatSessionKey(allocator, agent_id);
}

fn sendSessionsResetRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;

    const params = sessions_proto.SessionsResetParams{ .key = session_key };
    const request = requests.buildRequestPayload(allocator, "sessions.reset", params) catch |err| {
        logger.warn("Failed to build sessions.reset request: {}", .{err});
        return;
    };
    defer allocator.free(request.payload);
    defer allocator.free(request.id);

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send sessions.reset: {}", .{err});
        return;
    };
}

fn sendSessionsDeleteRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;

    const params = sessions_proto.SessionsDeleteParams{ .key = session_key };
    const request = requests.buildRequestPayload(allocator, "sessions.delete", params) catch |err| {
        logger.warn("Failed to build sessions.delete request: {}", .{err});
        return;
    };
    defer allocator.free(request.payload);
    defer allocator.free(request.id);

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send sessions.delete: {}", .{err});
        return;
    };
}

fn sendSessionsListRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_sessions_request_id != null) return;

    const params = sessions_proto.SessionsListParams{
        .includeGlobal = true,
        .includeUnknown = true,
    };

    const request = requests.buildRequestPayload(allocator, "sessions.list", params) catch |err| {
        logger.warn("Failed to build sessions.list request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send sessions.list: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingSessionsRequest(request.id);
}

fn sendNodesListRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_nodes_request_id != null) return;

    const params = nodes_proto.NodeListParams{};
    const request = requests.buildRequestPayload(allocator, "node.list", params) catch |err| {
        logger.warn("Failed to build node.list request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send node.list: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingNodesRequest(request.id);
}

fn sendChatHistoryRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.findSessionState(session_key)) |state_ptr| {
        if (state_ptr.pending_history_request_id != null) return;
    }

    const params = chat_proto.ChatHistoryParams{
        .sessionKey = session_key,
        .limit = 200,
    };

    const request = requests.buildRequestPayload(allocator, "chat.history", params) catch |err| {
        logger.warn("Failed to build chat.history request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send chat.history: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingHistoryRequestForSession(session_key, request.id) catch {
        allocator.free(request.id);
    };
}

fn sendNodeInvokeRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    node_id: []const u8,
    command: []const u8,
    params_json: ?[]const u8,
    timeout_ms: ?u32,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_node_invoke_request_id != null) {
        ctx.setOperatorNotice("Another node invoke is already in progress.") catch {};
        return;
    }

    var parsed_params: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_params) |*parsed| parsed.deinit();
    var params_value: ?std.json.Value = null;

    if (params_json) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            parsed_params = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| {
                logger.warn("Invalid node params JSON: {}", .{err});
                ctx.setOperatorNotice("Invalid JSON for node params.") catch {};
                return;
            };
            params_value = parsed_params.?.value;
        }
    }

    const idempotency = requests.makeRequestId(allocator) catch |err| {
        logger.warn("Failed to generate idempotency key: {}", .{err});
        return;
    };
    defer allocator.free(idempotency);

    const params = nodes_proto.NodeInvokeParams{
        .nodeId = node_id,
        .command = command,
        .params = params_value,
        .timeoutMs = timeout_ms,
        .idempotencyKey = idempotency,
    };

    const request = requests.buildRequestPayload(allocator, "node.invoke", params) catch |err| {
        logger.warn("Failed to build node.invoke request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send node.invoke: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingNodeInvokeRequest(request.id);
    ctx.clearOperatorNotice();
}

fn sendNodeDescribeRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    node_id: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_node_describe_request_id != null) {
        ctx.setOperatorNotice("Another node describe request is already in progress.") catch {};
        return;
    }

    const params = nodes_proto.NodeDescribeParams{
        .nodeId = node_id,
    };
    const request = requests.buildRequestPayload(allocator, "node.describe", params) catch |err| {
        logger.warn("Failed to build node.describe request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send node.describe: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingNodeDescribeRequest(request.id);
    ctx.clearOperatorNotice();
}

fn sendExecApprovalResolveRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    request_id: []const u8,
    decision: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_approval_resolve_request_id != null) {
        ctx.setOperatorNotice("Another approval resolve request is already in progress.") catch {};
        return;
    }

    const params = approvals_proto.ExecApprovalResolveParams{
        .id = request_id,
        .decision = decision,
    };
    const request = requests.buildRequestPayload(allocator, "exec.approval.resolve", params) catch |err| {
        logger.warn("Failed to build exec.approval.resolve request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    const target_copy = allocator.dupe(u8, request_id) catch {
        allocator.free(request.payload);
        allocator.free(request.id);
        return;
    };
    errdefer allocator.free(target_copy);

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send exec.approval.resolve: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingApprovalResolveRequest(request.id, target_copy);
    ctx.clearOperatorNotice();
}

fn sendChatMessageRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
    message: []const u8,
) void {
    if (!ws_client.is_connected or ctx.state != .connected) {
        logger.warn("Cannot send chat message while disconnected", .{});
        return;
    }

    const idempotency = requests.makeRequestId(allocator) catch |err| {
        logger.warn("Failed to generate idempotency key: {}", .{err});
        return;
    };
    defer allocator.free(idempotency);

    const params = chat_proto.ChatSendParams{
        .sessionKey = session_key,
        .message = message,
        .deliver = false,
        .idempotencyKey = idempotency,
    };

    const request = requests.buildRequestPayload(allocator, "chat.send", params) catch |err| {
        logger.warn("Failed to build chat.send request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    var msg = buildUserMessage(allocator, idempotency, message) catch |err| {
        logger.warn("Failed to build user message: {}", .{err});
        return;
    };
    ctx.upsertSessionMessageOwned(session_key, msg) catch |err| {
        logger.warn("Failed to append user message: {}", .{err});
        freeChatMessageOwned(allocator, &msg);
    };

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send chat.send: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingSendRequest(request.id);
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

fn buildUserMessage(
    allocator: std.mem.Allocator,
    id: []const u8,
    content: []const u8,
) !types.ChatMessage {
    const id_copy = try std.fmt.allocPrint(allocator, "user:{s}", .{id});
    errdefer allocator.free(id_copy);
    const role = try allocator.dupe(u8, "user");
    errdefer allocator.free(role);
    const content_copy = try allocator.dupe(u8, content);
    errdefer allocator.free(content_copy);
    return .{
        .id = id_copy,
        .role = role,
        .content = content_copy,
        .timestamp = std.time.milliTimestamp(),
        .attachments = null,
    };
}

fn agentDisplayName(registry: *agent_registry.AgentRegistry, agent_id: []const u8) []const u8 {
    if (registry.find(agent_id)) |agent| return agent.display_name;
    return agent_id;
}

fn isNotificationSession(session: types.Session) bool {
    const kind = session.kind orelse return false;
    return std.ascii.eqlIgnoreCase(kind, "cron") or std.ascii.eqlIgnoreCase(kind, "heartbeat");
}

fn syncRegistryDefaults(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    sessions: []const types.Session,
) bool {
    var changed = false;
    for (registry.agents.items) |*agent| {
        var default_valid = false;
        if (agent.default_session_key) |key| {
            for (sessions) |session| {
                if (!std.mem.eql(u8, session.key, key)) continue;
                if (isNotificationSession(session)) break;
                const parts = session_keys.parse(session.key) orelse break;
                if (std.mem.eql(u8, parts.agent_id, agent.id)) {
                    default_valid = true;
                }
                break;
            }
        }

        if (!default_valid) {
            var best_key: ?[]const u8 = null;
            var best_updated: i64 = -1;
            for (sessions) |session| {
                if (isNotificationSession(session)) continue;
                const parts = session_keys.parse(session.key) orelse continue;
                if (!std.mem.eql(u8, parts.agent_id, agent.id)) continue;
                const updated = session.updated_at orelse 0;
                if (updated > best_updated) {
                    best_updated = updated;
                    best_key = session.key;
                }
            }
            if (best_key) |key| {
                if (agent.default_session_key) |existing| {
                    allocator.free(existing);
                }
                agent.default_session_key = allocator.dupe(u8, key) catch agent.default_session_key;
                changed = true;
            } else if (agent.default_session_key != null) {
                allocator.free(agent.default_session_key.?);
                agent.default_session_key = null;
                changed = true;
            }
        }
    }
    return changed;
}

fn ensureChatPanelsReady(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    registry: *agent_registry.AgentRegistry,
    manager: *panel_manager.PanelManager,
) void {
    if (!ws_client.is_connected or ctx.state != .connected) return;

    var index: usize = 0;
    while (index < manager.workspace.panels.items.len) : (index += 1) {
        var panel = &manager.workspace.panels.items[index];
        if (panel.kind != .Chat) continue;
        const agent_id = panel.data.Chat.agent_id;
        var session_key = panel.data.Chat.session_key;
        if (session_key == null and agent_id != null) {
            if (registry.find(agent_id.?)) |agent| {
                if (agent.default_session_key) |default_key| {
                    panel.data.Chat.session_key = allocator.dupe(u8, default_key) catch panel.data.Chat.session_key;
                    session_key = panel.data.Chat.session_key;
                    manager.workspace.markDirty();
                }
            }
        }
        if (session_key == null) {
            if (ctx.current_session) |current| {
                var matches_agent = true;
                if (agent_id) |id| {
                    if (session_keys.parse(current)) |parts| {
                        matches_agent = std.mem.eql(u8, parts.agent_id, id);
                    } else {
                        matches_agent = std.mem.eql(u8, id, "main");
                    }
                }
                if (matches_agent) {
                    panel.data.Chat.session_key = allocator.dupe(u8, current) catch panel.data.Chat.session_key;
                    session_key = panel.data.Chat.session_key;
                    manager.workspace.markDirty();
                }
            }
        }
        if (session_key) |key| {
            if (ctx.findSessionState(key)) |state_ptr| {
                if (state_ptr.pending_history_request_id == null and !state_ptr.history_loaded) {
                    sendChatHistoryRequest(allocator, ctx, ws_client, key);
                }
            } else {
                sendChatHistoryRequest(allocator, ctx, ws_client, key);
            }
        }
    }
}

fn closeAgentChatPanels(manager: *panel_manager.PanelManager, agent_id: []const u8) void {
    var index: usize = 0;
    while (index < manager.workspace.panels.items.len) {
        const panel = &manager.workspace.panels.items[index];
        if (panel.kind == .Chat) {
            if (panel.data.Chat.agent_id) |existing| {
                if (std.mem.eql(u8, existing, agent_id)) {
                    _ = manager.closePanel(panel.id);
                    continue;
                }
            }
        }
        index += 1;
    }
}

fn clearChatPanelsForSession(
    manager: *panel_manager.PanelManager,
    allocator: std.mem.Allocator,
    session_key: []const u8,
) void {
    for (manager.workspace.panels.items) |*panel| {
        if (panel.kind != .Chat) continue;
        if (panel.data.Chat.session_key) |existing| {
            if (std.mem.eql(u8, existing, session_key)) {
                allocator.free(existing);
                panel.data.Chat.session_key = null;
                manager.workspace.markDirty();
            }
        }
    }
}

fn setCwdToPrefPath() void {
    const pref_path_c = sdl.SDL_GetPrefPath("deanoc", "ziggystarclaw");
    if (pref_path_c == null) return;
    defer sdl.SDL_free(pref_path_c);
    const pref_path = std.mem.span(@as([*:0]const u8, @ptrCast(pref_path_c.?)));
    std.posix.chdir(pref_path) catch {};
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    try initLogging(allocator);
    defer logger.deinit();

    setCwdToPrefPath();

    var cfg = try config.loadOrDefault(allocator, "ziggystarclaw_config.json");
    defer cfg.deinit(allocator);
    if (cfg.ui_theme) |label| {
        theme.setMode(theme.modeFromLabel(label));
    }
    var agents = try agent_registry.AgentRegistry.loadOrDefault(allocator, "ziggystarclaw_agents.json");
    defer agents.deinit(allocator);
    var app_state_state = app_state.loadOrDefault(allocator, "ziggystarclaw_state.json") catch app_state.initDefault();
    var auto_connect_enabled = app_state_state.last_connected;
    var auto_connect_pending = auto_connect_enabled and cfg.auto_connect_on_launch and cfg.server_url.len > 0;

    var ws_client = websocket_client.WebSocketClient.init(
        allocator,
        cfg.server_url,
        cfg.token,
        cfg.insecure_tls,
        cfg.connect_host_override,
    );
    var connect_job = ConnectJob{
        .allocator = allocator,
        .ws_client = &ws_client,
    };
    ws_client.setReadTimeout(15_000);
    defer ws_client.deinit();

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_GAMEPAD)) {
        logger.err("SDL init failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();
    _ = sdl.SDL_SetHint("SDL_IME_SHOW_UI", "1");
    sdl_input_backend.init(allocator);
    input_router.setBackend(input_backend.sdl3);
    defer input_router.deinit(allocator);
    defer sdl_input_backend.deinit();

    var window_width: c_int = 1280;
    var window_height: c_int = 720;
    if (app_state_state.window_width) |w| {
        if (w > 200) window_width = @intCast(w);
    }
    if (app_state_state.window_height) |h| {
        if (h > 200) window_height = @intCast(h);
    }

    const window_flags: sdl.SDL_WindowFlags = @intCast(
        sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    );
    const window = sdl.SDL_CreateWindow("ZiggyStarClaw", window_width, window_height, window_flags) orelse {
        logger.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlWindowCreateFailed;
    };
    defer sdl.SDL_DestroyWindow(window);
    text_input_backend.init(@ptrCast(window));
    defer text_input_backend.deinit();
    setWindowIcon(window);
    if (app_state_state.window_maximized) {
        _ = sdl.SDL_MaximizeWindow(window);
    } else if (app_state_state.window_pos_x != null and app_state_state.window_pos_y != null) {
        _ = sdl.SDL_SetWindowPosition(
            window,
            @intCast(app_state_state.window_pos_x.?),
            @intCast(app_state_state.window_pos_y.?),
        );
    }

    var renderer = try webgpu_renderer.Renderer.init(allocator, window);
    logSurfaceBackend(window);

    const dpi_scale_raw: f32 = sdl.SDL_GetWindowDisplayScale(window);
    const dpi_scale: f32 = if (dpi_scale_raw > 0.0) dpi_scale_raw else 1.0;
    if (!font_system.isInitialized()) {
        font_system.init(std.heap.page_allocator);
    }
    theme.applyTypography(dpi_scale);
    image_cache.init(allocator);
    attachment_cache.init(allocator);
    image_cache.setEnabled(true);
    defer image_cache.deinit();
    defer attachment_cache.deinit();
    defer renderer.deinit();

    var ctx = try client_state.ClientContext.init(allocator);
    defer ctx.deinit();
    const workspace_state = workspace_store.loadOrDefault(allocator, "ziggystarclaw_workspace.json") catch |err| blk: {
        logger.warn("Failed to load workspace: {}", .{err});
        break :blk workspace.Workspace.initDefault(allocator) catch |init_err| {
            logger.err("Failed to init default workspace: {}", .{init_err});
            return init_err;
        };
    };
    var manager = panel_manager.PanelManager.init(allocator, workspace_state);
    defer manager.deinit();
    defer ui.deinit(allocator);
    var command_inbox = ui_command_inbox.UiCommandInbox.init(allocator);
    defer command_inbox.deinit(allocator);

    var message_queue = MessageQueue{};
    defer message_queue.deinit(allocator);
    var read_loop = ReadLoop{
        .allocator = allocator,
        .ws_client = &ws_client,
        .queue = &message_queue,
    };
    var read_thread: ?std.Thread = null;
    defer stopReadThread(&read_loop, &read_thread);
    var should_reconnect = false;
    var reconnect_backoff_ms: u32 = 500;
    var next_reconnect_at_ms: i64 = 0;
    var next_ping_at_ms: i64 = 0;
    defer {
        app_state_state.last_connected = auto_connect_enabled;
        const flags = sdl.SDL_GetWindowFlags(window);
        const iconified = (flags & sdl.SDL_WINDOW_MINIMIZED) != 0;
        if (!iconified) {
            var size_w: c_int = 0;
            var size_h: c_int = 0;
            _ = sdl.SDL_GetWindowSize(window, &size_w, &size_h);
            var pos_x: c_int = 0;
            var pos_y: c_int = 0;
            _ = sdl.SDL_GetWindowPosition(window, &pos_x, &pos_y);
            app_state_state.window_width = size_w;
            app_state_state.window_height = size_h;
            app_state_state.window_pos_x = pos_x;
            app_state_state.window_pos_y = pos_y;
        }
        app_state_state.window_maximized = (flags & sdl.SDL_WINDOW_MAXIMIZED) != 0;
        app_state.save(allocator, "ziggystarclaw_state.json", app_state_state) catch |err| {
            logger.warn("Failed to save app state: {}", .{err});
        };
    }

    logger.info("ZiggyStarClaw client (native) loaded. Server: {s}", .{cfg.server_url});

    if (auto_connect_pending) {
        ctx.state = .connecting;
        ctx.clearError();
        ws_client.url = cfg.server_url;
        ws_client.token = cfg.token;
        ws_client.insecure_tls = cfg.insecure_tls;
        ws_client.connect_host_override = cfg.connect_host_override;
        auto_connect_enabled = true;
        should_reconnect = true;
        reconnect_backoff_ms = 500;
        next_reconnect_at_ms = 0;
        if (!connect_job.isRunning()) {
            const started = connect_job.start() catch |err| blk: {
                logger.err("Failed to start connect thread: {}", .{err});
                ctx.state = .error_state;
                ctx.setError(@errorName(err)) catch {};
                break :blk false;
            };
            if (!started) {
                logger.warn("Connect attempt already in progress", .{});
            }
        }
        auto_connect_pending = false;
    }

    var should_close = false;
    while (!should_close) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            sdl_input_backend.pushEvent(&event);
            switch (event.type) {
                sdl.SDL_EVENT_QUIT,
                sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
                => should_close = true,
                else => {},
            }
        }

        if (read_thread != null and !read_loop.running.load(.monotonic)) {
            stopReadThread(&read_loop, &read_thread);
        }
        if (!ws_client.is_connected and ctx.state == .connected) {
            ctx.state = .disconnected;
            if (should_reconnect and next_reconnect_at_ms == 0) {
                const now_ms = std.time.milliTimestamp();
                next_reconnect_at_ms = now_ms + reconnect_backoff_ms;
                logger.info("Reconnect scheduled in {d}ms", .{reconnect_backoff_ms});
            }
        }

        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(window, &fb_w, &fb_h);
        const fb_width: u32 = if (fb_w > 0) @intCast(fb_w) else 1;
        const fb_height: u32 = if (fb_h > 0) @intCast(fb_h) else 1;

        var drained = message_queue.drain();
        defer {
            for (drained.items) |payload| {
                allocator.free(payload);
            }
            drained.deinit(allocator);
        }
        for (drained.items) |payload| {
            const update = event_handler.handleRawMessage(&ctx, payload) catch |err| blk: {
                logger.err("Failed to handle server message: {}", .{err});
                break :blk null;
            };
            if (update) |auth_update| {
                defer auth_update.deinit(allocator);
                ws_client.storeDeviceToken(
                    auth_update.device_token,
                    auth_update.role,
                    auth_update.scopes,
                    auth_update.issued_at_ms,
                ) catch |err| {
                    logger.warn("Failed to store device token: {}", .{err});
                };
            }
        }

        if (ws_client.is_connected and ctx.state == .connected) {
            if (ctx.sessions.items.len == 0 and ctx.pending_sessions_request_id == null) {
                sendSessionsListRequest(allocator, &ctx, &ws_client);
            }
            if (ctx.nodes.items.len == 0 and ctx.pending_nodes_request_id == null) {
                sendNodesListRequest(allocator, &ctx, &ws_client);
            }
        }

        if (ctx.sessions_updated) {
            if (syncRegistryDefaults(allocator, &agents, ctx.sessions.items)) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
            }
            ctx.clearSessionsUpdated();
        }

        if (ws_client.is_connected and ctx.state == .connected) {
            const now_ms = std.time.milliTimestamp();
            if (next_ping_at_ms == 0 or now_ms >= next_ping_at_ms) {
                ws_client.sendPing() catch |err| {
                    logger.warn("WebSocket ping failed: {}", .{err});
                };
                next_ping_at_ms = now_ms + 10_000;
            }
        } else {
            next_ping_at_ms = 0;
        }

        // Keep safe area insets in sync with device cutouts/gesture areas.
        var safe_rect: sdl.SDL_Rect = undefined;
        if (sdl.SDL_GetWindowSafeArea(window, &safe_rect)) {
            var win_w: c_int = 0;
            var win_h: c_int = 0;
            _ = sdl.SDL_GetWindowSizeInPixels(window, &win_w, &win_h);
            const ww: f32 = @floatFromInt(@max(win_w, 1));
            const wh: f32 = @floatFromInt(@max(win_h, 1));
            const left: f32 = @floatFromInt(@max(safe_rect.x, 0));
            const top: f32 = @floatFromInt(@max(safe_rect.y, 0));
            const right: f32 = @max(0.0, ww - left - @as(f32, @floatFromInt(@max(safe_rect.w, 0))));
            const bottom: f32 = @max(0.0, wh - top - @as(f32, @floatFromInt(@max(safe_rect.h, 0))));
            ui.setSafeInsets(left, top, right, bottom);
        } else {
            ui.setSafeInsets(0.0, 0.0, 0.0, 0.0);
        }

        renderer.beginFrame(fb_width, fb_height);
        const ui_action = ui.draw(
            allocator,
            &ctx,
            &cfg,
            &agents,
            ws_client.is_connected,
            build_options.app_version,
            fb_width,
            fb_height,
            true,
            &manager,
            &command_inbox,
        );

        if (ui_action.config_updated) {
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
            if (cfg.ui_theme) |label| {
                theme.setMode(theme.modeFromLabel(label));
            }
        }

        if (ui_action.save_config) {
            config.save(allocator, "ziggystarclaw_config.json", cfg) catch |err| {
                logger.err("Failed to save config: {}", .{err});
            };
        }

        if (ui_action.save_workspace) {
            workspace_store.save(allocator, "ziggystarclaw_workspace.json", &manager.workspace) catch |err| {
                logger.err("Failed to save workspace: {}", .{err});
            };
            manager.workspace.markClean();
        }

        if (ui_action.check_updates) {
            const manifest_url = cfg.update_manifest_url orelse "";
            update_checker.UpdateState.startCheck(
                &ctx.update_state,
                allocator,
                manifest_url,
                build_options.app_version,
                true,
            );
        }
        if (ui_action.download_update) {
            const snapshot = ctx.update_state.snapshot();
            if (snapshot.download_url) |download_url| {
                const file_name = snapshot.download_file orelse "ziggystarclaw_update.zip";
                update_checker.UpdateState.startDownload(&ctx.update_state, allocator, download_url, file_name);
            }
        }
        if (ui_action.open_release) {
            const snapshot = ctx.update_state.snapshot();
            const release_url = snapshot.release_url orelse
                "https://github.com/DeanoC/ZiggyStarClaw/releases/latest";
            openUrl(allocator, release_url);
        }
        if (ui_action.open_url) |url| {
            defer allocator.free(url);
            openUrl(allocator, url);
        }
        if (ui_action.open_download) {
            const snapshot = ctx.update_state.snapshot();
            if (snapshot.download_path) |path| {
                openPath(allocator, path);
            }
        }
        if (ui_action.install_update) {
            const snapshot = ctx.update_state.snapshot();
            if (snapshot.download_path) |path| {
                if (installUpdate(allocator, path)) {
                    should_close = true;
                }
            }
        }
        if (ui_action.clear_saved) {
            cfg.deinit(allocator);
            cfg = config.initDefault(allocator) catch |err| {
                logger.err("Failed to reset config: {}", .{err});
                return;
            };
            if (cfg.ui_theme) |label| {
                theme.setMode(theme.modeFromLabel(label));
            }
            _ = std.fs.cwd().deleteFile("ziggystarclaw_config.json") catch {};
            app_state_state.last_connected = false;
            auto_connect_enabled = false;
            auto_connect_pending = false;
            _ = std.fs.cwd().deleteFile("ziggystarclaw_state.json") catch {};
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
            ui.syncSettings(cfg);
        }

        if (ui_action.connect) {
            ctx.state = .connecting;
            ctx.clearError();
            auto_connect_enabled = true;
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
            should_reconnect = true;
            reconnect_backoff_ms = 500;
            next_reconnect_at_ms = 0;
            const started = connect_job.start() catch |err| blk: {
                logger.err("Failed to start connect thread: {}", .{err});
                ctx.state = .error_state;
                ctx.setError(@errorName(err)) catch {};
                break :blk false;
            };
            if (!started) {
                logger.warn("Connect attempt already in progress", .{});
            }
        }

        if (ui_action.disconnect) {
            connect_job.requestCancel();
            stopReadThread(&read_loop, &read_thread);
            if (!connect_job.isRunning()) {
                ws_client.disconnect();
            }
            should_reconnect = false;
            auto_connect_enabled = false;
            next_reconnect_at_ms = 0;
            reconnect_backoff_ms = 500;
            ctx.state = .disconnected;
            ctx.clearPendingRequests();
            ctx.clearAllSessionStates();
            ctx.clearNodes();
            ctx.clearCurrentNode();
            ctx.clearApprovals();
            ctx.clearNodeDescribes();
            ctx.clearNodeResult();
            ctx.clearOperatorNotice();
            next_ping_at_ms = 0;
        }

        if (ui_action.refresh_sessions) {
            sendSessionsListRequest(allocator, &ctx, &ws_client);
        }

        if (ui_action.new_session) {
            if (ws_client.is_connected) {
                const key = makeNewSessionKey(allocator, "main") catch null;
                if (key) |session_key| {
                    defer allocator.free(session_key);
                    sendSessionsResetRequest(allocator, &ctx, &ws_client, session_key);
                    if (agents.setDefaultSession(allocator, "main", session_key) catch false) {
                        agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                    }
                    _ = manager.ensureChatPanelForAgent("main", agentDisplayName(&agents, "main"), session_key) catch {};
                    ctx.clearSessionState(session_key);
                    ctx.setCurrentSession(session_key) catch {};
                    sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
                    sendSessionsListRequest(allocator, &ctx, &ws_client);
                }
            }
        }

        if (ui_action.new_chat_agent_id) |agent_id| {
            defer allocator.free(agent_id);
            if (ws_client.is_connected) {
                const key = makeNewSessionKey(allocator, agent_id) catch null;
                if (key) |session_key| {
                    defer allocator.free(session_key);
                    sendSessionsResetRequest(allocator, &ctx, &ws_client, session_key);
                    if (agents.setDefaultSession(allocator, agent_id, session_key) catch false) {
                        agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                    }

                    _ = manager.ensureChatPanelForAgent(agent_id, agentDisplayName(&agents, agent_id), session_key) catch {};
                    ctx.clearSessionState(session_key);
                    ctx.setCurrentSession(session_key) catch {};
                    sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
                    sendSessionsListRequest(allocator, &ctx, &ws_client);
                }
            }
        }

        if (ui_action.refresh_nodes) {
            sendNodesListRequest(allocator, &ctx, &ws_client);
        }

        if (ui_action.open_session) |open| {
            defer allocator.free(open.agent_id);
            defer allocator.free(open.session_key);
            ctx.setCurrentSession(open.session_key) catch |err| {
                logger.warn("Failed to set session: {}", .{err});
            };
            _ = manager.ensureChatPanelForAgent(open.agent_id, agentDisplayName(&agents, open.agent_id), open.session_key) catch {};
            if (ws_client.is_connected) {
                sendChatHistoryRequest(allocator, &ctx, &ws_client, open.session_key);
            }
        }

        if (ui_action.select_session) |session_key| {
            defer allocator.free(session_key);
            ctx.setCurrentSession(session_key) catch |err| {
                logger.warn("Failed to set session: {}", .{err});
            };
            if (session_keys.parse(session_key)) |parts| {
                _ = manager.ensureChatPanelForAgent(parts.agent_id, agentDisplayName(&agents, parts.agent_id), session_key) catch {};
            } else {
                _ = manager.ensureChatPanelForAgent("main", agentDisplayName(&agents, "main"), session_key) catch {};
            }
            if (ws_client.is_connected) {
                sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
            }
        }

        if (ui_action.set_default_session) |choice| {
            defer allocator.free(choice.agent_id);
            defer allocator.free(choice.session_key);
            if (agents.setDefaultSession(allocator, choice.agent_id, choice.session_key) catch false) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
            }
        }

        if (ui_action.delete_session) |session_key| {
            defer allocator.free(session_key);
            sendSessionsDeleteRequest(allocator, &ctx, &ws_client, session_key);
            _ = ctx.removeSessionByKey(session_key);
            ctx.clearSessionState(session_key);
            clearChatPanelsForSession(&manager, allocator, session_key);
            if (agents.clearDefaultIfMatches(allocator, session_key)) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
            }
            sendSessionsListRequest(allocator, &ctx, &ws_client);
        }

        if (ui_action.add_agent) |agent_action| {
            const owned = agent_action;
            if (agents.addOwned(allocator, .{
                .id = owned.id,
                .display_name = owned.display_name,
                .icon = owned.icon,
                .soul_path = null,
                .config_path = null,
                .personality_path = null,
                .default_session_key = null,
            })) |_| {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                _ = manager.ensureChatPanelForAgent(owned.id, agentDisplayName(&agents, owned.id), null) catch {};
            } else |err| {
                logger.warn("Failed to add agent: {}", .{err});
                allocator.free(owned.id);
                allocator.free(owned.display_name);
                allocator.free(owned.icon);
            }
        }

        if (ui_action.remove_agent_id) |agent_id| {
            defer allocator.free(agent_id);
            if (agents.remove(allocator, agent_id)) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                closeAgentChatPanels(&manager, agent_id);
            }
        }

        if (ui_action.focus_session) |session_key| {
            defer allocator.free(session_key);
            ctx.setCurrentSession(session_key) catch |err| {
                logger.warn("Failed to set session: {}", .{err});
            };
        }

        if (ui_action.select_node) |node_id| {
            defer allocator.free(node_id);
            ctx.setCurrentNode(node_id) catch |err| {
                logger.warn("Failed to set node: {}", .{err});
            };
        }

        if (ui_action.invoke_node) |invoke| {
            var invoke_mut = invoke;
            defer invoke_mut.deinit(allocator);
            if (invoke_mut.node_id.len == 0 or invoke_mut.command.len == 0) {
                ctx.setOperatorNotice("Node ID and command are required.") catch {};
            } else {
                sendNodeInvokeRequest(
                    allocator,
                    &ctx,
                    &ws_client,
                    invoke_mut.node_id,
                    invoke_mut.command,
                    invoke_mut.params_json,
                    invoke_mut.timeout_ms,
                );
            }
        }

        if (ui_action.describe_node) |node_id| {
            defer allocator.free(node_id);
            if (node_id.len == 0) {
                ctx.setOperatorNotice("Node ID is required for describe.") catch {};
            } else {
                sendNodeDescribeRequest(allocator, &ctx, &ws_client, node_id);
            }
        }

        if (ui_action.resolve_approval) |resolve| {
            var resolve_mut = resolve;
            defer resolve_mut.deinit(allocator);
            sendExecApprovalResolveRequest(
                allocator,
                &ctx,
                &ws_client,
                resolve_mut.request_id,
                approvalDecisionLabel(resolve_mut.decision),
            );
        }

        if (ui_action.send_message) |payload| {
            defer allocator.free(payload.session_key);
            defer allocator.free(payload.message);
            ctx.setCurrentSession(payload.session_key) catch {};
            sendChatMessageRequest(allocator, &ctx, &ws_client, payload.session_key, payload.message);
        }

        ensureChatPanelsReady(allocator, &ctx, &ws_client, &agents, &manager);

        if (ui_action.clear_node_result) {
            ctx.clearNodeResult();
        }

        if (ui_action.clear_node_describe) |node_id| {
            defer allocator.free(node_id);
            _ = ctx.removeNodeDescribeById(node_id);
        }

        if (ui_action.clear_operator_notice) {
            ctx.clearOperatorNotice();
        }

        if (connect_job.takeResult()) |result| {
            if (result.canceled) {
                if (result.err) |err_msg| {
                    allocator.free(err_msg);
                }
                ws_client.disconnect();
                ctx.state = .disconnected;
                ctx.clearError();
                next_ping_at_ms = 0;
            } else if (result.ok) {
                ctx.clearError();
                ctx.state = .authenticating;
                next_ping_at_ms = 0;
                startReadThread(&read_loop, &read_thread) catch |err| {
                    logger.err("Failed to start read thread: {}", .{err});
                };
            } else {
                ctx.state = .error_state;
                if (result.err) |err_msg| {
                    ctx.setError(err_msg) catch {};
                    allocator.free(err_msg);
                }
                if (should_reconnect) {
                    const now_ms = std.time.milliTimestamp();
                    next_reconnect_at_ms = now_ms + reconnect_backoff_ms;
                    const grown = reconnect_backoff_ms + reconnect_backoff_ms / 2;
                    reconnect_backoff_ms = if (grown > 15_000) 15_000 else grown;
                }
            }
        }

        if (should_reconnect and !ws_client.is_connected and read_thread == null) {
            const now_ms = std.time.milliTimestamp();
            if (next_reconnect_at_ms == 0 or now_ms >= next_reconnect_at_ms) {
                ctx.state = .connecting;
                ws_client.url = cfg.server_url;
                ws_client.token = cfg.token;
                ws_client.insecure_tls = cfg.insecure_tls;
                ws_client.connect_host_override = cfg.connect_host_override;
                if (!connect_job.isRunning()) {
                    const started = connect_job.start() catch blk: {
                        break :blk false;
                    };
                    if (!started) {
                        next_reconnect_at_ms = now_ms + reconnect_backoff_ms;
                        const grown = reconnect_backoff_ms + reconnect_backoff_ms / 2;
                        reconnect_backoff_ms = if (grown > 15_000) 15_000 else grown;
                        logger.info("Reconnect scheduled in {d}ms", .{reconnect_backoff_ms});
                    }
                }
            }
        }

        renderer.render();
    }
}

pub export fn SDL_main(argc: c_int, argv: [*c][*c]u8) c_int {
    _ = argc;
    _ = argv;
    run() catch |err| {
        logger.err("ziggystarclaw SDL_main failed: {}", .{err});
        return 1;
    };
    return 0;
}

fn approvalDecisionLabel(decision: operator_view.ExecApprovalDecision) []const u8 {
    return switch (decision) {
        .allow_once => "allow-once",
        .allow_always => "allow-always",
        .deny => "deny",
    };
}

fn initLogging(allocator: std.mem.Allocator) !void {
    const env_level = std.process.getEnvVarOwned(allocator, "MOLT_LOG_LEVEL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_level) |value| {
        defer allocator.free(value);
        if (parseLogLevel(value)) |level| {
            logger.setLevel(level);
        }
    }

    const env_file = std.process.getEnvVarOwned(allocator, "MOLT_LOG_FILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_file) |path| {
        defer allocator.free(path);
        logger.initFile(path) catch |err| {
            logger.warn("Failed to open log file: {}", .{err});
        };
    } else {
        logger.initFile(startup_log_path) catch |err| {
            logger.warn("Failed to open startup log: {}", .{err});
        };
    }
    logger.initAsync(allocator) catch |err| {
        logger.warn("Failed to start async logger: {}", .{err});
    };
}

fn parseLogLevel(value: []const u8) ?logger.Level {
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn") or std.ascii.eqlIgnoreCase(value, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "error") or std.ascii.eqlIgnoreCase(value, "err")) return .err;
    return null;
}
