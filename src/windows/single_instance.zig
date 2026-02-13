const std = @import("std");
const builtin = @import("builtin");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("sddl.h");
});

pub const AcquireResult = struct {
    handle: std.os.windows.HANDLE,
    already_running: bool,
    name_used_utf8: []const u8,
};

pub const node_supervisor_lock_global = "Global\\ZiggyStarClaw.NodeSupervisor";
pub const node_supervisor_lock_local = "Local\\ZiggyStarClaw.NodeSupervisor";
pub const node_owner_lock_global = "Global\\ZiggyStarClaw.NodeOwner";
pub const node_owner_lock_local = "Local\\ZiggyStarClaw.NodeOwner";

fn utf16Z(a: std.mem.Allocator, s: []const u8) ![]u16 {
    const tmp = try std.unicode.utf8ToUtf16LeAlloc(a, s);
    defer a.free(tmp);
    var out = try a.alloc(u16, tmp.len + 1);
    @memcpy(out[0..tmp.len], tmp);
    out[tmp.len] = 0;
    return out;
}

fn createMutexWithSddl(a: std.mem.Allocator, name_utf8: []const u8, sddl_utf8: []const u8) !std.os.windows.HANDLE {
    const wname = try utf16Z(a, name_utf8);
    defer a.free(wname);

    const wsddl = try utf16Z(a, sddl_utf8);
    defer a.free(wsddl);

    var sd: ?*anyopaque = null;
    if (win.ConvertStringSecurityDescriptorToSecurityDescriptorW(wsddl.ptr, win.SDDL_REVISION_1, @ptrCast(&sd), null) == 0) {
        return error.AccessDenied;
    }
    defer if (sd) |p| {
        _ = win.LocalFree(@ptrCast(p));
    };

    var sa: win.SECURITY_ATTRIBUTES = std.mem.zeroes(win.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(win.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = win.FALSE;
    sa.lpSecurityDescriptor = sd;

    const h = win.CreateMutexW(&sa, win.TRUE, wname.ptr);
    if (h == null) {
        const err = win.GetLastError();
        // Map common errors.
        switch (err) {
            win.ERROR_ACCESS_DENIED => return error.AccessDenied,
            win.ERROR_INVALID_NAME => return error.InvalidName,
            else => return error.Unexpected,
        }
    }

    return @ptrCast(h);
}

fn acquireNamedMutex(
    allocator: std.mem.Allocator,
    global_name: []const u8,
    local_name: []const u8,
) !AcquireResult {
    if (builtin.os.tag != .windows) return error.Unsupported;

    // SYSTEM+Admins full; Everyone full (used only as a process guard).
    const sddl_utf8 = "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;WD)";

    var name_used: []const u8 = global_name;
    const h = createMutexWithSddl(allocator, global_name, sddl_utf8) catch |err| blk: {
        // If we can't create/open a global mutex (common for non-admin), fall back.
        if (err == error.AccessDenied or err == error.InvalidName) {
            name_used = local_name;
            break :blk try createMutexWithSddl(allocator, local_name, sddl_utf8);
        }
        return err;
    };

    const already = (win.GetLastError() == win.ERROR_ALREADY_EXISTS);
    return .{ .handle = h, .already_running = already, .name_used_utf8 = name_used };
}

/// Acquire the mutex used by the Windows node supervisor wrapper.
///
/// Historical name retained for compatibility with existing wrappers.
pub fn acquireNodeSupervisorMutex(allocator: std.mem.Allocator) !AcquireResult {
    return acquireNamedMutex(
        allocator,
        node_supervisor_lock_global,
        node_supervisor_lock_local,
    );
}

/// Acquire the cross-mode node ownership mutex (service/runner startup guard).
///
/// This prevents startup races from creating two concurrent node sessions.
pub fn acquireNodeOwnerMutex(allocator: std.mem.Allocator) !AcquireResult {
    return acquireNamedMutex(
        allocator,
        node_owner_lock_global,
        node_owner_lock_local,
    );
}

/// Acquire a process mutex using shared Global->Local fallback semantics.
///
/// Intended for process single-instance guards (for example, tray startup).
pub fn acquireNamedProcessMutex(
    allocator: std.mem.Allocator,
    global_name: []const u8,
    local_name: []const u8,
) !AcquireResult {
    return acquireNamedMutex(allocator, global_name, local_name);
}
