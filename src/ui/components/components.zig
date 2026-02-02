pub const core = struct {
    pub const button = @import("core/button.zig");
    pub const badge = @import("core/badge.zig");
};

pub const layout = struct {
    pub const card = @import("layout/card.zig");
    pub const scroll_area = @import("layout/scroll_area.zig");
};
