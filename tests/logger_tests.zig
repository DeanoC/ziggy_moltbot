const std = @import("std");
const moltbot = @import("moltbot");

const logger = moltbot.utils.logger;

test "logger writes to file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "test.log";
    const full_path = try tmp.dir.realpathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(full_path);

    logger.setLevel(.debug);
    try logger.initFile(full_path);
    defer logger.deinit();

    logger.info("hello {d}", .{1});

    const data = try tmp.dir.readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "[INFO] hello 1") != null);
}
