const std = @import("std");
const builtin = @import("builtin");
const input_state = @import("input_state.zig");
const input_backend = @import("input_backend.zig");
const ui_build = @import("../ui_build.zig");

var global_queue: ?input_state.InputQueue = null;
var backend: input_backend.Backend = if (ui_build.use_imgui)
    input_backend.imgui
else if (builtin.os.tag == .emscripten)
    input_backend.glfw
else
    input_backend.sdl3;

pub fn beginFrame(allocator: std.mem.Allocator) *input_state.InputQueue {
    if (global_queue == null) {
        global_queue = input_state.InputQueue.init(allocator);
    }
    global_queue.?.clear(allocator);
    return &global_queue.?;
}

pub fn collect(allocator: std.mem.Allocator) void {
    if (global_queue == null) {
        _ = beginFrame(allocator);
    }
    backend.collect(allocator, &global_queue.?);
}

pub fn setBackend(new_backend: input_backend.Backend) void {
    backend = new_backend;
}

pub fn getBackend() input_backend.Backend {
    return backend;
}

pub fn getQueue() *input_state.InputQueue {
    return &global_queue.?;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (global_queue) |*queue| {
        queue.deinit(allocator);
        global_queue = null;
    }
}
