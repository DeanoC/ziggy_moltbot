const types = @import("text_metrics_types.zig");

pub const Vec2 = types.Vec2;
pub const Metrics = types.Metrics;
pub const noop = types.noop;

const builtin = @import("builtin");
const ui_build = @import("ui_build.zig");
const use_imgui = ui_build.use_imgui;
const use_freetype = !builtin.abi.isAndroid() and builtin.os.tag != .emscripten;
const imgui_impl = if (use_imgui)
    @import("text_metrics_imgui.zig")
else
    struct {
        pub const metrics = types.noop;
    };
const Impl = if (use_freetype) @import("text_metrics_freetype.zig") else imgui_impl;

pub const imgui = imgui_impl.metrics;
pub const default = Impl.metrics;
