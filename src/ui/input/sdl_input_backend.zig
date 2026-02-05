const std = @import("std");
const sdl = @import("../../platform/sdl3.zig").c;
const input_events = @import("input_events.zig");
const input_state = @import("input_state.zig");

var pending_events: std.ArrayList(sdl.SDL_Event) = .empty;
var pending_allocator: ?std.mem.Allocator = null;

pub fn init(allocator: std.mem.Allocator) void {
    if (pending_allocator != null) return;
    pending_allocator = allocator;
}

pub fn deinit() void {
    if (pending_allocator == null) return;
    pending_events.deinit(pending_allocator.?);
    pending_events = .empty;
    pending_allocator = null;
}

pub fn pushEvent(event: *const sdl.SDL_Event) void {
    if (pending_allocator == null) return;
    pending_events.append(pending_allocator.?, event.*) catch {};
}

pub fn collect(allocator: std.mem.Allocator, queue: *input_state.InputQueue) void {
    const alloc = pending_allocator orelse return;

    var mouse_x: f32 = 0.0;
    var mouse_y: f32 = 0.0;
    const buttons = sdl.SDL_GetMouseState(&mouse_x, &mouse_y);
    queue.state.mouse_pos = .{ mouse_x, mouse_y };
    queue.state.mouse_down_left = (buttons & sdl.SDL_BUTTON_LMASK) != 0;
    queue.state.mouse_down_right = (buttons & sdl.SDL_BUTTON_RMASK) != 0;
    queue.state.mouse_down_middle = (buttons & sdl.SDL_BUTTON_MMASK) != 0;
    queue.state.modifiers = modifiersFromSDL(sdl.SDL_GetModState());

    const events = pending_events.toOwnedSlice(alloc) catch return;
    pending_events.clearRetainingCapacity();
    defer alloc.free(events);

    for (events) |event| {
        switch (event.type) {
            sdl.SDL_EVENT_MOUSE_MOTION => {
                queue.push(allocator, .{ .mouse_move = .{ .pos = .{ event.motion.x, event.motion.y } } });
            },
            sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (mapMouseButton(event.button.button)) |button| {
                    queue.push(allocator, .{ .mouse_down = .{ .button = button, .pos = .{ event.button.x, event.button.y } } });
                }
            },
            sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (mapMouseButton(event.button.button)) |button| {
                    queue.push(allocator, .{ .mouse_up = .{ .button = button, .pos = .{ event.button.x, event.button.y } } });
                }
            },
            sdl.SDL_EVENT_MOUSE_WHEEL => {
                queue.push(allocator, .{ .mouse_wheel = .{ .delta = .{ event.wheel.x, event.wheel.y } } });
            },
            sdl.SDL_EVENT_KEY_DOWN => {
                if (mapKey(event.key.scancode)) |key| {
                    queue.push(allocator, .{ .key_down = .{
                        .key = key,
                        .mods = modifiersFromSDL(event.key.mod),
                        .repeat = event.key.repeat,
                    } });
                }
            },
            sdl.SDL_EVENT_KEY_UP => {
                if (mapKey(event.key.scancode)) |key| {
                    queue.push(allocator, .{ .key_up = .{
                        .key = key,
                        .mods = modifiersFromSDL(event.key.mod),
                        .repeat = false,
                    } });
                }
            },
            sdl.SDL_EVENT_TEXT_INPUT => {
                if (event.text.text) |text_ptr| {
                    const slice = std.mem.span(text_ptr);
                    if (slice.len > 0) {
                        const owned = allocator.dupe(u8, slice) catch null;
                        if (owned) |text| {
                            queue.push(allocator, .{ .text_input = .{ .text = text } });
                        }
                    }
                }
            },
            sdl.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                queue.push(allocator, .focus_gained);
            },
            sdl.SDL_EVENT_WINDOW_FOCUS_LOST => {
                queue.push(allocator, .focus_lost);
            },
            else => {},
        }
    }
}

fn modifiersFromSDL(mods: sdl.SDL_Keymod) input_events.Modifiers {
    return .{
        .ctrl = (mods & sdl.SDL_KMOD_CTRL) != 0,
        .shift = (mods & sdl.SDL_KMOD_SHIFT) != 0,
        .alt = (mods & sdl.SDL_KMOD_ALT) != 0,
        .super = (mods & sdl.SDL_KMOD_GUI) != 0,
    };
}

fn mapMouseButton(button: u8) ?input_events.MouseButton {
    return switch (button) {
        sdl.SDL_BUTTON_LEFT => .left,
        sdl.SDL_BUTTON_RIGHT => .right,
        sdl.SDL_BUTTON_MIDDLE => .middle,
        else => null,
    };
}

fn mapKey(scancode: sdl.SDL_Scancode) ?input_events.Key {
    return switch (scancode) {
        sdl.SDL_SCANCODE_RETURN => .enter,
        sdl.SDL_SCANCODE_KP_ENTER => .keypad_enter,
        sdl.SDL_SCANCODE_BACKSPACE => .back_space,
        sdl.SDL_SCANCODE_DELETE => .delete,
        sdl.SDL_SCANCODE_TAB => .tab,
        sdl.SDL_SCANCODE_LEFT => .left_arrow,
        sdl.SDL_SCANCODE_RIGHT => .right_arrow,
        sdl.SDL_SCANCODE_UP => .up_arrow,
        sdl.SDL_SCANCODE_DOWN => .down_arrow,
        sdl.SDL_SCANCODE_HOME => .home,
        sdl.SDL_SCANCODE_END => .end,
        sdl.SDL_SCANCODE_PAGEUP => .page_up,
        sdl.SDL_SCANCODE_PAGEDOWN => .page_down,
        sdl.SDL_SCANCODE_A => .a,
        sdl.SDL_SCANCODE_C => .c,
        sdl.SDL_SCANCODE_V => .v,
        sdl.SDL_SCANCODE_X => .x,
        sdl.SDL_SCANCODE_Z => .z,
        sdl.SDL_SCANCODE_Y => .y,
        else => null,
    };
}
