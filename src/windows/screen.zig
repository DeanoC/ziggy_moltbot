const std = @import("std");
const builtin = @import("builtin");
const logger = @import("../utils/logger.zig");

pub const ScreenRecordFormat = enum {
    mp4,

    pub fn toString(self: ScreenRecordFormat) []const u8 {
        return switch (self) {
            .mp4 => "mp4",
        };
    }

    pub fn fromString(raw: []const u8) ?ScreenRecordFormat {
        if (std.ascii.eqlIgnoreCase(raw, "mp4")) {
            return .mp4;
        }
        return null;
    }

    fn fileExtension(self: ScreenRecordFormat) []const u8 {
        return switch (self) {
            .mp4 => "mp4",
        };
    }
};

pub const ScreenRecordRequest = struct {
    format: ScreenRecordFormat = .mp4,
    durationMs: u32 = 5000,
    fps: u32 = 12,
    screenIndex: u32 = 0,
    includeAudio: bool = false,
};

pub const ScreenRecordResult = struct {
    format: ScreenRecordFormat,
    base64: []const u8,
    durationMs: u32,
    fps: u32,
    screenIndex: u32,
    hasAudio: bool,
};

pub const ScreenRecordError = error{
    NotSupported,
    FfmpegNotFound,
    ScreenIndexNotSupported,
    InvalidParams,
    CommandFailed,
    OutOfMemory,
};

pub const ScreenBackendSupport = struct {
    record: bool,
};

const screen_backend_name = "ffmpeg-gdigrab";
const monitor_backend_name = "powershell-forms";

const ScreenMonitor = struct {
    deviceName: []const u8,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    primary: bool,
};

const CaptureTarget = union(enum) {
    desktop,
    monitor: struct {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    },
};

const MonitorListError = error{
    PowershellNotFound,
    CommandFailed,
    InvalidOutput,
    OutOfMemory,
};

/// Detect which Windows screen features should be advertised.
///
/// `screen.record` currently requires a runnable ffmpeg executable.
pub fn detectBackendSupport(allocator: std.mem.Allocator) ScreenBackendSupport {
    if (builtin.target.os.tag != .windows) {
        return .{ .record = false };
    }

    return .{ .record = hasWorkingFfmpeg(allocator) };
}

/// Record the Windows desktop and return an OpenClaw-compatible payload.
///
/// Current limitations:
/// - monitor-index mapping uses PowerShell Forms metadata; if unavailable,
///   `screenIndex=0` falls back to legacy desktop capture and non-zero indices
///   are rejected.
/// - video-only capture (`includeAudio` is ignored, `hasAudio=false`)
pub fn recordScreen(allocator: std.mem.Allocator, req: ScreenRecordRequest) ScreenRecordError!ScreenRecordResult {
    if (builtin.target.os.tag != .windows) return error.NotSupported;

    const support = detectBackendSupport(allocator);
    if (!support.record) return error.FfmpegNotFound;

    if (req.durationMs == 0 or req.durationMs > 300_000) return error.InvalidParams;
    if (req.fps == 0 or req.fps > 60) return error.InvalidParams;

    if (req.includeAudio) {
        logger.warn("screen.record backend={s}: includeAudio requested but audio capture is not implemented yet; capturing video-only", .{screen_backend_name});
    }

    const capture_target = resolveCaptureTarget(allocator, req.screenIndex) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ScreenIndexNotSupported => return error.ScreenIndexNotSupported,
        else => return error.CommandFailed,
    };

    const temp_dir = getTempDirAlloc(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    defer allocator.free(temp_dir);

    const now_ms = std.time.milliTimestamp();
    const file_name = try std.fmt.allocPrint(
        allocator,
        "zsc-screen-record-{d}.{s}",
        .{ now_ms, req.format.fileExtension() },
    );
    defer allocator.free(file_name);

    const out_path = try std.fs.path.join(allocator, &.{ temp_dir, file_name });
    defer allocator.free(out_path);
    defer std.fs.deleteFileAbsolute(out_path) catch {};

    try runFfmpegDesktopCapture(allocator, req, capture_target, out_path);

    const file = std.fs.openFileAbsolute(out_path, .{}) catch {
        logger.err("screen.record backend={s} output file missing: {s}", .{ screen_backend_name, out_path });
        return error.CommandFailed;
    };
    defer file.close();

    const video_bytes = file.readToEndAlloc(allocator, 150 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logger.err("screen.record backend={s} failed to read output video: {s}", .{ screen_backend_name, @errorName(err) });
            return error.CommandFailed;
        },
    };
    defer allocator.free(video_bytes);

    const b64_len = std.base64.standard.Encoder.calcSize(video_bytes.len);
    const b64_buf = allocator.alloc(u8, b64_len) catch return error.OutOfMemory;
    _ = std.base64.standard.Encoder.encode(b64_buf, video_bytes);

    return .{
        .format = req.format,
        .base64 = b64_buf,
        .durationMs = req.durationMs,
        .fps = req.fps,
        .screenIndex = req.screenIndex,
        .hasAudio = false,
    };
}

