const draw_context = @import("../../draw_context.zig");

pub const Widget = struct {
    id: u64,
    bounds: draw_context.Rect,
    state: State = .idle,

    pub const State = enum {
        idle,
        hovered,
        pressed,
        focused,
        disabled,
    };
};
