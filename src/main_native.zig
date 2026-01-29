const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("zglfw");
const ui = @import("ui/main_window.zig");
const imgui = @import("ui/imgui_wrapper.zig");
const client_state = @import("client/state.zig");
const config = @import("client/config.zig");
const event_handler = @import("client/event_handler.zig");
const websocket_client = @import("client/websocket_client.zig");

extern fn zgui_opengl_load() c_int;
extern fn zgui_glViewport(x: c_int, y: c_int, w: c_int, h: c_int) void;
extern fn zgui_glClearColor(r: f32, g: f32, b: f32, a: f32) void;
extern fn zgui_glClear(mask: c_uint) void;

fn glfwErrorCallback(code: glfw.ErrorCode, desc: ?[*:0]const u8) callconv(.c) void {
    if (desc) |d| {
        std.log.err("GLFW error {d}: {s}", .{ @as(i32, @intCast(code)), d });
    } else {
        std.log.err("GLFW error {d}: (no description)", .{ @as(i32, @intCast(code)) });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var cfg = try config.loadOrDefault(allocator, "moltbot_config.json");
    defer cfg.deinit(allocator);

    var ws_client = websocket_client.WebSocketClient.init(allocator, cfg.server_url, cfg.token);
    defer ws_client.deinit();

    _ = glfw.setErrorCallback(glfwErrorCallback);
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    if (builtin.os.tag == .macos) {
        glfw.windowHint(.opengl_forward_compat, true);
    }

    const window = try glfw.Window.create(1280, 720, "MoltBot Client", null, null);
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);
    if (glfw.getCurrentContext() == null) {
        std.log.err("OpenGL context creation failed. If running under WSL, ensure WSLg or an X server with OpenGL is available.", .{});
        return error.OpenGLContextUnavailable;
    }
    const missing = zgui_opengl_load();
    if (missing != 0) {
        std.log.err("Failed to load {d} OpenGL function pointers via GLFW.", .{missing});
        return error.OpenGLLoaderFailed;
    }

    imgui.init(allocator, window);
    const scale = window.getContentScale();
    const dpi_scale: f32 = @max(scale[0], scale[1]);
    if (dpi_scale > 0.0) {
        imgui.applyDpiScale(dpi_scale);
    }
    defer imgui.deinit();

    var ctx = try client_state.ClientContext.init(allocator);
    defer ctx.deinit();

    std.log.info("MoltBot client stub (native) loaded. Server: {s}", .{cfg.server_url});

    while (!window.shouldClose()) {
        glfw.pollEvents();

        const win = window.getSize();
        const win_width: u32 = if (win[0] > 0) @intCast(win[0]) else 1;
        const win_height: u32 = if (win[1] > 0) @intCast(win[1]) else 1;

        const fb = window.getFramebufferSize();
        const fb_width: u32 = if (fb[0] > 0) @intCast(fb[0]) else 1;
        const fb_height: u32 = if (fb[1] > 0) @intCast(fb[1]) else 1;

        zgui_glViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
        zgui_glClearColor(0.08, 0.08, 0.1, 1.0);
        zgui_glClear(0x00004000);

        if (ws_client.is_connected) {
            var handled: usize = 0;
            while (handled < 16) {
                const payload = ws_client.receive() catch |err| {
                    std.log.err("WebSocket receive failed: {}", .{err});
                    ws_client.disconnect();
                    ctx.state = .error_state;
                    break;
                } orelse break;
                defer allocator.free(payload);
                event_handler.handleRawMessage(&ctx, payload) catch |err| {
                    std.log.err("Failed to handle server message: {}", .{err});
                };
                handled += 1;
            }
        }

        imgui.beginFrame(win_width, win_height, fb_width, fb_height);
        const ui_action = ui.draw(allocator, &ctx, &cfg, ws_client.is_connected);

        if (ui_action.config_updated) {
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
        }

        if (ui_action.save_config) {
            config.save(allocator, "moltbot_config.json", cfg) catch |err| {
                std.log.err("Failed to save config: {}", .{err});
            };
        }

        if (ui_action.connect) {
            ctx.state = .connecting;
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.connect() catch |err| {
                std.log.err("WebSocket connect failed: {}", .{err});
                ctx.state = .error_state;
            };
            if (ws_client.is_connected) {
                ctx.state = .connected;
            }
        }

        if (ui_action.disconnect) {
            ws_client.disconnect();
            ctx.state = .disconnected;
        }

        if (ui_action.send_message) |message| {
            defer allocator.free(message);
            if (ws_client.is_connected) {
                ws_client.send(message) catch |err| {
                    std.log.err("Failed to send message: {}", .{err});
                };
            } else {
                std.log.warn("Cannot send message while disconnected", .{});
            }
        }

        imgui.endFrame();

        window.swapBuffers();
    }
}
