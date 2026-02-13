const std = @import("std");
const builtin = @import("builtin");

const theme_mod = @import("../theme.zig");
const theme_tokens = @import("../theme/theme.zig");

const profile = @import("profile.zig");
pub const schema = @import("schema.zig");
const theme_package = @import("theme_package.zig");
const style_sheet = @import("style_sheet.zig");
const builtin_packs = @import("builtin_packs.zig");
pub const runtime = @import("runtime.zig");
const ui_commands = @import("../render/command_list.zig");
const wasm_fetch = @import("../../platform/wasm_fetch.zig");
const wasm_storage = if (builtin.target.os.tag == .emscripten)
    @import("../../platform/wasm_storage.zig")
else
    struct {
        pub fn get(_: std.mem.Allocator, _: [:0]const u8) !?[]u8 {
            return null;
        }
        pub fn set(_: std.mem.Allocator, _: [:0]const u8, _: []const u8) !void {}
    };

pub const PlatformCaps = profile.PlatformCaps;
pub const ProfileId = profile.ProfileId;
pub const Profile = profile.Profile;

fn profileIndexForId(id: ProfileId) usize {
    return switch (id) {
        .desktop => 0,
        .phone => 1,
        .tablet => 2,
        .fullscreen => 3,
    };
}

fn dupTokensFileAlloc(allocator: std.mem.Allocator, src: schema.TokensFile) !schema.TokensFile {
    var out = src;
    out.typography.font_family = try allocator.dupe(u8, src.typography.font_family);
    return out;
}

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
    pack_tokens_light: ?schema.TokensFile = null,
    pack_tokens_dark: ?schema.TokensFile = null,

    // Cached per-profile runtime themes and resolved stylesheets (to support theme-pack
    // profile overrides like `profiles/phone.json`).
    profile_themes_light: [4]?*theme_tokens.Theme = .{ null, null, null, null },
    profile_themes_dark: [4]?*theme_tokens.Theme = .{ null, null, null, null },
    base_styles_light: style_sheet.StyleSheet = .{},
    base_styles_dark: style_sheet.StyleSheet = .{},
    profile_styles_light: [4]style_sheet.StyleSheet = .{ .{}, .{}, .{}, .{} },
    profile_styles_dark: [4]style_sheet.StyleSheet = .{ .{}, .{}, .{}, .{} },
    profile_styles_cached: [4]bool = .{ false, false, false, false },

    profile_overrides: [4]StoredProfileOverride = .{ .{}, .{}, .{}, .{} },
    active_pack_path: ?[]u8 = null,
    active_pack_root: ?[]u8 = null,

    active_profile: Profile = profile.defaultsFor(.desktop, profile.PlatformCaps.defaultForTarget()),
    styles: style_sheet.StyleSheetStore,
    windows: ?[]schema.WindowTemplate = null,
    // Pack-owned copies of manifest metadata/defaults so cached packs can be re-activated
    // without re-reading JSON from disk.
    pack_meta_set: bool = false,
    pack_meta_id: ?[]u8 = null,
    pack_meta_name: ?[]u8 = null,
    pack_meta_author: ?[]u8 = null,
    pack_meta_license: ?[]u8 = null,
    pack_meta_defaults_variant: ?[]u8 = null,
    pack_meta_defaults_profile: ?[]u8 = null,
    pack_defaults_lock_variant: bool = false,
    pack_meta_requires_multi_window: bool = false,
    pack_meta_requires_custom_shaders: bool = false,
    render_defaults: runtime.RenderDefaults = .{},
    workspace_layouts: [4]runtime.WorkspaceLayoutPreset = .{ .{}, .{}, .{}, .{} },
    workspace_layouts_set: [4]bool = .{ false, false, false, false },

    // Cache of previously loaded packs (keyed by raw pack path). The currently-active pack
    // lives in the ThemeEngine fields above and is not stored in this map.
    pack_cache: std.StringHashMapUnmanaged(PackState) = .{},

    // Web (Emscripten) theme pack loading is async; we keep a single in-flight job.
    web_job: ?*WebPackJob = null,
    web_generation: u32 = 0,
    web_theme_changed: bool = false,

    const StoredProfileOverride = struct {
        ui_scale: ?f32 = null,
        hit_target_min_px: ?f32 = null,
        tokens: schema.TokensOverrideFile = .{},
        owned_font_family: ?[]u8 = null,

        fn deinit(self: *StoredProfileOverride, allocator: std.mem.Allocator) void {
            if (self.owned_font_family) |buf| allocator.free(buf);
            self.* = .{};
        }

        fn hasTokenOverrides(self: *const StoredProfileOverride) bool {
            if (self.tokens.colors != null) return true;
            if (self.tokens.typography != null) return true;
            if (self.tokens.spacing != null) return true;
            if (self.tokens.radius != null) return true;
            if (self.tokens.shadows != null) return true;
            return false;
        }
    };

    const PackState = struct {
        runtime_light: ?*theme_tokens.Theme = null,
        runtime_dark: ?*theme_tokens.Theme = null,
        pack_tokens_light: ?schema.TokensFile = null,
        pack_tokens_dark: ?schema.TokensFile = null,
        profile_themes_light: [4]?*theme_tokens.Theme = .{ null, null, null, null },
        profile_themes_dark: [4]?*theme_tokens.Theme = .{ null, null, null, null },
        base_styles_light: style_sheet.StyleSheet = .{},
        base_styles_dark: style_sheet.StyleSheet = .{},
        profile_styles_light: [4]style_sheet.StyleSheet = .{ .{}, .{}, .{}, .{} },
        profile_styles_dark: [4]style_sheet.StyleSheet = .{ .{}, .{}, .{}, .{} },
        profile_styles_cached: [4]bool = .{ false, false, false, false },
        profile_overrides: [4]StoredProfileOverride = .{ .{}, .{}, .{}, .{} },
        active_pack_root: ?[]u8 = null,
        styles: style_sheet.StyleSheetStore,
        windows: ?[]schema.WindowTemplate = null,
        pack_meta_set: bool = false,
        pack_meta_id: ?[]u8 = null,
        pack_meta_name: ?[]u8 = null,
        pack_meta_author: ?[]u8 = null,
        pack_meta_license: ?[]u8 = null,
        pack_meta_defaults_variant: ?[]u8 = null,
        pack_meta_defaults_profile: ?[]u8 = null,
        pack_defaults_lock_variant: bool = false,
        pack_meta_requires_multi_window: bool = false,
        pack_meta_requires_custom_shaders: bool = false,
        render_defaults: runtime.RenderDefaults = .{},
        workspace_layouts: [4]runtime.WorkspaceLayoutPreset = .{ .{}, .{}, .{}, .{} },
        workspace_layouts_set: [4]bool = .{ false, false, false, false },

        fn deinit(self: *PackState, allocator: std.mem.Allocator) void {
            if (self.runtime_light) |ptr| freeTheme(allocator, ptr);
            if (self.runtime_dark) |ptr| freeTheme(allocator, ptr);
            self.runtime_light = null;
            self.runtime_dark = null;
            if (self.pack_tokens_light) |*t| allocator.free(t.typography.font_family);
            if (self.pack_tokens_dark) |*t| allocator.free(t.typography.font_family);
            self.pack_tokens_light = null;
            self.pack_tokens_dark = null;

            // Per-profile caches and overrides.
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                if (self.profile_themes_light[i]) |ptr| {
                    if (self.runtime_light == null or ptr != self.runtime_light.?) freeTheme(allocator, ptr);
                }
                if (self.profile_themes_dark[i]) |ptr| {
                    if (self.runtime_dark == null or ptr != self.runtime_dark.?) freeTheme(allocator, ptr);
                }
                self.profile_themes_light[i] = null;
                self.profile_themes_dark[i] = null;
                self.profile_styles_cached[i] = false;
                self.profile_styles_light[i] = .{};
                self.profile_styles_dark[i] = .{};
                self.profile_overrides[i].deinit(allocator);
            }

            if (self.active_pack_root) |p| allocator.free(p);
            self.active_pack_root = null;
            self.styles.deinit();
            if (self.windows) |v| theme_package.freeWindowTemplates(allocator, v);
            self.windows = null;

            if (self.pack_meta_id) |v| allocator.free(v);
            if (self.pack_meta_name) |v| allocator.free(v);
            if (self.pack_meta_author) |v| allocator.free(v);
            if (self.pack_meta_license) |v| allocator.free(v);
            if (self.pack_meta_defaults_variant) |v| allocator.free(v);
            if (self.pack_meta_defaults_profile) |v| allocator.free(v);
            self.pack_meta_id = null;
            self.pack_meta_name = null;
            self.pack_meta_author = null;
            self.pack_meta_license = null;
            self.pack_meta_defaults_variant = null;
            self.pack_meta_defaults_profile = null;
            self.pack_meta_set = false;
            self.pack_defaults_lock_variant = false;
            self.pack_meta_requires_multi_window = false;
            self.pack_meta_requires_custom_shaders = false;

            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, caps: PlatformCaps) ThemeEngine {
        return .{
            .allocator = allocator,
            .caps = caps,
            .active_profile = profile.defaultsFor(.desktop, caps),
            .styles = style_sheet.StyleSheetStore.initEmpty(allocator),
            .windows = null,
        };
    }

    fn clearPackMetaOwned(self: *ThemeEngine) void {
        if (self.pack_meta_id) |v| self.allocator.free(v);
        if (self.pack_meta_name) |v| self.allocator.free(v);
        if (self.pack_meta_author) |v| self.allocator.free(v);
        if (self.pack_meta_license) |v| self.allocator.free(v);
        if (self.pack_meta_defaults_variant) |v| self.allocator.free(v);
        if (self.pack_meta_defaults_profile) |v| self.allocator.free(v);
        self.pack_meta_id = null;
        self.pack_meta_name = null;
        self.pack_meta_author = null;
        self.pack_meta_license = null;
        self.pack_meta_defaults_variant = null;
        self.pack_meta_defaults_profile = null;
        self.pack_meta_set = false;
        self.pack_meta_requires_multi_window = false;
        self.pack_meta_requires_custom_shaders = false;
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
        if (self.pack_tokens_light) |*t| self.allocator.free(t.typography.font_family);
        if (self.pack_tokens_dark) |*t| self.allocator.free(t.typography.font_family);
        self.pack_tokens_light = null;
        self.pack_tokens_dark = null;
        self.freeProfileCaches();
        if (self.active_pack_path) |p| {
            self.allocator.free(p);
        }
        self.active_pack_path = null;
        if (self.active_pack_root) |p| {
            self.allocator.free(p);
        }
        self.active_pack_root = null;
        if (self.web_job) |job| {
            job.deinit();
            self.web_job = null;
        }
        if (self.windows) |v| theme_package.freeWindowTemplates(self.allocator, v);
        self.windows = null;
        self.clearPackMetaOwned();
        self.render_defaults = .{};
        self.workspace_layouts_set = .{ false, false, false, false };
        self.styles.deinit();
        {
            var it = self.pack_cache.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
                const k = entry.key_ptr.*;
                self.allocator.free(@constCast(k));
            }
            self.pack_cache.deinit(self.allocator);
            self.pack_cache = .{};
        }
        runtime.setStyleSheets(.{}, .{});
        runtime.setThemePackRootPath(null);
        runtime.setWindowTemplates(&[_]schema.WindowTemplate{});
        runtime.clearWorkspaceLayouts();
        runtime.setRenderDefaults(.{});
        runtime.clearPackDefaults();
        runtime.clearPackMeta();
        runtime.setProfile(profile.defaultsFor(.desktop, self.caps));
    }

    pub fn clearThemePack(self: *ThemeEngine) void {
        theme_mod.setRuntimeTheme(.light, null);
        theme_mod.setRuntimeTheme(.dark, null);
        if (self.runtime_light) |ptr| freeTheme(self.allocator, ptr);
        if (self.runtime_dark) |ptr| freeTheme(self.allocator, ptr);
        self.runtime_light = null;
        self.runtime_dark = null;
        if (self.pack_tokens_light) |*t| self.allocator.free(t.typography.font_family);
        if (self.pack_tokens_dark) |*t| self.allocator.free(t.typography.font_family);
        self.pack_tokens_light = null;
        self.pack_tokens_dark = null;
        self.freeProfileCaches();
        if (self.active_pack_path) |p| self.allocator.free(p);
        self.active_pack_path = null;
        if (self.active_pack_root) |p| self.allocator.free(p);
        self.active_pack_root = null;
        self.styles.deinit();
        self.styles = style_sheet.StyleSheetStore.initEmpty(self.allocator);
        if (self.windows) |v| theme_package.freeWindowTemplates(self.allocator, v);
        self.windows = null;
        self.clearPackMetaOwned();
        self.render_defaults = .{};
        self.workspace_layouts_set = .{ false, false, false, false };
        runtime.setStyleSheets(.{}, .{});
        runtime.setThemePackRootPath(null);
        runtime.setWindowTemplates(&[_]schema.WindowTemplate{});
        runtime.clearWorkspaceLayouts();
        runtime.setRenderDefaults(self.render_defaults);
        runtime.clearPackDefaults();
        runtime.clearPackMeta();
        runtime.setPackStatus(.ok, "Theme pack disabled");
    }

    pub fn takeWebThemeChanged(self: *ThemeEngine) bool {
        const v = self.web_theme_changed;
        self.web_theme_changed = false;
        return v;
    }

    /// Web (Emscripten) loader: fetches `manifest.json`, token files, and `styles/components.json`
    /// from the provided `pack_root` (URL or relative-to-origin path) and applies it when ready.
    /// This is async; failures are logged by the caller (if desired) via `takeWebThemeChanged`.
    pub fn requestThemePackWeb(self: *ThemeEngine, pack_root: ?[]const u8, force_reload: bool) void {
        if (builtin.target.os.tag != .emscripten) return;

        const raw = pack_root orelse "";
        if (raw.len == 0) {
            self.clearThemePack();
            runtime.setPackStatus(.ok, "Theme pack disabled");
            self.web_theme_changed = true;
            return;
        }

        if (!force_reload) {
            if (self.active_pack_path) |p| {
                if (std.mem.eql(u8, p, raw)) return;
            }
        }

        {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Fetching theme pack: {s}", .{raw}) catch "Fetching theme pack";
            runtime.setPackStatus(.fetching, msg);
        }

        self.web_generation +%= 1;
        const gen = self.web_generation;

        if (self.web_job) |job| {
            job.deinit();
            self.web_job = null;
        }

        const job = WebPackJob.init(self, gen, raw) catch return;
        self.web_job = job;
        job.start() catch {
            job.deinit();
            self.web_job = null;
        };
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
        var resolved = profile.resolveProfile(self.caps, framebuffer_width, framebuffer_height, requested);
        self.applyProfileOverride(&resolved);
        self.active_profile = resolved;
        runtime.setProfile(self.active_profile);
        self.applyPackForProfile(self.active_profile.id);
    }

    pub fn loadAndApplyThemePackDir(self: *ThemeEngine, root_path: []const u8) !void {
        var pack = try theme_package.loadFromPath(self.allocator, root_path);
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
            self.base_styles_light = ss_light;
            self.base_styles_dark = ss_dark;
        } else {
            runtime.setStyleSheets(.{}, .{});
            self.base_styles_light = .{};
            self.base_styles_dark = .{};
        }

        // Swap in new themes.
        theme_mod.setRuntimeTheme(.light, light_theme);
        theme_mod.setRuntimeTheme(.dark, dark_theme);

        // Record root path for asset resolution (e.g. frame images).
        if (self.active_pack_root) |p| self.allocator.free(p);
        var root_for_assets: []const u8 = pack.root_path;
        var abs_tmp: ?[]u8 = null;
        defer if (abs_tmp) |buf| self.allocator.free(buf);
        if (!std.fs.path.isAbsolute(root_for_assets) and builtin.target.os.tag != .emscripten and builtin.target.os.tag != .wasi and !builtin.target.abi.isAndroid()) {
            // Only attempt exe-dir resolution if the directory isn't already accessible
            // relative to CWD. (Also reduces reliance on selfExePath when running from
            // odd locations like UNC paths.)
            if (std.fs.cwd().access(root_for_assets, .{})) |_| {
                // ok, keep as-is
            } else |_| {
                if (try resolveRelativeToExeDir(self.allocator, root_for_assets)) |abs| {
                    abs_tmp = abs;
                    root_for_assets = abs_tmp.?;
                }
            }
        }
        self.active_pack_root = try self.allocator.dupe(u8, root_for_assets);
        runtime.setThemePackRootPath(self.active_pack_root);

        // Pack-wide defaults are used as runtime fallbacks when the user config doesn't
        // explicitly override mode/profile.
        self.clearPackMetaOwned();
        self.pack_meta_set = true;
        self.pack_meta_id = try self.allocator.dupe(u8, pack.manifest.id);
        self.pack_meta_name = try self.allocator.dupe(u8, pack.manifest.name);
        self.pack_meta_author = try self.allocator.dupe(u8, pack.manifest.author);
        self.pack_meta_license = try self.allocator.dupe(u8, pack.manifest.license);
        self.pack_meta_defaults_variant = try self.allocator.dupe(u8, pack.manifest.defaults.variant);
        self.pack_meta_defaults_profile = try self.allocator.dupe(u8, pack.manifest.defaults.profile);
        self.pack_meta_requires_multi_window = pack.manifest.capabilities.requires_multi_window;
        self.pack_meta_requires_custom_shaders = pack.manifest.capabilities.requires_custom_shaders;
        runtime.setPackDefaults(pack.manifest.defaults.variant, pack.manifest.defaults.profile);
        self.pack_defaults_lock_variant = pack.manifest.defaults.lock_variant;
        runtime.setPackModeLockToDefault(self.pack_defaults_lock_variant);
        runtime.setPackMeta(pack.manifest);

        // Pack-wide render defaults (used for "pixel" style packs).
        const defaults_sampling = if (std.ascii.eqlIgnoreCase(pack.manifest.defaults.image_sampling, "nearest"))
            ui_commands.ImageSampling.nearest
        else
            ui_commands.ImageSampling.linear;
        self.render_defaults = .{
            .image_sampling = defaults_sampling,
            .pixel_snap_textured = pack.manifest.defaults.pixel_snap_textured,
        };
        runtime.setRenderDefaults(self.render_defaults);

        // Adopt optional multi-window templates (ThemeEngine owns the memory).
        if (self.windows) |v| theme_package.freeWindowTemplates(self.allocator, v);
        self.windows = pack.windows;
        pack.windows = null;
        runtime.setWindowTemplates(self.windows orelse &[_]schema.WindowTemplate{});

        // Optional workspace layout presets.
        self.loadWorkspaceLayoutsFromDir(pack.root_path);

        // Replace owned themes.
        if (self.runtime_light) |prev| freeTheme(self.allocator, prev);
        if (self.runtime_dark) |prev| freeTheme(self.allocator, prev);
        self.runtime_light = light_theme;
        self.runtime_dark = dark_theme;

        if (self.pack_tokens_light) |*t| self.allocator.free(t.typography.font_family);
        if (self.pack_tokens_dark) |*t| self.allocator.free(t.typography.font_family);
        self.pack_tokens_light = try dupTokensFileAlloc(self.allocator, pack.tokens_light orelse pack.tokens_base);
        self.pack_tokens_dark = try dupTokensFileAlloc(self.allocator, pack.tokens_dark orelse pack.tokens_base);

        self.loadProfileOverridesFromDir(pack.root_path) catch {};
        self.clearProfileThemeCaches();

        // base_theme was only a builder input; no longer needed.
        freeTheme(self.allocator, base_theme);
    }

    fn applyCurrentPackToRuntimeBase(self: *ThemeEngine) void {
        // Apply the currently loaded pack state (already in ThemeEngine fields) to the global runtime.
        theme_mod.setRuntimeTheme(.light, self.runtime_light);
        theme_mod.setRuntimeTheme(.dark, self.runtime_dark);

        runtime.setThemePackRootPath(self.active_pack_root);
        runtime.setStyleSheets(self.base_styles_light, self.base_styles_dark);
        runtime.setWindowTemplates(self.windows orelse &[_]schema.WindowTemplate{});

        runtime.clearWorkspaceLayouts();
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (!self.workspace_layouts_set[i]) continue;
            const id: ProfileId = switch (i) {
                0 => .desktop,
                1 => .phone,
                2 => .tablet,
                else => .fullscreen,
            };
            runtime.setWorkspaceLayout(id, self.workspace_layouts[i]);
        }

        runtime.setRenderDefaults(self.render_defaults);
        if (self.pack_meta_set) {
            runtime.setPackDefaults(self.pack_meta_defaults_variant orelse "", self.pack_meta_defaults_profile orelse "");
            runtime.setPackModeLockToDefault(self.pack_defaults_lock_variant);
            runtime.setPackMetaFields(
                self.pack_meta_id orelse "",
                self.pack_meta_name orelse "",
                self.pack_meta_author orelse "",
                self.pack_meta_license orelse "",
                self.pack_meta_defaults_variant orelse "",
                self.pack_meta_defaults_profile orelse "",
                self.pack_meta_requires_multi_window,
                self.pack_meta_requires_custom_shaders,
            );
        } else {
            runtime.clearPackDefaults();
            runtime.setPackModeLockToDefault(false);
            runtime.clearPackMeta();
        }
    }

    fn takePackState(self: *ThemeEngine) PackState {
        const st: PackState = .{
            .runtime_light = self.runtime_light,
            .runtime_dark = self.runtime_dark,
            .pack_tokens_light = self.pack_tokens_light,
            .pack_tokens_dark = self.pack_tokens_dark,
            .profile_themes_light = self.profile_themes_light,
            .profile_themes_dark = self.profile_themes_dark,
            .base_styles_light = self.base_styles_light,
            .base_styles_dark = self.base_styles_dark,
            .profile_styles_light = self.profile_styles_light,
            .profile_styles_dark = self.profile_styles_dark,
            .profile_styles_cached = self.profile_styles_cached,
            .profile_overrides = self.profile_overrides,
            .active_pack_root = self.active_pack_root,
            .styles = self.styles,
            .windows = self.windows,
            .pack_meta_set = self.pack_meta_set,
            .pack_meta_id = self.pack_meta_id,
            .pack_meta_name = self.pack_meta_name,
            .pack_meta_author = self.pack_meta_author,
            .pack_meta_license = self.pack_meta_license,
            .pack_meta_defaults_variant = self.pack_meta_defaults_variant,
            .pack_meta_defaults_profile = self.pack_meta_defaults_profile,
            .pack_defaults_lock_variant = self.pack_defaults_lock_variant,
            .pack_meta_requires_multi_window = self.pack_meta_requires_multi_window,
            .pack_meta_requires_custom_shaders = self.pack_meta_requires_custom_shaders,
            .render_defaults = self.render_defaults,
            .workspace_layouts = self.workspace_layouts,
            .workspace_layouts_set = self.workspace_layouts_set,
        };

        self.runtime_light = null;
        self.runtime_dark = null;
        self.pack_tokens_light = null;
        self.pack_tokens_dark = null;
        self.profile_themes_light = .{ null, null, null, null };
        self.profile_themes_dark = .{ null, null, null, null };
        self.base_styles_light = .{};
        self.base_styles_dark = .{};
        self.profile_styles_light = .{ .{}, .{}, .{}, .{} };
        self.profile_styles_dark = .{ .{}, .{}, .{}, .{} };
        self.profile_styles_cached = .{ false, false, false, false };
        self.profile_overrides = .{ .{}, .{}, .{}, .{} };
        self.active_pack_root = null;
        self.styles = style_sheet.StyleSheetStore.initEmpty(self.allocator);
        self.windows = null;
        self.pack_meta_set = false;
        self.pack_meta_id = null;
        self.pack_meta_name = null;
        self.pack_meta_author = null;
        self.pack_meta_license = null;
        self.pack_meta_defaults_variant = null;
        self.pack_meta_defaults_profile = null;
        self.pack_defaults_lock_variant = false;
        self.pack_meta_requires_multi_window = false;
        self.pack_meta_requires_custom_shaders = false;
        self.render_defaults = .{};
        self.workspace_layouts_set = .{ false, false, false, false };

        return st;
    }

    fn restorePackState(self: *ThemeEngine, st: PackState) void {
        self.runtime_light = st.runtime_light;
        self.runtime_dark = st.runtime_dark;
        self.pack_tokens_light = st.pack_tokens_light;
        self.pack_tokens_dark = st.pack_tokens_dark;
        self.profile_themes_light = st.profile_themes_light;
        self.profile_themes_dark = st.profile_themes_dark;
        self.base_styles_light = st.base_styles_light;
        self.base_styles_dark = st.base_styles_dark;
        self.profile_styles_light = st.profile_styles_light;
        self.profile_styles_dark = st.profile_styles_dark;
        self.profile_styles_cached = st.profile_styles_cached;
        self.profile_overrides = st.profile_overrides;
        self.active_pack_root = st.active_pack_root;
        self.styles = st.styles;
        self.windows = st.windows;
        self.pack_meta_set = st.pack_meta_set;
        self.pack_meta_id = st.pack_meta_id;
        self.pack_meta_name = st.pack_meta_name;
        self.pack_meta_author = st.pack_meta_author;
        self.pack_meta_license = st.pack_meta_license;
        self.pack_meta_defaults_variant = st.pack_meta_defaults_variant;
        self.pack_meta_defaults_profile = st.pack_meta_defaults_profile;
        self.pack_defaults_lock_variant = st.pack_defaults_lock_variant;
        self.pack_meta_requires_multi_window = st.pack_meta_requires_multi_window;
        self.pack_meta_requires_custom_shaders = st.pack_meta_requires_custom_shaders;
        self.render_defaults = st.render_defaults;
        self.workspace_layouts = st.workspace_layouts;
        self.workspace_layouts_set = st.workspace_layouts_set;
    }

    fn cacheActivePack(self: *ThemeEngine) !void {
        const key = self.active_pack_path orelse return;
        const st = self.takePackState();
        // If an entry already exists for the same logical key, drop it to avoid leaking
        // the cached pack (can happen if a pack was loaded directly while still cached).
        if (self.pack_cache.fetchRemove(key)) |kv| {
            var v = kv.value;
            v.deinit(self.allocator);
            self.allocator.free(@constCast(kv.key));
        }
        // Transfer ownership of the key string to the cache.
        try self.pack_cache.put(self.allocator, key, st);
        self.active_pack_path = null;
    }

    fn activateBuiltinForRender(self: *ThemeEngine) void {
        _ = self;
        // Reset active pack state to "built-in theme" without touching the cache.
        theme_mod.setRuntimeTheme(.light, null);
        theme_mod.setRuntimeTheme(.dark, null);

        runtime.setStyleSheets(.{}, .{});
        runtime.setThemePackRootPath(null);
        runtime.setWindowTemplates(&[_]schema.WindowTemplate{});
        runtime.clearWorkspaceLayouts();
        runtime.setRenderDefaults(.{});
        runtime.clearPackDefaults();
        runtime.clearPackMeta();
    }

    /// Activate a theme pack for rendering (used by multi-window draws).
    /// This can switch between previously loaded packs without re-reading JSON each frame.
    pub fn activateThemePackForRender(self: *ThemeEngine, pack_path: ?[]const u8, force_reload: bool) !void {
        if (builtin.target.os.tag == .emscripten) {
            // Web builds don't support native multi-window; keep existing behavior.
            try self.applyThemePackDirFromPath(pack_path, force_reload);
            return;
        }

        const desired = pack_path orelse "";
        if (desired.len == 0) {
            if (self.active_pack_path != null) {
                try self.cacheActivePack();
            }
            self.activateBuiltinForRender();
            return;
        }

        if (!force_reload) {
            if (self.active_pack_path) |cur| {
                if (std.mem.eql(u8, cur, desired)) return;
            }
        }

        if (force_reload) {
            if (self.pack_cache.fetchRemove(desired)) |kv| {
                var v = kv.value;
                v.deinit(self.allocator);
                self.allocator.free(@constCast(kv.key));
            }
        }

        // If the desired pack is cached, restore it and apply runtime state.
        if (!force_reload) {
            if (self.pack_cache.fetchRemove(desired)) |kv| {
                if (self.active_pack_path != null) {
                    try self.cacheActivePack();
                }
                self.active_pack_path = @constCast(kv.key);
                self.restorePackState(kv.value);
                self.applyCurrentPackToRuntimeBase();
                return;
            }
        } else {
            if (self.active_pack_path != null) {
                // Cache current pack before reload switch, unless we're reloading in-place.
                if (self.active_pack_path) |cur| {
                    if (!std.mem.eql(u8, cur, desired)) {
                        try self.cacheActivePack();
                    }
                }
            }
        }

        // Fall back to loading from disk into the active engine state.
        if (self.active_pack_path != null) {
            if (self.active_pack_path) |cur| {
                if (!std.mem.eql(u8, cur, desired)) {
                    try self.cacheActivePack();
                }
            }
        }
        try self.applyThemePackDirFromPath(pack_path, force_reload);
    }

    /// Applies a theme pack from a directory path, tracking the currently applied pack.
    /// - `pack_path`: `null` or empty clears the theme pack and returns to built-in theme.
    /// - When `force_reload` is false, re-applying the same path is a no-op.
    pub fn applyThemePackDirFromPath(
        self: *ThemeEngine,
        pack_path: ?[]const u8,
        force_reload: bool,
    ) !void {
        if (builtin.target.os.tag == .emscripten) {
            // On web builds, theme packs are fetched over HTTP(S) and applied asynchronously.
            self.requestThemePackWeb(pack_path, force_reload);
            return;
        }
        const path = pack_path orelse "";
        if (path.len == 0) {
            self.clearThemePack();
            runtime.setPackStatus(.ok, "Theme pack disabled");
            return;
        }
        // If the user points at an embedded built-in theme under `themes/<id>`, ensure any
        // newly-added optional files (e.g. `windows.json`) are installed even when the
        // base pack already exists on disk.
        var effective_force_reload = force_reload;
        if (self.caps.supports_filesystem_write) {
            if (try builtin_packs.installIfBuiltinThemePathAlloc(self.allocator, path)) {
                effective_force_reload = true;
            }
        }

        if (!effective_force_reload) {
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
                {
                    var buf: [512]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Failed to load pack: {s} ({s})", .{ path, @errorName(err) }) catch "Failed to load pack";
                    runtime.setPackStatus(.failed, msg);
                }
                return err;
            };
            // Success.
            if (self.active_pack_path) |p| self.allocator.free(p);
            self.active_pack_path = try self.allocator.dupe(u8, path);
            {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Loaded theme pack: {s}", .{path}) catch "Loaded theme pack";
                runtime.setPackStatus(.ok, msg);
            }
            return;
        }
        // If the user asked for a built-in pack under `themes/<id>` and it isn't present,
        // attempt to install it into the writable filesystem (Android pref path, etc)
        // then retry once.
        if (last_err == error.MissingFile and self.caps.supports_filesystem_write) {
            if (try builtin_packs.installIfBuiltinThemePathAlloc(self.allocator, path)) {
                var retry = ThemePackCandidates.init(self.allocator, path);
                defer retry.deinit();
                try retry.populate();
                for (retry.items()) |cand| {
                    self.loadAndApplyThemePackDir(cand) catch |err| {
                        last_err = err;
                        if (err == error.MissingFile) continue;
                        {
                            var buf: [512]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "Failed to load pack: {s} ({s})", .{ path, @errorName(err) }) catch "Failed to load pack";
                            runtime.setPackStatus(.failed, msg);
                        }
                        return err;
                    };
                    if (self.active_pack_path) |p| self.allocator.free(p);
                    self.active_pack_path = try self.allocator.dupe(u8, path);
                    {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "Loaded theme pack: {s}", .{path}) catch "Loaded theme pack";
                        runtime.setPackStatus(.ok, msg);
                    }
                    return;
                }
            }
        }
        {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to load pack: {s} ({s})", .{ path, @errorName(last_err) }) catch "Failed to load pack";
            runtime.setPackStatus(.failed, msg);
        }
        return last_err;
    }

    fn freeProfileCaches(self: *ThemeEngine) void {
        self.clearProfileThemeCaches();
        var i: usize = 0;
        while (i < self.profile_overrides.len) : (i += 1) {
            self.profile_overrides[i].deinit(self.allocator);
        }
    }

    fn clearProfileThemeCaches(self: *ThemeEngine) void {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (self.profile_themes_light[i]) |ptr| {
                if (self.runtime_light == null or ptr != self.runtime_light.?) freeTheme(self.allocator, ptr);
            }
            if (self.profile_themes_dark[i]) |ptr| {
                if (self.runtime_dark == null or ptr != self.runtime_dark.?) freeTheme(self.allocator, ptr);
            }
            self.profile_themes_light[i] = null;
            self.profile_themes_dark[i] = null;
            self.profile_styles_cached[i] = false;
            self.profile_styles_light[i] = .{};
            self.profile_styles_dark[i] = .{};
        }
    }

    fn applyProfileOverride(self: *ThemeEngine, p: *Profile) void {
        const idx = profileIndexForId(p.id);
        const ov = &self.profile_overrides[idx];
        if (ov.ui_scale) |v| p.ui_scale = v;
        if (ov.hit_target_min_px) |v| p.hit_target_min_px = v;
    }

    fn applyPackForProfile(self: *ThemeEngine, id: ProfileId) void {
        if (self.runtime_light == null or self.runtime_dark == null) return;
        const idx = profileIndexForId(id);
        const ov = &self.profile_overrides[idx];

        if (!ov.hasTokenOverrides()) {
            theme_mod.setRuntimeTheme(.light, self.runtime_light);
            theme_mod.setRuntimeTheme(.dark, self.runtime_dark);
            runtime.setStyleSheets(self.base_styles_light, self.base_styles_dark);
            return;
        }

        if (self.profile_themes_light[idx] == null or self.profile_themes_dark[idx] == null) {
            const ltoks = self.pack_tokens_light orelse return;
            const dtoks = self.pack_tokens_dark orelse return;

            const merged_light = schema.mergeTokens(self.allocator, ltoks, ov.tokens) catch ltoks;
            const merged_dark = schema.mergeTokens(self.allocator, dtoks, ov.tokens) catch dtoks;

            const light_font = merged_light.typography.font_family;
            const dark_font = merged_dark.typography.font_family;
            const light_needs_free = (merged_light.typography.font_family.ptr != ltoks.typography.font_family.ptr);
            const dark_needs_free = (merged_dark.typography.font_family.ptr != dtoks.typography.font_family.ptr);

            const light_theme = buildRuntimeTheme(self.allocator, merged_light) catch null;
            const dark_theme = buildRuntimeTheme(self.allocator, merged_dark) catch null;

            if (light_needs_free) self.allocator.free(light_font);
            if (dark_needs_free) self.allocator.free(dark_font);

            if (light_theme) |ptr| self.profile_themes_light[idx] = ptr;
            if (dark_theme) |ptr| self.profile_themes_dark[idx] = ptr;

            if (self.styles.raw_json.len > 0 and light_theme != null and dark_theme != null) {
                self.profile_styles_light[idx] = style_sheet.parseResolved(self.allocator, self.styles.raw_json, self.profile_themes_light[idx].?) catch self.base_styles_light;
                self.profile_styles_dark[idx] = style_sheet.parseResolved(self.allocator, self.styles.raw_json, self.profile_themes_dark[idx].?) catch self.base_styles_dark;
                self.profile_styles_cached[idx] = true;
            }
        }

        theme_mod.setRuntimeTheme(.light, self.profile_themes_light[idx] orelse self.runtime_light);
        theme_mod.setRuntimeTheme(.dark, self.profile_themes_dark[idx] orelse self.runtime_dark);
        if (self.profile_styles_cached[idx]) {
            runtime.setStyleSheets(self.profile_styles_light[idx], self.profile_styles_dark[idx]);
        } else {
            runtime.setStyleSheets(self.base_styles_light, self.base_styles_dark);
        }
    }

    fn loadProfileOverridesFromDir(self: *ThemeEngine, root_path: []const u8) !void {
        // Reset all overrides, then load any present files.
        var i: usize = 0;
        while (i < self.profile_overrides.len) : (i += 1) {
            self.profile_overrides[i].deinit(self.allocator);
        }

        var dir = std.fs.cwd().openDir(root_path, .{}) catch return;
        defer dir.close();

        const pairs = [_]struct { id: ProfileId, rel: []const u8 }{
            .{ .id = .desktop, .rel = "profiles/desktop.json" },
            .{ .id = .phone, .rel = "profiles/phone.json" },
            .{ .id = .tablet, .rel = "profiles/tablet.json" },
            .{ .id = .fullscreen, .rel = "profiles/fullscreen.json" },
        };

        for (pairs) |pinfo| {
            const bytes = dir.readFileAlloc(self.allocator, pinfo.rel, 256 * 1024) catch continue;
            defer self.allocator.free(bytes);

            var parsed = schema.parseJson(schema.ProfileOverridesFile, self.allocator, bytes) catch continue;
            defer parsed.deinit();

            const idx = profileIndexForId(pinfo.id);
            const dst = &self.profile_overrides[idx];
            dst.deinit(self.allocator);

            if (parsed.value.ui_scale) |v| dst.ui_scale = v;
            if (parsed.value.hit_target_min_px) |v| dst.hit_target_min_px = v;

            if (parsed.value.overrides) |ov| {
                if (ov.ui_scale) |v| dst.ui_scale = v;
                if (ov.hit_target_min_px) |v| dst.hit_target_min_px = v;
                if (ov.components) |c| {
                    if (c.hit_target_min_px) |v| dst.hit_target_min_px = v;
                    if (c.button) |b| {
                        if (b.hit_target_min_px) |v| dst.hit_target_min_px = v;
                    }
                }

                dst.tokens.colors = ov.colors;
                dst.tokens.spacing = ov.spacing;
                dst.tokens.radius = ov.radius;
                dst.tokens.shadows = ov.shadows;
                if (ov.typography) |ty| {
                    var tcopy = ty;
                    if (ty.font_family) |ff| {
                        const owned = self.allocator.dupe(u8, ff) catch null;
                        if (owned) |buf| {
                            dst.owned_font_family = buf;
                            tcopy.font_family = buf;
                        } else {
                            tcopy.font_family = null;
                        }
                    }
                    dst.tokens.typography = tcopy;
                }
            }
        }
    }

    fn parsePanelKindLabel(label: []const u8) ?@import("../workspace.zig").PanelKind {
        if (std.ascii.eqlIgnoreCase(label, "workspace") or std.ascii.eqlIgnoreCase(label, "control")) return .Control;
        if (std.ascii.eqlIgnoreCase(label, "chat")) return .Chat;
        if (std.ascii.eqlIgnoreCase(label, "agents")) return .Agents;
        if (std.ascii.eqlIgnoreCase(label, "operator")) return .Operator;
        if (std.ascii.eqlIgnoreCase(label, "approvals") or std.ascii.eqlIgnoreCase(label, "approvals_inbox")) return .ApprovalsInbox;
        if (std.ascii.eqlIgnoreCase(label, "inbox")) return .Inbox;
        if (std.ascii.eqlIgnoreCase(label, "workboard") or std.ascii.eqlIgnoreCase(label, "board")) return .Workboard;
        if (std.ascii.eqlIgnoreCase(label, "settings")) return .Settings;
        if (std.ascii.eqlIgnoreCase(label, "showcase")) return .Showcase;
        if (std.ascii.eqlIgnoreCase(label, "code_editor") or std.ascii.eqlIgnoreCase(label, "codeeditor")) return .CodeEditor;
        if (std.ascii.eqlIgnoreCase(label, "tool_output") or std.ascii.eqlIgnoreCase(label, "tooloutput")) return .ToolOutput;
        return null;
    }

    fn workspaceIndexForId(id: ProfileId) usize {
        return switch (id) {
            .desktop => 0,
            .phone => 1,
            .tablet => 2,
            .fullscreen => 3,
        };
    }

    fn applyWorkspaceLayoutForProfile(self: *ThemeEngine, layout: schema.WorkspaceLayout, id: ProfileId) void {
        var preset: runtime.WorkspaceLayoutPreset = .{};
        preset.close_others = layout.close_others;

        if (layout.open_panels) |labels| {
            for (labels) |label| {
                const kind = parsePanelKindLabel(label) orelse continue;
                if (preset.panels_len >= preset.panels.len) break;
                preset.panels[preset.panels_len] = kind;
                preset.panels_len += 1;
            }
        }

        if (layout.focused_panel) |label| {
            preset.focused = parsePanelKindLabel(label);
        }
        if (layout.custom_layout) |cl| {
            preset.custom_layout_left_ratio = cl.left_ratio;
            preset.custom_layout_min_left_width = cl.min_left_width;
            preset.custom_layout_min_right_width = cl.min_right_width;
        }

        const idx = workspaceIndexForId(id);
        self.workspace_layouts[idx] = preset;
        self.workspace_layouts_set[idx] = true;
        runtime.setWorkspaceLayout(id, preset);
    }

    fn loadWorkspaceLayoutsFromBytes(self: *ThemeEngine, bytes: []const u8) void {
        runtime.clearWorkspaceLayouts();
        self.workspace_layouts_set = .{ false, false, false, false };
        if (bytes.len == 0) return;

        var parsed = schema.parseJson(schema.WorkspaceLayoutsFile, self.allocator, bytes) catch return;
        defer parsed.deinit();
        if (parsed.value.schema_version != 1) return;

        if (parsed.value.desktop) |layout| self.applyWorkspaceLayoutForProfile(layout, .desktop);
        if (parsed.value.phone) |layout| self.applyWorkspaceLayoutForProfile(layout, .phone);
        if (parsed.value.tablet) |layout| self.applyWorkspaceLayoutForProfile(layout, .tablet);
        if (parsed.value.fullscreen) |layout| self.applyWorkspaceLayoutForProfile(layout, .fullscreen);
    }

    fn loadWorkspaceLayoutsFromDir(self: *ThemeEngine, root_path: []const u8) void {
        runtime.clearWorkspaceLayouts();
        self.workspace_layouts_set = .{ false, false, false, false };

        var dir = std.fs.cwd().openDir(root_path, .{}) catch return;
        defer dir.close();
        const bytes = dir.readFileAlloc(self.allocator, "layouts/workspace.json", 256 * 1024) catch return;
        defer self.allocator.free(bytes);
        self.loadWorkspaceLayoutsFromBytes(bytes);
    }
};

