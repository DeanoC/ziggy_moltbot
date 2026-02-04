const std = @import("std");
const zgui = @import("zgui");
const imgui_bridge = @import("../imgui_bridge.zig");
const input_events = @import("input_events.zig");
const input_state = @import("input_state.zig");

pub fn collect(allocator: std.mem.Allocator, queue: *input_state.InputQueue) void {
    queue.state.mouse_pos = zgui.getMousePos();
    queue.state.modifiers = .{
        .ctrl = zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl),
        .shift = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift),
        .alt = zgui.isKeyDown(.left_alt) or zgui.isKeyDown(.right_alt),
        .super = zgui.isKeyDown(.left_super) or zgui.isKeyDown(.right_super),
    };
    queue.state.mouse_down_left = zgui.isMouseDown(.left);
    queue.state.mouse_down_right = zgui.isMouseDown(.right);
    queue.state.mouse_down_middle = zgui.isMouseDown(.middle);

    if (zgui.isMouseClicked(.left)) {
        queue.push(allocator, .{ .mouse_down = .{ .button = .left, .pos = queue.state.mouse_pos } });
    }
    if (zgui.isMouseClicked(.right)) {
        queue.push(allocator, .{ .mouse_down = .{ .button = .right, .pos = queue.state.mouse_pos } });
    }
    if (zgui.isMouseClicked(.middle)) {
        queue.push(allocator, .{ .mouse_down = .{ .button = .middle, .pos = queue.state.mouse_pos } });
    }

    if (zgui.isMouseReleased(.left)) {
        queue.push(allocator, .{ .mouse_up = .{ .button = .left, .pos = queue.state.mouse_pos } });
    }
    if (zgui.isMouseReleased(.right)) {
        queue.push(allocator, .{ .mouse_up = .{ .button = .right, .pos = queue.state.mouse_pos } });
    }
    if (zgui.isMouseReleased(.middle)) {
        queue.push(allocator, .{ .mouse_up = .{ .button = .middle, .pos = queue.state.mouse_pos } });
    }

    const wheel_y = imgui_bridge.getMouseWheel();
    const wheel_x = imgui_bridge.getMouseWheelH();
    if (wheel_x != 0.0 or wheel_y != 0.0) {
        queue.push(allocator, .{ .mouse_wheel = .{ .delta = .{ wheel_x, wheel_y } } });
    }

    const mods = queue.state.modifiers;
    const key_events = [_]zgui.Key{
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
        if (zgui.isKeyPressed(key, true)) {
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
