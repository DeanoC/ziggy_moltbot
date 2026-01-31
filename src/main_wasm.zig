const std = @import("std");
const zemscripten = @import("zemscripten");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const ui = @import("ui/main_window.zig");
const theme = @import("ui/theme.zig");
const operator_view = @import("ui/operator_view.zig");
const imgui_bridge = @import("ui/imgui_bridge.zig");
const panel_manager = @import("ui/panel_manager.zig");
const workspace = @import("ui/workspace.zig");
const ui_command_inbox = @import("ui/ui_command_inbox.zig");
const dock_layout = @import("ui/dock_layout.zig");
const client_state = @import("client/state.zig");
const config = @import("client/config.zig");
const event_handler = @import("client/event_handler.zig");
const gateway = @import("protocol/gateway.zig");
const messages = @import("protocol/messages.zig");
const requests = @import("protocol/requests.zig");
const chat_proto = @import("protocol/chat.zig");
const sessions_proto = @import("protocol/sessions.zig");
const nodes_proto = @import("protocol/nodes.zig");
const approvals_proto = @import("protocol/approvals.zig");
const types = @import("protocol/types.zig");
const identity = @import("client/device_identity_wasm.zig");
const wasm_storage = @import("platform/wasm_storage.zig");
const logger = @import("utils/logger.zig");
const builtin = @import("builtin");
const update_checker = @import("client/update_checker.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

extern fn ImGui_ImplGlfw_InitForOpenGL(window: *const anyopaque, install_callbacks: bool) bool;
extern fn ImGui_ImplGlfw_Shutdown() void;
extern fn ImGui_ImplGlfw_NewFrame() void;
extern fn ImGui_ImplOpenGL3_Init(glsl_version: [*c]const u8) void;
extern fn ImGui_ImplOpenGL3_Shutdown() void;
extern fn ImGui_ImplOpenGL3_NewFrame() void;
extern fn ImGui_ImplOpenGL3_RenderDrawData(data: *const anyopaque) void;
extern fn molt_clipboard_init() void;
extern fn molt_ws_open(url: [*:0]const u8) void;
extern fn molt_ws_send(text: [*:0]const u8) void;
extern fn molt_ws_close() void;
extern fn molt_ws_ready_state() c_int;
extern fn molt_open_url(url: [*:0]const u8) void;

pub const panic = zemscripten.panic;

pub const std_options = std.Options{
    .logFn = zemscripten.log,
    .enable_segfault_handler = false,
};

var emalloc = zemscripten.EmmallocAllocator{};
var allocator: std.mem.Allocator = undefined;
var window: ?*glfw.Window = null;
var ctx: client_state.ClientContext = undefined;
var cfg: config.Config = undefined;
var manager: panel_manager.PanelManager = undefined;
var command_inbox: ui_command_inbox.UiCommandInbox = undefined;
var dock_state: dock_layout.DockState = .{};
var message_queue = MessageQueue{};
var ws_connected = false;
var ws_connecting = false;
var connect_sent = false;
var connect_nonce: ?[]u8 = null;
var connect_started_ms: i64 = 0;
var ws_opened_ms: i64 = 0;
var use_device_identity = true;
var device_identity: ?identity.DeviceIdentity = null;
var last_state: ?client_state.ClientState = null;
var initialized = false;
const config_storage_key: [:0]const u8 = "ziggystarclaw.config";
const workspace_storage_key: [:0]const u8 = "ziggystarclaw.workspace";

const MessageQueue = struct {
    items: std.ArrayList([]u8) = .empty,

    pub fn push(self: *MessageQueue, alloc: std.mem.Allocator, message: []u8) !void {
        try self.items.append(alloc, message);
    }

    pub fn drain(self: *MessageQueue) std.ArrayList([]u8) {
        const out = self.items;
        self.items = .empty;
        return out;
    }

    pub fn deinit(self: *MessageQueue, alloc: std.mem.Allocator) void {
        for (self.items.items) |message| {
            alloc.free(message);
        }
        self.items.deinit(alloc);
        self.items = .empty;
    }
};

fn glfwErrorCallback(code: glfw.ErrorCode, desc: ?[*:0]const u8) callconv(.c) void {
    if (desc) |d| {
        logger.err("GLFW error {d}: {s}", .{ @as(i32, @intCast(code)), d });
    } else {
        logger.err("GLFW error {d}: (no description)", .{ @as(i32, @intCast(code)) });
    }
}

fn applyDpiScale(scale: f32) void {
    const resolved_scale: f32 = if (scale > 0.0) scale else 1.0;
    theme.apply();
    theme.applyTypography(resolved_scale);
    if (resolved_scale == 1.0) return;
    const style = zgui.getStyle();
    style.scaleAllSizes(resolved_scale);
}

fn beginFrame(
    window_width: u32,
    window_height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
) void {
    ImGui_ImplGlfw_NewFrame();
    ImGui_ImplOpenGL3_NewFrame();

    const win_w_u32: u32 = if (window_width > 0) window_width else framebuffer_width;
    const win_h_u32: u32 = if (window_height > 0) window_height else framebuffer_height;
    const win_w: f32 = @floatFromInt(win_w_u32);
    const win_h: f32 = @floatFromInt(win_h_u32);

    zgui.io.setDisplaySize(win_w, win_h);

    var scale_x: f32 = 1.0;
    var scale_y: f32 = 1.0;
    if (window_width > 0 and window_height > 0) {
        scale_x = @as(f32, @floatFromInt(framebuffer_width)) / win_w;
        scale_y = @as(f32, @floatFromInt(framebuffer_height)) / win_h;
    }
    zgui.io.setDisplayFramebufferScale(scale_x, scale_y);

    zgui.newFrame();
}

fn endFrame() void {
    zgui.render();
    ImGui_ImplOpenGL3_RenderDrawData(zgui.getDrawData());
}

fn initApp() !void {
    allocator = emalloc.allocator();
    _ = glfw.setErrorCallback(glfwErrorCallback);
    try glfw.init();

    glfw.windowHint(.client_api, .opengl_es_api);
    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 0);
    glfw.windowHint(.doublebuffer, true);

    const win = try glfw.createWindow(1280, 720, "ZiggyStarClaw (Web)", null, null);
    glfw.makeContextCurrent(win);
    glfw.swapInterval(1);

    zgui.init(allocator);
    zgui.io.setConfigFlags(.{ .dock_enable = true });
    zgui.io.setIniFilename(null);
    theme.apply();
    if (!ImGui_ImplGlfw_InitForOpenGL(win, true)) {
        logger.err("Failed to init ImGui GLFW backend.", .{});
    }
    ImGui_ImplOpenGL3_Init("#version 300 es");
    molt_clipboard_init();
    const scale = win.getContentScale();
    applyDpiScale(scale[0]);

    ctx = try client_state.ClientContext.init(allocator);
    cfg = try loadConfigFromStorage();
    const ws = try loadWorkspaceFromStorage();
    manager = panel_manager.PanelManager.init(allocator, ws);
    command_inbox = ui_command_inbox.UiCommandInbox.init(allocator);
    dock_state = .{};
    imgui_bridge.loadIniFromMemory(manager.workspace.layout.imgui_ini);
    window = win;
    message_queue = MessageQueue{};
    initialized = true;
    logger.info("ZiggyStarClaw client (wasm) initialized.", .{});
}

