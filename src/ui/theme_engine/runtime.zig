const profile = @import("profile.zig");
const schema = @import("schema.zig");
const style_sheet = @import("style_sheet.zig");
const theme = @import("../theme.zig");
const input_state = @import("../input/input_state.zig");
const workspace = @import("../workspace.zig");
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

pub const WorkspaceLayoutPreset = struct {
    panels: [10]workspace.PanelKind = undefined,
    panels_len: u8 = 0,
    focused: ?workspace.PanelKind = null,
    close_others: bool = false,

    custom_layout_left_ratio: ?f32 = null,
    custom_layout_min_left_width: ?f32 = null,
    custom_layout_min_right_width: ?f32 = null,

    pub fn openPanels(self: *const WorkspaceLayoutPreset) []const workspace.PanelKind {
        return self.panels[0..self.panels_len];
    }
};

var active_profile: Profile = profile.defaultsFor(.desktop, profile.PlatformCaps.defaultForTarget());
var active_styles_light: StyleSheet = .{};
var active_styles_dark: StyleSheet = .{};
var active_pack_root: ?[]const u8 = null;
// `ThemeEngine` owns its own copy of the active pack root and may free/replace it when
// switching packs (or when swapping cached pack state). Keep an owned copy here so the
// render/runtime layer never holds a dangling slice.
var active_pack_root_storage: std.ArrayListUnmanaged(u8) = .{};
var active_windows: []const WindowTemplate = &[_]WindowTemplate{};
var active_workspace_layouts: [4]WorkspaceLayoutPreset = .{ .{}, .{}, .{}, .{} };
var active_workspace_layouts_set: [4]bool = .{ false, false, false, false };
var render_defaults: RenderDefaults = .{};
var pack_default_mode: ?theme.Mode = null;
var pack_default_profile: ?ProfileId = null;
var pack_lock_mode_to_default: bool = false;

pub const PackStatusKind = enum {
    none,
    fetching,
    ok,
    failed,
};

var pack_status_kind: PackStatusKind = .none;
var pack_status_buf: [512]u8 = undefined;
var pack_status_len: usize = 0;

pub const PackMeta = struct {
    id: []const u8,
    name: []const u8,
    author: []const u8,
    license: []const u8,
    defaults_variant: []const u8,
    defaults_profile: []const u8,
    requires_multi_window: bool,
    requires_custom_shaders: bool,
};

var pack_meta_set: bool = false;
var pack_meta_id_buf: [64]u8 = undefined;
var pack_meta_id_len: usize = 0;
var pack_meta_name_buf: [128]u8 = undefined;
var pack_meta_name_len: usize = 0;
var pack_meta_author_buf: [96]u8 = undefined;
var pack_meta_author_len: usize = 0;
var pack_meta_license_buf: [64]u8 = undefined;
var pack_meta_license_len: usize = 0;
var pack_meta_variant_buf: [16]u8 = undefined;
var pack_meta_variant_len: usize = 0;
var pack_meta_profile_buf: [16]u8 = undefined;
var pack_meta_profile_len: usize = 0;
var pack_meta_requires_multi_window: bool = false;
var pack_meta_requires_custom_shaders: bool = false;

fn copyTrunc(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    return n;
}

pub fn clearPackMeta() void {
    pack_meta_set = false;
    pack_meta_id_len = 0;
    pack_meta_name_len = 0;
    pack_meta_author_len = 0;
    pack_meta_license_len = 0;
    pack_meta_variant_len = 0;
    pack_meta_profile_len = 0;
    pack_meta_requires_multi_window = false;
    pack_meta_requires_custom_shaders = false;
}

pub fn setPackMeta(m: schema.Manifest) void {
    pack_meta_set = true;
    pack_meta_id_len = copyTrunc(pack_meta_id_buf[0..], m.id);
    pack_meta_name_len = copyTrunc(pack_meta_name_buf[0..], m.name);
    pack_meta_author_len = copyTrunc(pack_meta_author_buf[0..], m.author);
    pack_meta_license_len = copyTrunc(pack_meta_license_buf[0..], m.license);
    pack_meta_variant_len = copyTrunc(pack_meta_variant_buf[0..], m.defaults.variant);
    pack_meta_profile_len = copyTrunc(pack_meta_profile_buf[0..], m.defaults.profile);
    pack_meta_requires_multi_window = m.capabilities.requires_multi_window;
    pack_meta_requires_custom_shaders = m.capabilities.requires_custom_shaders;
}