fn resolveCaptureTarget(allocator: std.mem.Allocator, screen_index: u32) ScreenRecordError!CaptureTarget {
    const monitors = listMonitors(allocator) catch |err| switch (err) {
        error.PowershellNotFound => {
            if (screen_index == 0) {
                logger.warn("screen.record backend={s}: monitor discovery unavailable (PowerShell not found), falling back to desktop capture", .{screen_backend_name});
                return .desktop;
            }

            logger.warn(
                "screen.record backend={s}: screenIndex={d} requires monitor discovery but PowerShell is unavailable",
                .{ screen_backend_name, screen_index },
            );
            return error.ScreenIndexNotSupported;
        },
        error.InvalidOutput, error.CommandFailed => {
            if (screen_index == 0) {
                logger.warn(
                    "screen.record backend={s}: monitor discovery failed ({s}), falling back to desktop capture",
                    .{ screen_backend_name, @errorName(err) },
                );
                return .desktop;
            }

            logger.warn(
                "screen.record backend={s}: unable to resolve screenIndex={d} because monitor discovery failed ({s})",
                .{ screen_backend_name, screen_index, @errorName(err) },
            );
            return error.ScreenIndexNotSupported;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer freeMonitors(allocator, monitors);

    if (screen_index >= monitors.len) {
        logger.warn(
            "screen.record backend={s}: requested screenIndex={d} is out of range (discovered={d})",
            .{ screen_backend_name, screen_index, monitors.len },
        );
        return error.ScreenIndexNotSupported;
    }

    const monitor = monitors[screen_index];
    return .{ .monitor = .{
        .x = monitor.x,
        .y = monitor.y,
        .width = monitor.width,
        .height = monitor.height,
    } };
}

fn runFfmpegDesktopCapture(
    allocator: std.mem.Allocator,
    req: ScreenRecordRequest,
    capture_target: CaptureTarget,
    out_path: []const u8,
) ScreenRecordError!void {
    _ = req.includeAudio;

    const fps_arg = try std.fmt.allocPrint(allocator, "{d}", .{req.fps});
    defer allocator.free(fps_arg);

    const duration_arg = try std.fmt.allocPrint(
        allocator,
        "{d}.{d:0>3}",
        .{ req.durationMs / 1000, req.durationMs % 1000 },
    );
    defer allocator.free(duration_arg);

    const offset_x_arg: ?[]u8 = switch (capture_target) {
        .desktop => null,
        .monitor => |target| try std.fmt.allocPrint(allocator, "{d}", .{target.x}),
    };
    defer if (offset_x_arg) |s| allocator.free(s);

    const offset_y_arg: ?[]u8 = switch (capture_target) {
        .desktop => null,
        .monitor => |target| try std.fmt.allocPrint(allocator, "{d}", .{target.y}),
    };
    defer if (offset_y_arg) |s| allocator.free(s);

    const video_size_arg: ?[]u8 = switch (capture_target) {
        .desktop => null,
        .monitor => |target| try std.fmt.allocPrint(allocator, "{d}x{d}", .{ target.width, target.height }),
    };
    defer if (video_size_arg) |s| allocator.free(s);

    var saw_executable = false;
    var last_error: ?ScreenRecordError = null;

    for (ffmpegCandidates()) |exe| {
        var argv_list = std.ArrayList([]const u8).empty;
        defer argv_list.deinit(allocator);

        try argv_list.appendSlice(allocator, &.{
            exe,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "gdigrab",
            "-framerate",
            fps_arg,
        });

        switch (capture_target) {
            .desktop => {},
            .monitor => {
                try argv_list.appendSlice(allocator, &.{
                    "-offset_x",
                    offset_x_arg.?,
                    "-offset_y",
                    offset_y_arg.?,
                    "-video_size",
                    video_size_arg.?,
                });
            },
        }

        try argv_list.appendSlice(allocator, &.{
            "-i",
            "desktop",
            "-t",
            duration_arg,
            "-pix_fmt",
            "yuv420p",
            "-c:v",
            "mpeg4",
            "-q:v",
            "5",
            "-movflags",
            "+faststart",
            "-y",
            out_path,
        });

        const argv = try argv_list.toOwnedSlice(allocator);
        defer allocator.free(argv);

        const res = std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .max_output_bytes = 1024 * 1024,
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                saw_executable = true;
                logger.warn("screen.record backend={s} failed to start {s}: {s}", .{ screen_backend_name, exe, @errorName(err) });
                last_error = error.CommandFailed;
                continue;
            },
        };

        saw_executable = true;

        const exit_code = childTermToExitCode(res.term);
        if (exit_code != 0) {
            logger.warn("screen.record backend={s} failed via {s}: exit={d} stderr={s}", .{ screen_backend_name, exe, exit_code, res.stderr });
            allocator.free(res.stdout);
            allocator.free(res.stderr);
            last_error = error.CommandFailed;
            continue;
        }

        allocator.free(res.stdout);
        allocator.free(res.stderr);
        return;
    }

    if (!saw_executable) return error.FfmpegNotFound;
    return last_error orelse error.CommandFailed;
}

