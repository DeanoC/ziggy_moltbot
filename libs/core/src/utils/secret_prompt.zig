const std = @import("std");
const builtin = @import("builtin");

/// Read a secret from stdin.
/// Best-effort disables echo on Windows; on other platforms it will echo.
pub fn readSecretAlloc(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(prompt);
    try stdout.writeAll("\n> ");

    const stdin = std.fs.File.stdin();

    const is_windows = builtin.os.tag == .windows;

    var restore_mode: ?u32 = null;
    if (is_windows) {
        const w = std.os.windows;
        const handle_opt = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
        if (handle_opt) |handle| {
            if (handle != w.INVALID_HANDLE_VALUE) {
                var mode: u32 = 0;
                if (w.kernel32.GetConsoleMode(handle, &mode) != 0) {
                    restore_mode = mode;
                    // Disable echo
                    const ENABLE_ECHO_INPUT: u32 = 0x0004;
                    const new_mode = mode & ~ENABLE_ECHO_INPUT;
                    _ = w.kernel32.SetConsoleMode(handle, new_mode);
                }
            }
        }
    }

    // IMPORTANT: keep windows-only symbols out of non-windows builds.
    defer if (is_windows) {
        if (restore_mode) |m| {
            const w = std.os.windows;
            const handle_opt = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
            if (handle_opt) |handle| {
                if (handle != w.INVALID_HANDLE_VALUE) {
                    _ = w.kernel32.SetConsoleMode(handle, m);
                }
            }
        }
    };

    const line = try stdin.deprecatedReader().readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
    if (line == null) return error.EndOfStream;
    var s = line.?;
    // Trim trailing \r (Windows). IMPORTANT: we must not return a subslice of an allocation
    // that the caller will free, because allocator.free() requires the original slice length.
    if (s.len > 0 and s[s.len - 1] == '\r') {
        const trimmed = try allocator.dupe(u8, s[0 .. s.len - 1]);
        allocator.free(s);
        s = trimmed;
    }

    // Re-enable echo before printing newline
    if (is_windows and restore_mode != null) {
        const w = std.os.windows;
        const handle_opt = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
        if (handle_opt) |handle| {
            if (handle != w.INVALID_HANDLE_VALUE) {
                _ = w.kernel32.SetConsoleMode(handle, restore_mode.?);
            }
        }
    }
    try stdout.writeAll("\n");

    return s;
}
