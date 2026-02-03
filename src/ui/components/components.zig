pub const core = struct {
    pub const button = @import("core/button.zig");
    pub const icon_button = @import("core/icon_button.zig");
    pub const badge = @import("core/badge.zig");
    pub const tab_bar = @import("core/tab_bar.zig");
    pub const file_row = @import("core/file_row.zig");
    pub const widget = @import("core/widget.zig");
};

pub const layout = struct {
    pub const card = @import("layout/card.zig");
    pub const scroll_area = @import("layout/scroll_area.zig");
    pub const sidebar = @import("layout/sidebar.zig");
    pub const header_bar = @import("layout/header_bar.zig");
    pub const split_pane = @import("layout/split_pane.zig");
};

pub const data = struct {
    pub const progress_step = @import("data/progress_step.zig");
    pub const agent_status = @import("data/agent_status.zig");
    pub const approval_card = @import("data/approval_card.zig");
    pub const list_item = @import("data/list_item.zig");
};

pub const composite = struct {
    pub const project_card = @import("composite/project_card.zig");
    pub const source_browser = @import("composite/source_browser.zig");
    pub const task_progress = @import("composite/task_progress.zig");
    pub const artifact_row = @import("composite/artifact_row.zig");
    pub const message_bubble = @import("composite/message_bubble.zig");
};
