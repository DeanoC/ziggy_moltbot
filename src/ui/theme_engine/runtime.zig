const profile = @import("profile.zig");
const schema = @import("schema.zig");
const style_sheet = @import("style_sheet.zig");
const theme = @import("../theme.zig");
const input_state = @import("../input/input_state.zig");
const std = @import("std");

pub const PlatformCaps = profile.PlatformCaps;
pub const ProfileId = profile.ProfileId;
pub const Profile = profile.Profile;

pub const StyleSheet = style_sheet.StyleSheet;
pub const WindowTemplate = schema.WindowTemplate;

pub const RenderDefaults = struct {
    image_sampling: @import("../render/command_list.zig").ImageSampling = .linear,
    pixel_snap_textured: bool = false,
};

var active_profile: Profile = profile.defaultsFor(.desktop, profile.PlatformCaps.defaultForTarget());
var active_styles_light: StyleSheet = .{};
var active_styles_dark: StyleSheet = .{};
var active_pack_root: ?[]const u8 = null;
var active_windows: []const WindowTemplate = &[_]WindowTemplate{};
var render_defaults: RenderDefaults = .{};
var pack_default_mode: ?theme.Mode = null;
var pack_default_profile: ?ProfileId = null;

pub fn setProfile(p: Profile) void {
    active_profile = p;
}

pub fn getProfile() Profile {
    return active_profile;
}

pub fn activeNav() bool {
    // Use the resolved profile as the authoritative signal for controller-first UI.
    // The nav system can be active outside fullscreen as well, but for now this is enough
    // to drive larger hit targets and reduced hover-only styling.
    return active_profile.modality == .controller;
}

pub fn allowHover(queue: *const input_state.InputQueue) bool {
    const p = getProfile();
    if (!p.allow_hover_states) return false;
    // Only show hover states for a real mouse pointer.
    return queue.state.pointer_kind == .mouse;
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

pub fn setWindowTemplates(templates: []const WindowTemplate) void {
    active_windows = templates;
}

pub fn getWindowTemplates() []const WindowTemplate {
    return active_windows;
}

pub fn setRenderDefaults(v: RenderDefaults) void {
    render_defaults = v;
}

pub fn getRenderDefaults() RenderDefaults {
    return render_defaults;
}

pub fn setPackDefaults(variant_label: []const u8, profile_label: []const u8) void {
    // Only accept known labels; unknown values fall back to app defaults.
    if (std.ascii.eqlIgnoreCase(variant_label, "light")) {
        pack_default_mode = .light;
    } else if (std.ascii.eqlIgnoreCase(variant_label, "dark")) {
        pack_default_mode = .dark;
    } else {
        pack_default_mode = null;
    }
    pack_default_profile = profile.profileFromLabel(profile_label);
}

pub fn clearPackDefaults() void {
    pack_default_mode = null;
    pack_default_profile = null;
}

pub fn getPackDefaultMode() ?theme.Mode {
    return pack_default_mode;
}

pub fn getPackDefaultProfile() ?ProfileId {
    return pack_default_profile;
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
