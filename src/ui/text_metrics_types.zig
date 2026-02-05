pub const Vec2 = [2]f32;

pub const Metrics = struct {
    measure: *const fn (text: []const u8, wrap_width: f32) Vec2,
    line_height: *const fn () f32,
};

fn nullMeasureText(text: []const u8, wrap_width: f32) Vec2 {
    _ = text;
    _ = wrap_width;
    return .{ 0.0, 0.0 };
}

fn nullLineHeight() f32 {
    return 0.0;
}

pub const noop = Metrics{
    .measure = nullMeasureText,
    .line_height = nullLineHeight,
};