fn listMonitors(allocator: std.mem.Allocator) MonitorListError![]ScreenMonitor {
    const script =
        "$ErrorActionPreference='Stop'; " ++
        "Add-Type -AssemblyName System.Windows.Forms; " ++
        "$screens = [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { " ++
        "[PSCustomObject]@{ DeviceName=$_.DeviceName; X=$_.Bounds.X; Y=$_.Bounds.Y; Width=$_.Bounds.Width; Height=$_.Bounds.Height; Primary=$_.Primary } " ++
        "}; " ++
        "$screens | ConvertTo-Json -Compress";

    const out = runPowershellJson(allocator, script) catch |err| switch (err) {
        error.FileNotFound => {
            logger.err("screen.record monitor discovery backend={s} failed: PowerShell not found (tried powershell, pwsh)", .{monitor_backend_name});
            return error.PowershellNotFound;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logger.err("screen.record monitor discovery backend={s} failed to execute: {s}", .{ monitor_backend_name, @errorName(err) });
            return error.CommandFailed;
        },
    };
    defer allocator.free(out);

    const monitors = parseMonitorsJson(allocator, out) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logger.err("screen.record monitor discovery backend={s} failed to parse JSON output: {s}", .{ monitor_backend_name, @errorName(err) });
            return error.InvalidOutput;
        },
    };

    if (monitors.len == 0) {
        allocator.free(monitors);
        logger.err("screen.record monitor discovery backend={s} returned no monitors", .{monitor_backend_name});
        return error.InvalidOutput;
    }

    return monitors;
}

fn parseMonitorsJson(allocator: std.mem.Allocator, stdout_bytes: []const u8) ![]ScreenMonitor {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout_bytes, .{});
    defer parsed.deinit();

    var monitors = std.ArrayList(ScreenMonitor).empty;
    errdefer {
        for (monitors.items) |monitor| {
            allocator.free(@constCast(monitor.deviceName));
        }
        monitors.deinit(allocator);
    }

    const v = parsed.value;
    switch (v) {
        .null => {},
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                try appendMonitor(allocator, &monitors, item.object);
            }
        },
        .object => |obj| {
            try appendMonitor(allocator, &monitors, obj);
        },
        else => {},
    }

    movePrimaryMonitorFirst(monitors.items);

    return monitors.toOwnedSlice(allocator);
}

