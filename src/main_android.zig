const std = @import("std");
const zgui = @import("zgui");
const builtin = @import("builtin");
const ui = @import("ui/main_window.zig");
const client_state = @import("client/state.zig");
const config = @import("client/config.zig");
const event_handler = @import("client/event_handler.zig");
const websocket_client = @import("client/websocket_client.zig");
const update_checker = @import("client/update_checker.zig");
const build_options = @import("build_options");
const logger = @import("utils/logger.zig");
const requests = @import("protocol/requests.zig");
const sessions_proto = @import("protocol/sessions.zig");
const chat_proto = @import("protocol/chat.zig");
const types = @import("protocol/types.zig");

const c = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_opengles2.h");
});

extern fn ImGui_ImplOpenGL3_Init(glsl_version: [*c]const u8) void;
extern fn ImGui_ImplOpenGL3_Shutdown() void;
extern fn ImGui_ImplOpenGL3_NewFrame() void;
extern fn ImGui_ImplOpenGL3_RenderDrawData(data: *const anyopaque) void;
extern fn ImGui_ImplSDL2_InitForOpenGL(window: *const anyopaque, sdl_gl_context: *const anyopaque) bool;
extern fn ImGui_ImplSDL2_Shutdown() void;
extern fn ImGui_ImplSDL2_NewFrame() void;
extern fn ImGui_ImplSDL2_ProcessEvent(event: *const anyopaque) bool;
extern fn ImGui_ImplSDL2_SetSafeOffset(x: f32, y: f32) void;

var ui_scale: f32 = 1.0;

fn openUrl(allocator: std.mem.Allocator, url: []const u8) void {
    const buf = allocator.alloc(u8, url.len + 1) catch return;
    defer allocator.free(buf);
    @memcpy(buf[0..url.len], url);
    buf[url.len] = 0;
    if (c.SDL_OpenURL(@ptrCast(buf.ptr)) != 0) {
        logger.warn("Failed to open URL: {s}", .{url});
    }
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
    loop.ws_client.setReadTimeout(0);
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
        loop.ws_client.signalClose();
        handle.join();
        thread.* = null;
        loop.ws_client.disconnect();
    }
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

fn sendChatHistoryRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
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

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send chat.history: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingHistoryRequest(request.id);
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
    ctx.upsertMessageOwned(msg) catch |err| {
        logger.warn("Failed to append user message: {}", .{err});
        freeChatMessageOwned(allocator, &msg);
    };

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send chat.send: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingSendRequest(request.id);
    logger.info("chat.send queued for session {s} (id={s})", .{ session_key, request.id });
}

