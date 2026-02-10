const std = @import("std");
const builtin = @import("builtin");
const logger = @import("../utils/logger.zig");

pub const CameraDevice = struct {
    name: []const u8,
    deviceId: []const u8,
};

pub const CameraListError = error{
    NotSupported,
    PowershellNotFound,
    CommandFailed,
    InvalidOutput,
};

/// Best-effort Windows camera enumeration.
///
/// MVP uses PowerShell + CIM as a dependency-free approach.
/// Follow-up: replace with Windows Media Foundation device enumeration.
pub fn listCameras(allocator: std.mem.Allocator) CameraListError![]CameraDevice {
    if (builtin.target.os.tag != .windows) return error.NotSupported;

    const script =
        "$ErrorActionPreference='Stop'; " ++
        "$devices = Get-CimInstance Win32_PnPEntity | ? { $_.PNPClass -eq 'Camera' -or $_.PNPClass -eq 'Image' } | Select-Object Name,PNPDeviceID; " ++
        "$devices | ConvertTo-Json -Compress";

    const out = runPowershellJson(allocator, script) catch |err| switch (err) {
        error.FileNotFound => return error.PowershellNotFound,
        else => return error.CommandFailed,
    };

    return parseDevicesJson(allocator, out) catch return error.InvalidOutput;
}

fn runPowershellJson(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    // Prefer Windows PowerShell if present, otherwise try pwsh.
    const candidates = &[_][]const u8{ "powershell", "pwsh" };

    for (candidates) |exe| {
        const argv = &[_][]const u8{
            exe,
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        };

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        const stdout_bytes = child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024) catch |err| {
            _ = child.kill() catch {};
            return err;
        };
        const stderr_bytes = child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024) catch |err| {
            _ = child.kill() catch {};
            return err;
        };

        const term = child.wait() catch |err| {
            logger.err("powershell wait failed: {s}", .{@errorName(err)});
            return err;
        };

        const exit_code: i32 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| @intCast(sig),
            .Stopped => |sig| @intCast(sig),
            .Unknown => |code| @intCast(code),
        };

        if (exit_code != 0) {
            logger.warn("powershell camera list failed: exit={d} stderr={s}", .{ exit_code, stderr_bytes });
            return error.CommandFailed;
        }

        // Ignore stderr if exit code is 0; some PS setups may emit warnings.
        _ = stderr_bytes;
        return stdout_bytes;
    }

    return error.FileNotFound;
}

fn parseDevicesJson(allocator: std.mem.Allocator, stdout_bytes: []const u8) ![]CameraDevice {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout_bytes, .{});
    defer parsed.deinit();

    const v = parsed.value;
    switch (v) {
        .null => return try allocator.alloc(CameraDevice, 0),
        .array => |arr| {
            var out = try allocator.alloc(CameraDevice, arr.items.len);
            var n: usize = 0;
            for (arr.items) |item| {
                if (item != .object) continue;
                const obj = item.object;

                const name_v = obj.get("Name") orelse continue;
                const pnp_v = obj.get("PNPDeviceID") orelse continue;
                if (name_v != .string or pnp_v != .string) continue;

                out[n] = .{
                    .name = try allocator.dupe(u8, name_v.string),
                    .deviceId = try allocator.dupe(u8, pnp_v.string),
                };
                n += 1;
            }
            return out[0..n];
        },
        .object => |obj| {
            const name_v = obj.get("Name") orelse return try allocator.alloc(CameraDevice, 0);
            const pnp_v = obj.get("PNPDeviceID") orelse return try allocator.alloc(CameraDevice, 0);
            if (name_v != .string or pnp_v != .string) return try allocator.alloc(CameraDevice, 0);

            const out = try allocator.alloc(CameraDevice, 1);
            out[0] = .{
                .name = try allocator.dupe(u8, name_v.string),
                .deviceId = try allocator.dupe(u8, pnp_v.string),
            };
            return out;
        },
        else => return try allocator.alloc(CameraDevice, 0),
    }
}
