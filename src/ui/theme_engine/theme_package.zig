const std = @import("std");
const builtin = @import("builtin");

const schema = @import("schema.zig");

pub const LoadError = error{
    UnsupportedPlatform,
    InvalidThemePack,
    MissingFile,
} || std.fs.File.OpenError || std.fs.File.ReadError || std.json.ParseError || std.mem.Allocator.Error;

pub const ThemePackage = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    manifest: schema.Manifest,
    tokens_base: schema.TokensFile,
    tokens_light: ?schema.TokensFile = null,
    tokens_dark: ?schema.TokensFile = null,
    windows: ?[]schema.WindowTemplate = null,

    pub fn deinit(self: *ThemePackage) void {
        self.allocator.free(self.root_path);
        freeManifestStrings(self.allocator, &self.manifest);
        freeTokensStrings(self.allocator, &self.tokens_base);
        if (self.tokens_light) |*t| freeTokensStrings(self.allocator, t);
        if (self.tokens_dark) |*t| freeTokensStrings(self.allocator, t);
        if (self.windows) |v| freeWindowTemplates(self.allocator, v);
    }
};

fn readFileAlloc(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, limit: usize) ![]u8 {
    const f = dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.MissingFile,
        else => return err,
    };
    defer f.close();
    return try f.readToEndAlloc(allocator, limit);
}

fn loadOptionalTokens(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    rel: []const u8,
    base_tokens: schema.TokensFile,
) !?schema.TokensFile {
    const data = readFileAlloc(allocator, dir, rel, 2 * 1024 * 1024) catch |err| switch (err) {
        error.MissingFile => return null,
        else => return err,
    };
    defer allocator.free(data);

    // Variant token files can be either:
    // - a full TokensFile (complete `colors.*` etc.)
    // - or a partial override file merged onto `tokens/base.json`.
    var parsed_full = schema.parseJson(schema.TokensFile, allocator, data) catch |err| switch (err) {
        error.MissingField => null,
        else => return err,
    };
    if (parsed_full) |*p| {
        defer p.deinit();
        var out = p.value;
        out.typography.font_family = try allocator.dupe(u8, out.typography.font_family);
        return out;
    }

    var parsed_override = try schema.parseJson(schema.TokensOverrideFile, allocator, data);
    defer parsed_override.deinit();
    return try schema.mergeTokens(allocator, base_tokens, parsed_override.value);
}

pub fn freeWindowTemplates(allocator: std.mem.Allocator, templates: []schema.WindowTemplate) void {
    for (templates) |tpl| {
        allocator.free(tpl.id);
        allocator.free(tpl.title);
        if (tpl.profile) |p| allocator.free(p);
        if (tpl.variant) |p| allocator.free(p);
        if (tpl.image_sampling) |p| allocator.free(p);
        if (tpl.focused_panel) |p| allocator.free(p);
        if (tpl.panels) |list| {
            for (list) |label| allocator.free(label);
            allocator.free(list);
        }
    }
    allocator.free(templates);
}

