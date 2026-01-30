const std = @import("std");
const builtin = @import("builtin");
const logger = @import("../utils/logger.zig");

pub const UpdateStatus = enum {
    idle,
    checking,
    up_to_date,
    update_available,
    failed,
    unsupported,
};

pub const DownloadStatus = enum {
    idle,
    downloading,
    complete,
    failed,
    unsupported,
};

pub const UpdateState = struct {
    mutex: std.Thread.Mutex = .{},
    status: UpdateStatus = .idle,
    latest_version: ?[]const u8 = null,
    release_url: ?[]const u8 = null,
    download_url: ?[]const u8 = null,
    download_file: ?[]const u8 = null,
    download_path: ?[]const u8 = null,
    download_status: DownloadStatus = .idle,
    download_bytes: u64 = 0,
    download_total: ?u64 = null,
    download_error_message: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    last_checked_ms: ?i64 = null,
    in_flight: bool = false,
    worker: ?std.Thread = null,
    download_worker: ?std.Thread = null,
    auto_download: bool = true,

    pub fn deinit(self: *UpdateState, allocator: std.mem.Allocator) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
        if (self.download_worker) |thread| {
            thread.join();
            self.download_worker = null;
        }
        self.clearLocked(allocator);
    }

    pub fn snapshot(self: *UpdateState) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .status = self.status,
            .latest_version = self.latest_version,
            .release_url = self.release_url,
            .error_message = self.error_message,
            .download_url = self.download_url,
            .download_file = self.download_file,
            .download_path = self.download_path,
            .download_status = self.download_status,
            .download_bytes = self.download_bytes,
            .download_total = self.download_total,
            .download_error_message = self.download_error_message,
            .last_checked_ms = self.last_checked_ms,
            .in_flight = self.in_flight,
        };
    }

    pub fn startCheck(
        self: *UpdateState,
        allocator: std.mem.Allocator,
        manifest_url: []const u8,
        current_version: []const u8,
        auto_download: bool,
    ) void {
        if (manifest_url.len == 0) {
            self.setError(allocator, "Update manifest URL is empty.");
            return;
        }
        if (builtin.target.os.tag == .emscripten) {
            self.setUnsupported(allocator);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.in_flight) return;

        self.clearLocked(allocator);
        self.status = .checking;
        self.in_flight = true;
        self.auto_download = auto_download;

        const url_copy = allocator.dupe(u8, manifest_url) catch {
            self.status = .failed;
            self.in_flight = false;
            return;
        };
        const version_copy = allocator.dupe(u8, current_version) catch {
            allocator.free(url_copy);
            self.status = .failed;
            self.in_flight = false;
            return;
        };

        const thread = std.Thread.spawn(.{}, checkThread, .{ self, allocator, url_copy, version_copy }) catch {
            allocator.free(url_copy);
            allocator.free(version_copy);
            self.status = .failed;
            self.in_flight = false;
            return;
        };
        self.worker = thread;
    }

    pub fn startDownload(self: *UpdateState, allocator: std.mem.Allocator, url: []const u8, file_name: []const u8) void {
        if (url.len == 0 or file_name.len == 0) {
            self.setDownloadError(allocator, "No download URL available.");
            return;
        }
        if (builtin.target.os.tag == .emscripten or builtin.abi == .android) {
            self.setDownloadUnsupported(allocator);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.download_status == .downloading) return;

        if (self.download_url) |value| allocator.free(value);
        if (self.download_path) |value| allocator.free(value);
        if (self.download_error_message) |value| allocator.free(value);

        self.download_url = allocator.dupe(u8, url) catch null;
        const path = std.fmt.allocPrint(allocator, "updates/{s}", .{file_name}) catch null;
        self.download_path = path;
        self.download_error_message = null;
        self.download_status = .downloading;
        self.download_bytes = 0;
        self.download_total = null;

        const url_copy = allocator.dupe(u8, url) catch {
            self.download_status = .failed;
            return;
        };
        const path_copy = allocator.dupe(u8, file_name) catch {
            allocator.free(url_copy);
            self.download_status = .failed;
            return;
        };

        const thread = std.Thread.spawn(.{}, downloadThread, .{ self, allocator, url_copy, path_copy }) catch {
            allocator.free(url_copy);
            allocator.free(path_copy);
            self.download_status = .failed;
            return;
        };
        self.download_worker = thread;
    }

    fn clearLocked(self: *UpdateState, allocator: std.mem.Allocator) void {
        if (self.latest_version) |value| {
            allocator.free(value);
        }
        if (self.release_url) |value| {
            allocator.free(value);
        }
        if (self.download_url) |value| {
            allocator.free(value);
        }
        if (self.download_file) |value| {
            allocator.free(value);
        }
        if (self.download_path) |value| {
            allocator.free(value);
        }
        if (self.download_error_message) |value| {
            allocator.free(value);
        }
        if (self.error_message) |value| {
            allocator.free(value);
        }
        self.latest_version = null;
        self.release_url = null;
        self.download_url = null;
        self.download_file = null;
        self.download_path = null;
        self.download_error_message = null;
        self.download_status = .idle;
        self.download_bytes = 0;
        self.download_total = null;
        self.error_message = null;
    }

    fn setError(self: *UpdateState, allocator: std.mem.Allocator, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearLocked(allocator);
        self.error_message = allocator.dupe(u8, message) catch null;
        self.status = .failed;
        self.last_checked_ms = std.time.milliTimestamp();
        self.in_flight = false;
    }

    fn setUnsupported(self: *UpdateState, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearLocked(allocator);
        self.status = .unsupported;
        self.error_message = allocator.dupe(u8, "Update checks are not supported in the web build.") catch null;
        self.last_checked_ms = std.time.milliTimestamp();
        self.in_flight = false;
    }

    fn setDownloadError(self: *UpdateState, allocator: std.mem.Allocator, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.download_error_message) |value| allocator.free(value);
        self.download_error_message = allocator.dupe(u8, message) catch null;
        self.download_status = .failed;
    }

    fn setDownloadUnsupported(self: *UpdateState, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.download_error_message) |value| allocator.free(value);
        self.download_error_message = allocator.dupe(u8, "Auto-download is not supported on this platform.") catch null;
        self.download_status = .unsupported;
    }
};

