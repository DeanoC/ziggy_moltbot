pub const core = struct {
    pub const button = @import("core/button.zig");
    pub const badge = @import("core/badge.zig");
    pub const tab_bar = @import("core/tab_bar.zig");
    pub const file_row = @import("core/file_row.zig");
};

pub const layout = struct {
    pub const card = @import("layout/card.zig");
    pub const scroll_area = @import("layout/scroll_area.zig");
    pub const sidebar = @import("layout/sidebar.zig");
    pub const header_bar = @import("layout/header_bar.zig");
    pub const split_pane = @import("layout/split_pane.zig");
};
