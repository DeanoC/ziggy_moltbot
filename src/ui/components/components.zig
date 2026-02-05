pub const composite = struct {
    pub const project_card = @import("composite/project_card.zig");
    pub const source_browser = @import("composite/source_browser.zig");
    pub const task_progress = @import("composite/task_progress.zig");
    pub const artifact_row = @import("composite/artifact_row.zig");
    pub const message_bubble = @import("composite/message_bubble.zig");
};
