const std = @import("std");
const builtin = @import("builtin");
const zsc = @import("ziggystarclaw");

const screen = zsc.windows.screen;

test "windows screen: format parser accepts mp4" {
    try std.testing.expect(screen.ScreenRecordFormat.fromString("mp4").? == .mp4);
    try std.testing.expect(screen.ScreenRecordFormat.fromString("MP4").? == .mp4);
    try std.testing.expect(screen.ScreenRecordFormat.fromString("webm") == null);
}

test "windows screen: detect backend support is false on non-Windows" {
    if (builtin.target.os.tag != .windows) {
        const support = screen.detectBackendSupport(std.testing.allocator);
        try std.testing.expect(!support.record);
    }
}

test "windows screen: recordScreen is not supported on non-Windows" {
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectError(error.NotSupported, screen.recordScreen(std.testing.allocator, .{}));
    }
}