fn appendMonitor(allocator: std.mem.Allocator, monitors: *std.ArrayList(ScreenMonitor), obj: std.json.ObjectMap) !void {
    const device_name_v = obj.get("DeviceName") orelse return;
    const x_v = obj.get("X") orelse return;
    const y_v = obj.get("Y") orelse return;
    const width_v = obj.get("Width") orelse return;
    const height_v = obj.get("Height") orelse return;

    if (device_name_v != .string) return;

    const x = try parseI32JsonValue(x_v);
    const y = try parseI32JsonValue(y_v);
    const width = try parseU32JsonValue(width_v);
    const height = try parseU32JsonValue(height_v);
    if (width == 0 or height == 0) return;

    const primary = if (obj.get("Primary")) |primary_v| blk: {
        if (primary_v == .bool) break :blk primary_v.bool;
        break :blk false;
    } else false;

    const device_name = try allocator.dupe(u8, device_name_v.string);
    errdefer allocator.free(device_name);

    try monitors.append(allocator, .{
        .deviceName = device_name,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .primary = primary,
    });
}

fn parseI32JsonValue(v: std.json.Value) !i32 {
    return switch (v) {
        .integer => |ival| blk: {
            if (ival < std.math.minInt(i32) or ival > std.math.maxInt(i32)) return error.InvalidOutput;
            break :blk @as(i32, @intCast(ival));
        },
        .float => |fval| blk: {
            const min = @as(f64, @floatFromInt(std.math.minInt(i32)));
            const max = @as(f64, @floatFromInt(std.math.maxInt(i32)));
            if (fval < min or fval > max) return error.InvalidOutput;
            break :blk @as(i32, @intFromFloat(fval));
        },
        else => error.InvalidOutput,
    };
}

fn parseU32JsonValue(v: std.json.Value) !u32 {
    return switch (v) {
        .integer => |ival| blk: {
            if (ival < 0 or ival > std.math.maxInt(u32)) return error.InvalidOutput;
            break :blk @as(u32, @intCast(ival));
        },
        .float => |fval| blk: {
            const max = @as(f64, @floatFromInt(std.math.maxInt(u32)));
            if (fval < 0 or fval > max) return error.InvalidOutput;
            break :blk @as(u32, @intFromFloat(fval));
        },
        else => error.InvalidOutput,
    };
}

fn movePrimaryMonitorFirst(monitors: []ScreenMonitor) void {
    if (monitors.len <= 1) return;

    var primary_idx: ?usize = null;
    for (monitors, 0..) |monitor, idx| {
        if (monitor.primary) {
            primary_idx = idx;
            break;
        }
    }

    if (primary_idx == null or primary_idx.? == 0) return;

    const first = monitors[0];
    monitors[0] = monitors[primary_idx.?];
    monitors[primary_idx.?] = first;
}

fn freeMonitors(allocator: std.mem.Allocator, monitors: []ScreenMonitor) void {
    for (monitors) |monitor| {
        allocator.free(@constCast(monitor.deviceName));
    }
    allocator.free(monitors);
}

fn hasWorkingFfmpeg(allocator: std.mem.Allocator) bool {
    for (ffmpegCandidates()) |exe| {
        const argv = &[_][]const u8{ exe, "-version" };
        if (probeCommand(allocator, argv)) {
            return true;
        }
    }

    return false;
}

fn ffmpegCandidates() []const []const u8 {
    return &[_][]const u8{ "ffmpeg", "ffmpeg.exe" };
}

fn powershellCandidates() []const []const u8 {
    return &[_][]const u8{ "powershell", "pwsh" };
}

