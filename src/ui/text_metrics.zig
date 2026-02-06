const types = @import("text_metrics_types.zig");

pub const Vec2 = types.Vec2;
pub const Metrics = types.Metrics;
pub const noop = types.noop;

pub const default = @import("text_metrics_freetype.zig").metrics;