pub const Snapshot = struct {
    status: UpdateStatus,
    latest_version: ?[]const u8,
    release_url: ?[]const u8,
    error_message: ?[]const u8,
    download_url: ?[]const u8,
    download_file: ?[]const u8,
    download_path: ?[]const u8,
    download_status: DownloadStatus,
    download_bytes: u64,
    download_total: ?u64,
    download_error_message: ?[]const u8,
    last_checked_ms: ?i64,
    in_flight: bool,
};

fn checkThread(
    state: *UpdateState,
    allocator: std.mem.Allocator,
    manifest_url: []const u8,
    current_version: []const u8,
) void {
    defer allocator.free(manifest_url);
    defer allocator.free(current_version);

    const latest_version = checkForUpdates(allocator, manifest_url, current_version) catch |err| {
        logger.warn("Update check failed: {}", .{err});
        state.setError(allocator, @errorName(err));
        return;
    };

    const should_download = state.auto_download and
        latest_version.download_url != null and
        latest_version.download_file != null and
        isNewerVersion(latest_version.version, current_version);

    state.mutex.lock();
    state.clearLocked(allocator);
    state.latest_version = latest_version.version;
    state.release_url = latest_version.release_url;
    state.download_url = latest_version.download_url;
    state.download_file = latest_version.download_file;
    state.last_checked_ms = std.time.milliTimestamp();
    state.in_flight = false;
    if (isNewerVersion(latest_version.version, current_version)) {
        state.status = .update_available;
    } else {
        state.status = .up_to_date;
    }
    state.mutex.unlock();

    if (should_download) {
        state.startDownload(
            allocator,
            latest_version.download_url.?,
            latest_version.download_file.?,
        );
    }
}

const UpdateInfo = struct {
    version: []const u8,
    release_url: ?[]const u8,
    download_url: ?[]const u8,
    download_file: ?[]const u8,
};

fn checkForUpdates(
    allocator: std.mem.Allocator,
    manifest_url: []const u8,
    current_version: []const u8,
) !UpdateInfo {
    _ = current_version;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = manifest_url },
        .method = .GET,
        .response_writer = &body.writer,
    });

    if (result.status != .ok) {
        return error.UpdateManifestFetchFailed;
    }

    const body_slice = body.written();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body_slice, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.UpdateManifestInvalid;
    const version_value = parsed.value.object.get("version") orelse return error.UpdateManifestMissingVersion;
    if (version_value != .string) return error.UpdateManifestInvalid;
    const version = version_value.string;
    if (version.len == 0) return error.UpdateManifestMissingVersion;

    var release_url: ?[]const u8 = null;
    var base_url_raw: ?[]const u8 = null;
    var download_url: ?[]const u8 = null;
    var download_file: ?[]const u8 = null;
    const platform_key = platformKey();
    if (parsed.value.object.get("release_url")) |rel| {
        if (rel == .string and rel.string.len > 0) {
            release_url = try allocator.dupe(u8, rel.string);
        }
    }
    if (parsed.value.object.get("base_url")) |base| {
        if (base == .string and base.string.len > 0) {
            base_url_raw = base.string;
        }
    }
    if (platform_key) |key| {
        if (parsed.value.object.get("platforms")) |platforms| {
            if (platforms == .object) {
                if (platforms.object.get(key)) |platform| {
                    if (platform == .object) {
                        if (platform.object.get("file")) |file| {
                            if (file == .string and file.string.len > 0) {
                                download_file = try allocator.dupe(u8, file.string);
                            }
                        }
                    }
                }
            }
        }
    }

    if (download_file) |file| {
        if (base_url_raw) |base_raw| {
            var base_buf: ?[]u8 = null;
            defer if (base_buf) |buf| allocator.free(buf);
            const base_trim = if (std.mem.endsWith(u8, base_raw, "/"))
                base_raw
            else blk: {
                const buf = try std.fmt.allocPrint(allocator, "{s}/", .{base_raw});
                base_buf = buf;
                break :blk buf;
            };
            download_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_trim, file });
        } else if (release_url) |rel| {
            const base = if (std.mem.endsWith(u8, rel, "/"))
                try std.fmt.allocPrint(allocator, "{s}download/", .{rel})
            else
                try std.fmt.allocPrint(allocator, "{s}/download/", .{rel});
            defer allocator.free(base);
            download_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, file });
        }
    }

    return .{
        .version = try allocator.dupe(u8, version),
        .release_url = release_url,
        .download_url = download_url,
        .download_file = download_file,
    };
}