fn pickSessionForSend(ctx: *client_state.ClientContext) ?struct { key: []const u8, should_set: bool } {
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

const Insets = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

fn computeSafeInsets(window: *c.SDL_Window, win_w: c_int, win_h: c_int) Insets {
    var full: c.SDL_Rect = undefined;
    var usable: c.SDL_Rect = undefined;
    const display_index = c.SDL_GetWindowDisplayIndex(window);
    if (display_index < 0) return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (c.SDL_GetDisplayBounds(display_index, &full) != 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    if (c.SDL_GetDisplayUsableBounds(display_index, &usable) != 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    if (full.w <= 0 or full.h <= 0 or win_w <= 0 or win_h <= 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    const scale_x = @as(f32, @floatFromInt(win_w)) / @as(f32, @floatFromInt(full.w));
    const scale_y = @as(f32, @floatFromInt(win_h)) / @as(f32, @floatFromInt(full.h));
    const left = @as(f32, @floatFromInt(usable.x - full.x)) * scale_x;
    const top = @as(f32, @floatFromInt(usable.y - full.y)) * scale_y;
    const right = @as(f32, @floatFromInt((full.x + full.w) - (usable.x + usable.w))) * scale_x;
    const bottom = @as(f32, @floatFromInt((full.y + full.h) - (usable.y + usable.h))) * scale_y;
    var top_out = @max(0.0, top);
    const bottom_out = @max(0.0, bottom);
    if (builtin.abi == .android and top_out == 0.0) {
        top_out = 64.0 * ui_scale;
    }
    return .{
        .left = @max(0.0, left),
        .top = top_out,
        .right = @max(0.0, right),
        .bottom = bottom_out,
    };
}

fn beginFrame(window: *c.SDL_Window) void {
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    c.SDL_GetWindowSize(window, &win_w, &win_h);
    c.SDL_GL_GetDrawableSize(window, &fb_w, &fb_h);

    const insets = computeSafeInsets(window, win_w, win_h);
    ui.setSafeInsets(insets.left, insets.top, insets.right, insets.bottom);
    ImGui_ImplSDL2_SetSafeOffset(0.0, insets.top);

    ImGui_ImplSDL2_NewFrame();
    ImGui_ImplOpenGL3_NewFrame();

    zgui.io.setDisplaySize(
        @as(f32, @floatFromInt(@max(1, win_w))),
        @as(f32, @floatFromInt(@max(1, win_h))),
    );

    var scale_x: f32 = 1.0;
    var scale_y: f32 = 1.0;
    if (win_w > 0 and win_h > 0) {
        scale_x = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(win_w));
        scale_y = @as(f32, @floatFromInt(fb_h)) / @as(f32, @floatFromInt(win_h));
    }
    zgui.io.setDisplayFramebufferScale(scale_x, scale_y);

    zgui.newFrame();
}

fn applyDpiScale(scale: f32) void {
    if (scale <= 0.0 or scale == 1.0) return;

    var cfg = zgui.FontConfig.init();
    cfg.size_pixels = 16.0 * scale;
    const font = zgui.io.addFontDefault(cfg);
    zgui.io.setDefaultFont(font);

    const style = zgui.getStyle();
    style.scaleAllSizes(scale);
}

fn guessDpiScale(window: *c.SDL_Window) f32 {
    const display_index = c.SDL_GetWindowDisplayIndex(window);
    if (display_index >= 0) {
        var ddpi: f32 = 0.0;
        if (c.SDL_GetDisplayDPI(display_index, &ddpi, null, null) == 0 and ddpi > 0.0) {
            const baseline: f32 = if (builtin.abi == .android) 160.0 else 96.0;
            const scale = ddpi / baseline;
            if (scale > 0.0) return scale;
        }
    }
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    c.SDL_GetWindowSize(window, &win_w, &win_h);
    c.SDL_GL_GetDrawableSize(window, &fb_w, &fb_h);
    if (win_w <= 0 or win_h <= 0 or fb_w <= 0 or fb_h <= 0) return 1.0;
    const scale_x = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(win_w));
    const scale_y = @as(f32, @floatFromInt(fb_h)) / @as(f32, @floatFromInt(win_h));
    const scale = if (scale_x > scale_y) scale_x else scale_y;
    if (scale >= 1.0) return scale;
    if (builtin.abi == .android) return 2.0;
    return 1.0;
}


pub export fn SDL_main(argc: c_int, argv: [*c][*c]u8) c_int {
    _ = argc;
    _ = argv;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_TIMER | c.SDL_INIT_EVENTS) != 0) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return 1;
    }
    defer c.SDL_Quit();

    _ = c.SDL_SetHint(c.SDL_HINT_IME_SHOW_UI, "1");

    const pref_path_c = c.SDL_GetPrefPath("deanoc", "ziggystarclaw");
    if (pref_path_c != null) {
        const pref_path = std.mem.span(@as([*:0]const u8, pref_path_c));
        std.posix.chdir(pref_path) catch {};
        c.SDL_free(pref_path_c);
    }

    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_ES);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 0);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_STENCIL_SIZE, 8);

    const window = c.SDL_CreateWindow(
        "ZiggyStarClaw",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        1280,
        720,
        c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
        return 1;
    };
    defer c.SDL_DestroyWindow(window);

    const gl_ctx = c.SDL_GL_CreateContext(window) orelse {
        c.SDL_Log("SDL_GL_CreateContext failed: %s", c.SDL_GetError());
        return 1;
    };
    defer c.SDL_GL_DeleteContext(gl_ctx);
    _ = c.SDL_GL_MakeCurrent(window, gl_ctx);
    _ = c.SDL_GL_SetSwapInterval(1);

    var ctx = client_state.ClientContext.init(allocator) catch return 1;
    defer ctx.deinit();
    var cfg = config.loadOrDefault(allocator, "ziggystarclaw_config.json") catch |err| blk: {
        logger.warn("Failed to load config: {}", .{err});
        break :blk config.initDefault(allocator) catch return 1;
    };
    defer cfg.deinit(allocator);
    ui.syncSettings(cfg);

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

    zgui.init(allocator);
    zgui.styleColorsDark(zgui.getStyle());
    _ = ImGui_ImplSDL2_InitForOpenGL(@ptrCast(window), @ptrCast(gl_ctx));
    ImGui_ImplOpenGL3_Init("#version 100");
    ui_scale = guessDpiScale(window);
    applyDpiScale(ui_scale);

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

    var running = true;
    var event: c.SDL_Event = undefined;
    var text_input_active = false;
    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            _ = ImGui_ImplSDL2_ProcessEvent(@ptrCast(&event));
            if (event.type == c.SDL_QUIT) {
                running = false;
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
            if (ctx.current_session) |session_key| {
                if (ctx.pending_history_request_id == null) {
                    const needs_history = ctx.history_session == null or
                        !std.mem.eql(u8, ctx.history_session.?, session_key);
                    if (needs_history) {
                        sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
                    }
                }
            }
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

        beginFrame(window);
        const ui_action = ui.draw(allocator, &ctx, &cfg, ws_client.is_connected, build_options.app_version);
        const want_text = zgui.io.getWantTextInput();
        if (want_text and !text_input_active) {
            c.SDL_StartTextInput();
            text_input_active = true;
        } else if (!want_text and text_input_active) {
            c.SDL_StopTextInput();
            text_input_active = false;
        }

        if (ui_action.config_updated) {
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
        }

        if (ui_action.save_config) {
            config.save(allocator, "ziggystarclaw_config.json", cfg) catch |err| {
                logger.err("Failed to save config: {}", .{err});
            };
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
        if (ui_action.clear_saved) {
            cfg.deinit(allocator);
            cfg = config.initDefault(allocator) catch |err| {
                logger.err("Failed to reset config: {}", .{err});
                return 1;
            };
            _ = std.fs.cwd().deleteFile("ziggystarclaw_config.json") catch {};
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
            ui.syncSettings(cfg);
        }

        if (ui_action.connect) {
            ctx.state = .connecting;
            ctx.clearError();
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
            next_reconnect_at_ms = 0;
            reconnect_backoff_ms = 500;
            ctx.state = .disconnected;
            ctx.clearPendingRequests();
            ctx.clearStreamText();
            ctx.clearStreamRunId();
            next_ping_at_ms = 0;
        }

        if (ui_action.refresh_sessions) {
            sendSessionsListRequest(allocator, &ctx, &ws_client);
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
            if (ws_client.is_connected) {
                sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
            }
        }

        if (ui_action.send_message) |message| {
            defer allocator.free(message);
            const resolved = pickSessionForSend(&ctx);
            if (resolved) |choice| {
                if (choice.should_set) {
                    ctx.setCurrentSession(choice.key) catch |err| {
                        logger.warn("Failed to set session: {}", .{err});
                    };
                }
                sendChatMessageRequest(allocator, &ctx, &ws_client, choice.key, message);
            } else {
                sendChatMessageRequest(allocator, &ctx, &ws_client, "main", message);
            }
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

        zgui.render();

        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        c.SDL_GL_GetDrawableSize(window, &fb_w, &fb_h);
        c.glViewport(0, 0, fb_w, fb_h);
        c.glClearColor(0.08, 0.08, 0.1, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL3_RenderDrawData(zgui.getDrawData());
        c.SDL_GL_SwapWindow(window);
    }

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    zgui.deinit();
    return 0;
}
