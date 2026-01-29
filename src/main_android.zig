const std = @import("std");

const c = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_opengles2.h");
});

pub export fn SDL_main(argc: c_int, argv: [*c][*c]u8) c_int {
    _ = argc;
    _ = argv;

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return 1;
    }
    defer c.SDL_Quit();

    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_ES);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 0);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);

    const window = c.SDL_CreateWindow(
        "MoltBot Client",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        1280,
        720,
        c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    );
    if (window == null) {
        c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
        return 1;
    }
    defer c.SDL_DestroyWindow(window);

    const gl_ctx = c.SDL_GL_CreateContext(window);
    if (gl_ctx == null) {
        c.SDL_Log("SDL_GL_CreateContext failed: %s", c.SDL_GetError());
        return 1;
    }
    defer c.SDL_GL_DeleteContext(gl_ctx);

    _ = c.SDL_GL_SetSwapInterval(1);

    var running = true;
    var event: c.SDL_Event = undefined;
    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) {
                running = false;
            }
        }

        c.glClearColor(0.08, 0.08, 0.1, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.SDL_GL_SwapWindow(window);

        c.SDL_Delay(16);
    }

    return 0;
}
