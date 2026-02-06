const builtin = @import("builtin");

const use_sdl = switch (builtin.os.tag) {
    // Zig models Android as `.os = .linux` with an Android ABI, so `.linux` covers Android too.
    .linux, .windows, .macos, .emscripten => true,
    else => false,
};
const sdl = if (use_sdl) @import("../../platform/sdl3.zig").c else struct {};

pub const Button = enum {
    left,
    right,
    middle,
};

var has_state: bool = false;
var prev_buttons: u32 = 0;
var curr_buttons: u32 = 0;
var mouse_pos: [2]f32 = .{ 0.0, 0.0 };

pub fn beginFrame() void {
    if (!use_sdl) return;
    prev_buttons = curr_buttons;
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    curr_buttons = sdl.SDL_GetMouseState(&x, &y);
    mouse_pos = .{ x, y };
    has_state = true;
}

pub fn pos() [2]f32 {
    if (!has_state) beginFrame();
    return mouse_pos;
}

pub fn isClicked(button: Button) bool {
    if (!has_state) beginFrame();
    if (!use_sdl) return false;
    const mask = buttonMask(button);
    return (curr_buttons & mask) != 0 and (prev_buttons & mask) == 0;
}

pub fn isDown(button: Button) bool {
    if (!has_state) beginFrame();
    if (!use_sdl) return false;
    return (curr_buttons & buttonMask(button)) != 0;
}

pub fn isDragging(button: Button, threshold: f32) bool {
    _ = threshold;
    if (!use_sdl) return false;
    return isDown(button);
}

pub fn isReleased(button: Button) bool {
    if (!has_state) beginFrame();
    if (!use_sdl) return false;
    const mask = buttonMask(button);
    return (curr_buttons & mask) == 0 and (prev_buttons & mask) != 0;
}

fn buttonMask(button: Button) u32 {
    return if (use_sdl) switch (button) {
        .left => sdl.SDL_BUTTON_LMASK,
        .right => sdl.SDL_BUTTON_RMASK,
        .middle => sdl.SDL_BUTTON_MMASK,
    } else 0;
}
// ImGui backend removed; SDL3 is the only mouse source now.
