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

pub const CameraSnapFormat = enum {
    jpeg,
    png,

    pub fn toString(self: CameraSnapFormat) []const u8 {
        return switch (self) {
            .jpeg => "jpeg",
            .png => "png",
        };
    }

    pub fn fromString(raw: []const u8) ?CameraSnapFormat {
        if (std.ascii.eqlIgnoreCase(raw, "jpeg") or std.ascii.eqlIgnoreCase(raw, "jpg")) {
            return .jpeg;
        }
        if (std.ascii.eqlIgnoreCase(raw, "png")) {
            return .png;
        }
        return null;
    }

    fn fileExtension(self: CameraSnapFormat) []const u8 {
        return switch (self) {
            .jpeg => "jpg",
            .png => "png",
        };
    }
};

pub const CameraSnapRequest = struct {
    format: CameraSnapFormat = .jpeg,
    deviceId: ?[]const u8 = null,
};

pub const CameraSnapResult = struct {
    format: CameraSnapFormat,
    base64: []const u8,
    width: u32,
    height: u32,
};

pub const CameraSnapError = error{
    NotSupported,
    PowershellNotFound,
    FfmpegNotFound,
    DeviceNotFound,
    CommandFailed,
    InvalidOutput,
    OutOfMemory,
};

pub const CameraClipFormat = enum {
    mp4,

    pub fn toString(self: CameraClipFormat) []const u8 {
        return switch (self) {
            .mp4 => "mp4",
        };
    }

    pub fn fromString(raw: []const u8) ?CameraClipFormat {
        if (std.ascii.eqlIgnoreCase(raw, "mp4")) {
            return .mp4;
        }
        return null;
    }

    fn fileExtension(self: CameraClipFormat) []const u8 {
        return switch (self) {
            .mp4 => "mp4",
        };
    }
};

pub const CameraClipRequest = struct {
    format: CameraClipFormat = .mp4,
    durationMs: u32 = 3000,
    includeAudio: bool = true,
    deviceId: ?[]const u8 = null,
    preferredPosition: ?CameraPosition = null,
};

pub const CameraClipResult = struct {
    format: CameraClipFormat,
    base64: []const u8,
    durationMs: u32,
    hasAudio: bool,
};

pub const CameraClipError = error{
    NotSupported,
    PowershellNotFound,
    FfmpegNotFound,
    DeviceNotFound,
    InvalidParams,
    CommandFailed,
    OutOfMemory,
};

const CameraCaptureResolveError = error{
    NotSupported,
    PowershellNotFound,
    DeviceNotFound,
    CommandFailed,
    OutOfMemory,
};

pub const CameraBackendSupport = struct {
    list: bool,
    snap: bool,
    clip: bool,
};

const list_backend_name = "powershell-cim";
const snap_backend_name = "ffmpeg-dshow";
const clip_backend_name = "ffmpeg-dshow";

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
            logger.err("camera.list backend={s} failed: PowerShell not found (tried powershell, pwsh)", .{list_backend_name});
            return error.PowershellNotFound;
        },
        else => {
            logger.err("camera.list backend={s} failed to execute: {s}", .{ list_backend_name, @errorName(err) });
            return error.CommandFailed;
        },
    };
    defer allocator.free(out);

    return parseDevicesJson(allocator, out) catch |err| {
        logger.err("camera.list backend={s} failed to parse JSON output: {s}", .{ list_backend_name, @errorName(err) });
        return error.InvalidOutput;
    };
}

pub fn freeCameraDevices(allocator: std.mem.Allocator, devices: []CameraDevice) void {
    for (devices) |dev| {
        allocator.free(@constCast(dev.name));
        allocator.free(@constCast(dev.deviceId));
    }
    allocator.free(devices);
}

/// Detect which Windows camera features should be advertised.
///
/// - `list` requires a working PowerShell executable.
/// - `snap`/`clip` require both PowerShell (for deviceId -> name mapping) and ffmpeg.
pub fn detectBackendSupport(allocator: std.mem.Allocator) CameraBackendSupport {
    if (builtin.target.os.tag != .windows) {
        return .{ .list = false, .snap = false, .clip = false };
    }

    const has_powershell = hasWorkingPowershell(allocator);
    const has_ffmpeg = hasWorkingFfmpeg(allocator);

    return .{
        .list = has_powershell,
        .snap = has_powershell and has_ffmpeg,
        .clip = has_powershell and has_ffmpeg,
    };
}

