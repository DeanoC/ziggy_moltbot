const std = @import("std");
const moltbot = @import("ziggystarclaw");

test "decode data uri" {
    const allocator = std.testing.allocator;
    const uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=";
    const bytes = try moltbot.ui.data_uri.decodeDataUri(allocator, uri);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 8);
    try std.testing.expectEqual(@as(u8, 0x89), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'P'), bytes[1]);
    try std.testing.expectEqual(@as(u8, 'N'), bytes[2]);
    try std.testing.expectEqual(@as(u8, 'G'), bytes[3]);
}