fn deinitApp() void {
    if (!initialized) return;
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    zgui.deinit();
    manager.deinit();
    command_inbox.deinit(allocator);
    ctx.deinit();
    cfg.deinit(allocator);
    message_queue.deinit(allocator);
    if (connect_nonce) |nonce| {
        allocator.free(nonce);
        connect_nonce = null;
    }
    if (device_identity) |*ident| {
        ident.deinit(allocator);
        device_identity = null;
    }
    if (window) |win| {
        glfw.destroyWindow(win);
    }
    glfw.terminate();
    initialized = false;
}

fn isLocalServer(raw_url: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const url = if (std.mem.indexOf(u8, raw_url, "://") == null)
        std.fmt.allocPrint(aa, "ws://{s}", .{raw_url}) catch return false
    else
        raw_url;

    const uri = std.Uri.parse(url) catch return false;
    const host = uri.getHostAlloc(aa) catch return false;
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

fn ensureDeviceIdentity() !*identity.DeviceIdentity {
    if (device_identity == null) {
        device_identity = try identity.loadOrCreate(allocator);
    }
    return &device_identity.?;
}

fn clearConnectNonce() void {
    if (connect_nonce) |nonce| {
        allocator.free(nonce);
        connect_nonce = null;
    }
}

fn parseConnectNonce(raw: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return null;
    if (type_val != .string or !std.mem.eql(u8, type_val.string, "event")) return null;
    const event_val = obj.get("event") orelse return null;
    if (event_val != .string or !std.mem.eql(u8, event_val.string, "connect.challenge")) return null;
    const payload_val = obj.get("payload") orelse return null;
    if (payload_val != .object) return null;
    const nonce_val = payload_val.object.get("nonce") orelse return null;
    if (nonce_val != .string or nonce_val.string.len == 0) return null;
    return try allocator.dupe(u8, nonce_val.string);
}

fn loadConfigFromStorage() !config.Config {
    const raw = wasm_storage.get(allocator, config_storage_key) catch |err| {
        logger.warn("Failed to read stored config: {}", .{err});
        return try config.initDefault(allocator);
    };
    if (raw == null) {
        return try config.initDefault(allocator);
    }
    defer allocator.free(raw.?);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw.?, .{}) catch |err| {
        logger.warn("Stored config parse failed: {}", .{err});
        return try config.initDefault(allocator);
    };
    defer parsed.deinit();

    var cfg_local = try config.initDefault(allocator);
    if (parsed.value == .object) {
        const obj = parsed.value.object;
        if (obj.get("server_url")) |value| {
            if (value == .string) {
                allocator.free(cfg_local.server_url);
                cfg_local.server_url = try allocator.dupe(u8, value.string);
            }
        }
        if (obj.get("token")) |value| {
            if (value == .string) {
                allocator.free(cfg_local.token);
                cfg_local.token = try allocator.dupe(u8, value.string);
            }
        }
        if (obj.get("insecure_tls")) |value| {
            if (value == .bool) {
                cfg_local.insecure_tls = value.bool;
            }
        }
        if (obj.get("connect_host_override")) |value| {
            if (value == .string) {
                if (cfg_local.connect_host_override) |prev| {
                    allocator.free(prev);
                }
                cfg_local.connect_host_override = try allocator.dupe(u8, value.string);
            }
        }
        if (obj.get("update_manifest_url")) |value| {
            if (value == .string) {
                if (cfg_local.update_manifest_url) |prev| {
                    allocator.free(prev);
                }
                cfg_local.update_manifest_url = try allocator.dupe(u8, value.string);
            }
        }
    }
    if (builtin.target.os.tag == .emscripten) {
        cfg_local.insecure_tls = false;
    }
    return cfg_local;
}