pub fn snapCamera(allocator: std.mem.Allocator, req: CameraSnapRequest) CameraSnapError!CameraSnapResult {
    if (builtin.target.os.tag != .windows) return error.NotSupported;

    const support = detectBackendSupport(allocator);
    if (!support.list) return error.PowershellNotFound;
    if (!support.snap) return error.FfmpegNotFound;

    const camera_name = try resolveCameraNameForCapture(allocator, req.deviceId, null);
    defer allocator.free(camera_name);

    const temp_dir = getTempDirAlloc(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    defer allocator.free(temp_dir);

    const now_ms = std.time.milliTimestamp();
    const file_name = try std.fmt.allocPrint(
        allocator,
        "zsc-camera-snap-{d}.{s}",
        .{ now_ms, req.format.fileExtension() },
    );
    defer allocator.free(file_name);

    const out_path = try std.fs.path.join(allocator, &.{ temp_dir, file_name });
    defer allocator.free(out_path);
    defer std.fs.deleteFileAbsolute(out_path) catch {};

    const input_spec = try formatDshowVideoInputAlloc(allocator, camera_name);
    defer allocator.free(input_spec);

    try runFfmpegSingleFrame(allocator, req.format, input_spec, out_path);

    const file = std.fs.openFileAbsolute(out_path, .{}) catch {
        logger.err("camera.snap backend={s} output file missing: {s}", .{ snap_backend_name, out_path });
        return error.CommandFailed;
    };
    defer file.close();

    const image_bytes = file.readToEndAlloc(allocator, 20 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logger.err("camera.snap backend={s} failed to read output image: {s}", .{ snap_backend_name, @errorName(err) });
            return error.CommandFailed;
        },
    };
    defer allocator.free(image_bytes);

    const dimensions = parseImageDimensions(image_bytes, req.format) catch |err| {
        logger.err("camera.snap backend={s} failed to parse image dimensions: {s}", .{ snap_backend_name, @errorName(err) });
        return error.InvalidOutput;
    };

    const b64_len = std.base64.standard.Encoder.calcSize(image_bytes.len);
    const b64_buf = allocator.alloc(u8, b64_len) catch return error.OutOfMemory;
    _ = std.base64.standard.Encoder.encode(b64_buf, image_bytes);

    return .{
        .format = req.format,
        .base64 = b64_buf,
        .width = dimensions.width,
        .height = dimensions.height,
    };
}

