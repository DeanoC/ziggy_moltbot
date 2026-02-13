const std = @import("std");

pub fn defaultAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}
