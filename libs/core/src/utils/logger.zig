const std = @import("std");
const builtin = @import("builtin");

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
    if (!has_fs) return error.UnsupportedPlatform;
    deinit();
    var file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    try file.seekFromEnd(0);
    log_file = file;
}

pub fn deinit() void {
    if (async_enabled.load(.monotonic) != 0) {
        shutdown_requested.store(1, .monotonic);
        queue_cond.signal();
        if (log_thread) |thread| {
            thread.join();
            log_thread = null;
        }
        async_enabled.store(0, .monotonic);
    }
    if (log_file) |file| {
        file.close();
        log_file = null;
    }
}

fn logThreadMain() void {
    while (true) {
        queue_mutex.lock();
        while (queue_head >= queue.items.len and shutdown_requested.load(.monotonic) == 0) {
            queue_cond.wait(&queue_mutex);
        }
        const has_items = queue_head < queue.items.len;
        queue_mutex.unlock();
        
        if (!has_items) break;
        
        while (true) {
            queue_mutex.lock();
            if (queue_head >= queue.items.len) {
                queue_mutex.unlock();
                break;
            }
            const entry = queue.items[queue_head];
            queue_head += 1;
            queue_mutex.unlock();
            
            writeLog(entry.level, entry.message);
            queue_allocator.free(entry.message);
        }
        
        queue_mutex.lock();
        if (queue_head > 0) {
            const new_len = queue.items.len - queue_head;
            std.mem.copyForwards(LogEntry, queue.items[0..new_len], queue.items[queue_head..]);
            queue.shrinkAndFree(queue_allocator, new_len);
            queue_head = 0;
        }
        queue_mutex.unlock();
    }
}

fn writeLog(level: Level, message: []const u8) void {
    const level_str = switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
    
    const timestamp = std.time.timestamp();
    const line = std.fmt.allocPrint(queue_allocator, "[{d}] {s}: {s}\n", .{ timestamp, level_str, message }) catch return;
    defer queue_allocator.free(line);
    
    log_mutex.lock();
    defer log_mutex.unlock();
    
    if (log_file) |file| {
        _ = file.write(line) catch {};
    }
    
    std.debug.print("{s}", .{line});
}

pub fn log(level: Level, comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) < min_level.load(.monotonic)) return;
    
    const message = std.fmt.allocPrint(queue_allocator, format, args) catch {
        dropped_count.fetchAdd(1, .monotonic);
        return;
    };
    
    if (async_enabled.load(.monotonic) != 0) {
        queue_mutex.lock();
        if (queue.items.len - queue_head >= max_queue_len) {
            queue_mutex.unlock();
            queue_allocator.free(message);
            dropped_count.fetchAdd(1, .monotonic);
            return;
        }
        queue.append(queue_allocator, .{ .level = level, .message = message }) catch {
            queue_mutex.unlock();
            queue_allocator.free(message);
            dropped_count.fetchAdd(1, .monotonic);
            return;
        };
        queue_mutex.unlock();
        queue_cond.signal();
    } else {
        writeLog(level, message);
        queue_allocator.free(message);
    }
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    log(.debug, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    log(.info, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    log(.warn, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    log(.err, format, args);
}
