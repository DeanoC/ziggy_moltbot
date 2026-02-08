const std = @import("std");
const events = @import("input_events.zig");

pub const PointerKind = enum {
    mouse,
    touch,
    pen,
    nav,
};

pub const InputState = struct {
    mouse_pos: [2]f32 = .{ 0.0, 0.0 },
    mouse_down_left: bool = false,
    mouse_down_right: bool = false,
    mouse_down_middle: bool = false,
    modifiers: events.Modifiers = .{},

    // Used for touch/pen drag scrolling (and potential future gestures).
    pointer_kind: PointerKind = .mouse,
    pointer_drag_delta: [2]f32 = .{ 0.0, 0.0 },
};

pub const InputQueue = struct {
    events: std.ArrayList(events.InputEvent),
    state: InputState = .{},

    pub fn init(allocator: std.mem.Allocator) InputQueue {
        _ = allocator;
        return .{ .events = .empty, .state = .{} };
    }

    pub fn deinit(self: *InputQueue, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.events.deinit(allocator);
    }

    pub fn clear(self: *InputQueue, allocator: std.mem.Allocator) void {
        for (self.events.items) |*evt| {
            evt.deinit(allocator);
        }
        self.events.clearRetainingCapacity();
    }

    pub fn push(self: *InputQueue, allocator: std.mem.Allocator, evt: events.InputEvent) void {
        self.events.append(allocator, evt) catch {
            var owned = evt;
            owned.deinit(allocator);
        };
    }
};
