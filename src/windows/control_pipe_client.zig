const std = @import("std");
const builtin = @import("builtin");

const supervisor_pipe = @import("supervisor_pipe.zig");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
});

fn utf16Z(allocator: std.mem.Allocator, s: []const u8) ![]u16 {
    const tmp = try std.unicode.utf8ToUtf16LeAlloc(allocator, s);
    defer allocator.free(tmp);

    var out = try allocator.alloc(u16, tmp.len + 1);
    @memcpy(out[0..tmp.len], tmp);
    out[tmp.len] = 0;
    return out;
}

/// Send a command to the node supervisor control pipe.
/// Returns null if the pipe is not available.
pub fn request(allocator: std.mem.Allocator, cmd: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;

    const wpipe = utf16Z(allocator, supervisor_pipe.pipe_name_utf8) catch return null;
    defer allocator.free(wpipe);

    const h = win.CreateFileW(
        wpipe.ptr,
        win.GENERIC_READ | win.GENERIC_WRITE,
        0,
        null,
        win.OPEN_EXISTING,
        0,
        null,
    );
    if (h == win.INVALID_HANDLE_VALUE) return null;
    defer _ = win.CloseHandle(h);

    // Write command line.
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s}\n", .{cmd});

    var written: u32 = 0;
    if (win.WriteFile(h, line.ptr, @intCast(line.len), &written, null) == 0) return error.PipeWriteFailed;

    // Read response.
    var out_buf: [256]u8 = undefined;
    var read_n: u32 = 0;
    if (win.ReadFile(h, &out_buf, out_buf.len, &read_n, null) == 0) return error.PipeReadFailed;
    if (read_n == 0) return error.PipeReadFailed;

    return try allocator.dupe(u8, out_buf[0..read_n]);
}

pub fn requestOk(allocator: std.mem.Allocator, cmd: []const u8) !?bool {
    const resp = (try request(allocator, cmd)) orelse return null;
    defer allocator.free(resp);

    const s = std.mem.trim(u8, resp, " \t\r\n");
    return std.mem.startsWith(u8, s, "ok");
}
