const std = @import("std");
const imgui_bridge = @import("../imgui_bridge.zig");
const input_events = @import("input_events.zig");
const input_state = @import("input_state.zig");
const mouse_backend = @import("mouse_backend.zig");
const keyboard_backend = @import("keyboard_backend.zig");

pub fn collect(allocator: std.mem.Allocator, queue: *input_state.InputQueue) void {
    mouse_backend.beginFrame();
    keyboard_backend.beginFrame();
    queue.state.mouse_pos = mouse_backend.pos();
    queue.state.modifiers = .{
        .ctrl = keyboard_backend.isKeyDown(.left_ctrl) or keyboard_backend.isKeyDown(.right_ctrl),
        .shift = keyboard_backend.isKeyDown(.left_shift) or keyboard_backend.isKeyDown(.right_shift),
        .alt = keyboard_backend.isKeyDown(.left_alt) or keyboard_backend.isKeyDown(.right_alt),
        .super = keyboard_backend.isKeyDown(.left_super) or keyboard_backend.isKeyDown(.right_super),
    };
    queue.state.mouse_down_left = mouse_backend.isDown(.left);
    queue.state.mouse_down_right = mouse_backend.isDown(.right);
    queue.state.mouse_down_middle = mouse_backend.isDown(.middle);

    if (mouse_backend.isClicked(.left)) {
        queue.push(allocator, .{ .mouse_down = .{ .button = .left, .pos = queue.state.mouse_pos } });
    }
    if (mouse_backend.isClicked(.right)) {
        queue.push(allocator, .{ .mouse_down = .{ .button = .right, .pos = queue.state.mouse_pos } });
    }
    if (mouse_backend.isClicked(.middle)) {
        queue.push(allocator, .{ .mouse_down = .{ .button = .middle, .pos = queue.state.mouse_pos } });
    }

    if (mouse_backend.isReleased(.left)) {
        queue.push(allocator, .{ .mouse_up = .{ .button = .left, .pos = queue.state.mouse_pos } });
    }
    if (mouse_backend.isReleased(.right)) {
        queue.push(allocator, .{ .mouse_up = .{ .button = .right, .pos = queue.state.mouse_pos } });
    }
    if (mouse_backend.isReleased(.middle)) {
        queue.push(allocator, .{ .mouse_up = .{ .button = .middle, .pos = queue.state.mouse_pos } });
    }

    const wheel_y = imgui_bridge.getMouseWheel();
    const wheel_x = imgui_bridge.getMouseWheelH();
    if (wheel_x != 0.0 or wheel_y != 0.0) {
        queue.push(allocator, .{ .mouse_wheel = .{ .delta = .{ wheel_x, wheel_y } } });
    }

    const mods = queue.state.modifiers;
    const key_events = [_]input_events.Key{
        .enter,
        .keypad_enter,
        .back_space,
        .delete,
        .tab,
        .left_arrow,
        .right_arrow,
        .up_arrow,
        .down_arrow,
        .home,
        .end,
        .page_up,
        .page_down,
        .a,
        .c,
        .v,
        .x,
        .z,
        .y,
    };
    for (key_events) |key| {
        if (keyboard_backend.isKeyPressed(key, true)) {
            queue.push(allocator, .{ .key_down = .{ .key = key, .mods = mods, .repeat = true } });
        }
    }

    if (imgui_bridge.peekInputQueueUtf8(allocator)) |text| {
        if (text.len > 0) {
            queue.push(allocator, .{ .text_input = .{ .text = text } });
        } else {
            allocator.free(text);
        }
    }
}
