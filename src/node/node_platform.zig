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
// Process lifecycle / shutdown
// -----------------------------------------------------------------------------

// NOTE: node-mode runs as a long-lived loop. Some hosts (Windows SCM service)
// need a cooperative shutdown signal.
var g_stop_requested = std.atomic.Value(bool).init(false);

/// Request a cooperative stop for node-mode (best-effort).
pub fn requestStop() void {
    g_stop_requested.store(true, .seq_cst);
}

/// Returns true if a cooperative stop has been requested.
pub fn stopRequested() bool {
    return g_stop_requested.load(.seq_cst);
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

/// System-wide storage templates (primarily for always-on Windows service mode).
///
/// NOTE: unified_config expands %ProgramData% at load time.
pub fn defaultSystemNodeStorageDirTemplate() []const u8 {
    return if (builtin.target.os.tag == .windows)
        "%ProgramData%\\ZiggyStarClaw"
    else
        "~/.config/ziggystarclaw";
}

pub fn defaultSystemNodeDeviceIdentityPathTemplate() []const u8 {
    return if (builtin.target.os.tag == .windows)
        "%ProgramData%\\ZiggyStarClaw\\node-device.json"
    else
        "~/.config/ziggystarclaw/node-device.json";
}

pub fn defaultSystemExecApprovalsPathTemplate() []const u8 {
    return if (builtin.target.os.tag == .windows)
        "%ProgramData%\\ZiggyStarClaw\\exec-approvals.json"
    else
        "~/.config/ziggystarclaw/exec-approvals.json";
}

// -----------------------------------------------------------------------------
// Notifications (placeholder)
// -----------------------------------------------------------------------------

pub fn notify(allocator: std.mem.Allocator, note: Notification) NotifyError!void {
    // Minimal best-effort notifications.
    // Philosophy: prefer a "works on my box" solution using common OS tools.

    switch (builtin.target.os.tag) {
        .linux => {
            // If there is no GUI session, just bail.
            const has_display = (std.process.getEnvVarOwned(allocator, "DISPLAY") catch null) != null or
                (std.process.getEnvVarOwned(allocator, "WAYLAND_DISPLAY") catch null) != null;
            if (!has_display) return error.NotSupported;

            var argv = std.ArrayList([]const u8).empty;
            defer argv.deinit(allocator);

            // notify-send TITLE BODY
            argv.append(allocator, "notify-send") catch return error.NotSupported;
            argv.append(allocator, note.title) catch return error.NotSupported;
            if (note.body) |b| {
                argv.append(allocator, b) catch return error.NotSupported;
            }

            var child = std.process.Child.init(argv.items, allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            child.spawn() catch |err| switch (err) {
                error.FileNotFound => return error.NotSupported,
                else => return error.NotImplemented,
            };

            _ = child.wait() catch return error.NotImplemented;
            return;
        },
        .macos => {
            // osascript -e 'display notification "body" with title "title"'
            const body = note.body orelse "";

            // Very small escape (good enough for our own usage).
            const esc = struct {
                fn q(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
                    var out = std.ArrayList(u8).empty;
                    errdefer out.deinit(alloc);
                    for (s) |c| {
                        if (c == '"' or c == '\\') {
                            try out.append(alloc, '\\');
                        }
                        try out.append(alloc, c);
                    }
                    return out.toOwnedSlice(alloc);
                }
            };

            const title_esc = esc.q(allocator, note.title) catch return error.NotImplemented;
            defer allocator.free(title_esc);
            const body_esc = esc.q(allocator, body) catch return error.NotImplemented;
            defer allocator.free(body_esc);

            const script = std.fmt.allocPrint(
                allocator,
                "display notification \"{s}\" with title \"{s}\"",
                .{ body_esc, title_esc },
            ) catch return error.NotImplemented;
            defer allocator.free(script);

            const argv = &[_][]const u8{ "osascript", "-e", script };

            var child = std.process.Child.init(argv, allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            child.spawn() catch |err| switch (err) {
                error.FileNotFound => return error.NotSupported,
                else => return error.NotImplemented,
            };
            _ = child.wait() catch return error.NotImplemented;
            return;
        },
        .windows => {
            // TODO: implement native Windows notifications.
            // For now, keep it explicit so callers know it didn't happen.
            return error.NotImplemented;
        },
        else => {
            return error.NotSupported;
        },
    }
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
