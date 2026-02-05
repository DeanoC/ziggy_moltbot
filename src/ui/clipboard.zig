const std = @import("std");
const builtin = @import("builtin");

const use_sdl3 = !builtin.abi.isAndroid() and builtin.os.tag != .emscripten;
const use_sdl2 = builtin.abi.isAndroid();
const sdl3 = if (use_sdl3) @import("../platform/sdl3.zig").c else struct {};
const sdl2 = if (use_sdl2)
    @cImport({
        @cInclude("SDL.h");
    })
else
    struct {};

var cached: ?[:0]u8 = null;

pub fn setTextZ(text: [:0]const u8) void {
    if (use_sdl3) {
        _ = sdl3.SDL_SetClipboardText(text.ptr);
        return;
    }
    if (use_sdl2) {
        _ = sdl2.SDL_SetClipboardText(text.ptr);
    }
}

pub fn getTextZ() [:0]const u8 {
    if (!use_sdl3 and !use_sdl2) return "";
    if (cached) |buf| {
        std.heap.page_allocator.free(buf);
        cached = null;
    }
    if (use_sdl3) {
        const raw = sdl3.SDL_GetClipboardText();
        if (raw == null) return "";
        const slice = std.mem.span(raw);
        cached = std.heap.page_allocator.dupeZ(u8, slice) catch null;
        sdl3.SDL_free(raw);
        return cached orelse "";
    }
    if (use_sdl2) {
        const raw = sdl2.SDL_GetClipboardText();
        if (raw == null) return "";
        const slice = std.mem.span(raw);
        cached = std.heap.page_allocator.dupeZ(u8, slice) catch null;
        sdl2.SDL_free(raw);
    }
    return cached orelse "";
}
