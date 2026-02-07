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
        profile: []const u8 = "desktop",
    };

    pub const Capabilities = struct {
        requires_multi_window: bool = false,
        requires_custom_shaders: bool = false,
    };
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

pub const Typography = struct {
    font_family: []const u8 = "Space Grotesk",
    title_size: f32 = 22.0,
    heading_size: f32 = 18.0,
    body_size: f32 = 16.0,
    caption_size: f32 = 12.0,
};

pub const Spacing = struct {
    xs: f32 = 4.0,
    sm: f32 = 8.0,
    md: f32 = 16.0,
    lg: f32 = 24.0,
    xl: f32 = 32.0,
};

pub const Radius = struct {
    sm: f32 = 4.0,
    md: f32 = 8.0,
    lg: f32 = 12.0,
    full: f32 = 9999.0,
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

pub fn parseJson(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{ .ignore_unknown_fields = true });
}