fn runPowershellJson(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    var saw_executable = false;
    var last_error: ?anyerror = null;

    for (powershellCandidates()) |exe| {
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
            error.FileNotFound => {
                logger.warn("screen.record monitor discovery backend={s}: executable not found: {s}", .{ monitor_backend_name, exe });
                continue;
            },
            else => {
                logger.warn("screen.record monitor discovery backend={s}: failed to start {s}: {s}", .{ monitor_backend_name, exe, @errorName(err) });
                saw_executable = true;
                last_error = err;
                continue;
            },
        };

        saw_executable = true;

        const exit_code = childTermToExitCode(res.term);
        if (exit_code != 0) {
            logger.warn("screen.record monitor discovery backend={s} failed via {s}: exit={d} stderr={s}", .{ monitor_backend_name, exe, exit_code, res.stderr });
            allocator.free(res.stdout);
            allocator.free(res.stderr);
            last_error = error.CommandFailed;
            continue;
        }

        allocator.free(res.stderr);
        return res.stdout;
    }

    if (!saw_executable) return error.FileNotFound;
    return last_error orelse error.CommandFailed;
}

fn probeCommand(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 64 * 1024,
    }) catch return false;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    return childTermToExitCode(res.term) == 0;
}

fn childTermToExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| @intCast(sig),
        .Stopped => |sig| @intCast(sig),
        .Unknown => |code| @intCast(code),
    };
}

fn getTempDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    const envs = &[_][]const u8{ "TEMP", "TMP" };

    for (envs) |key| {
        const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };

        if (value) |raw| {
            if (std.fs.path.isAbsolute(raw)) {
                return raw;
            }

            const cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd);

            const abs = try std.fs.path.join(allocator, &.{ cwd, raw });
            allocator.free(raw);
            return abs;
        }
    }

    return std.process.getCwdAlloc(allocator);
}

test "ScreenRecordFormat.fromString accepts mp4" {
    try std.testing.expect(ScreenRecordFormat.fromString("mp4").? == .mp4);
    try std.testing.expect(ScreenRecordFormat.fromString("MP4").? == .mp4);
    try std.testing.expect(ScreenRecordFormat.fromString("webm") == null);
}

test "detectBackendSupport returns false on non-Windows targets" {
    if (builtin.target.os.tag != .windows) {
        const support = detectBackendSupport(std.testing.allocator);
        try std.testing.expect(!support.record);
    }
}

test "recordScreen returns NotSupported on non-Windows targets" {
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectError(error.NotSupported, recordScreen(std.testing.allocator, .{}));
    }
}

test "parseMonitorsJson handles array/object/null and prioritizes primary" {
    const allocator = std.testing.allocator;

    const json_array =
        "[" ++
        "{\"DeviceName\":\"\\\\.\\DISPLAY2\",\"X\":1920,\"Y\":0,\"Width\":1920,\"Height\":1080,\"Primary\":false}," ++
        "{\"DeviceName\":\"\\\\.\\DISPLAY1\",\"X\":0,\"Y\":0,\"Width\":1920,\"Height\":1080,\"Primary\":true}" ++
        "]";

    const monitors = try parseMonitorsJson(allocator, json_array);
    defer freeMonitors(allocator, monitors);

    try std.testing.expectEqual(@as(usize, 2), monitors.len);
    try std.testing.expect(monitors[0].primary);
    try std.testing.expectEqualStrings("\\\\.\\DISPLAY1", monitors[0].deviceName);
    try std.testing.expectEqual(@as(i32, 0), monitors[0].x);
    try std.testing.expectEqual(@as(u32, 1920), monitors[0].width);

    const json_object =
        "{\"DeviceName\":\"\\\\.\\DISPLAY3\",\"X\":-1280,\"Y\":0,\"Width\":1280,\"Height\":1024,\"Primary\":false}";
    const single = try parseMonitorsJson(allocator, json_object);
    defer freeMonitors(allocator, single);

    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqual(@as(i32, -1280), single[0].x);
    try std.testing.expectEqual(@as(u32, 1024), single[0].height);

    const json_null = "null";
    const empty = try parseMonitorsJson(allocator, json_null);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "movePrimaryMonitorFirst keeps order when no primary exists" {
    var monitors = [_]ScreenMonitor{
        .{ .deviceName = "A", .x = 0, .y = 0, .width = 100, .height = 100, .primary = false },
        .{ .deviceName = "B", .x = 100, .y = 0, .width = 100, .height = 100, .primary = false },
    };

    movePrimaryMonitorFirst(monitors[0..]);
    try std.testing.expectEqualStrings("A", monitors[0].deviceName);
    try std.testing.expectEqualStrings("B", monitors[1].deviceName);
}