pub fn clipCamera(allocator: std.mem.Allocator, req: CameraClipRequest) CameraClipError!CameraClipResult {
    if (builtin.target.os.tag != .windows) return error.NotSupported;

    const support = detectBackendSupport(allocator);
    if (!support.list) return error.PowershellNotFound;
    if (!support.clip) return error.FfmpegNotFound;

    if (req.durationMs == 0 or req.durationMs > 60_000) return error.InvalidParams;

    if (req.includeAudio) {
        logger.warn("camera.clip backend={s}: includeAudio requested but audio capture is not implemented yet; capturing video-only", .{clip_backend_name});
    }

    const camera_name = try resolveCameraNameForCapture(allocator, req.deviceId, req.preferredPosition);
    defer allocator.free(camera_name);

    const temp_dir = getTempDirAlloc(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    defer allocator.free(temp_dir);

    const now_ms = std.time.milliTimestamp();
    const file_name = try std.fmt.allocPrint(
        allocator,
        "zsc-camera-clip-{d}.{s}",
        .{ now_ms, req.format.fileExtension() },
    );
    defer allocator.free(file_name);

    const out_path = try std.fs.path.join(allocator, &.{ temp_dir, file_name });
    defer allocator.free(out_path);
    defer std.fs.deleteFileAbsolute(out_path) catch {};

    const input_spec = try formatDshowVideoInputAlloc(allocator, camera_name);
    defer allocator.free(input_spec);

    try runFfmpegCameraClip(allocator, req, input_spec, out_path);

    const file = std.fs.openFileAbsolute(out_path, .{}) catch {
        logger.err("camera.clip backend={s} output file missing: {s}", .{ clip_backend_name, out_path });
        return error.CommandFailed;
    };
    defer file.close();

    const video_bytes = file.readToEndAlloc(allocator, 150 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logger.err("camera.clip backend={s} failed to read output video: {s}", .{ clip_backend_name, @errorName(err) });
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
        .hasAudio = false,
    };
}

fn resolveCameraNameForCapture(
    allocator: std.mem.Allocator,
    wanted_device_id: ?[]const u8,
    preferred_position: ?CameraPosition,
) CameraCaptureResolveError![]u8 {
    const devices = listCameras(allocator) catch |err| switch (err) {
        error.NotSupported => return error.NotSupported,
        error.PowershellNotFound => return error.PowershellNotFound,
        else => return error.CommandFailed,
    };
    defer freeCameraDevices(allocator, devices);

    if (devices.len == 0) {
        return error.DeviceNotFound;
    }

    if (wanted_device_id) |device_id| {
        for (devices) |device| {
            if (std.ascii.eqlIgnoreCase(device.deviceId, device_id)) {
                return allocator.dupe(u8, device.name) catch return error.OutOfMemory;
            }
        }
        return error.DeviceNotFound;
    }

    if (preferred_position) |pos| {
        for (devices) |device| {
            if (device.position != null and device.position.? == pos) {
                return allocator.dupe(u8, device.name) catch return error.OutOfMemory;
            }
        }
    }

    return allocator.dupe(u8, devices[0].name) catch return error.OutOfMemory;
}

fn formatDshowVideoInputAlloc(allocator: std.mem.Allocator, camera_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "video={s}", .{camera_name});
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

fn hasWorkingPowershell(allocator: std.mem.Allocator) bool {
    const probe_script = "$PSVersionTable.PSVersion.Major";

    for (powershellCandidates()) |exe| {
        const argv = &[_][]const u8{
            exe,
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            probe_script,
        };

        if (probeCommand(allocator, argv)) {
            return true;
        }
    }

    return false;
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

fn powershellCandidates() []const []const u8 {
    return &[_][]const u8{ "powershell", "pwsh" };
}

fn ffmpegCandidates() []const []const u8 {
    return &[_][]const u8{ "ffmpeg", "ffmpeg.exe" };
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
            // Try the next candidate.
            error.FileNotFound => {
                logger.warn("camera.list backend={s}: executable not found: {s}", .{ list_backend_name, exe });
                continue;
            },
            else => {
                logger.warn("camera.list backend={s}: failed to start {s}: {s}", .{ list_backend_name, exe, @errorName(err) });
                saw_executable = true;
                last_error = err;
                continue;
            },
        };

        saw_executable = true;

        const exit_code = childTermToExitCode(res.term);
        if (exit_code != 0) {
            logger.warn("camera.list backend={s} failed via {s}: exit={d} stderr={s}", .{ list_backend_name, exe, exit_code, res.stderr });
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

fn runFfmpegSingleFrame(
    allocator: std.mem.Allocator,
    format: CameraSnapFormat,
    input_spec: []const u8,
    out_path: []const u8,
) CameraSnapError!void {
    var saw_executable = false;
    var last_error: ?CameraSnapError = null;

    for (ffmpegCandidates()) |exe| {
        const jpeg_argv = &[_][]const u8{
            exe,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "dshow",
            "-i",
            input_spec,
            "-frames:v",
            "1",
            "-q:v",
            "2",
            "-update",
            "1",
            "-y",
            out_path,
        };

        const png_argv = &[_][]const u8{
            exe,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "dshow",
            "-i",
            input_spec,
            "-frames:v",
            "1",
            "-update",
            "1",
            "-y",
            out_path,
        };

        const argv = switch (format) {
            .jpeg => jpeg_argv,
            .png => png_argv,
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
                logger.warn("camera.snap backend={s} failed to start {s}: {s}", .{ snap_backend_name, exe, @errorName(err) });
                last_error = error.CommandFailed;
                continue;
            },
        };

        saw_executable = true;

        const exit_code = childTermToExitCode(res.term);
        if (exit_code != 0) {
            logger.warn("camera.snap backend={s} failed via {s}: exit={d} stderr={s}", .{ snap_backend_name, exe, exit_code, res.stderr });
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

fn runFfmpegCameraClip(
    allocator: std.mem.Allocator,
    req: CameraClipRequest,
    input_spec: []const u8,
    out_path: []const u8,
) CameraClipError!void {
    const duration_arg = try std.fmt.allocPrint(
        allocator,
        "{d}.{d:0>3}",
        .{ req.durationMs / 1000, req.durationMs % 1000 },
    );
    defer allocator.free(duration_arg);

    var saw_executable = false;
    var last_error: ?CameraClipError = null;

    for (ffmpegCandidates()) |exe| {
        const mp4_argv = &[_][]const u8{
            exe,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "dshow",
            "-i",
            input_spec,
            "-t",
            duration_arg,
            "-an",
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

        const argv = switch (req.format) {
            .mp4 => mp4_argv,
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
                logger.warn("camera.clip backend={s} failed to start {s}: {s}", .{ clip_backend_name, exe, @errorName(err) });
                last_error = error.CommandFailed;
                continue;
            },
        };

        saw_executable = true;

        const exit_code = childTermToExitCode(res.term);
        if (exit_code != 0) {
            logger.warn("camera.clip backend={s} failed via {s}: exit={d} stderr={s}", .{ clip_backend_name, exe, exit_code, res.stderr });
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

const ImageDimensions = struct {
    width: u32,
    height: u32,
};

fn parseImageDimensions(image_bytes: []const u8, format: CameraSnapFormat) !ImageDimensions {
    return switch (format) {
        .png => parsePngDimensions(image_bytes),
        .jpeg => parseJpegDimensions(image_bytes),
    };
}

fn parsePngDimensions(image_bytes: []const u8) !ImageDimensions {
    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    if (image_bytes.len < 24) return error.InvalidOutput;
    if (!std.mem.eql(u8, image_bytes[0..8], &png_sig)) return error.InvalidOutput;
    if (!std.mem.eql(u8, image_bytes[12..16], "IHDR")) return error.InvalidOutput;

    const width = readU32Big(image_bytes[16..20]);
    const height = readU32Big(image_bytes[20..24]);
    if (width == 0 or height == 0) return error.InvalidOutput;

    return .{ .width = width, .height = height };
}

fn parseJpegDimensions(image_bytes: []const u8) !ImageDimensions {
    if (image_bytes.len < 4) return error.InvalidOutput;
    if (!(image_bytes[0] == 0xFF and image_bytes[1] == 0xD8)) return error.InvalidOutput;

    var i: usize = 2;
    while (i + 1 < image_bytes.len) {
        while (i < image_bytes.len and image_bytes[i] != 0xFF) : (i += 1) {}
        if (i + 1 >= image_bytes.len) break;

        var marker_idx = i + 1;
        while (marker_idx < image_bytes.len and image_bytes[marker_idx] == 0xFF) : (marker_idx += 1) {}
        if (marker_idx >= image_bytes.len) break;

        const marker = image_bytes[marker_idx];
        i = marker_idx + 1;

        if (marker == 0xD8 or marker == 0xD9) {
            continue;
        }
        if (marker >= 0xD0 and marker <= 0xD7) {
            continue;
        }

        if (i + 2 > image_bytes.len) return error.InvalidOutput;

        const seg_len_u16 = readU16Big(image_bytes[i .. i + 2]);
        if (seg_len_u16 < 2) return error.InvalidOutput;

        const seg_len: usize = @intCast(seg_len_u16);
        const seg_data_start = i + 2;
        const seg_data_len = seg_len - 2;
        const seg_data_end = seg_data_start + seg_data_len;
        if (seg_data_end > image_bytes.len) return error.InvalidOutput;

        if (isJpegSofMarker(marker)) {
            if (seg_data_len < 5) return error.InvalidOutput;

            const height = readU16Big(image_bytes[seg_data_start + 1 .. seg_data_start + 3]);
            const width = readU16Big(image_bytes[seg_data_start + 3 .. seg_data_start + 5]);
            if (width == 0 or height == 0) return error.InvalidOutput;

            return .{
                .width = @as(u32, width),
                .height = @as(u32, height),
            };
        }

        i = seg_data_end;
    }

    return error.InvalidOutput;
}

fn isJpegSofMarker(marker: u8) bool {
    return switch (marker) {
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => true,
        else => false,
    };
}

fn readU16Big(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readU32Big(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
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

fn childTermToExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| @intCast(sig),
        .Stopped => |sig| @intCast(sig),
        .Unknown => |code| @intCast(code),
    };
}

test "CameraSnapFormat.fromString accepts jpeg/jpg/png" {
    try std.testing.expect(CameraSnapFormat.fromString("jpeg").? == .jpeg);
    try std.testing.expect(CameraSnapFormat.fromString("jpg").? == .jpeg);
    try std.testing.expect(CameraSnapFormat.fromString("PNG").? == .png);
    try std.testing.expect(CameraSnapFormat.fromString("webp") == null);
}

test "CameraClipFormat.fromString accepts mp4" {
    try std.testing.expect(CameraClipFormat.fromString("mp4").? == .mp4);
    try std.testing.expect(CameraClipFormat.fromString("MP4").? == .mp4);
    try std.testing.expect(CameraClipFormat.fromString("webm") == null);
}

test "parsePngDimensions reads width/height from IHDR" {
    const png_bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1A, '\n',
        0x00, 0x00, 0x00, 0x0D, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0xD0,
    };

    const dims = try parsePngDimensions(&png_bytes);
    try std.testing.expectEqual(@as(u32, 1280), dims.width);
    try std.testing.expectEqual(@as(u32, 720), dims.height);
}

test "parseJpegDimensions reads width/height from SOF" {
    const jpeg_bytes = [_]u8{
        // SOI
        0xFF, 0xD8,
        // APP0 (length 16)
        0xFF, 0xE0,
        0x00, 0x10,
        0x4A, 0x46,
        0x49, 0x46,
        0x00, 0x01,
        0x01, 0x00,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00,
        // SOF0 (length 17)
        0xFF, 0xC0,
        0x00, 0x11,
        0x08, 0x01,
        0xE0, 0x02,
        0x80, 0x03,
        0x01, 0x11,
        0x00, 0x02,
        0x11, 0x01,
        0x03, 0x11,
        0x01,
    };

    const dims = try parseJpegDimensions(&jpeg_bytes);
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}

test "detectBackendSupport returns false on non-Windows targets" {
    if (builtin.target.os.tag != .windows) {
        const support = detectBackendSupport(std.testing.allocator);
        try std.testing.expect(!support.list);
        try std.testing.expect(!support.snap);
        try std.testing.expect(!support.clip);
    }
}

test "parseDevicesJson handles object/array/null payloads" {
    const allocator = std.testing.allocator;

    const json_array =
        "[" ++
        "{\"Name\":\"Integrated Front Camera\",\"PNPDeviceID\":\"SWD\\\\CAMERA\\\\FRONT_CAM\"}," ++
        "{\"Name\":\"USB Camera\",\"PNPDeviceID\":\"USB\\\\VID_046D&PID_0825\"}" ++
        "]";

    const devices = try parseDevicesJson(allocator, json_array);
    defer freeCameraDevices(allocator, devices);

    try std.testing.expectEqual(@as(usize, 2), devices.len);
    try std.testing.expectEqualStrings("Integrated Front Camera", devices[0].name);
    try std.testing.expect(devices[0].position.? == .front);
    try std.testing.expect(devices[1].position.? == .external);

    const json_object = "{\"Name\":\"Rear Camera\",\"PNPDeviceID\":\"SWD\\\\CAMERA\\\\REAR_CAM\"}";
    const single = try parseDevicesJson(allocator, json_object);
    defer freeCameraDevices(allocator, single);

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

test "snapCamera returns NotSupported on non-Windows targets" {
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectError(error.NotSupported, snapCamera(std.testing.allocator, .{}));
    }
}

test "clipCamera returns NotSupported on non-Windows targets" {
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectError(error.NotSupported, clipCamera(std.testing.allocator, .{}));
    }
}
