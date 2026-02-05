const std = @import("std");
const command_list = @import("command_list.zig");
const draw_context = @import("../draw_context.zig");

var global_list: ?command_list.CommandList = null;

pub fn beginFrame(allocator: std.mem.Allocator) *command_list.CommandList {
    if (global_list == null) {
        global_list = command_list.CommandList.init(allocator);
    }
    var list = &global_list.?;
    list.clear();
    draw_context.setGlobalCommandList(list);
    return list;
}

pub fn endFrame() void {
    draw_context.clearGlobalCommandList();
}

pub fn get() ?*command_list.CommandList {
    if (global_list) |*list| {
        return list;
    }
    return null;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (global_list) |*list| {
        list.deinit();
        global_list = null;
    }
    _ = allocator;
}
