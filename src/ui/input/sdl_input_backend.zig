const std = @import("std");
const sdl = @import("../../platform/sdl3.zig").c;
const input_events = @import("input_events.zig");
const input_state = @import("input_state.zig");

var pending_events: std.ArrayList(sdl.SDL_Event) = .empty;
var pending_allocator: ?std.mem.Allocator = null;
var text_input_supported: bool = false;
var pending_text_inputs: std.ArrayList([]u8) = .empty;

pub fn init(allocator: std.mem.Allocator) void {
    if (pending_allocator != null) return;
    pending_allocator = allocator;
    text_input_supported = false;
    pending_text_inputs = .empty;
}

pub fn deinit() void {
    if (pending_allocator == null) return;
    pending_events.deinit(pending_allocator.?);
    pending_events = .empty;
    for (pending_text_inputs.items) |text| pending_allocator.?.free(text);
    pending_text_inputs.deinit(pending_allocator.?);
    pending_text_inputs = .empty;
    pending_allocator = null;
    text_input_supported = false;
}

pub fn pushEvent(event: *const sdl.SDL_Event) void {
    if (pending_allocator == null) return;
    pending_events.append(pending_allocator.?, event.*) catch {};
}

pub fn pushTextInputUtf8(ptr: [*]const u8, len: usize) void {
    const alloc = pending_allocator orelse return;
    if (len == 0) return;
    const copy = alloc.dupe(u8, ptr[0..len]) catch return;
    pending_text_inputs.append(alloc, copy) catch {
        alloc.free(copy);
    };
}

