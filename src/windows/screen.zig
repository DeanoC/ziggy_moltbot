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
/// Current MVP limitations:
/// - primary desktop only (`screenIndex=0`)
/// - video-only capture (`includeAudio` is ignored, `hasAudio=false`)
pub fn recordScreen(allocator: std.mem.Allocator, req: ScreenRecordRequest) ScreenRecordError!ScreenRecordResult {
    if (builtin.target.os.tag != .windows) return error.NotSupported;

    const support = detectBackendSupport(allocator);
    if (!support.record) return error.FfmpegNotFound;

    if (req.screenIndex != 0) {
        logger.warn("screen.record backend={s}: only screenIndex=0 is currently supported (requested={d})", .{ screen_backend_name, req.screenIndex });
        return error.ScreenIndexNotSupported;
    }

    if (req.durationMs == 0 or req.durationMs > 300_000) return error.InvalidParams;
    if (req.fps == 0 or req.fps > 60) return error.InvalidParams;

    if (req.includeAudio) {
        logger.warn("screen.record backend={s}: includeAudio requested but audio capture is not implemented yet; capturing video-only", .{screen_backend_name});
    }

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

    try runFfmpegDesktopCapture(allocator, req, out_path);

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

fn runFfmpegDesktopCapture(allocator: std.mem.Allocator, req: ScreenRecordRequest, out_path: []const u8) ScreenRecordError!void {
    _ = req.includeAudio;

    const fps_arg = try std.fmt.allocPrint(allocator, "{d}", .{req.fps});
    defer allocator.free(fps_arg);

    const duration_arg = try std.fmt.allocPrint(
        allocator,
        "{d}.{d:0>3}",
        .{ req.durationMs / 1000, req.durationMs % 1000 },
    );
    defer allocator.free(duration_arg);

    var saw_executable = false;
    var last_error: ?ScreenRecordError = null;

    for (ffmpegCandidates()) |exe| {
        const argv = &[_][]const u8{
            exe,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "gdigrab",
            "-framerate",
            fps_arg,
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
        };

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
