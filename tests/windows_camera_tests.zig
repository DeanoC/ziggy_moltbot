const std = @import("std");
const builtin = @import("builtin");
const zsc = @import("ziggystarclaw");

const camera = zsc.windows.camera;

test "windows camera: snap format parser accepts jpeg/jpg/png" {
    try std.testing.expect(camera.CameraSnapFormat.fromString("jpeg").? == .jpeg);
    try std.testing.expect(camera.CameraSnapFormat.fromString("jpg").? == .jpeg);
    try std.testing.expect(camera.CameraSnapFormat.fromString("PNG").? == .png);
    try std.testing.expect(camera.CameraSnapFormat.fromString("webp") == null);
}

test "windows camera: detect backend support is false on non-Windows" {
    if (builtin.target.os.tag != .windows) {
        const support = camera.detectBackendSupport(std.testing.allocator);
        try std.testing.expect(!support.list);
        try std.testing.expect(!support.snap);
    }
}

test "windows camera: snapCamera is not supported on non-Windows" {
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectError(error.NotSupported, camera.snapCamera(std.testing.allocator, .{}));
    }
}