pub fn collect(allocator: std.mem.Allocator, queue: *input_state.InputQueue) void {
    const alloc = pending_allocator orelse return;

    const scale = mouseToFramebufferScale();
    var mouse_x: f32 = 0.0;
    var mouse_y: f32 = 0.0;
    const buttons = sdl.SDL_GetMouseState(&mouse_x, &mouse_y);
    mouse_x *= scale[0];
    mouse_y *= scale[1];
    queue.state.mouse_pos = .{ mouse_x, mouse_y };
    queue.state.mouse_down_left = (buttons & sdl.SDL_BUTTON_LMASK) != 0;
    queue.state.mouse_down_right = (buttons & sdl.SDL_BUTTON_RMASK) != 0;
    queue.state.mouse_down_middle = (buttons & sdl.SDL_BUTTON_MMASK) != 0;
    queue.state.modifiers = modifiersFromSDL(sdl.SDL_GetModState());

    const events = pending_events.toOwnedSlice(alloc) catch return;
    pending_events.clearRetainingCapacity();
    defer alloc.free(events);

    const pasted = pending_text_inputs.toOwnedSlice(alloc) catch &[_][]u8{};
    pending_text_inputs.clearRetainingCapacity();
    defer alloc.free(pasted);
    for (pasted) |text| {
        // Ownership of `text` transfers to the queue (freed in InputQueue.clear()).
        queue.push(allocator, .{ .text_input = .{ .text = text } });
    }

    for (events) |event| {
        switch (event.type) {
            sdl.SDL_EVENT_MOUSE_MOTION => {
                queue.push(allocator, .{ .mouse_move = .{ .pos = .{ event.motion.x * scale[0], event.motion.y * scale[1] } } });
            },
            sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (mapMouseButton(event.button.button)) |button| {
                    queue.push(allocator, .{ .mouse_down = .{ .button = button, .pos = .{ event.button.x * scale[0], event.button.y * scale[1] } } });
                }
            },
            sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (mapMouseButton(event.button.button)) |button| {
                    queue.push(allocator, .{ .mouse_up = .{ .button = button, .pos = .{ event.button.x * scale[0], event.button.y * scale[1] } } });
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

                // Fallback for environments where SDL text input isn't wired up (notably
                // wasm builds that don't emit SDL_EVENT_TEXT_INPUT reliably).
                if (!text_input_supported) {
                    const mods = modifiersFromSDL(event.key.mod);
                    if (!mods.ctrl and !mods.alt and !mods.super) {
                        if (scancodeToAscii(event.key.scancode, mods.shift)) |ch| {
                            const owned = allocator.alloc(u8, 1) catch null;
                            if (owned) |buf| {
                                buf[0] = ch;
                                queue.push(allocator, .{ .text_input = .{ .text = buf } });
                            }
                        }
                    }
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
                        text_input_supported = true;
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

fn mouseToFramebufferScale() [2]f32 {
    // SDL mouse coordinates are reported in window coordinates (logical points).
    // Our UI uses framebuffer pixel coordinates (for HiDPI / browser DPR), so scale.
    const win = sdl.SDL_GetMouseFocus();
    if (win == null) return .{ 1.0, 1.0 };

    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetWindowSize(win.?, &w, &h);
    var pw: c_int = 0;
    var ph: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(win.?, &pw, &ph);

    if (w <= 0 or h <= 0 or pw <= 0 or ph <= 0) return .{ 1.0, 1.0 };
    const sx: f32 = @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(w));
    const sy: f32 = @as(f32, @floatFromInt(ph)) / @as(f32, @floatFromInt(h));
    return .{ sx, sy };
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

fn scancodeToAscii(scancode: sdl.SDL_Scancode, shift: bool) ?u8 {
    return switch (scancode) {
        sdl.SDL_SCANCODE_A => if (shift) 'A' else 'a',
        sdl.SDL_SCANCODE_B => if (shift) 'B' else 'b',
        sdl.SDL_SCANCODE_C => if (shift) 'C' else 'c',
        sdl.SDL_SCANCODE_D => if (shift) 'D' else 'd',
        sdl.SDL_SCANCODE_E => if (shift) 'E' else 'e',
        sdl.SDL_SCANCODE_F => if (shift) 'F' else 'f',
        sdl.SDL_SCANCODE_G => if (shift) 'G' else 'g',
        sdl.SDL_SCANCODE_H => if (shift) 'H' else 'h',
        sdl.SDL_SCANCODE_I => if (shift) 'I' else 'i',
        sdl.SDL_SCANCODE_J => if (shift) 'J' else 'j',
        sdl.SDL_SCANCODE_K => if (shift) 'K' else 'k',
        sdl.SDL_SCANCODE_L => if (shift) 'L' else 'l',
        sdl.SDL_SCANCODE_M => if (shift) 'M' else 'm',
        sdl.SDL_SCANCODE_N => if (shift) 'N' else 'n',
        sdl.SDL_SCANCODE_O => if (shift) 'O' else 'o',
        sdl.SDL_SCANCODE_P => if (shift) 'P' else 'p',
        sdl.SDL_SCANCODE_Q => if (shift) 'Q' else 'q',
        sdl.SDL_SCANCODE_R => if (shift) 'R' else 'r',
        sdl.SDL_SCANCODE_S => if (shift) 'S' else 's',
        sdl.SDL_SCANCODE_T => if (shift) 'T' else 't',
        sdl.SDL_SCANCODE_U => if (shift) 'U' else 'u',
        sdl.SDL_SCANCODE_V => if (shift) 'V' else 'v',
        sdl.SDL_SCANCODE_W => if (shift) 'W' else 'w',
        sdl.SDL_SCANCODE_X => if (shift) 'X' else 'x',
        sdl.SDL_SCANCODE_Y => if (shift) 'Y' else 'y',
        sdl.SDL_SCANCODE_Z => if (shift) 'Z' else 'z',

        sdl.SDL_SCANCODE_1 => if (shift) '!' else '1',
        sdl.SDL_SCANCODE_2 => if (shift) '@' else '2',
        sdl.SDL_SCANCODE_3 => if (shift) '#' else '3',
        sdl.SDL_SCANCODE_4 => if (shift) '$' else '4',
        sdl.SDL_SCANCODE_5 => if (shift) '%' else '5',
        sdl.SDL_SCANCODE_6 => if (shift) '^' else '6',
        sdl.SDL_SCANCODE_7 => if (shift) '&' else '7',
        sdl.SDL_SCANCODE_8 => if (shift) '*' else '8',
        sdl.SDL_SCANCODE_9 => if (shift) '(' else '9',
        sdl.SDL_SCANCODE_0 => if (shift) ')' else '0',

        sdl.SDL_SCANCODE_SPACE => ' ',

        sdl.SDL_SCANCODE_MINUS => if (shift) '_' else '-',
        sdl.SDL_SCANCODE_EQUALS => if (shift) '+' else '=',
        sdl.SDL_SCANCODE_LEFTBRACKET => if (shift) '{' else '[',
        sdl.SDL_SCANCODE_RIGHTBRACKET => if (shift) '}' else ']',
        sdl.SDL_SCANCODE_BACKSLASH => if (shift) '|' else '\\',
        sdl.SDL_SCANCODE_SEMICOLON => if (shift) ':' else ';',
        sdl.SDL_SCANCODE_APOSTROPHE => if (shift) '\"' else '\'',
        sdl.SDL_SCANCODE_GRAVE => if (shift) '~' else '`',
        sdl.SDL_SCANCODE_COMMA => if (shift) '<' else ',',
        sdl.SDL_SCANCODE_PERIOD => if (shift) '>' else '.',
        sdl.SDL_SCANCODE_SLASH => if (shift) '?' else '/',

        else => null,
    };
}