fn saveConfigToStorage() void {
    const json = std.json.Stringify.valueAlloc(allocator, cfg, .{}) catch |err| {
        logger.warn("Failed to serialize config: {}", .{err});
        return;
    };
    defer allocator.free(json);
    wasm_storage.set(allocator, config_storage_key, json) catch |err| {
        logger.warn("Failed to persist config: {}", .{err});
    };
}

fn loadWorkspaceFromStorage() !workspace.Workspace {
    const raw = wasm_storage.get(allocator, workspace_storage_key) catch |err| {
        logger.warn("Failed to read stored workspace: {}", .{err});
        return try workspace.Workspace.initDefault(allocator);
    };
    if (raw == null) {
        return try workspace.Workspace.initDefault(allocator);
    }
    defer allocator.free(raw.?);

    var parsed = std.json.parseFromSlice(workspace.WorkspaceSnapshot, allocator, raw.?, .{}) catch |err| {
        logger.warn("Stored workspace parse failed: {}", .{err});
        return try workspace.Workspace.initDefault(allocator);
    };
    defer parsed.deinit();

    return try workspace.Workspace.fromSnapshot(allocator, parsed.value);
}

fn saveWorkspaceToStorage(ws: *workspace.Workspace) void {
    var snapshot = ws.toSnapshot(allocator) catch |err| {
        logger.warn("Failed to snapshot workspace: {}", .{err});
        return;
    };
    defer snapshot.deinit(allocator);

    const json = std.json.Stringify.valueAlloc(allocator, snapshot, .{}) catch |err| {
        logger.warn("Failed to serialize workspace: {}", .{err});
        return;
    };
    defer allocator.free(json);
    wasm_storage.set(allocator, workspace_storage_key, json) catch |err| {
        logger.warn("Failed to persist workspace: {}", .{err});
    };
}