pub fn setPackMetaFields(
    id: []const u8,
    name: []const u8,
    author: []const u8,
    license: []const u8,
    defaults_variant: []const u8,
    defaults_profile: []const u8,
    requires_multi_window: bool,
    requires_custom_shaders: bool,
) void {
    pack_meta_set = true;
    pack_meta_id_len = copyTrunc(pack_meta_id_buf[0..], id);
    pack_meta_name_len = copyTrunc(pack_meta_name_buf[0..], name);
    pack_meta_author_len = copyTrunc(pack_meta_author_buf[0..], author);
    pack_meta_license_len = copyTrunc(pack_meta_license_buf[0..], license);
    pack_meta_variant_len = copyTrunc(pack_meta_variant_buf[0..], defaults_variant);
    pack_meta_profile_len = copyTrunc(pack_meta_profile_buf[0..], defaults_profile);
    pack_meta_requires_multi_window = requires_multi_window;
    pack_meta_requires_custom_shaders = requires_custom_shaders;
}

pub fn getPackMeta() ?PackMeta {
    if (!pack_meta_set) return null;
    return .{
        .id = pack_meta_id_buf[0..pack_meta_id_len],
        .name = pack_meta_name_buf[0..pack_meta_name_len],
        .author = pack_meta_author_buf[0..pack_meta_author_len],
        .license = pack_meta_license_buf[0..pack_meta_license_len],
        .defaults_variant = pack_meta_variant_buf[0..pack_meta_variant_len],
        .defaults_profile = pack_meta_profile_buf[0..pack_meta_profile_len],
        .requires_multi_window = pack_meta_requires_multi_window,
        .requires_custom_shaders = pack_meta_requires_custom_shaders,
    };
}

pub fn setPackStatus(kind: PackStatusKind, msg: []const u8) void {
    pack_status_kind = kind;
    const n = @min(msg.len, pack_status_buf.len);
    if (n > 0) @memcpy(pack_status_buf[0..n], msg[0..n]);
    pack_status_len = n;
}

pub fn clearPackStatus() void {
    pack_status_kind = .none;
    pack_status_len = 0;
}

pub fn getPackStatus() struct { kind: PackStatusKind, msg: []const u8 } {
    return .{
        .kind = pack_status_kind,
        .msg = pack_status_buf[0..pack_status_len],
    };
}

fn profileIndex(id: ProfileId) usize {
    return switch (id) {
        .desktop => 0,
        .phone => 1,
        .tablet => 2,
        .fullscreen => 3,
    };
}

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
    const p = path orelse {
        active_pack_root_storage.clearRetainingCapacity();
        active_pack_root = null;
        return;
    };
    if (p.len == 0) {
        active_pack_root_storage.clearRetainingCapacity();
        active_pack_root = null;
        return;
    }

    if (active_pack_root) |cur| {
        if (std.mem.eql(u8, cur, p)) return;
    }

    active_pack_root_storage.resize(std.heap.page_allocator, p.len) catch {
        active_pack_root_storage.clearRetainingCapacity();
        active_pack_root = null;
        return;
    };
    @memcpy(active_pack_root_storage.items[0..p.len], p);
    active_pack_root = active_pack_root_storage.items[0..p.len];
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

pub fn clearWorkspaceLayouts() void {
    active_workspace_layouts_set = .{ false, false, false, false };
    active_workspace_layouts = .{ .{}, .{}, .{}, .{} };
}

pub fn setWorkspaceLayout(id: ProfileId, preset: WorkspaceLayoutPreset) void {
    const idx = profileIndex(id);
    active_workspace_layouts[idx] = preset;
    active_workspace_layouts_set[idx] = true;
}

pub fn getWorkspaceLayout(id: ProfileId) ?WorkspaceLayoutPreset {
    const idx = profileIndex(id);
    if (!active_workspace_layouts_set[idx]) return null;
    return active_workspace_layouts[idx];
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

pub fn setPackModeLockToDefault(v: bool) void {
    pack_lock_mode_to_default = v;
}

pub fn getPackModeLockToDefault() bool {
    return pack_lock_mode_to_default;
}

pub fn clearPackDefaults() void {
    pack_default_mode = null;
    pack_default_profile = null;
    pack_lock_mode_to_default = false;
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
