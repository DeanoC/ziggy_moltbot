const std = @import("std");
const builtin = @import("builtin");
const ui_build = @import("../ui_build.zig");
const use_imgui = ui_build.use_imgui;
const imgui_bridge = if (use_imgui)
    @import("../imgui_bridge.zig")
else
    struct {
        pub fn setWantTextInput(_: bool) void {}
        pub fn setImeData(_: [2]f32, _: f32, _: bool) void {}
    };

const use_sdl = !builtin.abi.isAndroid() and switch (builtin.os.tag) {
    .linux, .windows, .macos => true,
    else => false,
};

const sdl = if (use_sdl) @import("../../platform/sdl3.zig").c else struct {};

var window_ptr: ?*sdl.SDL_Window = null;
var active: bool = false;
var frame_active_requested: bool = false;
var frame_ime_pos: [2]f32 = .{ 0.0, 0.0 };
var frame_ime_line: f32 = 0.0;
var frame_ime_visible: bool = false;

pub fn init(window: *sdl.SDL_Window) void {
    if (!use_sdl) return;
    window_ptr = window;
}

pub fn deinit() void {
    if (!use_sdl) return;
    if (active) {
        if (window_ptr) |window| {
            _ = sdl.SDL_StopTextInput(window);
        }
        active = false;
    }
    window_ptr = null;
    frame_active_requested = false;
    frame_ime_visible = false;
}

pub fn beginFrame() void {
    frame_active_requested = false;
    frame_ime_visible = false;
}

pub fn endFrame() void {
    if (use_sdl) {
        if (frame_active_requested) {
            if (!active) {
                if (window_ptr) |window| {
                    _ = sdl.SDL_StartTextInput(window);
                }
                active = true;
            }
            if (frame_ime_visible) {
                if (window_ptr) |window| {
                    const x = @as(c_int, @intFromFloat(@max(0.0, frame_ime_pos[0])));
                    const y = @as(c_int, @intFromFloat(@max(0.0, frame_ime_pos[1])));
                    const h = @as(c_int, @intFromFloat(@max(1.0, frame_ime_line)));
                    var rect = sdl.SDL_Rect{ .x = x, .y = y, .w = 1, .h = h };
                    _ = sdl.SDL_SetTextInputArea(window, &rect, 0);
                }
            }
        } else if (active) {
            if (window_ptr) |window| {
                _ = sdl.SDL_StopTextInput(window);
            }
            active = false;
        }
        return;
    }

    imgui_bridge.setWantTextInput(frame_active_requested);
    if (frame_ime_visible) {
        imgui_bridge.setImeData(frame_ime_pos, frame_ime_line, true);
    } else {
        imgui_bridge.setImeData(frame_ime_pos, frame_ime_line, false);
    }
}

pub fn setActive(enable: bool) void {
    if (enable) {
        frame_active_requested = true;
    }
}

pub fn setImeRect(pos: [2]f32, line_height: f32, visible: bool) void {
    frame_ime_pos = pos;
    frame_ime_line = line_height;
    frame_ime_visible = visible;
    if (visible) {
        frame_active_requested = true;
    }
}
