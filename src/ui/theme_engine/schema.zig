const std = @import("std");

pub const SchemaError = error{
    InvalidSchemaVersion,
    MissingRequiredField,
};

pub const Manifest = struct {
    schema_version: u32 = 1,
    id: []const u8,
    name: []const u8 = "",
    author: []const u8 = "",
    license: []const u8 = "",
    defaults: Defaults = .{},
    capabilities: Capabilities = .{},

    pub const Defaults = struct {
        variant: []const u8 = "dark",
        // If true, the theme pack opts out of user light/dark switching and forces
        // `variant` as the active mode while the pack is selected.
        lock_variant: bool = false,
        profile: []const u8 = "desktop",
        image_sampling: []const u8 = "linear",
        pixel_snap_textured: bool = false,
    };

    pub const Capabilities = struct {
        requires_multi_window: bool = false,
        requires_custom_shaders: bool = false,
    };
};

/// Optional `windows.json` provides desktop multi-window templates (Winamp-style).
///
/// This file is intentionally small and UI-focused:
/// - "panels" lists which core panels should be opened in the new window
///   (e.g. ["workspace", "chat", "showcase"]).
/// - "profile" can force a specific profile for that window ("desktop"/"phone"/...).
pub const WindowTemplate = struct {
    id: []const u8,
    title: []const u8 = "",
    width: u32 = 960,
    height: u32 = 720,
    /// Optional UI chrome role: "main_workspace" | "detached_panel" | "template_utility".
    chrome_mode: ?[]const u8 = null,
    /// Optional menu profile: "full" | "compact" | "minimal".
    menu_profile: ?[]const u8 = null,
    /// Optional menu bar visibility override for this window template.
    show_menu_bar: ?bool = null,
    /// Optional status bar visibility override for this window template.
    show_status_bar: ?bool = null,
    profile: ?[]const u8 = null,
    /// Optional theme variant ("light"/"dark") applied to this window only.
    variant: ?[]const u8 = null,
    image_sampling: ?[]const u8 = null,
    pixel_snap_textured: ?bool = null,
    panels: ?[]const []const u8 = null,
    focused_panel: ?[]const u8 = null,
};

pub const WindowsFile = struct {
    schema_version: u32 = 1,
    windows: []WindowTemplate = &[_]WindowTemplate{},
};

/// Optional `layouts/workspace.json` provides per-profile workspace layout defaults.
/// These are used to open/focus panels (and optionally close others) when a profile becomes active.
pub const WorkspaceLayout = struct {
    open_panels: ?[]const []const u8 = null,
    focused_panel: ?[]const u8 = null,
    close_others: bool = false,
    custom_layout: ?WorkspaceCustomLayout = null,
};

pub const WorkspaceCustomLayout = struct {
    left_ratio: ?f32 = null,
    min_left_width: ?f32 = null,
    min_right_width: ?f32 = null,
};

pub const WorkspaceLayoutsFile = struct {
    schema_version: u32 = 1,
    desktop: ?WorkspaceLayout = null,
    phone: ?WorkspaceLayout = null,
    tablet: ?WorkspaceLayout = null,
    fullscreen: ?WorkspaceLayout = null,
};

pub const Shadow = struct {
    blur: f32,
    spread: f32,
    offset_x: f32,
    offset_y: f32,
};

pub const Shadows = struct {
    sm: Shadow,
    md: Shadow,
    lg: Shadow,
};

pub const Colors = struct {
    background: [4]f32,
    surface: [4]f32,
    primary: [4]f32,
    success: [4]f32,
    danger: [4]f32,
    warning: [4]f32,
    text_primary: [4]f32,
    text_secondary: [4]f32,
    border: [4]f32,
    divider: [4]f32,
};

pub const ColorsOverride = struct {
    background: ?[4]f32 = null,
    surface: ?[4]f32 = null,
    primary: ?[4]f32 = null,
    success: ?[4]f32 = null,
    danger: ?[4]f32 = null,
    warning: ?[4]f32 = null,
    text_primary: ?[4]f32 = null,
    text_secondary: ?[4]f32 = null,
    border: ?[4]f32 = null,
    divider: ?[4]f32 = null,
};

pub const Typography = struct {
    font_family: []const u8 = "Space Grotesk",
    title_size: f32 = 22.0,
    heading_size: f32 = 18.0,
    body_size: f32 = 16.0,
    caption_size: f32 = 12.0,
};

pub const TypographyOverride = struct {
    font_family: ?[]const u8 = null,
    title_size: ?f32 = null,
    heading_size: ?f32 = null,
    body_size: ?f32 = null,
    caption_size: ?f32 = null,
};

pub const Spacing = struct {
    xs: f32 = 4.0,
    sm: f32 = 8.0,
    md: f32 = 16.0,
    lg: f32 = 24.0,
    xl: f32 = 32.0,
};

pub const SpacingOverride = struct {
    xs: ?f32 = null,
    sm: ?f32 = null,
    md: ?f32 = null,
    lg: ?f32 = null,
    xl: ?f32 = null,
};

pub const Radius = struct {
    sm: f32 = 4.0,
    md: f32 = 8.0,
    lg: f32 = 12.0,
    full: f32 = 9999.0,
};

pub const RadiusOverride = struct {
    sm: ?f32 = null,
    md: ?f32 = null,
    lg: ?f32 = null,
    full: ?f32 = null,
};

