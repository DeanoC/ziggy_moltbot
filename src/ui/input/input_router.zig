const std = @import("std");
const input_state = @import("input_state.zig");
const input_backend = @import("input_backend.zig");

var owned_queue: ?input_state.InputQueue = null;
var active_queue: ?*input_state.InputQueue = null;
var backend: input_backend.Backend = input_backend.sdl3;

pub fn beginFrame(allocator: std.mem.Allocator) *input_state.InputQueue {
    if (owned_queue == null) {
        owned_queue = input_state.InputQueue.init(allocator);
    }
    owned_queue.?.clear(allocator);
    active_queue = &owned_queue.?;
    return active_queue.?;
}

pub fn collect(allocator: std.mem.Allocator) void {
    const queue = active_queue orelse beginFrame(allocator);
    backend.collect(allocator, queue);
}

pub fn setBackend(new_backend: input_backend.Backend) void {
    backend = new_backend;
}

pub fn getBackend() input_backend.Backend {
    return backend;
}

pub fn setExternalQueue(queue: ?*input_state.InputQueue) void {
    active_queue = queue;
}

pub fn getQueue() *input_state.InputQueue {
    return active_queue.?;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (owned_queue) |*queue| {
        queue.deinit(allocator);
        owned_queue = null;
    }
    active_queue = null;
}