fn loadOptionalWindows(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
) !?[]schema.WindowTemplate {
    const data = readFileAlloc(allocator, dir, "windows.json", 512 * 1024) catch |err| switch (err) {
        error.MissingFile => return null,
        else => return err,
    };
    defer allocator.free(data);

    var parsed = try schema.parseJson(schema.WindowsFile, allocator, data);
    defer parsed.deinit();
    if (parsed.value.schema_version != 1) return error.InvalidThemePack;

    const src = parsed.value.windows;
    if (src.len == 0) return null;

    var out = try allocator.alloc(schema.WindowTemplate, src.len);
    var filled: usize = 0;
    errdefer {
        freeWindowTemplates(allocator, out[0..filled]);
    }

    for (src, 0..) |tpl, idx| {
        _ = idx;
        const id_copy = try allocator.dupe(u8, tpl.id);
        errdefer allocator.free(id_copy);
        const title_src = if (tpl.title.len > 0) tpl.title else tpl.id;
        const title_copy = try allocator.dupe(u8, title_src);
        errdefer allocator.free(title_copy);
        const profile_copy = if (tpl.profile) |p| try allocator.dupe(u8, p) else null;
        errdefer if (profile_copy) |p| allocator.free(p);
        const variant_copy = if (tpl.variant) |p| try allocator.dupe(u8, p) else null;
        errdefer if (variant_copy) |p| allocator.free(p);
        const sampling_copy = if (tpl.image_sampling) |p| try allocator.dupe(u8, p) else null;
        errdefer if (sampling_copy) |p| allocator.free(p);
        const focused_copy = if (tpl.focused_panel) |p| try allocator.dupe(u8, p) else null;
        errdefer if (focused_copy) |p| allocator.free(p);

        const panels_copy = if (tpl.panels) |list| blk: {
            var labels = try allocator.alloc([]const u8, list.len);
            var labels_filled: usize = 0;
            errdefer {
                for (labels[0..labels_filled]) |s| allocator.free(s);
                allocator.free(labels);
            }
            for (list, 0..) |label, j| {
                labels[j] = try allocator.dupe(u8, label);
                labels_filled = j + 1;
            }
            break :blk labels;
        } else null;
        errdefer if (panels_copy) |list| {
            for (list) |s| allocator.free(s);
            allocator.free(list);
        };

        out[filled] = .{
            .id = id_copy,
            .title = title_copy,
            .width = tpl.width,
            .height = tpl.height,
            .profile = profile_copy,
            .variant = variant_copy,
            .image_sampling = sampling_copy,
            .pixel_snap_textured = tpl.pixel_snap_textured,
            .panels = panels_copy,
            .focused_panel = focused_copy,
        };
        filled += 1;
    }

    return out;
}

pub fn loadFromDirectory(allocator: std.mem.Allocator, path: []const u8) !ThemePackage {
    if (builtin.cpu.arch == .wasm32) return error.UnsupportedPlatform;

    var dir = std.fs.cwd().openDir(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.MissingFile,
        else => return err,
    };
    defer dir.close();

    const manifest_bytes = try readFileAlloc(allocator, dir, "manifest.json", 512 * 1024);
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try schema.parseJson(schema.Manifest, allocator, manifest_bytes);
    defer parsed_manifest.deinit();
    var manifest = parsed_manifest.value;
    if (manifest.schema_version != 1) return error.InvalidThemePack;
    manifest.id = try allocator.dupe(u8, manifest.id);
    manifest.name = try allocator.dupe(u8, manifest.name);
    manifest.author = try allocator.dupe(u8, manifest.author);
    manifest.license = try allocator.dupe(u8, manifest.license);
    manifest.defaults.variant = try allocator.dupe(u8, manifest.defaults.variant);
    manifest.defaults.profile = try allocator.dupe(u8, manifest.defaults.profile);
    manifest.defaults.image_sampling = try allocator.dupe(u8, manifest.defaults.image_sampling);

    const tokens_base_bytes = try readFileAlloc(allocator, dir, "tokens/base.json", 2 * 1024 * 1024);
    defer allocator.free(tokens_base_bytes);
    var parsed_tokens = try schema.parseJson(schema.TokensFile, allocator, tokens_base_bytes);
    defer parsed_tokens.deinit();
    var tokens_base = parsed_tokens.value;
    tokens_base.typography.font_family = try allocator.dupe(u8, tokens_base.typography.font_family);

    const tokens_light = try loadOptionalTokens(allocator, dir, "tokens/light.json", tokens_base);
    const tokens_dark = try loadOptionalTokens(allocator, dir, "tokens/dark.json", tokens_base);
    const windows = try loadOptionalWindows(allocator, dir);

    return .{
        .allocator = allocator,
        .root_path = try allocator.dupe(u8, path),
        .manifest = manifest,
        .tokens_base = tokens_base,
        .tokens_light = tokens_light,
        .tokens_dark = tokens_dark,
        .windows = windows,
    };
}

fn freeManifestStrings(allocator: std.mem.Allocator, m: *schema.Manifest) void {
    allocator.free(m.id);
    allocator.free(m.name);
    allocator.free(m.author);
    allocator.free(m.license);
    allocator.free(m.defaults.variant);
    allocator.free(m.defaults.profile);
    allocator.free(m.defaults.image_sampling);
}

fn freeTokensStrings(allocator: std.mem.Allocator, t: *schema.TokensFile) void {
    allocator.free(t.typography.font_family);
}
