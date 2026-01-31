const std = @import("std");

pub const FetchError = error{HttpStatus};

pub fn fetchHttpBytes(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
    });

    if (result.status != .ok) {
        return error.HttpStatus;
    }

    return body.toOwnedSlice();
}
