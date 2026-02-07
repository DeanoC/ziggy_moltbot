const std = @import("std");
const builtin = @import("builtin");

const theme_mod = @import("../theme.zig");
const theme_tokens = @import("../theme/theme.zig");

const profile = @import("profile.zig");
const schema = @import("schema.zig");
const theme_package = @import("theme_package.zig");
const style_sheet = @import("style_sheet.zig");
pub const runtime = @import("runtime.zig");

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
    active_pack_path: ?[]u8 = null,
    active_pack_root: ?[]u8 = null,

    active_profile: Profile = profile.defaultsFor(.desktop, profile.PlatformCaps.defaultForTarget()),
    styles: style_sheet.StyleSheetStore,

    pub fn init(allocator: std.mem.Allocator, caps: PlatformCaps) ThemeEngine {
        return .{
            .allocator = allocator,
            .caps = caps,
            .active_profile = profile.defaultsFor(.desktop, caps),
            .styles = style_sheet.StyleSheetStore.initEmpty(allocator),
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
        if (self.active_pack_path) |p| {
            self.allocator.free(p);
        }
        self.active_pack_path = null;
        if (self.active_pack_root) |p| {
            self.allocator.free(p);
        }
        self.active_pack_root = null;
        self.styles.deinit();
        runtime.setStyleSheets(.{}, .{});
        runtime.setThemePackRootPath(null);
        runtime.setProfile(profile.defaultsFor(.desktop, self.caps));
    }

    pub fn clearThemePack(self: *ThemeEngine) void {
        theme_mod.setRuntimeTheme(.light, null);
        theme_mod.setRuntimeTheme(.dark, null);
        if (self.runtime_light) |ptr| freeTheme(self.allocator, ptr);
        if (self.runtime_dark) |ptr| freeTheme(self.allocator, ptr);
        self.runtime_light = null;
        self.runtime_dark = null;
        if (self.active_pack_path) |p| self.allocator.free(p);
        self.active_pack_path = null;
        if (self.active_pack_root) |p| self.allocator.free(p);
        self.active_pack_root = null;
        self.styles.deinit();
        self.styles = style_sheet.StyleSheetStore.initEmpty(self.allocator);
        runtime.setStyleSheets(.{}, .{});
        runtime.setThemePackRootPath(null);
    }

    pub fn setProfile(self: *ThemeEngine, p: Profile) void {
        self.active_profile = p;
        runtime.setProfile(p);
    }

    pub fn resolveProfileFromConfig(
        self: *ThemeEngine,
        framebuffer_width: u32,
        framebuffer_height: u32,
        cfg_profile_label: ?[]const u8,
    ) void {
        const requested = profile.profileFromLabel(cfg_profile_label);
        self.active_profile = profile.resolveProfile(self.caps, framebuffer_width, framebuffer_height, requested);
        runtime.setProfile(self.active_profile);
    }

    pub fn loadAndApplyThemePackDir(self: *ThemeEngine, root_path: []const u8) !void {
        var pack = try theme_package.loadFromDirectory(self.allocator, root_path);
        defer pack.deinit();

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

        // Load style sheet raw JSON once (optional) and resolve per mode so light/dark
        // overrides don't accidentally render dark surfaces in light mode.
        self.styles.deinit();
        self.styles = try style_sheet.loadRawFromDirectoryMaybe(self.allocator, pack.root_path);
        if (self.styles.raw_json.len > 0) {
            const ss_light = try style_sheet.parseResolved(self.allocator, self.styles.raw_json, light_theme);
            const ss_dark = try style_sheet.parseResolved(self.allocator, self.styles.raw_json, dark_theme);
            runtime.setStyleSheets(ss_light, ss_dark);
        } else {
            runtime.setStyleSheets(.{}, .{});
        }

        // Swap in new themes.
        theme_mod.setRuntimeTheme(.light, light_theme);
        theme_mod.setRuntimeTheme(.dark, dark_theme);

        // Record root path for asset resolution (e.g. frame images).
        if (self.active_pack_root) |p| self.allocator.free(p);
        var root_for_assets: []const u8 = pack.root_path;
        var abs_tmp: ?[]u8 = null;
        defer if (abs_tmp) |buf| self.allocator.free(buf);
        if (!std.fs.path.isAbsolute(root_for_assets) and builtin.target.os.tag != .emscripten and builtin.target.os.tag != .wasi) {
            if (try resolveRelativeToExeDir(self.allocator, root_for_assets)) |abs| {
                abs_tmp = abs;
                root_for_assets = abs_tmp.?;
            }
        }
        self.active_pack_root = try self.allocator.dupe(u8, root_for_assets);
        runtime.setThemePackRootPath(self.active_pack_root);

        // Replace owned themes.
        if (self.runtime_light) |prev| freeTheme(self.allocator, prev);
        if (self.runtime_dark) |prev| freeTheme(self.allocator, prev);
        self.runtime_light = light_theme;
        self.runtime_dark = dark_theme;

        // base_theme was only a builder input; no longer needed.
        freeTheme(self.allocator, base_theme);
    }

    /// Applies a theme pack from a directory path, tracking the currently applied pack.
    /// - `pack_path`: `null` or empty clears the theme pack and returns to built-in theme.
    /// - When `force_reload` is false, re-applying the same path is a no-op.
    pub fn applyThemePackDirFromPath(
        self: *ThemeEngine,
        pack_path: ?[]const u8,
        force_reload: bool,
    ) !void {
        const path = pack_path orelse "";
        if (path.len == 0) {
            self.clearThemePack();
            return;
        }
        if (!force_reload) {
            if (self.active_pack_path) |p| {
                if (std.mem.eql(u8, p, path)) return;
            }
        }

        // Only update `active_pack_path` on success so a transient bad reload doesn't
        // "stick" and prevent the user from reloading after fixing files.
        var candidates = ThemePackCandidates.init(self.allocator, path);
        defer candidates.deinit();
        try candidates.populate();

        var last_err: anyerror = error.MissingFile;
        for (candidates.items()) |cand| {
            self.loadAndApplyThemePackDir(cand) catch |err| {
                last_err = err;
                // Missing file: keep trying fallbacks. Anything else: stop.
                if (err == error.MissingFile) continue;
                return err;
            };
            // Success.
            if (self.active_pack_path) |p| self.allocator.free(p);
            self.active_pack_path = try self.allocator.dupe(u8, path);
            return;
        }
        return last_err;
    }
};

