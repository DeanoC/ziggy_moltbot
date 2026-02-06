const std = @import("std");
const zemscripten = @import("zemscripten");
const sdl = @import("platform/sdl3.zig").c;
const ui = @import("ui/main_window.zig");
const theme = @import("ui/theme.zig");
const operator_view = @import("ui/operator_view.zig");
const panel_manager = @import("ui/panel_manager.zig");
const workspace = @import("ui/workspace.zig");
const ui_command_inbox = @import("ui/ui_command_inbox.zig");
const image_cache = @import("ui/image_cache.zig");
const attachment_cache = @import("ui/attachment_cache.zig");
const input_router = @import("ui/input/input_router.zig");
const input_backend = @import("ui/input/input_backend.zig");
const sdl_input_backend = @import("ui/input/sdl_input_backend.zig");
const text_input_backend = @import("ui/input/text_input_backend.zig");
const clipboard = @import("ui/clipboard.zig");
const client_state = @import("client/state.zig");
const agent_registry = @import("client/agent_registry.zig");
const session_keys = @import("client/session_keys.zig");
const config = @import("client/config.zig");
const app_state = @import("client/app_state.zig");
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
const webgpu_renderer = @import("client/renderer.zig");
const font_system = @import("ui/font_system.zig");

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
var window: ?*sdl.SDL_Window = null;
var renderer: ?webgpu_renderer.Renderer = null;
var ctx: client_state.ClientContext = undefined;
var cfg: config.Config = undefined;
var agents: agent_registry.AgentRegistry = undefined;
var manager: panel_manager.PanelManager = undefined;
var command_inbox: ui_command_inbox.UiCommandInbox = undefined;
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
const app_state_storage_key: [:0]const u8 = "ziggystarclaw.state";
const agents_storage_key: [:0]const u8 = "ziggystarclaw.agents";
var app_state_state: app_state.AppState = app_state.initDefault();
var auto_connect_pending = false;

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

