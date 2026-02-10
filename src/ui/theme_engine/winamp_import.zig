const std = @import("std");

pub const ImportError = anyerror;

pub fn extractWszToDirectory(
    allocator: std.mem.Allocator,
    wsz_path: []const u8,
    dest_dir_path: []const u8,
) ImportError!void {
    if (wsz_path.len == 0 or dest_dir_path.len == 0) return error.InvalidArguments;

    // Create destination directory if needed.
    try std.fs.cwd().makePath(dest_dir_path);
    var dest_dir = try std.fs.cwd().openDir(dest_dir_path, .{});
    defer dest_dir.close();

    // Open the archive and extract.
    var f = try std.fs.cwd().openFile(wsz_path, .{});
    defer f.close();
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = f.reader(&read_buf);

    // Winamp skins are typically well-behaved, but allow backslashes to be robust.
    try std.zip.extract(dest_dir, &reader, .{ .allow_backslashes = true });

    _ = allocator;
}
