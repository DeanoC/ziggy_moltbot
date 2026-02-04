const std = @import("std");
const zgui = @import("zgui");

extern fn zsc_imgui_save_ini_settings_to_memory(out_size: ?*usize) ?[*:0]const u8;
extern fn zsc_imgui_load_ini_settings_from_memory(data: [*]const u8, size: usize) void;
extern fn zsc_imgui_set_next_window_dock_id(dock_id: zgui.Ident, cond: zgui.Condition) void;
extern fn zsc_imgui_get_window_dock_id() zgui.Ident;
extern fn zsc_imgui_get_want_save_ini_settings() bool;
extern fn zsc_imgui_clear_want_save_ini_settings() void;
extern fn zsc_imgui_peek_input_queue_utf8(out_buf: ?[*]u8, buf_size: usize) usize;
extern fn zsc_imgui_get_mouse_wheel() f32;
extern fn zsc_imgui_get_mouse_wheel_h() f32;
extern fn zsc_imgui_set_want_text_input(value: bool) void;
extern fn zsc_imgui_set_ime_data(x: f32, y: f32, line_height: f32, want_visible: bool) void;
extern fn zsc_imgui_set_next_window_size_constraints(min_w: f32, min_h: f32, max_w: f32, max_h: f32) void;

pub fn saveIniToMemory(allocator: std.mem.Allocator) ![]u8 {
    var out_size: usize = 0;
    const ptr = zsc_imgui_save_ini_settings_to_memory(&out_size) orelse return allocator.dupe(u8, "");
    if (out_size == 0) return allocator.dupe(u8, "");
    return allocator.dupe(u8, ptr[0..out_size]);
}

pub fn loadIniFromMemory(data: []const u8) void {
    if (data.len == 0) return;
    zsc_imgui_load_ini_settings_from_memory(data.ptr, data.len);
}

pub fn resetIni() void {
    zsc_imgui_load_ini_settings_from_memory("", 0);
}

pub fn setNextWindowDockId(dock_id: zgui.Ident, cond: zgui.Condition) void {
    zsc_imgui_set_next_window_dock_id(dock_id, cond);
}

pub fn getWindowDockId() zgui.Ident {
    return zsc_imgui_get_window_dock_id();
}

pub fn wantSaveIniSettings() bool {
    return zsc_imgui_get_want_save_ini_settings();
}

pub fn clearWantSaveIniSettings() void {
    zsc_imgui_clear_want_save_ini_settings();
}

pub fn peekInputQueueUtf8(allocator: std.mem.Allocator) ?[]u8 {
    const needed = zsc_imgui_peek_input_queue_utf8(null, 0);
    if (needed == 0) return null;
    var buf = allocator.alloc(u8, needed) catch return null;
    const written = zsc_imgui_peek_input_queue_utf8(buf.ptr, buf.len);
    if (written == 0) {
        allocator.free(buf);
        return null;
    }
    return buf[0..written];
}

pub fn getMouseWheel() f32 {
    return zsc_imgui_get_mouse_wheel();
}

pub fn getMouseWheelH() f32 {
    return zsc_imgui_get_mouse_wheel_h();
}

pub fn setWantTextInput(value: bool) void {
    zsc_imgui_set_want_text_input(value);
}

pub fn setImeData(pos: [2]f32, line_height: f32, want_visible: bool) void {
    zsc_imgui_set_ime_data(pos[0], pos[1], line_height, want_visible);
}

pub fn setNextWindowSizeConstraints(min: [2]f32, max: [2]f32) void {
    zsc_imgui_set_next_window_size_constraints(min[0], min[1], max[0], max[1]);
}