fn buildDeviceAuthPayload(params: struct {
    device_id: []const u8,
    client_id: []const u8,
    client_mode: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    signed_at_ms: i64,
    token: []const u8,
    nonce: []const u8,
}) ![]u8 {
    const scopes_joined = try std.mem.join(allocator, ",", params.scopes);
    defer allocator.free(scopes_joined);

    const version = "v2";
    return std.fmt.allocPrint(
        allocator,
        "{s}|{s}|{s}|{s}|{s}|{s}|{d}|{s}|{s}",
        .{
            version,
            params.device_id,
            params.client_id,
            params.client_mode,
            params.role,
            scopes_joined,
            params.signed_at_ms,
            params.token,
            params.nonce,
        },
    );
}

fn sendWsText(payload: []const u8) bool {
    if (molt_ws_ready_state() != 1) {
        logger.warn("WebSocket not open; dropping outgoing message", .{});
        return false;
    }
    const buf = allocator.alloc(u8, payload.len + 1) catch return false;
    defer allocator.free(buf);
    @memcpy(buf[0..payload.len], payload);
    buf[payload.len] = 0;
    const z: [:0]const u8 = buf[0..payload.len :0];
    molt_ws_send(z.ptr);
    return true;
}

fn openUrl(url: []const u8) void {
    const buf = allocator.alloc(u8, url.len + 1) catch return;
    defer allocator.free(buf);
    @memcpy(buf[0..url.len], url);
    buf[url.len] = 0;
    molt_open_url(@ptrCast(buf.ptr));
}

fn sendConnectRequest(nonce: ?[]const u8) void {
    if (connect_sent) return;
    const scopes = [_][]const u8{ "operator.admin", "operator.approvals", "operator.pairing" };
    const caps = [_][]const u8{};
    const client_id = "webchat";
    const client_mode = "webchat";

    const auth_token = if (cfg.token.len > 0)
        cfg.token
    else if (device_identity) |ident|
        if (ident.device_token) |token| token else cfg.token
    else
        cfg.token;
    const auth = if (auth_token.len > 0) gateway.ConnectAuth{ .token = auth_token } else null;

    var signature_buf: ?[]u8 = null;
    defer if (signature_buf) |sig| allocator.free(sig);

    const device = blk: {
        if (!use_device_identity) break :blk null;
        const ident = ensureDeviceIdentity() catch |err| {
            logger.err("Device identity error: {}", .{err});
            break :blk null;
        };
        if (nonce == null) {
            logger.warn("Missing connect nonce; skipping device auth.", .{});
            break :blk null;
        }
        const signed_at = std.time.milliTimestamp();
        const payload = buildDeviceAuthPayload(.{
            .device_id = ident.device_id,
            .client_id = client_id,
            .client_mode = client_mode,
            .role = "operator",
            .scopes = &scopes,
            .signed_at_ms = signed_at,
            .token = if (auth_token.len > 0) auth_token else "",
            .nonce = nonce.?,
        }) catch |err| {
            logger.err("Failed to build device auth payload: {}", .{err});
            break :blk null;
        };
        defer allocator.free(payload);
        signature_buf = identity.signPayload(allocator, ident.*, payload) catch |err| {
            logger.err("Failed to sign payload: {}", .{err});
            break :blk null;
        };
        break :blk gateway.DeviceAuth{
            .id = ident.device_id,
            .publicKey = ident.public_key_b64,
            .signature = signature_buf.?,
            .signedAt = signed_at,
            .nonce = nonce,
        };
    };

    const request_id = requests.makeRequestId(allocator) catch |err| {
        logger.err("Failed to build connect request id: {}", .{err});
        return;
    };
    defer allocator.free(request_id);

    const connect_params = gateway.ConnectParams{
        .minProtocol = gateway.PROTOCOL_VERSION,
        .maxProtocol = gateway.PROTOCOL_VERSION,
        .client = .{
            .id = client_id,
            .displayName = "ZiggyStarClaw",
            .version = "0.1.0",
            .platform = "web",
            .mode = client_mode,
        },
        .caps = &caps,
        .role = "operator",
        .scopes = &scopes,
        .auth = auth,
        .device = device,
    };

    const request = gateway.ConnectRequestFrame{
        .id = request_id,
        .params = connect_params,
    };

    const payload = messages.serializeMessage(allocator, request) catch |err| {
        logger.err("Failed to serialize connect payload: {}", .{err});
        return;
    };
    defer allocator.free(payload);
    logger.info(
        "Sending connect request (device_auth={} nonce={s})",
        .{ device != null, if (nonce) |value| value else "(none)" },
    );
    if (sendWsText(payload)) {
        connect_sent = true;
        ctx.state = .authenticating;
    }
}

