const std = @import("std");
const workspace = @import("../workspace.zig");
const draw_context = @import("../draw_context.zig");
const input_router = @import("../input/input_router.zig");
const theme = @import("../theme.zig");
const colors = @import("../theme/colors.zig");
const text_editor = @import("../widgets/text_editor.zig");
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

pub fn draw(panel: *workspace.Panel, allocator: std.mem.Allocator, rect_override: ?draw_context.Rect) bool {
    if (panel.kind != .CodeEditor) return false;
    var editor = &panel.data.CodeEditor;
    const history = getHistory(allocator, panel.id);
    syncHistoryIfNeeded(history, editor.content.slice());

    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return false;
    var ctx = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer ctx.deinit();
    ctx.drawRect(panel_rect, .{ .fill = t.colors.background });

    const header_height = drawHeader(&ctx, panel_rect, editor, panel.state.is_dirty);
    const footer_height = drawFooter(&ctx, panel_rect, editor);
    const body_top = panel_rect.min[1] + header_height + t.spacing.sm;
    const body_bottom = panel_rect.max[1] - footer_height - t.spacing.sm;
    const body_height = body_bottom - body_top;
    const body_width = panel_rect.size()[0] - t.spacing.md * 2.0;
    if (body_height <= 0.0 or body_width <= 0.0) return false;

    const editor_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0] + t.spacing.md, body_top },
        .{ body_width, body_height },
    );

    if (editor.editor == null) {
        editor.editor = text_editor.TextEditor.init(allocator) catch null;
    }
    if (editor.editor) |*text_editor_state| {
        const content_hash = std.hash.Wyhash.hash(0, editor.content.slice());
        if (content_hash != editor.editor_hash) {
            text_editor_state.setText(allocator, editor.content.slice());
            editor.editor_hash = content_hash;
        }

        const queue = input_router.getQueue();
        const edit_action = text_editor_state.draw(
            allocator,
            &ctx,
            editor_rect,
            queue,
            .{ .submit_on_enter = false },
        );

        if (text_editor_state.focused) {
            const sys = ui_systems.get();
            sys.keyboard.setFocus("code_editor");
            active_panel = panel;
            registerShortcuts(sys);
        }

        if (edit_action.changed) {
            const before = history.last_snapshot;
            const new_text = text_editor_state.slice();
            editor.content.set(allocator, new_text) catch {};
            editor.editor_hash = std.hash.Wyhash.hash(0, new_text);
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

        return edit_action.changed;
    }

    return false;
}

fn drawHeader(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    editor: *workspace.CodeEditorPanel,
    dirty: bool,
) f32 {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const left = rect.min[0] + t.spacing.md;
    const title_y = rect.min[1] + top_pad;

    theme.push(.heading);
    const title_height = ctx.lineHeight();
    ctx.drawText(editor.file_id, .{ left, title_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    var cursor_x = left + ctx.measureText(editor.file_id, 0.0)[0] + t.spacing.sm;
    const badge_y = title_y;
    if (editor.language.len > 0) {
        cursor_x += drawBadge(ctx, .{ cursor_x, badge_y }, editor.language, t.colors.primary, t);
        cursor_x += t.spacing.xs;
    }
    if (dirty) {
        _ = drawBadge(ctx, .{ cursor_x, badge_y }, "modified", t.colors.warning, t);
    }

    return top_pad + title_height + t.spacing.sm;
}

fn drawFooter(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    editor: *workspace.CodeEditorPanel,
) f32 {
    const t = theme.activeTheme();
    const line_height = ctx.lineHeight();
    const height = line_height + t.spacing.sm * 2.0;
    const pos = .{ rect.min[0] + t.spacing.md, rect.max[1] - height + t.spacing.sm };
    var buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(
        &buf,
        "v{d} · {s}",
        .{ editor.version, if (editor.last_modified_by == .user) "edited" else "ai" },
    ) catch "v0 · ai";
    ctx.drawText(label, pos, .{ .color = t.colors.text_secondary });
    return height;
}

fn drawBadge(
    ctx: *draw_context.DrawContext,
    pos: [2]f32,
    label: []const u8,
    base: [4]f32,
    t: *const theme.Theme,
) f32 {
    const text_size = ctx.measureText(label, 0.0);
    const pad_x = t.spacing.xs;
    const pad_y = t.spacing.xs * 0.5;
    const size = .{ text_size[0] + pad_x * 2.0, text_size[1] + pad_y * 2.0 };
    const rect = draw_context.Rect.fromMinSize(pos, size);
    ctx.drawRoundedRect(rect, t.radius.lg, .{
        .fill = colors.withAlpha(base, 0.18),
        .stroke = colors.withAlpha(base, 0.4),
        .thickness = 1.0,
    });
    ctx.drawText(label, .{ pos[0] + pad_x, pos[1] + pad_y }, .{ .color = base });
    return size[0];
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
