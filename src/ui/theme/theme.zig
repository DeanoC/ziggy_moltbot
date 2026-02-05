const colors = @import("colors.zig");
const typography = @import("typography.zig");
const spacing = @import("spacing.zig");

pub const Mode = enum { light, dark };

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

pub const Theme = struct {
    colors: colors.Colors,
    typography: typography.Typography,
    spacing: spacing.Spacing,
    radius: spacing.Radius,
    shadows: Shadows,
};

pub const light = Theme{
    .colors = colors.light,
    .typography = typography.default,
    .spacing = spacing.default_spacing,
    .radius = spacing.default_radius,
    .shadows = .{
        .sm = .{ .blur = 2.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 1.0 },
        .md = .{ .blur = 4.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 2.0 },
        .lg = .{ .blur = 8.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 4.0 },
    },
};

pub const dark = Theme{
    .colors = colors.dark,
    .typography = typography.default,
    .spacing = spacing.default_spacing,
    .radius = spacing.default_radius,
    .shadows = .{
        .sm = .{ .blur = 2.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 1.0 },
        .md = .{ .blur = 4.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 2.0 },
        .lg = .{ .blur = 8.0, .spread = 0.0, .offset_x = 0.0, .offset_y = 4.0 },
    },
};

pub fn get(mode: Mode) *const Theme {
    return switch (mode) {
        .light => &light,
        .dark => &dark,
    };
}
