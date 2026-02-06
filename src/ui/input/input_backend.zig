const std = @import("std");

const input_state = @import("input_state.zig");
const sdl_input_backend = @import("sdl_input_backend.zig");

pub const Backend = struct {
    collectFn: *const fn (std.mem.Allocator, *input_state.InputQueue) void,

    pub fn collect(self: Backend, allocator: std.mem.Allocator, queue: *input_state.InputQueue) void {
        self.collectFn(allocator, queue);
    }
};

pub const noop = Backend{
    .collectFn = collectNoop,
};

pub const sdl3 = Backend{
    .collectFn = sdl_input_backend.collect,
};

fn collectNoop(_: std.mem.Allocator, _: *input_state.InputQueue) void {}