const WebStage = enum {
    manifest,
    tokens_base,
    tokens_light,
    tokens_dark,
    styles,
    profile_desktop,
    profile_phone,
    profile_tablet,
    profile_fullscreen,
    workspace_layouts,
};

const WebPackJob = struct {
    engine: *ThemeEngine,
    allocator: std.mem.Allocator,
    generation: u32,
    root: []u8,
    stage: WebStage = .manifest,

    manifest: ?schema.Manifest = null,
    tokens_base: ?schema.TokensFile = null,
    tokens_light: ?schema.TokensFile = null,
    tokens_dark: ?schema.TokensFile = null,
    styles_raw: ?[]u8 = null,
    profile_raw: [4]?[]u8 = .{ null, null, null, null },
    workspace_layouts_raw: ?[]u8 = null,
    last_rel: []const u8 = "",

    fn init(engine: *ThemeEngine, generation: u32, root: []const u8) !*WebPackJob {
        const job = try engine.allocator.create(WebPackJob);
        job.* = .{
            .engine = engine,
            .allocator = engine.allocator,
            .generation = generation,
            .root = try engine.allocator.dupe(u8, root),
        };
        return job;
    }

    fn deinit(self: *WebPackJob) void {
        self.allocator.free(self.root);
        if (self.styles_raw) |bytes| self.allocator.free(bytes);
        for (self.profile_raw) |maybe| {
            if (maybe) |buf| self.allocator.free(buf);
        }
        if (self.workspace_layouts_raw) |buf| self.allocator.free(buf);
        if (self.manifest) |*m| freeManifestStrings(self.allocator, m);
        if (self.tokens_base) |*t| freeTokensStrings(self.allocator, t);
        if (self.tokens_light) |*t| freeTokensStrings(self.allocator, t);
        if (self.tokens_dark) |*t| freeTokensStrings(self.allocator, t);
        self.allocator.destroy(self);
    }

    fn start(self: *WebPackJob) !void {
        self.stage = .manifest;
        try self.fetchRel("manifest.json");
    }

    fn fetchRel(self: *WebPackJob, rel: []const u8) !void {
        self.last_rel = rel;
        const url = try joinUrl(self.allocator, self.root, rel);
        defer self.allocator.free(url);
        try wasm_fetch.fetchBytes(self.allocator, url, @intFromPtr(self), webFetchSuccess, webFetchError);
    }
};

