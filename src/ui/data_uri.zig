const std = @import("std");

pub const DataUriError = error{
    InvalidDataUri,
    UnsupportedDataUri,
    DecodeFailed,
};

pub fn decodeDataUriBytes(allocator: std.mem.Allocator, uri: []const u8) DataUriError![]u8 {
    if (!std.mem.startsWith(u8, uri, "data:")) return error.InvalidDataUri;
    const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUri;
    const header = uri[5..comma];
    if (std.mem.indexOf(u8, header, ";base64") == null) return error.UnsupportedDataUri;
    const payload = uri[comma + 1 ..];
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return error.DecodeFailed;
    const out = allocator.alloc(u8, size) catch return error.DecodeFailed;
    decoder.decode(out, payload) catch {
        allocator.free(out);
        return error.DecodeFailed;
    };
    return out;
}

pub fn decodeDataUri(allocator: std.mem.Allocator, uri: []const u8) DataUriError![]u8 {
    if (!std.mem.startsWith(u8, uri, "data:")) return error.InvalidDataUri;
    const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUri;
    const header = uri[5..comma];
    if (std.mem.indexOf(u8, header, ";base64") == null) return error.UnsupportedDataUri;
    if (std.mem.indexOf(u8, header, "image/") == null) return error.UnsupportedDataUri;
    const payload = uri[comma + 1 ..];
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return error.DecodeFailed;
    const out = allocator.alloc(u8, size) catch return error.DecodeFailed;
    decoder.decode(out, payload) catch {
        allocator.free(out);
        return error.DecodeFailed;
    };
    return out;
}
