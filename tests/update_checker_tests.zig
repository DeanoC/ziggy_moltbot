const std = @import("std");
const update_checker = @import("ziggystarclaw").client.update_checker;

const allocator = std.testing.allocator;

test "sanitizeUrl strips wrappers and whitespace" {
    const raw = "  <https://example.com/update.json>  ";
    const sanitized = try update_checker.sanitizeUrl(allocator, raw);
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("https://example.com/update.json", sanitized);
}

test "normalizeUrlForParse escapes spaces and stray percent" {
    var url = try allocator.dupe(u8, "https://example.com/file%ZZ name+test");
    defer allocator.free(url);
    const changed = try update_checker.normalizeUrlForParse(allocator, &url);
    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("https://example.com/file%25ZZ%20name+test", url);
}

test "normalizeUrlForParse handles github release asset urls" {
    var url = try allocator.dupe(u8,
        "https://release-assets.githubusercontent.com/github-production-release-asset/1144344095/bc719dc3-cd0a-4417-92b9-4b81113e00e1?sp=r&sv=2018-11-09&sr=b&spr=https&se=2026-02-01T12%3A15%3A59Z&rscd=attachment%3B+filename%3Dziggystarclaw_windows_0.1.12.zip&rsct=application%2Foctet-stream&skoid=96c2d410-5711-43a1-aedd-ab1947aa7ab0&sktid=398a6654-997b-47e9-b12b-9515b896b4de&skt=2026-02-01T11%3A15%3A36Z&ske=2026-02-01T12%3A15%3A59Z&sks=b&skv=2018-11-09&sig=DHq2CBR5dEKlg7tSfsXZDO9K5gwQ0DE4jtnt2xqtuho%3D&jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmVsZWFzZS1hc3NldHMuZ2l0aHVidXNlcmNvbnRlbnQuY29tIiwia2V5Ijoia2V5MSIsImV4cCI6MTc2OTk0NzEyNywibmJmIjoxNzY5OTQ1MzI3LCJwYXRoIjoicmVsZWFzZWFzc2V0cHJvZHVjdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQifQ.xep6_4UKNnZP_ag873hngL8OOCkrRk41X-Zwbqimwi4&response-content-disposition=attachment%3B%20filename%3Dziggystarclaw_windows_0.1.12.zip&response-content-type=application%2Foctet-stream");
    defer allocator.free(url);
    _ = try update_checker.normalizeUrlForParse(allocator, &url);
    _ = try std.Uri.parse(url);
}

test "normalizeUrlForParse encodes invalid characters" {
    var url = try allocator.dupe(u8, "https://example.com/a|b");
    defer allocator.free(url);
    const changed = try update_checker.normalizeUrlForParse(allocator, &url);
    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("https://example.com/a%7Cb", url);
}

test "checkOnce reads manifest from file url" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest =
        \\{
        \\  "version": "0.2.0",
        \\  "release_url": "https://example.com/release/",
        \\  "platforms": {
        \\    "linux": { "file": "ziggystarclaw_linux.zip", "sha256": "abc123" }
        \\  }
        \\}
    ;
    const filename = "update manifest.json";
    try tmp.dir.writeFile(.{ .sub_path = filename, .data = manifest });

    const abs_path = try tmp.dir.realpathAlloc(allocator, filename);
    defer allocator.free(abs_path);
    const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
    defer allocator.free(file_url);

    var info = try update_checker.checkOnce(allocator, file_url, "0.1.0");
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("0.2.0", info.version);
    try std.testing.expect(info.download_file != null);
}
