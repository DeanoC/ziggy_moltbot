const zgui = @import("zgui");
const types = @import("text_metrics_types.zig");

fn measure(text: []const u8, wrap_width: f32) types.Vec2 {
    const wrap = if (wrap_width <= 0.0) -1.0 else wrap_width;
    return zgui.calcTextSize(text, .{ .wrap_width = wrap });
}

fn lineHeight() f32 {
    return zgui.getTextLineHeightWithSpacing();
}

pub const metrics = types.Metrics{
    .measure = measure,
    .line_height = lineHeight,
};
