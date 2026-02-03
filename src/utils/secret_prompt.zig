const std = @import("std");
const builtin = @import("builtin");

/// Read a secret from stdin.
/// Best-effort disables echo on Windows; on other platforms it will echo.
pub fn readSecretAlloc(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(prompt);
    try stdout.writeAll("\n> ");

    const stdin = std.fs.File.stdin();

    var restore_mode: ?u32 = null;
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const handle = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
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
    defer {
        if (restore_mode) |m| {
            const w = std.os.windows;
            const handle = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
            if (handle != w.INVALID_HANDLE_VALUE) {
                _ = w.kernel32.SetConsoleMode(handle, m);
            }
        }
    }

    const line = try stdin.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
    if (line == null) return error.EndOfStream;
    var s = line.?;
    // Trim \r
    if (s.len > 0 and s[s.len - 1] == '\r') {
        s = s[0 .. s.len - 1];
    }

    // Re-enable echo before printing newline
    if (builtin.os.tag == .windows and restore_mode != null) {
        const w = std.os.windows;
        const handle = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE);
        if (handle != w.INVALID_HANDLE_VALUE) {
            _ = w.kernel32.SetConsoleMode(handle, restore_mode.?);
        }
    }
    try stdout.writeAll("\n");

    return s;
}
