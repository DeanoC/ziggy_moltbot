const std = @import("std");
const builtin = @import("builtin");
const logger = @import("../utils/logger.zig");

pub const CameraPosition = enum {
    front,
    back,
    external,

    pub fn toString(self: CameraPosition) []const u8 {
        return switch (self) {
            .front => "front",
            .back => "back",
            .external => "external",
        };
    }
};

pub const CameraDevice = struct {
    name: []const u8,
    deviceId: []const u8,
    position: ?CameraPosition = null,
};

pub const CameraListError = error{
    NotSupported,
    PowershellNotFound,
    CommandFailed,
    InvalidOutput,
};

const backend_name = "powershell-cim";

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
        error.FileNotFound => {
            logger.err("camera.list backend={s} failed: PowerShell not found (tried powershell, pwsh)", .{backend_name});
            return error.PowershellNotFound;
        },
        else => {
            logger.err("camera.list backend={s} failed to execute: {s}", .{ backend_name, @errorName(err) });
            return error.CommandFailed;
        },
    };
    defer allocator.free(out);

    return parseDevicesJson(allocator, out) catch |err| {
        logger.err("camera.list backend={s} failed to parse JSON output: {s}", .{ backend_name, @errorName(err) });
        return error.InvalidOutput;
    };
}

fn runPowershellJson(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    // Prefer Windows PowerShell if present, otherwise try pwsh.
    const candidates = &[_][]const u8{ "powershell", "pwsh" };

    var saw_executable = false;
    var last_error: ?anyerror = null;

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

        const res = std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .max_output_bytes = 1024 * 1024,
        }) catch |err| switch (err) {
            // Try the next candidate.
            error.FileNotFound => {
                logger.warn("camera.list backend={s}: executable not found: {s}", .{ backend_name, exe });
                continue;
            },
            else => {
                logger.warn("camera.list backend={s}: failed to start {s}: {s}", .{ backend_name, exe, @errorName(err) });
                saw_executable = true;
                last_error = err;
                continue;
            },
        };

        saw_executable = true;

        const term = res.term;
        const exit_code: i32 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| @intCast(sig),
            .Stopped => |sig| @intCast(sig),
            .Unknown => |code| @intCast(code),
        };

        if (exit_code != 0) {
            logger.warn("camera.list backend={s} failed via {s}: exit={d} stderr={s}", .{ backend_name, exe, exit_code, res.stderr });
            allocator.free(res.stdout);
            allocator.free(res.stderr);
            last_error = error.CommandFailed;
            continue;
        }

        // Ignore stderr if exit code is 0; some PS setups may emit warnings.
        allocator.free(res.stderr);
        return res.stdout;
    }

    if (!saw_executable) return error.FileNotFound;
    return last_error orelse error.CommandFailed;
}

fn parseDevicesJson(allocator: std.mem.Allocator, stdout_bytes: []const u8) ![]CameraDevice {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout_bytes, .{});
    defer parsed.deinit();

    var devices = std.ArrayList(CameraDevice).empty;
    errdefer {
        for (devices.items) |dev| {
            allocator.free(@constCast(dev.name));
            allocator.free(@constCast(dev.deviceId));
        }
        devices.deinit(allocator);
    }

    const v = parsed.value;
    switch (v) {
        .null => {},
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                try appendDevice(allocator, &devices, item.object);
            }
        },
        .object => |obj| {
            try appendDevice(allocator, &devices, obj);
        },
        else => {},
    }

    return devices.toOwnedSlice(allocator);
}

fn appendDevice(allocator: std.mem.Allocator, devices: *std.ArrayList(CameraDevice), obj: std.json.ObjectMap) !void {
    const name_v = obj.get("Name") orelse return;
    const pnp_v = obj.get("PNPDeviceID") orelse return;
    if (name_v != .string or pnp_v != .string) return;

    const name = try allocator.dupe(u8, name_v.string);
    errdefer allocator.free(name);

    const device_id = try allocator.dupe(u8, pnp_v.string);
    errdefer allocator.free(device_id);

    try devices.append(allocator, .{
        .name = name,
        .deviceId = device_id,
        .position = inferCameraPosition(name_v.string, pnp_v.string),
    });
}

fn inferCameraPosition(name: []const u8, pnp_id: []const u8) ?CameraPosition {
    if (containsAsciiIgnoreCase(name, "front") or
        containsAsciiIgnoreCase(name, "user facing") or
        containsAsciiIgnoreCase(pnp_id, "front"))
    {
        return .front;
    }

    if (containsAsciiIgnoreCase(name, "back") or
        containsAsciiIgnoreCase(name, "rear") or
        containsAsciiIgnoreCase(name, "world") or
        containsAsciiIgnoreCase(name, "environment") or
        containsAsciiIgnoreCase(pnp_id, "rear") or
        containsAsciiIgnoreCase(pnp_id, "back"))
    {
        return .back;
    }

    if (containsAsciiIgnoreCase(name, "usb") or
        containsAsciiIgnoreCase(name, "external") or
        containsAsciiIgnoreCase(name, "logitech") or
        containsAsciiIgnoreCase(pnp_id, "usb"))
    {
        return .external;
    }

    return null;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }

    return false;
}

test "parseDevicesJson handles object/array/null payloads" {
    const allocator = std.testing.allocator;

    const json_array =
        "[" ++
        "{\"Name\":\"Integrated Front Camera\",\"PNPDeviceID\":\"SWD\\\\CAMERA\\\\FRONT_CAM\"}," ++
        "{\"Name\":\"USB Camera\",\"PNPDeviceID\":\"USB\\\\VID_046D&PID_0825\"}" ++
        "]";

    const devices = try parseDevicesJson(allocator, json_array);
    defer {
        for (devices) |dev| {
            allocator.free(@constCast(dev.name));
            allocator.free(@constCast(dev.deviceId));
        }
        allocator.free(devices);
    }

    try std.testing.expectEqual(@as(usize, 2), devices.len);
    try std.testing.expectEqualStrings("Integrated Front Camera", devices[0].name);
    try std.testing.expect(devices[0].position.? == .front);
    try std.testing.expect(devices[1].position.? == .external);

    const json_object = "{\"Name\":\"Rear Camera\",\"PNPDeviceID\":\"SWD\\\\CAMERA\\\\REAR_CAM\"}";
    const single = try parseDevicesJson(allocator, json_object);
    defer {
        for (single) |dev| {
            allocator.free(@constCast(dev.name));
            allocator.free(@constCast(dev.deviceId));
        }
        allocator.free(single);
    }

    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expect(single[0].position.? == .back);

    const json_null = "null";
    const empty = try parseDevicesJson(allocator, json_null);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "listCameras returns NotSupported on non-Windows targets" {
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectError(error.NotSupported, listCameras(std.testing.allocator));
    }
}
