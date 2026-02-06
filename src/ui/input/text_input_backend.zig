const builtin = @import("builtin");

const use_sdl3 = switch (builtin.os.tag) {
    // Zig models Android as `.os = .linux` with an Android ABI, so `.linux` covers Android too.
    .linux, .windows, .macos, .emscripten => true,
    else => false,
};

var window_ptr: ?*anyopaque = null;
var active: bool = false;
var frame_active_requested: bool = false;
var frame_ime_pos: [2]f32 = .{ 0.0, 0.0 };
var frame_ime_line: f32 = 0.0;
var frame_ime_visible: bool = false;

pub fn init(window: *anyopaque) void {
    if (!use_sdl3) return;
    window_ptr = window;
}

pub fn deinit() void {
    if (use_sdl3) {
        const sdl = @import("../../platform/sdl3.zig").c;
        if (active) {
            if (window_ptr) |window| {
                _ = sdl.SDL_StopTextInput(@ptrCast(window));
            }
            active = false;
        }
        window_ptr = null;
    }
    frame_active_requested = false;
    frame_ime_visible = false;
}

pub fn beginFrame() void {
    frame_active_requested = false;
    frame_ime_visible = false;
}

pub fn endFrame() void {
    if (!use_sdl3) return;
    const sdl = @import("../../platform/sdl3.zig").c;

    if (frame_active_requested) {
        if (!active) {
            if (window_ptr) |window| {
                _ = sdl.SDL_StartTextInput(@ptrCast(window));
            }
            active = true;
        }
        if (frame_ime_visible) {
            if (window_ptr) |window| {
                const x = @as(c_int, @intFromFloat(@max(0.0, frame_ime_pos[0])));
                const y = @as(c_int, @intFromFloat(@max(0.0, frame_ime_pos[1])));
                const h = @as(c_int, @intFromFloat(@max(1.0, frame_ime_line)));
                var rect = sdl.SDL_Rect{ .x = x, .y = y, .w = 1, .h = h };
                _ = sdl.SDL_SetTextInputArea(@ptrCast(window), &rect, 0);
            }
        }
    } else if (active) {
        if (window_ptr) |window| {
            _ = sdl.SDL_StopTextInput(@ptrCast(window));
        }
        active = false;
    }
}

pub fn setActive(enable: bool) void {
    if (enable) frame_active_requested = true;
}

pub fn setImeRect(pos: [2]f32, line_height: f32, visible: bool) void {
    frame_ime_pos = pos;
    frame_ime_line = line_height;
    frame_ime_visible = visible;
    if (visible) frame_active_requested = true;
}

