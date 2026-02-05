const std = @import("std");

pub const FetchError = std.Uri.ParseError || std.http.Client.RequestError || std.http.Client.Request.ReceiveHeadError || std.http.Reader.BodyError || std.mem.Allocator.Error || error{
    HttpStatus,
    TooLarge,
    UnsupportedCompressionMethod,
};

pub fn fetchHttpBytesLimited(
    allocator: std.mem.Allocator,
    url: []const u8,
    max_bytes: usize,
) FetchError![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.status != .ok) {
        return error.HttpStatus;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const bytes = reader.allocRemaining(allocator, std.Io.Limit.limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        error.ReadFailed => return response.bodyErr().?,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return bytes;
}
