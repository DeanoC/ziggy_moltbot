const std = @import("std");
const builtin = @import("builtin");

// Generic async fetch for WASM builds, implemented by `src/wasm_fetch.cpp`.
// The C++ glue calls back into the exported functions below.
const c = if (builtin.cpu.arch == .wasm32) struct {
    extern fn zsc_wasm_fetch(url: [*:0]const u8, ctx: usize) void;
} else struct {};

pub const SuccessFn = *const fn (user_ctx: usize, bytes: []const u8) void;
pub const ErrorFn = *const fn (user_ctx: usize, msg: []const u8) void;

const Request = struct {
    allocator: std.mem.Allocator,
    user_ctx: usize,
    on_success: SuccessFn,
    on_error: ErrorFn,
};

pub fn fetchBytes(
    allocator: std.mem.Allocator,
    url: []const u8,
    user_ctx: usize,
    on_success: SuccessFn,
    on_error: ErrorFn,
) !void {
    if (builtin.cpu.arch != .wasm32) return error.UnsupportedPlatform;
    if (url.len == 0) return error.InvalidUrl;

    const req = try allocator.create(Request);
    req.* = .{
        .allocator = allocator,
        .user_ctx = user_ctx,
        .on_success = on_success,
        .on_error = on_error,
    };

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    c.zsc_wasm_fetch(url_z.ptr, @intFromPtr(req));
}

pub export fn zsc_wasm_fetch_on_success(ctx: usize, ptr: [*]u8, len: usize) void {
    if (builtin.cpu.arch != .wasm32) return;
    const req: *Request = @ptrFromInt(ctx);
    const bytes = ptr[0..len];
    req.on_success(req.user_ctx, bytes);
    req.allocator.destroy(req);
}

pub export fn zsc_wasm_fetch_on_error(ctx: usize, msg_ptr: [*:0]const u8) void {
    if (builtin.cpu.arch != .wasm32) return;
    const req: *Request = @ptrFromInt(ctx);
    const msg = if (@intFromPtr(msg_ptr) == 0) "fetch failed" else std.mem.sliceTo(msg_ptr, 0);
    req.on_error(req.user_ctx, msg);
    req.allocator.destroy(req);
}

