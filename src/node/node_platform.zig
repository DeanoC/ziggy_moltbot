const std = @import("std");
const builtin = @import("builtin");

/// Minimal platform surface for node-mode.
///
/// Design goals:
/// - Keep node-mode logic mostly platform-agnostic.
/// - Centralize OS-specific path conventions.
/// - Provide placeholders for features that will be implemented per-platform later
///   (notifications, runtime permissions).
///
/// This is intentionally small and blocking/synchronous for now.
pub const Permission = enum {
    notifications,
    camera,
    microphone,
    location,
    screen_capture,
    process_execution,
    filesystem,
};

pub const PermissionStatus = enum {
    unknown,
    granted,
    denied,
};

pub const Notification = struct {
    title: []const u8,
    body: ?[]const u8 = null,
};

pub const NotifyError = error{ NotImplemented, NotSupported };
pub const PermissionError = error{ NotImplemented, NotSupported };

// -----------------------------------------------------------------------------
// Time
// -----------------------------------------------------------------------------

pub fn nowMs() i64 {
    // Use std.time for all hosted builds. (Future: WASM/Android ports may swap this.)
    return std.time.milliTimestamp();
}

pub fn sleepMs(ms: u64) void {
    // Blocking sleep.
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

// -----------------------------------------------------------------------------
// Storage paths (defaults / templates)
// -----------------------------------------------------------------------------

/// Default path to the unified config.json used by node-mode.
///
/// Returns an owned path.
pub fn defaultUnifiedConfigPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return @import("../unified_config.zig").defaultConfigPath(allocator);
}

/// Template directory for per-user node storage.
///
/// These are *templates* (may contain %APPDATA% / ~) so callers can persist them
/// into config.json without resolving env vars at write time.
pub fn defaultNodeStorageDirTemplate() []const u8 {
    return if (builtin.target.os.tag == .windows)
        "%APPDATA%\\ZiggyStarClaw"
    else
        "~/.config/ziggystarclaw";
}

pub fn defaultNodeDeviceIdentityPathTemplate() []const u8 {
    return if (builtin.target.os.tag == .windows)
        "%APPDATA%\\ZiggyStarClaw\\node-device.json"
    else
        "~/.config/ziggystarclaw/node-device.json";
}

pub fn defaultExecApprovalsPathTemplate() []const u8 {
    return if (builtin.target.os.tag == .windows)
        "%APPDATA%\\ZiggyStarClaw\\exec-approvals.json"
    else
        "~/.config/ziggystarclaw/exec-approvals.json";
}

// -----------------------------------------------------------------------------
// Notifications (placeholder)
// -----------------------------------------------------------------------------

pub fn notify(_: std.mem.Allocator, _: Notification) NotifyError!void {
    // TODO: implement per-platform notifications.
    return error.NotImplemented;
}

// -----------------------------------------------------------------------------
// Permissions (placeholder)
// -----------------------------------------------------------------------------

pub fn permissionStatus(_: Permission) PermissionStatus {
    // TODO: query OS-level permissions (Android runtime permissions, macOS TCC, etc.)
    return .unknown;
}

pub fn requestPermission(_: Permission) PermissionError!PermissionStatus {
    // TODO: request OS-level permission.
    return error.NotImplemented;
}
