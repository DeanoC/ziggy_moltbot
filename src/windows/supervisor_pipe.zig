const std = @import("std");
const builtin = @import("builtin");

pub const pipe_name_utf8: []const u8 = "\\\\.\\pipe\\ZiggyStarClaw.NodeControl";

pub const Shared = struct {
    mutex: std.Thread.Mutex = .{},
    desired_running: bool = true,
    restart_requested: bool = false,
    is_running: bool = false,
    pid: u32 = 0,
};

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("sddl.h");
});

fn utf16Z(a: std.mem.Allocator, s: []const u8) ![]u16 {
    const tmp = try std.unicode.utf8ToUtf16LeAlloc(a, s);
    defer a.free(tmp);
    var out = try a.alloc(u16, tmp.len + 1);
    @memcpy(out[0..tmp.len], tmp);
    out[tmp.len] = 0;
    return out;
}

pub fn spawnServerThread(allocator: std.mem.Allocator, shared: *Shared) !void {
    if (builtin.os.tag != .windows) return;
    const t = try std.Thread.spawn(.{}, serverThreadMain, .{ allocator, shared });
    t.detach();
}

pub fn getExitCode(h_process: std.os.windows.HANDLE) ?u32 {
    if (builtin.os.tag != .windows) return null;
    var code: u32 = 0;
    if (win.GetExitCodeProcess(@ptrCast(h_process), &code) == 0) return null;
    return code;
}

pub fn getPid(h_process: std.os.windows.HANDLE) u32 {
    if (builtin.os.tag != .windows) return 0;
    return @intCast(win.GetProcessId(@ptrCast(h_process)));
}

pub fn isStillActive(exit_code: u32) bool {
    return exit_code == win.STILL_ACTIVE;
}

fn serverThreadMain(allocator: std.mem.Allocator, shared: *Shared) void {
    // Allow any user to connect (read/write), plus SYSTEM/Administrators full.
    const sddl_utf8 = "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;WD)";

    const wpipe = utf16Z(allocator, pipe_name_utf8) catch return;
    defer allocator.free(wpipe);

    const wsddl = utf16Z(allocator, sddl_utf8) catch return;
    defer allocator.free(wsddl);

    var sd: ?*anyopaque = null;
    if (win.ConvertStringSecurityDescriptorToSecurityDescriptorW(wsddl.ptr, win.SDDL_REVISION_1, @ptrCast(&sd), null) == 0) {
        sd = null;
    }
    defer if (sd) |p| {
        _ = win.LocalFree(@ptrCast(p));
    };

    var sa: win.SECURITY_ATTRIBUTES = std.mem.zeroes(win.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(win.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = win.TRUE;
    sa.lpSecurityDescriptor = sd;

    while (true) {
        const hpipe = win.CreateNamedPipeW(
            wpipe.ptr,
            win.PIPE_ACCESS_DUPLEX,
            win.PIPE_TYPE_MESSAGE | win.PIPE_READMODE_MESSAGE | win.PIPE_WAIT,
            1,
            4096,
            4096,
            0,
            if (sd != null) &sa else null,
        );
        if (hpipe == win.INVALID_HANDLE_VALUE) {
            std.time.sleep(1 * std.time.ns_per_s);
            continue;
        }

        const connected = win.ConnectNamedPipe(hpipe, null);
        if (connected == 0) {
            const err = win.GetLastError();
            if (err != win.ERROR_PIPE_CONNECTED) {
                _ = win.CloseHandle(hpipe);
                continue;
            }
        }

        var buf: [512]u8 = undefined;
        var read_n: u32 = 0;
        const ok_read = win.ReadFile(hpipe, &buf, buf.len, &read_n, null);
        if (ok_read != 0 and read_n > 0) {
            const line = std.mem.trim(u8, buf[0..read_n], " \t\r\n");

            var response: [256]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&response);
            const w = fbs.writer();

            if (std.mem.eql(u8, line, "status")) {
                shared.mutex.lock();
                const running = shared.is_running;
                const pid = shared.pid;
                shared.mutex.unlock();
                _ = w.print("ok status={s} pid={d}\n", .{ if (running) "running" else "stopped", pid }) catch {};
            } else if (std.mem.eql(u8, line, "start")) {
                shared.mutex.lock();
                shared.desired_running = true;
                shared.mutex.unlock();
                _ = w.writeAll("ok\n") catch {};
            } else if (std.mem.eql(u8, line, "stop")) {
                shared.mutex.lock();
                shared.desired_running = false;
                shared.mutex.unlock();
                _ = w.writeAll("ok\n") catch {};
            } else if (std.mem.eql(u8, line, "restart")) {
                shared.mutex.lock();
                shared.desired_running = true;
                shared.restart_requested = true;
                shared.mutex.unlock();
                _ = w.writeAll("ok\n") catch {};
            } else if (std.mem.eql(u8, line, "ping")) {
                _ = w.writeAll("ok pong\n") catch {};
            } else {
                _ = w.writeAll("err unknown_command\n") catch {};
            }

            const out = fbs.getWritten();
            var wrote_n: u32 = 0;
            _ = win.WriteFile(hpipe, out.ptr, @intCast(out.len), &wrote_n, null);
        }

        _ = win.FlushFileBuffers(hpipe);
        _ = win.DisconnectNamedPipe(hpipe);
        _ = win.CloseHandle(hpipe);
    }
}
