const std = @import("std");

pub const Key = enum {
    enter,
    keypad_enter,
    back_space,
    delete,
    tab,
    left_arrow,
    right_arrow,
    up_arrow,
    down_arrow,
    home,
    end,
    page_up,
    page_down,
    a,
    c,
    v,
    x,
    z,
    y,
    left_ctrl,
    right_ctrl,
    left_shift,
    right_shift,
    left_alt,
    right_alt,
    left_super,
    right_super,
};

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn matches(a: Modifiers, b: Modifiers) bool {
        return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and a.super == b.super;
    }
};

pub const MouseButton = enum {
    left,
    right,
    middle,
};

pub const KeyEvent = struct {
    key: Key,
    mods: Modifiers,
    repeat: bool = false,
};

pub const MouseMoveEvent = struct {
    pos: [2]f32,
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    pos: [2]f32,
};

pub const MouseWheelEvent = struct {
    delta: [2]f32,
};

pub const TextInputEvent = struct {
    text: []u8,
};

pub const InputEvent = union(enum) {
    key_down: KeyEvent,
    key_up: KeyEvent,
    text_input: TextInputEvent,
    mouse_move: MouseMoveEvent,
    mouse_down: MouseButtonEvent,
    mouse_up: MouseButtonEvent,
    mouse_wheel: MouseWheelEvent,
    focus_gained,
    focus_lost,

    pub fn deinit(self: *InputEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text_input => |*evt| allocator.free(evt.text),
            else => {},
        }
    }
};