fn platformKey() ?[]const u8 {
    return switch (builtin.target.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => null,
    };
}

fn downloadThread(
    state: *UpdateState,
    allocator: std.mem.Allocator,
    url: []const u8,
    file_name: []const u8,
) void {
    defer allocator.free(url);
    defer allocator.free(file_name);

    const result = downloadFile(allocator, state, url, file_name) catch |err| {
        logger.warn("Download failed: {}", .{err});
        state.setDownloadError(allocator, @errorName(err));
        return;
    };
    _ = result;

    state.mutex.lock();
    state.download_status = .complete;
    state.mutex.unlock();
}

fn downloadFile(
    allocator: std.mem.Allocator,
    state: *UpdateState,
    url: []const u8,
    file_name: []const u8,
) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const path = std.fmt.allocPrint(allocator, "updates/{s}", .{file_name}) catch return error.OutOfMemory;
    defer allocator.free(path);

    std.fs.cwd().makePath("updates") catch {};
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.UpdateDownloadFailed;

    const total = response.head.content_length;
    state.mutex.lock();
    state.download_total = total;
    state.download_bytes = 0;
    state.mutex.unlock();

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var download_writer = DownloadWriter.init(file, state);
    _ = reader.streamRemaining(&download_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return error.UpdateDownloadFailed,
        error.WriteFailed => return error.UpdateDownloadFailed,
    };
}

const DownloadWriter = struct {
    file: std.fs.File,
    state: *UpdateState,
    writer: std.Io.Writer,

    pub fn init(file: std.fs.File, state: *UpdateState) DownloadWriter {
        return .{
            .file = file,
            .state = state,
            .writer = .{
                .vtable = &vtable,
                .buffer = &.{},
                .end = 0,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DownloadWriter = @fieldParentPtr("writer", w);
        var total: usize = 0;
        for (data) |chunk| {
            if (chunk.len == 0) continue;
            self.file.writeAll(chunk) catch return error.WriteFailed;
            total += chunk.len;
        }
        if (splat > 0 and data.len > 0) {
            const last = data[data.len - 1];
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                if (last.len == 0) continue;
                self.file.writeAll(last) catch return error.WriteFailed;
                total += last.len;
            }
        }
        self.state.mutex.lock();
        self.state.download_bytes += total;
        self.state.mutex.unlock();
        return total;
    }

    fn sendFile(
        w: *std.Io.Writer,
        file_reader: *std.fs.File.Reader,
        limit: std.Io.Limit,
    ) std.Io.Writer.FileError!usize {
        _ = w;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = w;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = w;
        _ = preserve;
        _ = capacity;
        return error.WriteFailed;
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .sendFile = sendFile,
        .flush = flush,
        .rebase = rebase,
    };
};

fn isNewerVersion(latest: []const u8, current: []const u8) bool {
    const latest_parts = parseVersion(latest);
    const current_parts = parseVersion(current);
    if (latest_parts[0] != current_parts[0]) return latest_parts[0] > current_parts[0];
    if (latest_parts[1] != current_parts[1]) return latest_parts[1] > current_parts[1];
    return latest_parts[2] > current_parts[2];
}

fn parseVersion(raw: []const u8) [3]u32 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len > 0 and (text[0] == 'v' or text[0] == 'V')) {
        text = text[1..];
    }
    var parts: [3]u32 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, text, '.');
    var idx: usize = 0;
    while (it.next()) |part| : (idx += 1) {
        if (idx >= parts.len) break;
        parts[idx] = std.fmt.parseInt(u32, part, 10) catch 0;
    }
    return parts;
}