fn initApp() !void {
    allocator = emalloc.allocator();

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_GAMEPAD)) {
        logger.err("SDL init failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    _ = sdl.SDL_SetHint("SDL_IME_SHOW_UI", "1");

    const window_flags: sdl.SDL_WindowFlags = @intCast(
        sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    );
    const win = sdl.SDL_CreateWindow("ZiggyStarClaw (Web)", 1280, 720, window_flags) orelse {
        logger.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlWindowCreateFailed;
    };

    sdl_input_backend.init(allocator);
    input_router.setBackend(input_backend.sdl3);
    text_input_backend.init(win);
    clipboard.init();

    theme.apply();
    const dpi_scale_raw: f32 = sdl.SDL_GetWindowDisplayScale(win);
    const dpi_scale: f32 = if (dpi_scale_raw > 0.0) dpi_scale_raw else 1.0;
    if (!font_system.isInitialized()) {
        font_system.init(std.heap.page_allocator);
    }
    theme.applyTypography(dpi_scale);

    image_cache.init(allocator);
    attachment_cache.init(allocator);
    attachment_cache.setEnabled(true);

    const created_renderer = try webgpu_renderer.Renderer.init(allocator, win);
    renderer = created_renderer;

    ctx = try client_state.ClientContext.init(allocator);
    cfg = try loadConfigFromStorage();
    if (cfg.ui_theme) |label| {
        theme.setMode(theme.modeFromLabel(label));
        theme.apply();
    }
    agents = try loadAgentRegistryFromStorage();
    app_state_state = loadAppStateFromStorage();
    auto_connect_pending = app_state_state.last_connected and cfg.auto_connect_on_launch and cfg.server_url.len > 0;
    const ws = try loadWorkspaceFromStorage();
    manager = panel_manager.PanelManager.init(allocator, ws);
    command_inbox = ui_command_inbox.UiCommandInbox.init(allocator);
    window = win;
    message_queue = MessageQueue{};
    initialized = true;
    logger.info("ZiggyStarClaw client (wasm) initialized.", .{});
}

fn deinitApp() void {
    if (!initialized) return;

    if (renderer) |*r| {
        r.deinit();
        renderer = null;
    }

    text_input_backend.deinit();
    sdl_input_backend.deinit();
    attachment_cache.deinit();
    image_cache.deinit();
    ui.deinit(allocator);
    manager.deinit();
    command_inbox.deinit(allocator);
    input_router.deinit(allocator);
    ctx.deinit();
    saveAgentRegistryToStorage();
    agents.deinit(allocator);
    cfg.deinit(allocator);
    saveAppStateToStorage();
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
        sdl.SDL_DestroyWindow(win);
        window = null;
    }
    sdl.SDL_Quit();
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
        if (obj.get("auto_connect_on_launch")) |value| {
            if (value == .bool) {
                cfg_local.auto_connect_on_launch = value.bool;
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

fn loadAppStateFromStorage() app_state.AppState {
    const raw = wasm_storage.get(allocator, app_state_storage_key) catch |err| {
        logger.warn("Failed to read stored app state: {}", .{err});
        return app_state.initDefault();
    };
    if (raw == null) {
        return app_state.initDefault();
    }
    defer allocator.free(raw.?);

    var parsed = std.json.parseFromSlice(app_state.AppState, allocator, raw.?, .{}) catch |err| {
        logger.warn("Stored app state parse failed: {}", .{err});
        return app_state.initDefault();
    };
    defer parsed.deinit();

    if (parsed.value.version != 1) return app_state.initDefault();
    return parsed.value;
}

fn saveAppStateToStorage() void {
    const json = std.json.Stringify.valueAlloc(allocator, app_state_state, .{}) catch |err| {
        logger.warn("Failed to serialize app state: {}", .{err});
        return;
    };
    defer allocator.free(json);
    wasm_storage.set(allocator, app_state_storage_key, json) catch |err| {
        logger.warn("Failed to persist app state: {}", .{err});
    };
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

fn loadAgentRegistryFromStorage() !agent_registry.AgentRegistry {
    const raw = wasm_storage.get(allocator, agents_storage_key) catch |err| {
        logger.warn("Failed to read stored agents: {}", .{err});
        return try agent_registry.AgentRegistry.initDefault(allocator);
    };
    if (raw == null) {
        return try agent_registry.AgentRegistry.initDefault(allocator);
    }
    defer allocator.free(raw.?);

    const reg = agent_registry.AgentRegistry.fromJson(allocator, raw.?) catch |err| {
        logger.warn("Stored agents parse failed: {}", .{err});
        return try agent_registry.AgentRegistry.initDefault(allocator);
    };
    return reg;
}

fn saveAgentRegistryToStorage() void {
    const json = agents.toJson(allocator) catch |err| {
        logger.warn("Failed to serialize agents: {}", .{err});
        return;
    };
    defer allocator.free(json);
    wasm_storage.set(allocator, agents_storage_key, json) catch |err| {
        logger.warn("Failed to persist agents: {}", .{err});
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

fn makeNewSessionKey(alloc: std.mem.Allocator, agent_id: []const u8) ![]u8 {
    return try session_keys.buildChatSessionKey(alloc, agent_id);
}

fn sendSessionsResetRequest(session_key: []const u8) void {
    if (!ws_connected or ctx.state != .connected) return;

    const params = sessions_proto.SessionsResetParams{ .key = session_key };
    const request = requests.buildRequestPayload(allocator, "sessions.reset", params) catch |err| {
        logger.warn("Failed to build sessions.reset request: {}", .{err});
        return;
    };
    defer allocator.free(request.payload);
    defer allocator.free(request.id);

    _ = sendWsText(request.payload);
}

fn sendSessionsDeleteRequest(session_key: []const u8) void {
    if (!ws_connected or ctx.state != .connected) return;

    const params = sessions_proto.SessionsDeleteParams{ .key = session_key };
    const request = requests.buildRequestPayload(allocator, "sessions.delete", params) catch |err| {
        logger.warn("Failed to build sessions.delete request: {}", .{err});
        return;
    };
    defer allocator.free(request.payload);
    defer allocator.free(request.id);

    _ = sendWsText(request.payload);
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

    if (sendWsText(request.payload)) {
        allocator.free(request.payload);
        ctx.setPendingHistoryRequestForSession(session_key, request.id) catch {
            allocator.free(request.id);
        };
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

fn agentDisplayName(registry: *agent_registry.AgentRegistry, agent_id: []const u8) []const u8 {
    if (registry.find(agent_id)) |agent| return agent.display_name;
    return agent_id;
}

fn isNotificationSession(session: types.Session) bool {
    const kind = session.kind orelse return false;
    return std.ascii.eqlIgnoreCase(kind, "cron") or std.ascii.eqlIgnoreCase(kind, "heartbeat");
}

fn syncRegistryDefaults(
    alloc: std.mem.Allocator,
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
                    alloc.free(existing);
                }
                agent.default_session_key = alloc.dupe(u8, key) catch agent.default_session_key;
                changed = true;
            } else if (agent.default_session_key != null) {
                alloc.free(agent.default_session_key.?);
                agent.default_session_key = null;
                changed = true;
            }
        }
    }
    return changed;
}

fn ensureChatPanelsReady(
    alloc: std.mem.Allocator,
    ctx_ptr: *client_state.ClientContext,
    connected: bool,
    registry: *agent_registry.AgentRegistry,
    mgr: *panel_manager.PanelManager,
) void {
    if (!connected or ctx_ptr.state != .connected) return;

    var index: usize = 0;
    while (index < mgr.workspace.panels.items.len) : (index += 1) {
        var panel = &mgr.workspace.panels.items[index];
        if (panel.kind != .Chat) continue;
        const agent_id = panel.data.Chat.agent_id;
        var session_key = panel.data.Chat.session_key;
        if (session_key == null and agent_id != null) {
            if (registry.find(agent_id.?)) |agent| {
                if (agent.default_session_key) |default_key| {
                    panel.data.Chat.session_key = alloc.dupe(u8, default_key) catch panel.data.Chat.session_key;
                    session_key = panel.data.Chat.session_key;
                    mgr.workspace.markDirty();
                }
            }
        }
        if (session_key == null) {
            if (ctx_ptr.current_session) |current| {
                var matches_agent = true;
                if (agent_id) |id| {
                    if (session_keys.parse(current)) |parts| {
                        matches_agent = std.mem.eql(u8, parts.agent_id, id);
                    } else {
                        matches_agent = std.mem.eql(u8, id, "main");
                    }
                }
                if (matches_agent) {
                    panel.data.Chat.session_key = alloc.dupe(u8, current) catch panel.data.Chat.session_key;
                    session_key = panel.data.Chat.session_key;
                    mgr.workspace.markDirty();
                }
            }
        }
        if (session_key) |key| {
            if (ctx_ptr.findSessionState(key)) |state_ptr| {
                if (state_ptr.pending_history_request_id == null and !state_ptr.history_loaded) {
                    sendChatHistoryRequest(key);
                }
            } else {
                sendChatHistoryRequest(key);
            }
        }
    }
}

fn closeAgentChatPanels(mgr: *panel_manager.PanelManager, agent_id: []const u8) void {
    var index: usize = 0;
    while (index < mgr.workspace.panels.items.len) {
        const panel = &mgr.workspace.panels.items[index];
        if (panel.kind == .Chat) {
            if (panel.data.Chat.agent_id) |existing| {
                if (std.mem.eql(u8, existing, agent_id)) {
                    _ = mgr.closePanel(panel.id);
                    continue;
                }
            }
        }
        index += 1;
    }
}

fn clearChatPanelsForSession(
    mgr: *panel_manager.PanelManager,
    alloc: std.mem.Allocator,
    session_key: []const u8,
) void {
    for (mgr.workspace.panels.items) |*panel| {
        if (panel.kind != .Chat) continue;
        if (panel.data.Chat.session_key) |existing| {
            if (std.mem.eql(u8, existing, session_key)) {
                alloc.free(existing);
                panel.data.Chat.session_key = null;
                mgr.workspace.markDirty();
            }
        }
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
    ctx.upsertSessionMessageOwned(session_key, msg) catch |err| {
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

export fn zsc_wasm_on_paste(ptr: [*]const u8, len: usize) void {
    if (!initialized or len == 0) return;
    sdl_input_backend.pushTextInputUtf8(ptr, len);
}

fn frame() callconv(.c) void {
    if (!initialized) return;
    const win = window.?;

    var should_close = false;
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
    if (should_close) {
        zemscripten.cancelMainLoop();
        deinitApp();
        return;
    }

    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(win, &fb_w, &fb_h);
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

    if (auto_connect_pending) {
        ctx.state = .connecting;
        ctx.clearError();
        app_state_state.last_connected = true;
        saveAppStateToStorage();
        openWebSocket();
        auto_connect_pending = false;
    }

    if (ws_connected and ctx.state == .connected) {
        if (ctx.sessions.items.len == 0 and ctx.pending_sessions_request_id == null) {
            sendSessionsListRequest();
        }
        if (ctx.nodes.items.len == 0 and ctx.pending_nodes_request_id == null) {
            sendNodesListRequest();
        }
    }

    if (ctx.sessions_updated) {
        if (syncRegistryDefaults(allocator, &agents, ctx.sessions.items)) {
            saveAgentRegistryToStorage();
        }
        ctx.clearSessionsUpdated();
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

    renderer.?.beginFrame(fb_width, fb_height);
    const ui_action = ui.draw(
        allocator,
        &ctx,
        &cfg,
        &agents,
        ws_connected,
        build_options.app_version,
        fb_width,
        fb_height,
        true,
        &manager,
        &command_inbox,
    );

    if (ui_action.config_updated) {
        // config updated in-place
        saveConfigToStorage();
    }

    if (ui_action.save_config) {
        saveConfigToStorage();
    }
    if (ui_action.save_workspace) {
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
    if (ui_action.open_url) |url| {
        defer allocator.free(url);
        openUrl(url);
    }
    if (ui_action.clear_saved) {
        wasm_storage.remove(config_storage_key);
        app_state_state.last_connected = false;
        auto_connect_pending = false;
        wasm_storage.remove(app_state_storage_key);
        cfg.deinit(allocator);
        cfg = config.initDefault(allocator) catch |err| {
            logger.warn("Failed to reset config: {}", .{err});
            return;
        };
        if (cfg.ui_theme) |label| {
            theme.setMode(theme.modeFromLabel(label));
            theme.apply();
        }
        ui.syncSettings(cfg);
    }

    if (ui_action.connect) {
        ctx.state = .connecting;
        ctx.clearError();
        app_state_state.last_connected = true;
        auto_connect_pending = false;
        saveAppStateToStorage();
        openWebSocket();
    }

    if (ui_action.disconnect) {
        closeWebSocket();
        ctx.state = .disconnected;
        app_state_state.last_connected = false;
        saveAppStateToStorage();
        ctx.clearPendingRequests();
        ctx.clearAllSessionStates();
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

    if (ui_action.new_session) {
        if (ws_connected) {
            const key = makeNewSessionKey(allocator, "main") catch null;
            if (key) |session_key| {
                defer allocator.free(session_key);
                sendSessionsResetRequest(session_key);
                if (agents.setDefaultSession(allocator, "main", session_key) catch false) {
                    saveAgentRegistryToStorage();
                }
                _ = manager.ensureChatPanelForAgent("main", agentDisplayName(&agents, "main"), session_key) catch {};
                ctx.clearSessionState(session_key);
                ctx.setCurrentSession(session_key) catch {};
                sendChatHistoryRequest(session_key);
                sendSessionsListRequest();
            }
        }
    }

    if (ui_action.new_chat_agent_id) |agent_id| {
        defer allocator.free(agent_id);
        if (ws_connected) {
            const key = makeNewSessionKey(allocator, agent_id) catch null;
            if (key) |session_key| {
                defer allocator.free(session_key);
                sendSessionsResetRequest(session_key);
                if (agents.setDefaultSession(allocator, agent_id, session_key) catch false) {
                    saveAgentRegistryToStorage();
                }
                _ = manager.ensureChatPanelForAgent(agent_id, agentDisplayName(&agents, agent_id), session_key) catch {};
                ctx.clearSessionState(session_key);
                ctx.setCurrentSession(session_key) catch {};
                sendChatHistoryRequest(session_key);
                sendSessionsListRequest();
            }
        }
    }

    if (ui_action.refresh_nodes) {
        sendNodesListRequest();
    }

    if (ui_action.open_session) |open| {
        defer allocator.free(open.agent_id);
        defer allocator.free(open.session_key);
        ctx.setCurrentSession(open.session_key) catch |err| {
            logger.warn("Failed to set session: {}", .{err});
        };
        _ = manager.ensureChatPanelForAgent(open.agent_id, agentDisplayName(&agents, open.agent_id), open.session_key) catch {};
        if (ws_connected) {
            sendChatHistoryRequest(open.session_key);
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
        if (ws_connected) {
            sendChatHistoryRequest(session_key);
        }
    }

    if (ui_action.set_default_session) |choice| {
        defer allocator.free(choice.agent_id);
        defer allocator.free(choice.session_key);
        if (agents.setDefaultSession(allocator, choice.agent_id, choice.session_key) catch false) {
            saveAgentRegistryToStorage();
        }
    }

    if (ui_action.delete_session) |session_key| {
        defer allocator.free(session_key);
        sendSessionsDeleteRequest(session_key);
        _ = ctx.removeSessionByKey(session_key);
        ctx.clearSessionState(session_key);
        clearChatPanelsForSession(&manager, allocator, session_key);
        if (agents.clearDefaultIfMatches(allocator, session_key)) {
            saveAgentRegistryToStorage();
        }
        sendSessionsListRequest();
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
            saveAgentRegistryToStorage();
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
            saveAgentRegistryToStorage();
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

    if (ui_action.send_message) |payload| {
        defer allocator.free(payload.session_key);
        defer allocator.free(payload.message);
        ctx.setCurrentSession(payload.session_key) catch {};
        sendChatMessageRequest(payload.session_key, payload.message);
    }

    ensureChatPanelsReady(allocator, &ctx, ws_connected, &agents, &manager);

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

    renderer.?.render();
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
