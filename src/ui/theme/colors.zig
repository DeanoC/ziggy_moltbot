pub const Color = [4]f32;

pub const Colors = struct {
    background: Color,
    surface: Color,
    primary: Color,
    success: Color,
    danger: Color,
    warning: Color,
    text_primary: Color,
    text_secondary: Color,
    border: Color,
    divider: Color,
};

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

pub fn withAlpha(color: Color, alpha: f32) Color {
    return .{ color[0], color[1], color[2], alpha };
}

pub fn blend(a: Color, b: Color, t: f32) Color {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    };
}

pub const light = Colors{
    .background = rgba(255, 255, 255, 255),
    .surface = rgba(245, 245, 245, 255),
    .primary = rgba(66, 133, 244, 255),
    .success = rgba(52, 168, 83, 255),
    .danger = rgba(234, 67, 53, 255),
    .warning = rgba(251, 188, 4, 255),
    .text_primary = rgba(32, 33, 36, 255),
    .text_secondary = rgba(95, 99, 104, 255),
    .border = rgba(218, 220, 224, 255),
    .divider = rgba(232, 234, 237, 255),
};

pub const dark = Colors{
    .background = rgba(20, 23, 26, 255),
    .surface = rgba(30, 35, 43, 255),
    .primary = rgba(229, 148, 59, 255),
    .success = rgba(52, 168, 83, 255),
    .danger = rgba(234, 67, 53, 255),
    .warning = rgba(251, 188, 4, 255),
    .text_primary = rgba(230, 233, 237, 255),
    .text_secondary = rgba(154, 162, 172, 255),
    .border = rgba(43, 49, 58, 255),
    .divider = rgba(33, 39, 48, 255),
};