pub const TokensFile = struct {
    colors: Colors,
    typography: Typography = .{},
    spacing: Spacing = .{},
    radius: Radius = .{},
    shadows: Shadows = .{
        .sm = .{ .blur = 2.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 1.0 },
        .md = .{ .blur = 4.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 2.0 },
        .lg = .{ .blur = 8.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 4.0 },
    },
};

pub const ShadowOverride = struct {
    blur: ?f32 = null,
    spread: ?f32 = null,
    offset_x: ?f32 = null,
    offset_y: ?f32 = null,
};

pub const ShadowsOverride = struct {
    sm: ?ShadowOverride = null,
    md: ?ShadowOverride = null,
    lg: ?ShadowOverride = null,
};

/// Variant token files like `tokens/light.json` / `tokens/dark.json` can be partial.
/// They are merged on top of `tokens/base.json`.
pub const TokensOverrideFile = struct {
    colors: ?ColorsOverride = null,
    typography: ?TypographyOverride = null,
    spacing: ?SpacingOverride = null,
    radius: ?RadiusOverride = null,
    shadows: ?ShadowsOverride = null,
};

pub fn mergeTokens(
    allocator: std.mem.Allocator,
    base: TokensFile,
    override: TokensOverrideFile,
) !TokensFile {
    var out = base;

    if (override.colors) |c| {
        if (c.background) |v| out.colors.background = v;
        if (c.surface) |v| out.colors.surface = v;
        if (c.primary) |v| out.colors.primary = v;
        if (c.success) |v| out.colors.success = v;
        if (c.danger) |v| out.colors.danger = v;
        if (c.warning) |v| out.colors.warning = v;
        if (c.text_primary) |v| out.colors.text_primary = v;
        if (c.text_secondary) |v| out.colors.text_secondary = v;
        if (c.border) |v| out.colors.border = v;
        if (c.divider) |v| out.colors.divider = v;
    }

    if (override.typography) |t| {
        if (t.title_size) |v| out.typography.title_size = v;
        if (t.heading_size) |v| out.typography.heading_size = v;
        if (t.body_size) |v| out.typography.body_size = v;
        if (t.caption_size) |v| out.typography.caption_size = v;
        // font_family handled below (needs ownership).
    }

    if (override.spacing) |s| {
        if (s.xs) |v| out.spacing.xs = v;
        if (s.sm) |v| out.spacing.sm = v;
        if (s.md) |v| out.spacing.md = v;
        if (s.lg) |v| out.spacing.lg = v;
        if (s.xl) |v| out.spacing.xl = v;
    }

    if (override.radius) |r| {
        if (r.sm) |v| out.radius.sm = v;
        if (r.md) |v| out.radius.md = v;
        if (r.lg) |v| out.radius.lg = v;
        if (r.full) |v| out.radius.full = v;
    }

    if (override.shadows) |s| {
        if (s.sm) |sh| {
            if (sh.blur) |v| out.shadows.sm.blur = v;
            if (sh.spread) |v| out.shadows.sm.spread = v;
            if (sh.offset_x) |v| out.shadows.sm.offset_x = v;
            if (sh.offset_y) |v| out.shadows.sm.offset_y = v;
        }
        if (s.md) |sh| {
            if (sh.blur) |v| out.shadows.md.blur = v;
            if (sh.spread) |v| out.shadows.md.spread = v;
            if (sh.offset_x) |v| out.shadows.md.offset_x = v;
            if (sh.offset_y) |v| out.shadows.md.offset_y = v;
        }
        if (s.lg) |sh| {
            if (sh.blur) |v| out.shadows.lg.blur = v;
            if (sh.spread) |v| out.shadows.lg.spread = v;
            if (sh.offset_x) |v| out.shadows.lg.offset_x = v;
            if (sh.offset_y) |v| out.shadows.lg.offset_y = v;
        }
    }

    const desired_font = if (override.typography) |t| (t.font_family orelse base.typography.font_family) else base.typography.font_family;
    out.typography.font_family = try allocator.dupe(u8, desired_font);
    return out;
}

pub fn parseJson(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{ .ignore_unknown_fields = true });
}

// -----------------------------------------------------------------------------
// Profile overrides (`profiles/*.json`)
// -----------------------------------------------------------------------------

pub const ProfileOverridesComponents = struct {
    // Applies to the resolved profile's `hit_target_min_px`.
    hit_target_min_px: ?f32 = null,

    // Optional nested component scopes (kept small; expand as needed).
    button: ?ProfileOverridesButton = null,
};

pub const ProfileOverridesButton = struct {
    hit_target_min_px: ?f32 = null,
};

pub const ProfileOverrides = struct {
    // Profile-level tuning.
    ui_scale: ?f32 = null,
    hit_target_min_px: ?f32 = null,

    // Token overrides (same shape as TokensOverrideFile).
    colors: ?ColorsOverride = null,
    typography: ?TypographyOverride = null,
    spacing: ?SpacingOverride = null,
    radius: ?RadiusOverride = null,
    shadows: ?ShadowsOverride = null,

    // Component knobs (mapped onto Profile fields for now).
    components: ?ProfileOverridesComponents = null,
};

pub const ProfileOverridesFile = struct {
    // Optional metadata; ignored by loader besides validation/debug.
    profile: ?[]const u8 = null,

    // Back-compat: allow overrides at the root (as used by zsc_showcase).
    ui_scale: ?f32 = null,
    hit_target_min_px: ?f32 = null,

    // Preferred structure (as described in docs).
    overrides: ?ProfileOverrides = null,
};
