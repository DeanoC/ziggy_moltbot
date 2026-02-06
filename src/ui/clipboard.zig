const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("../platform/sdl3.zig").c;

const use_wasm_clipboard = builtin.os.tag == .emscripten;

extern fn zsc_clipboard_init() void;
extern fn zsc_clipboard_set(text: [*:0]const u8) void;
extern fn zsc_clipboard_len() c_int;
extern fn zsc_clipboard_copy(dst: [*]u8, dst_len: c_int) c_int;

var cached: ?[:0]u8 = null;

pub fn setTextZ(text: [:0]const u8) void {
    if (use_wasm_clipboard) {
        zsc_clipboard_set(text.ptr);
        return;
    }
    _ = sdl.SDL_SetClipboardText(text.ptr);
}

pub fn getTextZ() [:0]const u8 {
    if (cached) |buf| {
        std.heap.page_allocator.free(buf);
        cached = null;
    }
    if (use_wasm_clipboard) {
        const len_c = zsc_clipboard_len();
        if (len_c <= 0) return "";
        const len: usize = @intCast(len_c);
        const buf = std.heap.page_allocator.alloc(u8, len + 1) catch return "";
        buf[len] = 0;
        // Write including terminator; JS will truncate if needed.
        _ = zsc_clipboard_copy(buf.ptr, @intCast(len + 1));
        cached = buf[0..len :0];
        return cached orelse "";
    }
    const raw = sdl.SDL_GetClipboardText();
    if (raw == null) return "";
    const slice = std.mem.span(raw);
    cached = std.heap.page_allocator.dupeZ(u8, slice) catch null;
    sdl.SDL_free(raw);
    return cached orelse "";
}

pub fn init() void {
    if (use_wasm_clipboard) {
        zsc_clipboard_init();
    }
}