fn joinUrl(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    if (root.len == 0) return allocator.dupe(u8, rel);
    const needs = if (root[root.len - 1] == '/') "" else "/";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ root, needs, rel });
}

fn looksLikeNotFound(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "HTTP 404");
}

fn looksLikeHttpError(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "HTTP ");
}

fn cacheKeyZ(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![:0]u8 {
    // Use a simple delimiter; localStorage keys can be arbitrary strings.
    // Note: this is a 0-terminated key for `molt_storage_*`.
    const buf = try std.fmt.allocPrint(allocator, "zsc.theme_pack_cache|{s}|{s}\x00", .{ root, rel });
    return buf[0 .. buf.len - 1 :0];
}

fn cachePut(job: *WebPackJob, rel: []const u8, bytes: []const u8) void {
    // Cache only text JSON-ish resources. (Binary assets are handled by the browser HTTP cache.)
    if (builtin.target.os.tag != .emscripten) return;
    if (bytes.len == 0) return;
    const key_z = cacheKeyZ(job.allocator, job.root, rel) catch return;
    defer job.allocator.free(key_z);
    wasm_storage.set(job.allocator, key_z, bytes) catch {};
}

fn cacheGet(job: *WebPackJob, rel: []const u8) ?[]u8 {
    if (builtin.target.os.tag != .emscripten) return null;
    const key_z = cacheKeyZ(job.allocator, job.root, rel) catch return null;
    defer job.allocator.free(key_z);
    const cached = wasm_storage.get(job.allocator, key_z) catch return null;
    return cached;
}

fn webFetchSuccess(user_ctx: usize, bytes: []const u8) void {
    const job: *WebPackJob = @ptrFromInt(user_ctx);
    const eng = job.engine;
    if (eng.web_job == null or eng.web_job.? != job or eng.web_generation != job.generation) {
        job.deinit();
        return;
    }

    cachePut(job, job.last_rel, bytes);

    switch (job.stage) {
        .manifest => {
            var parsed = schema.parseJson(schema.Manifest, job.allocator, bytes) catch {
                job.deinit();
                eng.web_job = null;
                return;
            };
            defer parsed.deinit();
            var m = parsed.value;
            if (m.schema_version != 1) {
                job.deinit();
                eng.web_job = null;
                return;
            }
            m.id = job.allocator.dupe(u8, m.id) catch {
                job.deinit();
                eng.web_job = null;
                return;
            };
            m.name = job.allocator.dupe(u8, m.name) catch {
                job.allocator.free(m.id);
                job.deinit();
                eng.web_job = null;
                return;
            };
            m.author = job.allocator.dupe(u8, m.author) catch {
                job.allocator.free(m.id);
                job.allocator.free(m.name);
                job.deinit();
                eng.web_job = null;
                return;
            };
            m.license = job.allocator.dupe(u8, m.license) catch {
                job.allocator.free(m.id);
                job.allocator.free(m.name);
                job.allocator.free(m.author);
                job.deinit();
                eng.web_job = null;
                return;
            };
            m.defaults.variant = job.allocator.dupe(u8, m.defaults.variant) catch {
                job.allocator.free(m.id);
                job.allocator.free(m.name);
                job.allocator.free(m.author);
                job.allocator.free(m.license);
                job.deinit();
                eng.web_job = null;
                return;
            };
            m.defaults.profile = job.allocator.dupe(u8, m.defaults.profile) catch {
                job.allocator.free(m.id);
                job.allocator.free(m.name);
                job.allocator.free(m.author);
                job.allocator.free(m.license);
                job.allocator.free(m.defaults.variant);
                job.deinit();
                eng.web_job = null;
                return;
            };
            job.manifest = m;

            job.stage = .tokens_base;
            job.fetchRel("tokens/base.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .tokens_base => {
            var parsed = schema.parseJson(schema.TokensFile, job.allocator, bytes) catch {
                job.deinit();
                eng.web_job = null;
                return;
            };
            defer parsed.deinit();
            var tbase = parsed.value;
            tbase.typography.font_family = job.allocator.dupe(u8, tbase.typography.font_family) catch {
                job.deinit();
                eng.web_job = null;
                return;
            };
            job.tokens_base = tbase;

            job.stage = .tokens_light;
            job.fetchRel("tokens/light.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .tokens_light => {
            const base = job.tokens_base orelse {
                job.deinit();
                eng.web_job = null;
                return;
            };
            parseOptionalVariant(job, bytes, base) catch {
                // If parsing failed, treat it as absent and continue.
            };
            job.stage = .tokens_dark;
            job.fetchRel("tokens/dark.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .tokens_dark => {
            const base = job.tokens_base orelse {
                job.deinit();
                eng.web_job = null;
                return;
            };
            parseOptionalVariant(job, bytes, base) catch {
                // ignore
            };
            job.stage = .styles;
            job.fetchRel("styles/components.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .styles => {
            // Styles are optional; an empty sheet is valid.
            if (bytes.len > 0) {
                job.styles_raw = job.allocator.dupe(u8, bytes) catch null;
            }
            job.stage = .profile_desktop;
            job.fetchRel("profiles/desktop.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .profile_desktop => {
            if (bytes.len > 0) job.profile_raw[0] = job.allocator.dupe(u8, bytes) catch null;
            job.stage = .profile_phone;
            job.fetchRel("profiles/phone.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .profile_phone => {
            if (bytes.len > 0) job.profile_raw[1] = job.allocator.dupe(u8, bytes) catch null;
            job.stage = .profile_tablet;
            job.fetchRel("profiles/tablet.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .profile_tablet => {
            if (bytes.len > 0) job.profile_raw[2] = job.allocator.dupe(u8, bytes) catch null;
            job.stage = .profile_fullscreen;
            job.fetchRel("profiles/fullscreen.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .profile_fullscreen => {
            if (bytes.len > 0) job.profile_raw[3] = job.allocator.dupe(u8, bytes) catch null;
            job.stage = .workspace_layouts;
            job.fetchRel("layouts/workspace.json") catch {
                job.deinit();
                eng.web_job = null;
            };
        },
        .workspace_layouts => {
            if (bytes.len > 0) job.workspace_layouts_raw = job.allocator.dupe(u8, bytes) catch null;
            applyWebJob(job);
        },
    }
}

fn webFetchError(user_ctx: usize, msg: []const u8) void {
    const job: *WebPackJob = @ptrFromInt(user_ctx);
    const eng = job.engine;
    if (eng.web_job == null or eng.web_job.? != job or eng.web_generation != job.generation) {
        job.deinit();
        return;
    }

    {
        var buf: [512]u8 = undefined;
        const err_line = std.fmt.bufPrint(&buf, "Failed to fetch theme pack: {s}/{s} ({s})", .{
            job.root,
            job.last_rel,
            msg,
        }) catch "Failed to fetch theme pack";
        runtime.setPackStatus(.failed, err_line);
    }

    // Network-ish errors: try cached version before failing (lets offline loads work).
    if (!looksLikeHttpError(msg)) {
        if (cacheGet(job, job.last_rel)) |cached| {
            defer job.allocator.free(cached);
            webFetchSuccess(user_ctx, cached);
            return;
        }
    }

    // Optional resources: treat 404 as missing and continue.
    if (looksLikeNotFound(msg)) {
        switch (job.stage) {
            .tokens_light => {
                job.stage = .tokens_dark;
                job.fetchRel("tokens/dark.json") catch {
                    job.deinit();
                    eng.web_job = null;
                };
                return;
            },
            .tokens_dark => {
                job.stage = .styles;
                job.fetchRel("styles/components.json") catch {
                    job.deinit();
                    eng.web_job = null;
                };
                return;
            },
            .styles => {
                job.stage = .profile_desktop;
                job.fetchRel("profiles/desktop.json") catch {
                    job.deinit();
                    eng.web_job = null;
                };
                return;
            },
            .profile_desktop => {
                job.stage = .profile_phone;
                job.fetchRel("profiles/phone.json") catch {
                    job.deinit();
                    eng.web_job = null;
                };
                return;
            },
            .profile_phone => {
                job.stage = .profile_tablet;
                job.fetchRel("profiles/tablet.json") catch {
                    job.deinit();
                    eng.web_job = null;
                };
                return;
            },
            .profile_tablet => {
                job.stage = .profile_fullscreen;
                job.fetchRel("profiles/fullscreen.json") catch {
                    job.deinit();
                    eng.web_job = null;
                };
                return;
            },
            .profile_fullscreen => {
                job.stage = .workspace_layouts;
                job.fetchRel("layouts/workspace.json") catch {
                    job.deinit();
                    eng.web_job = null;
                };
                return;
            },
            .workspace_layouts => {
                applyWebJob(job);
                return;
            },
            else => {},
        }
    }

    job.deinit();
    eng.web_job = null;
}

fn parseOptionalVariant(job: *WebPackJob, bytes: []const u8, base_tokens: schema.TokensFile) !void {
    // Try full file first.
    var parsed_full = schema.parseJson(schema.TokensFile, job.allocator, bytes) catch |err| switch (err) {
        error.MissingField => null,
        else => return err,
    };
    if (parsed_full) |*p| {
        defer p.deinit();
        var out = p.value;
        out.typography.font_family = try job.allocator.dupe(u8, out.typography.font_family);
        // Heuristic: choose slot based on stage.
        if (job.stage == .tokens_light) job.tokens_light = out else job.tokens_dark = out;
        return;
    }

    var parsed_override = try schema.parseJson(schema.TokensOverrideFile, job.allocator, bytes);
    defer parsed_override.deinit();
    const merged = try schema.mergeTokens(job.allocator, base_tokens, parsed_override.value);
    if (job.stage == .tokens_light) job.tokens_light = merged else job.tokens_dark = merged;
}

fn applyWebJob(job: *WebPackJob) void {
    const eng = job.engine;
    const base = job.tokens_base orelse {
        job.deinit();
        eng.web_job = null;
        return;
    };

    // Tear down any previous per-profile caches tied to the old pack before we swap pointers.
    if (eng.pack_tokens_light) |*t| eng.allocator.free(t.typography.font_family);
    if (eng.pack_tokens_dark) |*t| eng.allocator.free(t.typography.font_family);
    eng.pack_tokens_light = null;
    eng.pack_tokens_dark = null;
    eng.freeProfileCaches();

    // Build runtime themes.
    const base_theme = buildRuntimeTheme(eng.allocator, base) catch {
        job.deinit();
        eng.web_job = null;
        return;
    };
    errdefer freeTheme(eng.allocator, base_theme);

    const light_theme = if (job.tokens_light) |tf|
        buildRuntimeTheme(eng.allocator, tf) catch cloneTheme(eng.allocator, base_theme) catch {
            freeTheme(eng.allocator, base_theme);
            job.deinit();
            eng.web_job = null;
            return;
        }
    else
        cloneTheme(eng.allocator, base_theme) catch {
            freeTheme(eng.allocator, base_theme);
            job.deinit();
            eng.web_job = null;
            return;
        };
    errdefer freeTheme(eng.allocator, light_theme);

    const dark_theme = if (job.tokens_dark) |tf|
        buildRuntimeTheme(eng.allocator, tf) catch cloneTheme(eng.allocator, base_theme) catch {
            freeTheme(eng.allocator, base_theme);
            freeTheme(eng.allocator, light_theme);
            job.deinit();
            eng.web_job = null;
            return;
        }
    else
        cloneTheme(eng.allocator, base_theme) catch {
            freeTheme(eng.allocator, base_theme);
            freeTheme(eng.allocator, light_theme);
            job.deinit();
            eng.web_job = null;
            return;
        };
    errdefer freeTheme(eng.allocator, dark_theme);

    // Style sheet (optional).
    eng.styles.deinit();
    eng.styles = style_sheet.StyleSheetStore.initEmpty(eng.allocator);
    if (job.styles_raw) |raw| {
        // Keep raw bytes for future debugging/hot-reload (owned by StyleSheetStore).
        eng.styles.raw_json = raw;
        const ss_light: style_sheet.StyleSheet = style_sheet.parseResolved(eng.allocator, raw, light_theme) catch .{};
        const ss_dark: style_sheet.StyleSheet = style_sheet.parseResolved(eng.allocator, raw, dark_theme) catch .{};
        eng.styles.resolved = .{};
        runtime.setStyleSheets(ss_light, ss_dark);
        eng.base_styles_light = ss_light;
        eng.base_styles_dark = ss_dark;
        job.styles_raw = null; // ownership transferred
    } else {
        runtime.setStyleSheets(.{}, .{});
        eng.base_styles_light = .{};
        eng.base_styles_dark = .{};
    }

    // Swap in new themes.
    theme_mod.setRuntimeTheme(.light, light_theme);
    theme_mod.setRuntimeTheme(.dark, dark_theme);

        if (eng.active_pack_root) |p| eng.allocator.free(p);
        eng.active_pack_root = eng.allocator.dupe(u8, job.root) catch null;
        runtime.setThemePackRootPath(eng.active_pack_root);

    if (job.manifest) |m| {
        eng.clearPackMetaOwned();
        eng.pack_meta_set = true;
        eng.pack_meta_id = eng.allocator.dupe(u8, m.id) catch null;
        eng.pack_meta_name = eng.allocator.dupe(u8, m.name) catch null;
        eng.pack_meta_author = eng.allocator.dupe(u8, m.author) catch null;
        eng.pack_meta_license = eng.allocator.dupe(u8, m.license) catch null;
        eng.pack_meta_defaults_variant = eng.allocator.dupe(u8, m.defaults.variant) catch null;
        eng.pack_meta_defaults_profile = eng.allocator.dupe(u8, m.defaults.profile) catch null;
        eng.pack_meta_requires_multi_window = m.capabilities.requires_multi_window;
        eng.pack_meta_requires_custom_shaders = m.capabilities.requires_custom_shaders;
        eng.pack_defaults_lock_variant = m.defaults.lock_variant;
        runtime.setPackDefaults(m.defaults.variant, m.defaults.profile);
        runtime.setPackModeLockToDefault(eng.pack_defaults_lock_variant);
        runtime.setPackMeta(m);
        const defaults_sampling = if (std.ascii.eqlIgnoreCase(m.defaults.image_sampling, "nearest"))
            ui_commands.ImageSampling.nearest
        else
            ui_commands.ImageSampling.linear;
        eng.render_defaults = .{
            .image_sampling = defaults_sampling,
            .pixel_snap_textured = m.defaults.pixel_snap_textured,
        };
        runtime.setRenderDefaults(eng.render_defaults);
    } else {
        eng.clearPackMetaOwned();
        eng.render_defaults = .{};
        eng.pack_defaults_lock_variant = false;
        runtime.clearPackDefaults();
        runtime.setPackModeLockToDefault(false);
        runtime.clearPackMeta();
        runtime.setRenderDefaults(eng.render_defaults);
    }

    if (eng.active_pack_path) |p| eng.allocator.free(p);
    eng.active_pack_path = eng.allocator.dupe(u8, job.root) catch null;

    if (eng.runtime_light) |prev| freeTheme(eng.allocator, prev);
    if (eng.runtime_dark) |prev| freeTheme(eng.allocator, prev);
    eng.runtime_light = light_theme;
    eng.runtime_dark = dark_theme;

    // Persist pack tokens so we can apply `profiles/*.json` overrides on web builds too.
    // Note: tokens_light/dark are optional; fall back to base tokens.
    eng.pack_tokens_light = dupTokensFileAlloc(eng.allocator, job.tokens_light orelse base) catch null;
    eng.pack_tokens_dark = dupTokensFileAlloc(eng.allocator, job.tokens_dark orelse base) catch null;

    // Load optional per-profile overrides (bytes already fetched/cached by WebPackJob).
    // Missing or invalid files are ignored.
    const pairs = [_]struct { id: ProfileId, idx: usize }{
        .{ .id = .desktop, .idx = 0 },
        .{ .id = .phone, .idx = 1 },
        .{ .id = .tablet, .idx = 2 },
        .{ .id = .fullscreen, .idx = 3 },
    };
    for (pairs) |pinfo| {
        const bytes = job.profile_raw[pinfo.idx] orelse continue;
        var parsed = schema.parseJson(schema.ProfileOverridesFile, eng.allocator, bytes) catch continue;
        defer parsed.deinit();

        const dst = &eng.profile_overrides[profileIndexForId(pinfo.id)];
        dst.deinit(eng.allocator);

        if (parsed.value.ui_scale) |v| dst.ui_scale = v;
        if (parsed.value.hit_target_min_px) |v| dst.hit_target_min_px = v;

        if (parsed.value.overrides) |ov| {
            if (ov.ui_scale) |v| dst.ui_scale = v;
            if (ov.hit_target_min_px) |v| dst.hit_target_min_px = v;
            if (ov.components) |c| {
                if (c.hit_target_min_px) |v| dst.hit_target_min_px = v;
                if (c.button) |b| {
                    if (b.hit_target_min_px) |v| dst.hit_target_min_px = v;
                }
            }

            dst.tokens.colors = ov.colors;
            dst.tokens.spacing = ov.spacing;
            dst.tokens.radius = ov.radius;
            dst.tokens.shadows = ov.shadows;
            if (ov.typography) |ty| {
                var tcopy = ty;
                if (ty.font_family) |ff| {
                    const owned = eng.allocator.dupe(u8, ff) catch null;
                    if (owned) |buf| {
                        dst.owned_font_family = buf;
                        tcopy.font_family = buf;
                    } else {
                        tcopy.font_family = null;
                    }
                }
                dst.tokens.typography = tcopy;
            }
        }
    }
    eng.clearProfileThemeCaches();

    // Optional workspace layouts (`layouts/workspace.json`).
    eng.loadWorkspaceLayoutsFromBytes(job.workspace_layouts_raw orelse "");

    freeTheme(eng.allocator, base_theme);

    {
        var buf: [512]u8 = undefined;
        const ok_line = std.fmt.bufPrint(&buf, "Loaded theme pack: {s}", .{job.root}) catch "Loaded theme pack";
        runtime.setPackStatus(.ok, ok_line);
    }

    eng.web_theme_changed = true;
    eng.web_job = null;
    job.deinit();
}

fn freeManifestStrings(allocator: std.mem.Allocator, m: *schema.Manifest) void {
    allocator.free(m.id);
    allocator.free(m.name);
    allocator.free(m.author);
    allocator.free(m.license);
    allocator.free(m.defaults.variant);
    allocator.free(m.defaults.profile);
}

fn freeTokensStrings(allocator: std.mem.Allocator, t: *schema.TokensFile) void {
    allocator.free(t.typography.font_family);
}

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

        // If the pack exists relative to CWD, don't bother probing exe-dir fallbacks.
        // This also avoids calling `selfExePathAlloc` on platforms/environments where
        // the executable path resolution can be fragile (e.g. running from UNC paths).
        if (std.fs.cwd().access(self.raw_path, .{})) |_| {
            return;
        } else |_| {}

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
