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

pub fn setLevel(level: Level) void {
    min_level.store(@intFromEnum(level), .monotonic);
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
    if (log_file) |file| {
        file.close();
        log_file = null;
    }
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
    writeFile(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fmt, args);
    writeFile(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
    writeFile(.err, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
    writeFile(.debug, fmt, args);
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