const ThemePackCandidates = struct {
    allocator: std.mem.Allocator,
    raw_path: []const u8,
    list: std.ArrayList([]const u8),
    owned: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator, raw_path: []const u8) ThemePackCandidates {
        return .{
            .allocator = allocator,
            .raw_path = raw_path,
            .list = std.ArrayList([]const u8).empty,
            .owned = std.ArrayList([]u8).empty,
        };
    }

    fn deinit(self: *ThemePackCandidates) void {
        for (self.owned.items) |buf| self.allocator.free(buf);
        self.owned.deinit(self.allocator);
        self.list.deinit(self.allocator);
        self.* = undefined;
    }

    fn items(self: *const ThemePackCandidates) []const []const u8 {
        return self.list.items;
    }

    fn populate(self: *ThemePackCandidates) !void {
        // Always try raw as-is first.
        try self.list.append(self.allocator, self.raw_path);

        if (self.raw_path.len == 0) return;
        if (std.fs.path.isAbsolute(self.raw_path)) return;

        // WASM/WASI builds: theme packs are unsupported anyway, and selfExePath is not
        // available (or meaningful).
        if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) return;

        if (try resolveRelativeToExeDir(self.allocator, self.raw_path)) |cand| {
            try self.owned.append(self.allocator, cand);
            try self.list.append(self.allocator, cand);
        }

        // Back-compat: older configs used the repo-relative docs path. In production builds
        // we install example packs alongside the executable at `themes/<id>`.
        const docs_prefix = "docs/theme_engine/examples/";
        if (std.mem.startsWith(u8, self.raw_path, docs_prefix)) {
            const suffix = self.raw_path[docs_prefix.len..];
            if (suffix.len > 0) {
                const rel_themes = try std.fs.path.join(self.allocator, &.{ "themes", suffix });
                try self.owned.append(self.allocator, rel_themes);
                try self.list.append(self.allocator, rel_themes);

                if (try resolveRelativeToExeDir(self.allocator, rel_themes)) |abs_themes| {
                    try self.owned.append(self.allocator, abs_themes);
                    try self.list.append(self.allocator, abs_themes);
                }
            }
        }
    }
};

fn resolveRelativeToExeDir(allocator: std.mem.Allocator, rel: []const u8) !?[]u8 {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    return std.fs.path.join(allocator, &.{ exe_dir, rel }) catch null;
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
