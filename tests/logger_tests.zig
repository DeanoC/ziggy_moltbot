const std = @import("std");
const moltbot = @import("ziggystarclaw");

const logger = moltbot.utils.logger;

test "logger writes to file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "test.log";

    logger.setLevel(.debug);
    try logger.initFile(path);
    defer logger.deinit();

    logger.info("hello {d}", .{1});

    const data = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(data);
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.testing.expect(std.mem.indexOf(u8, data, "[INFO] hello 1") != null);
}
