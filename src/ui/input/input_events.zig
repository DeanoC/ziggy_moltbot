const std = @import("std");
const zgui = @import("zgui");

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
    key: zgui.Key,
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
