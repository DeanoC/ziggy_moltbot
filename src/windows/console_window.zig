const std = @import("std");
const builtin = @import("builtin");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
});

/// Hide the current process console window if one exists.
pub fn hideIfPresent() void {
    if (builtin.os.tag != .windows) return;
    const hwnd = win.GetConsoleWindow();
    if (hwnd != null) {
        _ = win.ShowWindow(hwnd, win.SW_HIDE);
    }
}