fn handleConnectChallenge(raw: []const u8) void {
    const nonce = parseConnectNonce(raw) catch |err| {
        logger.warn("Connect challenge parse error: {}", .{err});
        return;
    } orelse return;
    clearConnectNonce();
    connect_nonce = nonce;
    logger.info("Connect challenge nonce received: {s}", .{nonce});
    sendConnectRequest(nonce);
}

fn sendSessionsListRequest() void {
    if (!ws_connected or ctx.state != .connected) return;
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

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingSessionsRequest(request.id);
    } else {
        allocator.free(request.payload);
        allocator.free(request.id);
    }
}

fn sendNodesListRequest() void {
    if (!ws_connected or ctx.state != .connected) return;
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

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingNodesRequest(request.id);
    } else {
        allocator.free(request.payload);
        allocator.free(request.id);
    }
}

fn sendChatHistoryRequest(session_key: []const u8) void {
    if (!ws_connected or ctx.state != .connected) return;
    if (ctx.pending_history_request_id != null) return;

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

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingHistoryRequest(request.id);
    } else {
        allocator.free(request.payload);
        allocator.free(request.id);
    }
}

fn sendNodeInvokeRequest(
    node_id: []const u8,
    command: []const u8,
    params_json: ?[]const u8,
    timeout_ms: ?u32,
) void {
    if (!ws_connected or ctx.state != .connected) return;
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

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingNodeInvokeRequest(request.id);
        ctx.clearOperatorNotice();
    } else {
        allocator.free(request.payload);
        allocator.free(request.id);
    }
}

fn sendNodeDescribeRequest(node_id: []const u8) void {
    if (!ws_connected or ctx.state != .connected) return;
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

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingNodeDescribeRequest(request.id);
        ctx.clearOperatorNotice();
    } else {
        allocator.free(request.payload);
        allocator.free(request.id);
    }
}

fn sendExecApprovalResolveRequest(request_id: []const u8, decision: operator_view.ExecApprovalDecision) void {
    if (!ws_connected or ctx.state != .connected) return;
    if (ctx.pending_approval_resolve_request_id != null) {
        ctx.setOperatorNotice("Another approval resolve request is already in progress.") catch {};
        return;
    }

    const params = approvals_proto.ExecApprovalResolveParams{
        .id = request_id,
        .decision = approvalDecisionLabel(decision),
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

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingApprovalResolveRequest(request.id, target_copy);
        ctx.clearOperatorNotice();
    } else {
        allocator.free(request.payload);
        allocator.free(request.id);
    }
}

