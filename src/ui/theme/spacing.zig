pub const Spacing = struct {
    xs: f32,
    sm: f32,
    md: f32,
    lg: f32,
    xl: f32,
};

pub const Radius = struct {
    sm: f32,
    md: f32,
    lg: f32,
    full: f32,
};

pub const default_spacing = Spacing{
    .xs = 4.0,
    .sm = 8.0,
    .md = 16.0,
    .lg = 24.0,
    .xl = 32.0,
};

pub const default_radius = Radius{
    .sm = 4.0,
    .md = 8.0,
    .lg = 12.0,
    .full = 9999.0,
};
