const std = @import("std");
const messages = @import("messages.zig");

pub const RequestPayload = struct {
    id: []u8,
    payload: []u8,
};

pub fn RequestFrame(comptime Params: type) type {
    return struct {
        type: []const u8 = "req",
        id: []const u8,
        method: []const u8,
        params: Params,
    };
}

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
) !RequestPayload {
    const id = try makeRequestId(allocator);
    const frame = RequestFrame(@TypeOf(params)){
        .id = id,
        .method = method,
        .params = params,
    };
    const payload = try messages.serializeMessage(allocator, frame);
    return .{ .id = id, .payload = payload };
}

pub fn makeRequestId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}