fn buildUserMessage(id: []const u8, content: []const u8) !types.ChatMessage {
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

fn freeChatMessageOwned(msg: *types.ChatMessage) void {
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

fn sendChatMessageRequest(session_key: []const u8, message: []const u8) void {
    if (!ws_connected or ctx.state != .connected) {
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

    var msg = buildUserMessage(idempotency, message) catch |err| {
        logger.warn("Failed to build user message: {}", .{err});
        return;
    };
    ctx.upsertMessageOwned(msg) catch |err| {
        logger.warn("Failed to append user message: {}", .{err});
        freeChatMessageOwned(&msg);
    };

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingSendRequest(request.id);
    } else {
        allocator.free(request.payload);
        allocator.free(request.id);
    }
}

fn pickSessionForSend() ?struct { key: []const u8, should_set: bool } {
    if (ctx.current_session) |session| {
        return .{ .key = session, .should_set = false };
    }
    if (ctx.sessions.items.len == 0) return null;

    var best_index: usize = 0;
    var best_updated: i64 = -1;
    for (ctx.sessions.items, 0..) |session, index| {
        const updated = session.updated_at orelse 0;
        if (updated > best_updated) {
            best_updated = updated;
            best_index = index;
        }
    }
    return .{ .key = ctx.sessions.items[best_index].key, .should_set = true };
}

fn openWebSocket() void {
    const url_z = std.mem.concat(allocator, u8, &.{ cfg.server_url, "\x00" }) catch return;
    defer allocator.free(url_z);
    const url_ptr: [:0]const u8 = url_z[0..cfg.server_url.len :0];
    ws_connected = false;
    ws_connecting = true;
    connect_sent = false;
    connect_started_ms = std.time.milliTimestamp();
    ws_opened_ms = 0;
    clearConnectNonce();
    use_device_identity = !isLocalServer(cfg.server_url);
    molt_ws_open(url_ptr.ptr);
}

fn closeWebSocket() void {
    ws_connecting = false;
    ws_connected = false;
    connect_sent = false;
    clearConnectNonce();
    molt_ws_close();
}

export fn molt_ws_on_open() void {
    if (!initialized) return;
    ws_connected = true;
    ws_connecting = false;
    ws_opened_ms = std.time.milliTimestamp();
    logger.info("WebSocket open", .{});
    ctx.state = .connecting;
    if (!use_device_identity) {
        sendConnectRequest(null);
    }
}

export fn molt_ws_on_close(code: c_int) void {
    if (!initialized) return;
    ws_connected = false;
    ws_connecting = false;
    connect_sent = false;
    clearConnectNonce();
    ws_opened_ms = 0;
    ctx.state = .disconnected;
    logger.warn("WebSocket closed (code={d})", .{code});
}

export fn molt_ws_on_error() void {
    if (!initialized) return;
    ws_connected = false;
    ws_connecting = false;
    connect_sent = false;
    ws_opened_ms = 0;
    ctx.state = .error_state;
    logger.warn("WebSocket error", .{});
}

export fn molt_ws_on_message(ptr: [*]const u8, len: usize) void {
    if (!initialized or len == 0) return;
    const slice = ptr[0..len];
    if (len <= 512) {
        logger.debug("WebSocket message ({d}): {s}", .{ len, slice });
    } else {
        logger.debug("WebSocket message ({d})", .{len});
    }
    const copy = allocator.dupe(u8, slice) catch return;
    message_queue.push(allocator, copy) catch {
        allocator.free(copy);
    };
}

fn frame() callconv(.c) void {
    if (!initialized) return;
    const win = window.?;
    glfw.pollEvents();

    if (win.shouldClose()) {
        zemscripten.cancelMainLoop();
        deinitApp();
        return;
    }

    const win_size = win.getSize();
    const win_width: u32 = if (win_size[0] > 0) @intCast(win_size[0]) else 1;
    const win_height: u32 = if (win_size[1] > 0) @intCast(win_size[1]) else 1;
    const fb_size = win.getFramebufferSize();
    const fb_width: u32 = if (fb_size[0] > 0) @intCast(fb_size[0]) else 1;
    const fb_height: u32 = if (fb_size[1] > 0) @intCast(fb_size[1]) else 1;

    c.glViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    c.glClearColor(0.08, 0.08, 0.1, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    var drained = message_queue.drain();
    defer {
        for (drained.items) |payload| {
            allocator.free(payload);
        }
        drained.deinit(allocator);
    }
    for (drained.items) |payload| {
        handleConnectChallenge(payload);
        const update = event_handler.handleRawMessage(&ctx, payload) catch |err| blk: {
            logger.err("Failed to handle server message: {}", .{err});
            break :blk null;
        };
        if (update) |auth_update| {
            defer auth_update.deinit(allocator);
            if (device_identity) |*ident| {
                identity.storeDeviceToken(
                    allocator,
                    ident,
                    auth_update.device_token,
                    auth_update.role,
                    auth_update.scopes,
                    auth_update.issued_at_ms,
                ) catch |err| {
                    logger.warn("Failed to store device token: {}", .{err});
                };
            }
        }
    }

    if (last_state == null or last_state.? != ctx.state) {
        logger.info("Client state -> {s}", .{@tagName(ctx.state)});
        last_state = ctx.state;
    }

    if (ws_connected and ctx.state == .connected) {
        if (ctx.sessions.items.len == 0 and ctx.pending_sessions_request_id == null) {
            sendSessionsListRequest();
        }
        if (ctx.nodes.items.len == 0 and ctx.pending_nodes_request_id == null) {
            sendNodesListRequest();
        }
        if (ctx.current_session) |session_key| {
            if (ctx.pending_history_request_id == null) {
                const needs_history = ctx.history_session == null or
                    !std.mem.eql(u8, ctx.history_session.?, session_key);
                if (needs_history) {
                    sendChatHistoryRequest(session_key);
                }
            }
        }
    } else if (ws_connected and use_device_identity and !connect_sent) {
        const now_ms = std.time.milliTimestamp();
        if (connect_nonce == null and ws_opened_ms > 0 and now_ms - ws_opened_ms > 1500) {
            logger.warn("No connect.challenge received; sending connect without device auth.", .{});
            use_device_identity = false;
            sendConnectRequest(null);
        }
    } else if (ws_connecting and !ws_connected) {
        if (molt_ws_ready_state() == 1) {
            ws_connected = true;
            ws_connecting = false;
            ws_opened_ms = std.time.milliTimestamp();
            logger.info("WebSocket open (polled)", .{});
        }
    }

    beginFrame(win_width, win_height, fb_width, fb_height);
    const ui_action = ui.draw(
        allocator,
        &ctx,
        &cfg,
        ws_connected,
        build_options.app_version,
        &manager,
        &command_inbox,
        &dock_state,
    );

    if (ui_action.config_updated) {
        // config updated in-place
        saveConfigToStorage();
    }

    if (ui_action.save_config) {
        saveConfigToStorage();
    }
    if (ui_action.save_workspace) {
        dock_layout.captureIni(allocator, &manager.workspace) catch |err| {
            logger.warn("Failed to capture workspace layout: {}", .{err});
        };
        saveWorkspaceToStorage(&manager.workspace);
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
        openUrl(release_url);
    }
    if (ui_action.clear_saved) {
        wasm_storage.remove(config_storage_key);
        cfg.deinit(allocator);
        cfg = config.initDefault(allocator) catch |err| {
            logger.warn("Failed to reset config: {}", .{err});
            return;
        };
        ui.syncSettings(cfg);
    }

    if (ui_action.connect) {
        ctx.state = .connecting;
        ctx.clearError();
        openWebSocket();
    }

    if (ui_action.disconnect) {
        closeWebSocket();
        ctx.state = .disconnected;
        ctx.clearPendingRequests();
        ctx.clearStreamText();
        ctx.clearStreamRunId();
        ctx.clearNodes();
        ctx.clearCurrentNode();
        ctx.clearApprovals();
        ctx.clearNodeDescribes();
        ctx.clearNodeResult();
        ctx.clearOperatorNotice();
    }

    if (ui_action.refresh_sessions) {
        sendSessionsListRequest();
    }

    if (ui_action.refresh_nodes) {
        sendNodesListRequest();
    }

    if (ui_action.select_session) |session_key| {
        defer allocator.free(session_key);
        ctx.setCurrentSession(session_key) catch |err| {
            logger.warn("Failed to set session: {}", .{err});
        };
        ctx.clearMessages();
        ctx.clearStreamText();
        ctx.clearStreamRunId();
        ctx.clearPendingHistoryRequest();
        if (ws_connected) {
            sendChatHistoryRequest(session_key);
        }
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
            sendNodeDescribeRequest(node_id);
        }
    }

    if (ui_action.resolve_approval) |resolve| {
        var resolve_mut = resolve;
        defer resolve_mut.deinit(allocator);
        sendExecApprovalResolveRequest(resolve_mut.request_id, resolve_mut.decision);
    }

    if (ui_action.send_message) |message| {
        defer allocator.free(message);
        const resolved = pickSessionForSend();
        if (resolved) |choice| {
            if (choice.should_set) {
                ctx.setCurrentSession(choice.key) catch |err| {
                    logger.warn("Failed to set session: {}", .{err});
                };
            }
            sendChatMessageRequest(choice.key, message);
        } else {
            sendChatMessageRequest("main", message);
        }
    }

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

    endFrame();

    win.swapBuffers();
}

fn approvalDecisionLabel(decision: operator_view.ExecApprovalDecision) []const u8 {
    return switch (decision) {
        .allow_once => "allow-once",
        .allow_always => "allow-always",
        .deny => "deny",
    };
}

export fn main() c_int {
    initApp() catch |err| {
        logger.err("Failed to init wasm app: {}", .{err});
        return 1;
    };
    zemscripten.setMainLoop(frame, null, true);
    return 0;
}
