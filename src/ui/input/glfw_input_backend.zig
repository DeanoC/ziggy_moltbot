const std = @import("std");
const glfw = @import("zglfw");
const input_events = @import("input_events.zig");
const input_state = @import("input_state.zig");

var pending_events: std.ArrayList(input_events.InputEvent) = .empty;
var pending_allocator: ?std.mem.Allocator = null;
var window_ptr: ?*glfw.Window = null;

pub fn init(allocator: std.mem.Allocator, window: *glfw.Window) void {
    if (pending_allocator != null) return;
    pending_allocator = allocator;
    window_ptr = window;
    _ = glfw.setWindowFocusCallback(window, onFocus);
    _ = glfw.setKeyCallback(window, onKey);
    _ = glfw.setCharCallback(window, onChar);
    _ = glfw.setMouseButtonCallback(window, onMouseButton);
    _ = glfw.setCursorPosCallback(window, onCursorPos);
    _ = glfw.setScrollCallback(window, onScroll);
}

pub fn deinit() void {
    const alloc = pending_allocator orelse return;
    for (pending_events.items) |*evt| {
        evt.deinit(alloc);
    }
    pending_events.deinit(alloc);
    pending_events = .empty;
    pending_allocator = null;
    window_ptr = null;
}

pub fn collect(allocator: std.mem.Allocator, queue: *input_state.InputQueue) void {
    const alloc = pending_allocator orelse return;
    const win = window_ptr orelse return;

    var mouse_x: f64 = 0.0;
    var mouse_y: f64 = 0.0;
    glfw.getCursorPos(win, &mouse_x, &mouse_y);
    queue.state.mouse_pos = .{ @floatCast(mouse_x), @floatCast(mouse_y) };
    queue.state.mouse_down_left = isMouseDown(win, .left);
    queue.state.mouse_down_right = isMouseDown(win, .right);
    queue.state.mouse_down_middle = isMouseDown(win, .middle);
    queue.state.modifiers = modifiersFromKeys(win);

    const events = pending_events.toOwnedSlice(alloc) catch return;
    pending_events.clearRetainingCapacity();
    defer alloc.free(events);

    for (events) |event| {
        queue.push(allocator, event);
    }
}

fn isMouseDown(window: *glfw.Window, button: glfw.MouseButton) bool {
    return switch (glfw.getMouseButton(window, button)) {
        .press, .repeat => true,
        else => false,
    };
}

fn isKeyDown(window: *glfw.Window, key: glfw.Key) bool {
    return switch (glfw.getKey(window, key)) {
        .press, .repeat => true,
        else => false,
    };
}

fn modifiersFromKeys(window: *glfw.Window) input_events.Modifiers {
    return .{
        .ctrl = isKeyDown(window, .left_control) or isKeyDown(window, .right_control),
        .shift = isKeyDown(window, .left_shift) or isKeyDown(window, .right_shift),
        .alt = isKeyDown(window, .left_alt) or isKeyDown(window, .right_alt),
        .super = isKeyDown(window, .left_super) or isKeyDown(window, .right_super),
    };
}

fn modifiersFromGlfw(mods: glfw.Mods) input_events.Modifiers {
    return .{
        .ctrl = mods.control,
        .shift = mods.shift,
        .alt = mods.alt,
        .super = mods.super,
    };
}

fn pushEvent(event: input_events.InputEvent) void {
    const alloc = pending_allocator orelse return;
    pending_events.append(alloc, event) catch {
        var owned = event;
        owned.deinit(alloc);
    };
}

fn onFocus(_: *glfw.Window, focused: glfw.Bool) callconv(.c) void {
    if (focused == glfw.TRUE) {
        pushEvent(.focus_gained);
    } else {
        pushEvent(.focus_lost);
    }
}

fn onCursorPos(_: *glfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
    pushEvent(.{ .mouse_move = .{ .pos = .{ @floatCast(xpos), @floatCast(ypos) } } });
}

fn onScroll(_: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    const dx: f32 = @floatCast(xoffset);
    const dy: f32 = @floatCast(yoffset);
    if (dx == 0.0 and dy == 0.0) return;
    pushEvent(.{ .mouse_wheel = .{ .delta = .{ dx, dy } } });
}

fn onMouseButton(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    const mapped = mapMouseButton(button) orelse return;
    var xpos: f64 = 0.0;
    var ypos: f64 = 0.0;
    glfw.getCursorPos(window, &xpos, &ypos);
    const pos: [2]f32 = .{ @floatCast(xpos), @floatCast(ypos) };
    _ = mods;
    switch (action) {
        .press => pushEvent(.{ .mouse_down = .{ .button = mapped, .pos = pos } }),
        .release => pushEvent(.{ .mouse_up = .{ .button = mapped, .pos = pos } }),
        else => {},
    }
}

fn onKey(_: *glfw.Window, key: glfw.Key, _: c_int, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    const mapped = mapKey(key) orelse return;
    const event_mods = modifiersFromGlfw(mods);
    switch (action) {
        .press => pushEvent(.{ .key_down = .{ .key = mapped, .mods = event_mods, .repeat = false } }),
        .repeat => pushEvent(.{ .key_down = .{ .key = mapped, .mods = event_mods, .repeat = true } }),
        .release => pushEvent(.{ .key_up = .{ .key = mapped, .mods = event_mods, .repeat = false } }),
    }
}

fn onChar(_: *glfw.Window, codepoint: u32) callconv(.c) void {
    const alloc = pending_allocator orelse return;
    if (codepoint > 0x10FFFF) return;
    const cp: u21 = @intCast(codepoint);
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return;
    const text = alloc.dupe(u8, buf[0..len]) catch return;
    pushEvent(.{ .text_input = .{ .text = text } });
}

fn mapMouseButton(button: glfw.MouseButton) ?input_events.MouseButton {
    return switch (button) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        else => null,
    };
}

fn mapKey(key: glfw.Key) ?input_events.Key {
    return switch (key) {
        .enter => .enter,
        .kp_enter => .keypad_enter,
        .backspace => .back_space,
        .delete => .delete,
        .tab => .tab,
        .left => .left_arrow,
        .right => .right_arrow,
        .up => .up_arrow,
        .down => .down_arrow,
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
        .left_control => .left_ctrl,
        .right_control => .right_ctrl,
        .left_shift => .left_shift,
        .right_shift => .right_shift,
        .left_alt => .left_alt,
        .right_alt => .right_alt,
        .left_super => .left_super,
        .right_super => .right_super,
        else => null,
    };
}
