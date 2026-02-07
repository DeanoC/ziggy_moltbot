const std = @import("std");

const theme_mod = @import("../theme.zig");
const theme_tokens = @import("../theme/theme.zig");

const profile = @import("profile.zig");
const schema = @import("schema.zig");
const theme_package = @import("theme_package.zig");
const style_sheet = @import("style_sheet.zig");

pub const PlatformCaps = profile.PlatformCaps;
pub const ProfileId = profile.ProfileId;
pub const Profile = profile.Profile;

pub const ThemeContext = struct {
    profile: Profile,
    // Tokens are the existing `Theme` struct used throughout the UI.
    tokens: *const theme_tokens.Theme,
    styles: style_sheet.StyleSheet,
};

pub const EngineError = error{
    ThemePackLoadFailed,
} || theme_package.LoadError || std.mem.Allocator.Error;

pub const ThemeEngine = struct {
    allocator: std.mem.Allocator,
    caps: PlatformCaps,

    // Owned runtime themes (stable pointers handed to `ui/theme.zig`).
    runtime_light: ?*theme_tokens.Theme = null,
    runtime_dark: ?*theme_tokens.Theme = null,

    active_profile: Profile = profile.defaultsFor(.desktop, profile.PlatformCaps.defaultForTarget()),
    styles: style_sheet.StyleSheet,

    pub fn init(allocator: std.mem.Allocator, caps: PlatformCaps) ThemeEngine {
        return .{
            .allocator = allocator,
            .caps = caps,
            .active_profile = profile.defaultsFor(.desktop, caps),
            .styles = style_sheet.StyleSheet.initEmpty(allocator),
        };
    }

    pub fn deinit(self: *ThemeEngine) void {
        // Detach from global theme before freeing memory to avoid dangling pointers.
        theme_mod.setRuntimeTheme(.light, null);
        theme_mod.setRuntimeTheme(.dark, null);

        if (self.runtime_light) |ptr| {
            freeTheme(self.allocator, ptr);
        }
        if (self.runtime_dark) |ptr| {
            freeTheme(self.allocator, ptr);
        }
        self.runtime_light = null;
        self.runtime_dark = null;
        self.styles.deinit();
    }

    pub fn setProfile(self: *ThemeEngine, p: Profile) void {
        self.active_profile = p;
    }

    pub fn resolveProfileFromConfig(
        self: *ThemeEngine,
        framebuffer_width: u32,
        framebuffer_height: u32,
        cfg_profile_label: ?[]const u8,
    ) void {
        const requested = profile.profileFromLabel(cfg_profile_label);
        self.active_profile = profile.resolveProfile(self.caps, framebuffer_width, framebuffer_height, requested);
    }

    pub fn loadAndApplyThemePackDir(self: *ThemeEngine, root_path: []const u8) !void {
        var pack = try theme_package.loadFromDirectory(self.allocator, root_path);
        defer pack.deinit();

        // Load style sheet payload if present (kept as raw JSON for now).
        self.styles.deinit();
        self.styles = try loadStyleSheetMaybe(self.allocator, pack.root_path);

        const base_theme = try buildRuntimeTheme(self.allocator, pack.tokens_base);
        errdefer freeTheme(self.allocator, base_theme);

        const light_theme = if (pack.tokens_light) |tf|
            try buildRuntimeTheme(self.allocator, tf)
        else
            try cloneTheme(self.allocator, base_theme);
        errdefer freeTheme(self.allocator, light_theme);

        const dark_theme = if (pack.tokens_dark) |tf|
            try buildRuntimeTheme(self.allocator, tf)
        else
            try cloneTheme(self.allocator, base_theme);
        errdefer freeTheme(self.allocator, dark_theme);

        // Swap in new themes.
        theme_mod.setRuntimeTheme(.light, light_theme);
        theme_mod.setRuntimeTheme(.dark, dark_theme);

        // Replace owned themes.
        if (self.runtime_light) |prev| freeTheme(self.allocator, prev);
        if (self.runtime_dark) |prev| freeTheme(self.allocator, prev);
        self.runtime_light = light_theme;
        self.runtime_dark = dark_theme;

        // base_theme was only a builder input; no longer needed.
        freeTheme(self.allocator, base_theme);
    }
};

fn loadStyleSheetMaybe(allocator: std.mem.Allocator, root_path: []const u8) !style_sheet.StyleSheet {
    var dir = std.fs.cwd().openDir(root_path, .{}) catch {
        return style_sheet.StyleSheet.initEmpty(allocator);
    };
    defer dir.close();
    const f = dir.openFile("styles/components.json", .{}) catch {
        return style_sheet.StyleSheet.initEmpty(allocator);
    };
    defer f.close();
    const bytes = try f.readToEndAlloc(allocator, 512 * 1024);
    return .{ .allocator = allocator, .raw_json = bytes };
}

fn buildRuntimeTheme(allocator: std.mem.Allocator, tokens: schema.TokensFile) !*theme_tokens.Theme {
    const font_family = try allocator.dupe(u8, tokens.typography.font_family);
    errdefer allocator.free(font_family);

    const out = try allocator.create(theme_tokens.Theme);
    out.* = .{
        .colors = .{
            .background = tokens.colors.background,
            .surface = tokens.colors.surface,
            .primary = tokens.colors.primary,
            .success = tokens.colors.success,
            .danger = tokens.colors.danger,
            .warning = tokens.colors.warning,
            .text_primary = tokens.colors.text_primary,
            .text_secondary = tokens.colors.text_secondary,
            .border = tokens.colors.border,
            .divider = tokens.colors.divider,
        },
        .typography = .{
            .font_family = font_family,
            .title_size = tokens.typography.title_size,
            .heading_size = tokens.typography.heading_size,
            .body_size = tokens.typography.body_size,
            .caption_size = tokens.typography.caption_size,
        },
        .spacing = .{
            .xs = tokens.spacing.xs,
            .sm = tokens.spacing.sm,
            .md = tokens.spacing.md,
            .lg = tokens.spacing.lg,
            .xl = tokens.spacing.xl,
        },
        .radius = .{
            .sm = tokens.radius.sm,
            .md = tokens.radius.md,
            .lg = tokens.radius.lg,
            .full = tokens.radius.full,
        },
        .shadows = .{
            .sm = .{ .blur = tokens.shadows.sm.blur, .spread = tokens.shadows.sm.spread, .offset_x = tokens.shadows.sm.offset_x, .offset_y = tokens.shadows.sm.offset_y },
            .md = .{ .blur = tokens.shadows.md.blur, .spread = tokens.shadows.md.spread, .offset_x = tokens.shadows.md.offset_x, .offset_y = tokens.shadows.md.offset_y },
            .lg = .{ .blur = tokens.shadows.lg.blur, .spread = tokens.shadows.lg.spread, .offset_x = tokens.shadows.lg.offset_x, .offset_y = tokens.shadows.lg.offset_y },
        },
    };
    return out;
}

fn cloneTheme(allocator: std.mem.Allocator, src: *theme_tokens.Theme) !*theme_tokens.Theme {
    const dup = try allocator.create(theme_tokens.Theme);
    errdefer allocator.destroy(dup);
    dup.* = src.*;
    // Deep copy font family so each runtime theme can be freed independently.
    dup.typography.font_family = try allocator.dupe(u8, src.typography.font_family);
    return dup;
}

fn freeTheme(allocator: std.mem.Allocator, t: *theme_tokens.Theme) void {
    allocator.free(t.typography.font_family);
    allocator.destroy(t);
}
