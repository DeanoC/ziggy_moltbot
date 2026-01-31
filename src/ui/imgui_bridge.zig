const std = @import("std");
const zgui = @import("zgui");

extern fn zsc_imgui_save_ini_settings_to_memory(out_size: ?*usize) ?[*:0]const u8;
extern fn zsc_imgui_load_ini_settings_from_memory(data: [*]const u8, size: usize) void;
extern fn zsc_imgui_set_next_window_dock_id(dock_id: zgui.Ident, cond: zgui.Condition) void;
extern fn zsc_imgui_get_window_dock_id() zgui.Ident;
extern fn zsc_imgui_get_want_save_ini_settings() bool;
extern fn zsc_imgui_clear_want_save_ini_settings() void;

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
