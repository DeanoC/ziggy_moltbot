const std = @import("std");
const zgui = @import("zgui");
const workspace = @import("../workspace.zig");
const components = @import("../components/components.zig");
const ui_systems = @import("../ui_systems.zig");
const undo_redo = @import("../systems/undo_redo.zig");
const systems = @import("../systems/systems.zig");

const TextSnapshot = struct {
    text: []u8,
};

const EditorHistory = struct {
    undo: undo_redo.UndoRedoStack(TextSnapshot),
    last_snapshot: ?TextSnapshot = null,
};

var histories: ?std.AutoHashMap(workspace.PanelId, EditorHistory) = null;
var active_panel: ?*workspace.Panel = null;

pub fn draw(panel: *workspace.Panel, allocator: std.mem.Allocator) bool {
    if (panel.kind != .CodeEditor) return false;
    var editor = &panel.data.CodeEditor;
    const history = getHistory(allocator, panel.id);
    syncHistoryIfNeeded(history, editor.content.slice());

    components.core.file_row.draw(.{
        .filename = editor.file_id,
        .language = editor.language,
        .dirty = panel.state.is_dirty,
    });
    zgui.separator();

    const avail = zgui.getContentRegionAvail();
    const min_capacity = @max(@as(usize, 64 * 1024), editor.content.slice().len);
    _ = editor.content.ensureCapacity(allocator, min_capacity) catch {};

    const changed = zgui.inputTextMultiline("##code_editor", .{
        .buf = editor.content.asZ(),
        .h = avail[1] - zgui.getFrameHeightWithSpacing(),
        .flags = .{ .allow_tab_input = true },
    });
    if (zgui.isItemActive()) {
        const sys = ui_systems.get();
        sys.keyboard.setFocus("code_editor");
        active_panel = panel;
        registerShortcuts(sys);
    }

    if (changed) {
        const before = history.last_snapshot;
        editor.content.syncFromInput();
        editor.last_modified_by = .user;
        editor.version += 1;
        panel.state.is_dirty = true;
        if (before) |prev| {
            history.last_snapshot = null;
            if (snapshotAlloc(history.undo.allocator, editor.content.slice())) |after| {
                if (!std.mem.eql(u8, prev.text, after.text)) {
                    if (history.undo.execute(.{
                        .name = "edit",
                        .state_before = prev,
                        .state_after = after,
                    })) |_| {
                        updateLastSnapshot(history, after.text);
                    } else |_| {
                        history.last_snapshot = prev;
                        var after_mut = after;
                        freeSnapshot(&after_mut, history.undo.allocator);
                    }
                } else {
                    history.last_snapshot = prev;
                    var after_mut = after;
                    freeSnapshot(&after_mut, history.undo.allocator);
                }
            } else {
                history.last_snapshot = prev;
            }
        } else {
            updateLastSnapshot(history, editor.content.slice());
        }
    }

    zgui.separator();
    zgui.textDisabled("v{d} · {s}", .{
        editor.version,
        if (editor.last_modified_by == .user) "edited" else "ai",
    });
    return changed;
}

fn registerShortcuts(sys: *systems.Systems) void {
    _ = sys.keyboard.register(.{
        .id = "code_editor.undo",
        .key = .z,
        .ctrl = true,
        .scope = .focused,
        .focus_id = "code_editor",
        .action = onUndoShortcut,
    }) catch {};
    _ = sys.keyboard.register(.{
        .id = "code_editor.redo",
        .key = .y,
        .ctrl = true,
        .scope = .focused,
        .focus_id = "code_editor",
        .action = onRedoShortcut,
    }) catch {};
    _ = sys.keyboard.register(.{
        .id = "code_editor.redo_shift",
        .key = .z,
        .ctrl = true,
        .shift = true,
        .scope = .focused,
        .focus_id = "code_editor",
        .action = onRedoShortcut,
    }) catch {};
}

fn onUndoShortcut(_: ?*anyopaque) void {
    if (active_panel) |panel| {
        _ = applyUndo(panel);
    }
}

fn onRedoShortcut(_: ?*anyopaque) void {
    if (active_panel) |panel| {
        _ = applyRedo(panel);
    }
}

fn applyUndo(panel: *workspace.Panel) bool {
    if (panel.kind != .CodeEditor) return false;
    const history = getHistoryIfExists(panel.id) orelse return false;
    if (history.undo.undo()) |state| {
        const editor = &panel.data.CodeEditor;
        editor.content.set(history.undo.allocator, state.text) catch return false;
        editor.last_modified_by = .user;
        editor.version += 1;
        panel.state.is_dirty = true;
        updateLastSnapshot(history, state.text);
        return true;
    }
    return false;
}

fn applyRedo(panel: *workspace.Panel) bool {
    if (panel.kind != .CodeEditor) return false;
    const history = getHistoryIfExists(panel.id) orelse return false;
    if (history.undo.redo()) |state| {
        const editor = &panel.data.CodeEditor;
        editor.content.set(history.undo.allocator, state.text) catch return false;
        editor.last_modified_by = .user;
        editor.version += 1;
        panel.state.is_dirty = true;
        updateLastSnapshot(history, state.text);
        return true;
    }
    return false;
}

fn getHistory(allocator: std.mem.Allocator, id: workspace.PanelId) *EditorHistory {
    if (histories == null) {
        histories = std.AutoHashMap(workspace.PanelId, EditorHistory).init(allocator);
    }
    var map = &histories.?;
    const entry = map.getOrPut(id) catch unreachable;
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .undo = undo_redo.UndoRedoStack(TextSnapshot).init(allocator, 80, freeSnapshot),
            .last_snapshot = null,
        };
    }
    return entry.value_ptr;
}

fn getHistoryIfExists(id: workspace.PanelId) ?*EditorHistory {
    if (histories == null) return null;
    return histories.?.getPtr(id);
}

fn snapshotAlloc(allocator: std.mem.Allocator, text: []const u8) ?TextSnapshot {
    const copy = allocator.dupe(u8, text) catch return null;
    return .{ .text = copy };
}

fn freeSnapshot(state: *TextSnapshot, allocator: std.mem.Allocator) void {
    allocator.free(state.text);
}

fn updateLastSnapshot(history: *EditorHistory, text: []const u8) void {
    if (history.last_snapshot) |prev| {
        var prev_mut = prev;
        freeSnapshot(&prev_mut, history.undo.allocator);
    }
    history.last_snapshot = snapshotAlloc(history.undo.allocator, text);
}

fn syncHistoryIfNeeded(history: *EditorHistory, text: []const u8) void {
    if (history.last_snapshot == null) {
        history.last_snapshot = snapshotAlloc(history.undo.allocator, text);
        return;
    }
    const current = history.last_snapshot.?;
    if (!std.mem.eql(u8, current.text, text) and
        history.undo.undo_stack.items.len == 0 and
        history.undo.redo_stack.items.len == 0)
    {
        history.undo.clear();
        var current_mut = current;
        freeSnapshot(&current_mut, history.undo.allocator);
        history.last_snapshot = snapshotAlloc(history.undo.allocator, text);
    }
}
