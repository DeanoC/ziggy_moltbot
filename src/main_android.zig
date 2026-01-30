const std = @import("std");
const zgui = @import("zgui");
const ui = @import("ui/main_window.zig");
const client_state = @import("client/state.zig");
const config = @import("client/config.zig");

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

fn beginFrame(window: *c.SDL_Window) void {
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    c.SDL_GetWindowSize(window, &win_w, &win_h);
    c.SDL_GL_GetDrawableSize(window, &fb_w, &fb_h);

    ImGui_ImplSDL2_NewFrame();
    ImGui_ImplOpenGL3_NewFrame();

    const size_w: c_int = if (win_w > 0) win_w else fb_w;
    const size_h: c_int = if (win_h > 0) win_h else fb_h;
    zgui.io.setDisplaySize(
        @as(f32, @floatFromInt(size_w)),
        @as(f32, @floatFromInt(size_h)),
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

pub export fn SDL_main(argc: c_int, argv: [*c][*c]u8) c_int {
    _ = argc;
    _ = argv;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_TIMER | c.SDL_INIT_EVENTS) != 0) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return 1;
    }
    defer c.SDL_Quit();

    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_ES);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 0);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_STENCIL_SIZE, 8);

    const window = c.SDL_CreateWindow(
        "MoltBot Client",
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
    var cfg = config.initDefault(allocator) catch return 1;
    defer cfg.deinit(allocator);
    ui.syncSettings(cfg);

    zgui.init(allocator);
    zgui.styleColorsDark(zgui.getStyle());
    _ = ImGui_ImplSDL2_InitForOpenGL(@ptrCast(window), @ptrCast(gl_ctx));
    ImGui_ImplOpenGL3_Init("#version 100");

    var running = true;
    var event: c.SDL_Event = undefined;
    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            _ = ImGui_ImplSDL2_ProcessEvent(@ptrCast(&event));
            if (event.type == c.SDL_QUIT) {
                running = false;
            }
        }

        beginFrame(window);
        _ = ui.draw(allocator, &ctx, &cfg, false);
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
