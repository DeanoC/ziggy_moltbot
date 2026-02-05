const builtin = @import("builtin");

const use_sdl = !builtin.abi.isAndroid() and switch (builtin.os.tag) {
    .linux, .windows, .macos => true,
    else => false,
};
const sdl = if (use_sdl) @import("../../platform/sdl3.zig").c else struct {};

const CursorHandle = if (use_sdl) *sdl.SDL_Cursor else u8;
var arrow_cursor: ?CursorHandle = null;
var resize_ew_cursor: ?CursorHandle = null;
var resize_ns_cursor: ?CursorHandle = null;

pub const Cursor = enum {
    arrow,
    resize_ew,
    resize_ns,
};

pub fn set(cursor: Cursor) void {
    if (!use_sdl) return;
    const handle = switch (cursor) {
        .arrow => &arrow_cursor,
        .resize_ew => &resize_ew_cursor,
        .resize_ns => &resize_ns_cursor,
    };
    if (handle.* == null) {
        handle.* = sdl.SDL_CreateSystemCursor(switch (cursor) {
            .arrow => sdl.SDL_SYSTEM_CURSOR_DEFAULT,
            .resize_ew => sdl.SDL_SYSTEM_CURSOR_EW_RESIZE,
            .resize_ns => sdl.SDL_SYSTEM_CURSOR_NS_RESIZE,
        });
    }
    if (handle.*) |cursor_handle| {
        _ = sdl.SDL_SetCursor(cursor_handle);
    }
}
