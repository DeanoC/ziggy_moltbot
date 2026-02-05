pub const Typography = struct {
    font_family: []const u8,
    title_size: f32,
    heading_size: f32,
    body_size: f32,
    caption_size: f32,
};

pub const default = Typography{
    .font_family = "Space Grotesk",
    .title_size = 22.0,
    .heading_size = 18.0,
    .body_size = 16.0,
    .caption_size = 12.0,
};
