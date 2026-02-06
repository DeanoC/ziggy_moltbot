const std = @import("std");
const builtin = @import("builtin");
const profiler = @import("profiler.zig");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

const has_fs = builtin.os.tag != .emscripten and builtin.os.tag != .wasi;
var log_file: ?std.fs.File = null;
var log_mutex: std.Thread.Mutex = .{};
var min_level: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Level.info));

const LogEntry = struct {
    level: Level,
    message: []u8,
};

var async_enabled: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var shutdown_requested: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var log_thread: ?std.Thread = null;
var queue: std.ArrayList(LogEntry) = .empty;
var queue_head: usize = 0;
var queue_mutex: std.Thread.Mutex = .{};
var queue_cond: std.Thread.Condition = .{};
var queue_allocator: std.mem.Allocator = std.heap.page_allocator;
const max_queue_len: usize = 2048;
var dropped_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub fn setLevel(level: Level) void {
    min_level.store(@intFromEnum(level), .monotonic);
}

pub fn initAsync(allocator: std.mem.Allocator) !void {
    if (async_enabled.load(.monotonic) != 0) return;
    queue_allocator = allocator;
    shutdown_requested.store(0, .monotonic);
    log_thread = try std.Thread.spawn(.{}, logThreadMain, .{});
    async_enabled.store(1, .monotonic);
}

pub fn getLevel() Level {
    return @enumFromInt(min_level.load(.monotonic));
}

pub fn initFile(path: []const u8) !void {
    if (has_fs) {
        deinit();
        var file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        try file.seekFromEnd(0);
        log_file = file;
        return;
    }
    return error.UnsupportedPlatform;
}

pub fn deinit() void {
    if (async_enabled.load(.monotonic) != 0) {
        shutdown_requested.store(1, .monotonic);
        queue_cond.signal();
        if (log_thread) |handle| {
            handle.join();
            log_thread = null;
        }
        async_enabled.store(0, .monotonic);
    }
    if (log_file) |file| {
        file.close();
        log_file = null;
    }
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (async_enabled.load(.monotonic) != 0) {
        enqueue(.info, fmt, args);
        return;
    }
    std.log.info(fmt, args);
    writeFile(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (async_enabled.load(.monotonic) != 0) {
        enqueue(.warn, fmt, args);
        return;
    }
    std.log.warn(fmt, args);
    writeFile(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (async_enabled.load(.monotonic) != 0) {
        enqueue(.err, fmt, args);
        return;
    }
    std.log.err(fmt, args);
    writeFile(.err, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    const current = min_level.load(.monotonic);
    if (@intFromEnum(Level.debug) < current) return;
    if (async_enabled.load(.monotonic) != 0) {
        enqueue(.debug, fmt, args);
        return;
    }
    std.log.debug(fmt, args);
    writeFile(.debug, fmt, args);
}

fn enqueue(level: Level, comptime fmt: []const u8, args: anytype) void {
    const current = min_level.load(.monotonic);
    if (@intFromEnum(level) < current) return;
    queue_mutex.lock();
    defer queue_mutex.unlock();
    const queued = queue.items.len - queue_head;
    if (queued >= max_queue_len) {
        _ = dropped_count.fetchAdd(1, .monotonic);
        return;
    }
    const message = std.fmt.allocPrint(queue_allocator, fmt, args) catch return;
    _ = queue.append(queue_allocator, .{ .level = level, .message = message }) catch {
        queue_allocator.free(message);
        return;
    };
    queue_cond.signal();
}

fn logThreadMain() void {
    profiler.setThreadName("logger");
    var stderr = std.fs.File.stderr().deprecatedWriter();
    while (true) {
        queue_mutex.lock();
        while ((queue.items.len == queue_head) and shutdown_requested.load(.monotonic) == 0) {
            queue_cond.wait(&queue_mutex);
        }
        if (queue.items.len == queue_head and shutdown_requested.load(.monotonic) != 0) {
            queue_mutex.unlock();
            break;
        }
        const entry = queue.items[queue_head];
        queue_head += 1;
        if (queue_head > 64 and queue_head * 2 > queue.items.len) {
            const remaining = queue.items[queue_head..];
            std.mem.copyForwards(LogEntry, queue.items[0..remaining.len], remaining);
            queue.items.len = remaining.len;
            queue_head = 0;
        }
        queue_mutex.unlock();

        const zone = profiler.zone(@src(), "logger.process");
        defer zone.end();

        const tag = switch (entry.level) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
        stderr.print("{s}: {s}\n", .{ tag, entry.message }) catch {};
        writeFileString(entry.level, entry.message);
        queue_allocator.free(entry.message);
        reportDropped(&stderr);
    }

    reportDropped(&stderr);
    queue_mutex.lock();
    const remaining = queue.items[queue_head..];
    queue.items.len = 0;
    queue_head = 0;
    queue_mutex.unlock();
    for (remaining) |entry| {
        queue_allocator.free(entry.message);
    }
    queue.deinit(queue_allocator);
}

fn reportDropped(stderr: anytype) void {
    const dropped = dropped_count.swap(0, .monotonic);
    if (dropped == 0) return;
    const current = min_level.load(.monotonic);
    if (@intFromEnum(Level.warn) < current) return;
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    fbs.writer().print("logger dropped {d} messages", .{dropped}) catch return;
    const msg = fbs.getWritten();
    stderr.print("warn: {s}\n", .{msg}) catch {};
    writeFileString(.warn, msg);
}

fn writeFile(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (has_fs) {
        const current = min_level.load(.monotonic);
        if (@intFromEnum(level) < current) return;
        const file = log_file orelse return;

        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        const tag = switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
        writer.print("[{s}] ", .{tag}) catch return;
        writer.print(fmt, args) catch return;
        writer.writeByte('\n') catch return;
        const written = fbs.getWritten();

        log_mutex.lock();
        defer log_mutex.unlock();
        file.writeAll(written) catch {};
    }
}

fn writeFileString(level: Level, message: []const u8) void {
    if (has_fs) {
        const current = min_level.load(.monotonic);
        if (@intFromEnum(level) < current) return;
        const file = log_file orelse return;
        const tag = switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        writer.print("[{s}] ", .{tag}) catch return;
        writer.print("{s}", .{message}) catch return;
        writer.writeByte('\n') catch return;
        const written = fbs.getWritten();

        log_mutex.lock();
        defer log_mutex.unlock();
        file.writeAll(written) catch {};
    }
}
