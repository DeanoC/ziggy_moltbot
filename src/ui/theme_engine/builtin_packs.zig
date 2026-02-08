const std = @import("std");
const builtin = @import("builtin");

pub const PackFile = struct {
    rel_path: []const u8,
    bytes: []const u8,
};

pub const BuiltinPack = struct {
    dir_name: []const u8,
    files: []const PackFile,
};

// These packs exist primarily to make Android and other "no assets next to exe" targets
// usable out-of-the-box. We install them into the writable `themes/<id>` directory
// only if missing, so user-modified packs are not overwritten.
const packs = [_]BuiltinPack{
    .{
        .dir_name = "zsc_clean",
        .files = &[_]PackFile{
            .{ .rel_path = "manifest.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/manifest.json") },
            .{ .rel_path = "windows.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/windows.json") },
            .{ .rel_path = "layouts/workspace.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/layouts/workspace.json") },
            .{ .rel_path = "profiles/phone.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/profiles/phone.json") },
            .{ .rel_path = "profiles/tablet.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/profiles/tablet.json") },
            .{ .rel_path = "profiles/fullscreen.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/profiles/fullscreen.json") },
            .{ .rel_path = "tokens/base.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/tokens/base.json") },
            .{ .rel_path = "tokens/light.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/tokens/light.json") },
            .{ .rel_path = "tokens/dark.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/tokens/dark.json") },
            .{ .rel_path = "styles/components.json", .bytes = @embedFile("builtin_packs_data/zsc_clean/styles/components.json") },
        },
    },
    .{
        .dir_name = "zsc_winamp",
        .files = &[_]PackFile{
            .{ .rel_path = "manifest.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp/manifest.json") },
            .{ .rel_path = "windows.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp/windows.json") },
            .{ .rel_path = "tokens/base.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp/tokens/base.json") },
            .{ .rel_path = "tokens/light.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp/tokens/light.json") },
            .{ .rel_path = "tokens/dark.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp/tokens/dark.json") },
            .{ .rel_path = "styles/components.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp/styles/components.json") },
            .{ .rel_path = "assets/images/panel_frame.png", .bytes = @embedFile("builtin_packs_data/zsc_winamp/assets/images/panel_frame.png") },
        },
    },
    .{
        .dir_name = "zsc_winamp_pixel",
        .files = &[_]PackFile{
            .{ .rel_path = "manifest.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp_pixel/manifest.json") },
            .{ .rel_path = "windows.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp_pixel/windows.json") },
            .{ .rel_path = "tokens/base.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp_pixel/tokens/base.json") },
            .{ .rel_path = "tokens/light.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp_pixel/tokens/light.json") },
            .{ .rel_path = "tokens/dark.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp_pixel/tokens/dark.json") },
            .{ .rel_path = "styles/components.json", .bytes = @embedFile("builtin_packs_data/zsc_winamp_pixel/styles/components.json") },
            .{ .rel_path = "assets/images/panel_frame.png", .bytes = @embedFile("builtin_packs_data/zsc_winamp_pixel/assets/images/panel_frame.png") },
        },
    },
    .{
        .dir_name = "zsc_showcase",
        .files = &[_]PackFile{
            .{ .rel_path = "manifest.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/manifest.json") },
            .{ .rel_path = "windows.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/windows.json") },
            .{ .rel_path = "layouts/workspace.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/layouts/workspace.json") },
            .{ .rel_path = "profiles/phone.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/profiles/phone.json") },
            .{ .rel_path = "profiles/tablet.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/profiles/tablet.json") },
            .{ .rel_path = "profiles/fullscreen.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/profiles/fullscreen.json") },
            .{ .rel_path = "tokens/base.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/tokens/base.json") },
            .{ .rel_path = "tokens/light.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/tokens/light.json") },
            .{ .rel_path = "tokens/dark.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/tokens/dark.json") },
            .{ .rel_path = "styles/components.json", .bytes = @embedFile("builtin_packs_data/zsc_showcase/styles/components.json") },
            .{ .rel_path = "assets/images/panel_frame.png", .bytes = @embedFile("builtin_packs_data/zsc_showcase/assets/images/panel_frame.png") },
        },
    },
};

fn findPackByDirName(dir_name: []const u8) ?*const BuiltinPack {
    for (packs[0..]) |*p| {
        if (std.mem.eql(u8, p.dir_name, dir_name)) return p;
    }
    return null;
}

fn fileExists(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return false;
    return true;
}

fn ensureParentDir(cwd: std.fs.Dir, full_path: []const u8) !void {
    const parent = std.fs.path.dirname(full_path) orelse return;
    try cwd.makePath(parent);
}

fn writeFileIfMissing(cwd: std.fs.Dir, path: []const u8, bytes: []const u8) !bool {
    if (fileExists(cwd, path)) return false;
    try ensureParentDir(cwd, path);
    var f = try cwd.createFile(path, .{ .truncate = false, .exclusive = true });
    defer f.close();
    try f.writeAll(bytes);
    return true;
}

fn dirNameFromThemePath(theme_path: []const u8) ?[]const u8 {
    const prefix = "themes/";
    if (!std.mem.startsWith(u8, theme_path, prefix)) return null;
    const rest = theme_path[prefix.len..];
    if (rest.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const name = rest[0..slash];
    return if (name.len == 0) null else name;
}

/// Installs an embedded built-in pack into `theme_path` (typically `themes/<id>`) in the
/// current working directory (which is pref path on Android).
/// Returns `true` if any file was written.
pub fn installIfBuiltinThemePath(theme_path: []const u8) !bool {
    // Theme packs are installed from embedded bytes into the local filesystem.
    // WASM targets can't rely on std.fs, so just report "not installed".
    if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) return false;
    return installIfBuiltinThemePathAlloc(std.heap.page_allocator, theme_path);
}

pub fn installIfBuiltinThemePathAlloc(allocator: std.mem.Allocator, theme_path: []const u8) !bool {
    const dir_name = dirNameFromThemePath(theme_path) orelse return false;
    const pack = findPackByDirName(dir_name) orelse return false;

    var wrote_any = false;
    const cwd = std.fs.cwd();
    for (pack.files) |file| {
        // Write only missing files; do not overwrite user edits.
        const dst = try std.fs.path.join(allocator, &.{ theme_path, file.rel_path });
        defer allocator.free(dst);
        if (try writeFileIfMissing(cwd, dst, file.bytes)) {
            wrote_any = true;
        }
    }
    return wrote_any;
}
