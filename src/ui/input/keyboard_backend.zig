const std = @import("std");
const builtin = @import("builtin");
const input_events = @import("input_events.zig");
const zgui = @import("zgui");

const use_sdl = !builtin.abi.isAndroid() and switch (builtin.os.tag) {
    .linux, .windows, .macos => true,
    else => false,
};
const sdl = if (use_sdl) @import("../../platform/sdl3.zig").c else struct {};

const scancode_count = if (use_sdl)
    @as(usize, @intCast(sdl.SDL_SCANCODE_COUNT))
else
    0;
var has_state: bool = false;
var prev_state: [scancode_count]bool = [_]bool{false} ** scancode_count;
var curr_state: [scancode_count]bool = [_]bool{false} ** scancode_count;

pub fn beginFrame() void {
    if (!use_sdl) return;
    var count: c_int = 0;
    const raw = sdl.SDL_GetKeyboardState(&count) orelse return;
    const len = @min(@as(usize, @intCast(count)), curr_state.len);
    const slice = raw[0..len];
    if (!has_state) {
        std.mem.copyForwards(bool, curr_state[0..len], slice);
        std.mem.copyForwards(bool, prev_state[0..len], curr_state[0..len]);
        has_state = true;
        return;
    }
    std.mem.copyForwards(bool, prev_state[0..len], curr_state[0..len]);
    std.mem.copyForwards(bool, curr_state[0..len], slice);
}

pub fn isKeyDown(key: input_events.Key) bool {
    if (use_sdl) {
        if (!has_state) beginFrame();
        const scancode = toSDL(key);
        return curr_state[@intCast(scancode)];
    }
    return zgui.isKeyDown(toZgui(key));
}

pub fn isKeyPressed(key: input_events.Key, repeat: bool) bool {
    if (use_sdl) {
        if (!has_state) beginFrame();
        const scancode = toSDL(key);
        const idx: usize = @intCast(scancode);
        if (repeat) return curr_state[idx];
        return curr_state[idx] and !prev_state[idx];
    }
    return zgui.isKeyPressed(toZgui(key), repeat);
}

fn toSDL(key: input_events.Key) sdl.SDL_Scancode {
    return switch (key) {
        .enter => sdl.SDL_SCANCODE_RETURN,
        .keypad_enter => sdl.SDL_SCANCODE_KP_ENTER,
        .back_space => sdl.SDL_SCANCODE_BACKSPACE,
        .delete => sdl.SDL_SCANCODE_DELETE,
        .tab => sdl.SDL_SCANCODE_TAB,
        .left_arrow => sdl.SDL_SCANCODE_LEFT,
        .right_arrow => sdl.SDL_SCANCODE_RIGHT,
        .up_arrow => sdl.SDL_SCANCODE_UP,
        .down_arrow => sdl.SDL_SCANCODE_DOWN,
        .home => sdl.SDL_SCANCODE_HOME,
        .end => sdl.SDL_SCANCODE_END,
        .page_up => sdl.SDL_SCANCODE_PAGEUP,
        .page_down => sdl.SDL_SCANCODE_PAGEDOWN,
        .a => sdl.SDL_SCANCODE_A,
        .c => sdl.SDL_SCANCODE_C,
        .v => sdl.SDL_SCANCODE_V,
        .x => sdl.SDL_SCANCODE_X,
        .z => sdl.SDL_SCANCODE_Z,
        .y => sdl.SDL_SCANCODE_Y,
        .left_ctrl => sdl.SDL_SCANCODE_LCTRL,
        .right_ctrl => sdl.SDL_SCANCODE_RCTRL,
        .left_shift => sdl.SDL_SCANCODE_LSHIFT,
        .right_shift => sdl.SDL_SCANCODE_RSHIFT,
        .left_alt => sdl.SDL_SCANCODE_LALT,
        .right_alt => sdl.SDL_SCANCODE_RALT,
        .left_super => sdl.SDL_SCANCODE_LGUI,
        .right_super => sdl.SDL_SCANCODE_RGUI,
    };
}

fn toZgui(key: input_events.Key) zgui.Key {
    return switch (key) {
        .enter => .enter,
        .keypad_enter => .keypad_enter,
        .back_space => .back_space,
        .delete => .delete,
        .tab => .tab,
        .left_arrow => .left_arrow,
        .right_arrow => .right_arrow,
        .up_arrow => .up_arrow,
        .down_arrow => .down_arrow,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .a => .a,
        .c => .c,
        .v => .v,
        .x => .x,
        .z => .z,
        .y => .y,
        .left_ctrl => .left_ctrl,
        .right_ctrl => .right_ctrl,
        .left_shift => .left_shift,
        .right_shift => .right_shift,
        .left_alt => .left_alt,
        .right_alt => .right_alt,
        .left_super => .left_super,
        .right_super => .right_super,
    };
}
