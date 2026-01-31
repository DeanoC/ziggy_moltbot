const std = @import("std");
const zgui = @import("zgui");
const workspace = @import("../workspace.zig");

pub fn draw(panel: *workspace.Panel, allocator: std.mem.Allocator) bool {
    if (panel.kind != .CodeEditor) return false;
    var editor = &panel.data.CodeEditor;

    zgui.text("File:", .{});
    zgui.sameLine(.{});
    zgui.text("{s}", .{editor.file_id});
    zgui.sameLine(.{ .spacing = 12.0 });
    zgui.textDisabled("({s})", .{editor.language});
    zgui.separator();

    const avail = zgui.getContentRegionAvail();
    const min_capacity = @max(@as(usize, 64 * 1024), editor.content.slice().len);
    _ = editor.content.ensureCapacity(allocator, min_capacity) catch {};

    const changed = zgui.inputTextMultiline("##code_editor", .{
        .buf = editor.content.asZ(),
        .h = avail[1] - zgui.getFrameHeightWithSpacing(),
        .flags = .{ .allow_tab_input = true },
    });

    if (changed) {
        editor.content.syncFromInput();
        editor.last_modified_by = .user;
        editor.version += 1;
        panel.state.is_dirty = true;
    }

    zgui.separator();
    zgui.textDisabled("v{d} · {s}", .{
        editor.version,
        if (editor.last_modified_by == .user) "edited" else "ai",
    });
    return changed;
}
