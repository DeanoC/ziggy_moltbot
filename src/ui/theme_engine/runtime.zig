const profile = @import("profile.zig");
const style_sheet = @import("style_sheet.zig");
const theme = @import("../theme.zig");
const std = @import("std");

pub const PlatformCaps = profile.PlatformCaps;
pub const ProfileId = profile.ProfileId;
pub const Profile = profile.Profile;

pub const StyleSheet = style_sheet.StyleSheet;

var active_profile: Profile = profile.defaultsFor(.desktop, profile.PlatformCaps.defaultForTarget());
var active_styles_light: StyleSheet = .{};
var active_styles_dark: StyleSheet = .{};
var active_pack_root: ?[]const u8 = null;

pub fn setProfile(p: Profile) void {
    active_profile = p;
}

pub fn getProfile() Profile {
    return active_profile;
}

pub fn setStyleSheet(sheet: StyleSheet) void {
    setStyleSheets(sheet, sheet);
}

pub fn setStyleSheets(light: StyleSheet, dark: StyleSheet) void {
    active_styles_light = light;
    active_styles_dark = dark;
}

pub fn getStyleSheet() StyleSheet {
    return switch (theme.getMode()) {
        .light => active_styles_light,
        .dark => active_styles_dark,
    };
}

pub fn setThemePackRootPath(path: ?[]const u8) void {
    active_pack_root = path;
}

pub fn getThemePackRootPath() ?[]const u8 {
    return active_pack_root;
}

pub fn resolveThemeAssetPath(buf: []u8, rel_path: []const u8) ?[]const u8 {
    // Allow direct URLs/data URIs to flow through untouched.
    if (std.mem.startsWith(u8, rel_path, "data:")) return rel_path;
    if (std.mem.indexOf(u8, rel_path, "://") != null) return rel_path;
    if (std.fs.path.isAbsolute(rel_path)) return rel_path;

    const root = active_pack_root orelse return null;
    if (root.len == 0) return null;

    // Manual join into provided buffer to avoid per-frame allocations.
    // Theme packs are authored with forward slashes; convert to native separator
    // when building the actual filesystem path.
    const sep = std.fs.path.sep;
    const root_has_sep = (root.len > 0 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\'));
    const extra: usize = if (root_has_sep) 0 else 1;
    const need: usize = root.len + extra + rel_path.len;
    if (need > buf.len) return null;
    @memcpy(buf[0..root.len], root);
    var idx: usize = root.len;
    if (!root_has_sep) {
        buf[idx] = sep;
        idx += 1;
    }
    for (rel_path) |c| {
        buf[idx] = if (c == '/') sep else c;
        idx += 1;
    }
    return buf[0..idx];
}
