const std = @import("std");
const ui_systems = @import("ui_systems.zig");
const draw_context = @import("draw_context.zig");
const text_editor = @import("widgets/text_editor.zig");
const widgets = @import("widgets/widgets.zig");
const input_state = @import("input/input_state.zig");
const theme_runtime = @import("theme_engine/runtime.zig");

const hint = "Message (⏎ to send, Shift+⏎ for line breaks, paste images)";

var editor_state: ?text_editor.TextEditor = null;
var emoji_open = false;

fn computeEmojiPickerRect(t: anytype, anchor: draw_context.Rect) draw_context.Rect {
    const emojis_len: usize = 24;
    const cols: usize = 6;
    const rows: usize = (emojis_len + cols - 1) / cols;
    const cell = anchor.size()[1];
    const gap = t.spacing.xs;
    const padding = t.spacing.xs;
    const picker_w = @as(f32, @floatFromInt(cols)) * cell + @as(f32, @floatFromInt(cols - 1)) * gap + padding * 2.0;
    const picker_h = @as(f32, @floatFromInt(rows)) * cell + @as(f32, @floatFromInt(rows - 1)) * gap + padding * 2.0;

    var picker_min = .{ anchor.min[0], anchor.min[1] - picker_h - gap };
    if (picker_min[1] < 0.0) {
        picker_min[1] = anchor.max[1] + gap;
    }
    return draw_context.Rect.fromMinSize(picker_min, .{ picker_w, picker_h });
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (editor_state) |*editor| editor.deinit(allocator);
    editor_state = null;
    emoji_open = false;
}

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    editor_enabled: bool,
    send_enabled: bool,
) ?[]u8 {
    if (editor_state == null) {
        editor_state = text_editor.TextEditor.init(allocator) catch null;
    }
    if (editor_state == null) return null;
    const editor = &editor_state.?;

    const t = ctx.theme;
    const line_h = ctx.lineHeight();
    const button_height = @max(widgets.button.defaultHeight(t, line_h), theme_runtime.getProfile().hit_target_min_px);
    const gap = t.spacing.xs;
    var editor_height = rect.size()[1] - button_height - gap;
    if (editor_height < 40.0) {
        editor_height = @max(20.0, rect.size()[1] - button_height);
    }

    const editor_rect = draw_context.Rect.fromMinSize(rect.min, .{ rect.size()[0], editor_height });
    const row_y = editor_rect.max[1] + gap;

    var disabled_queue = input_state.InputQueue{ .events = .empty, .state = .{} };
    disabled_queue.state.mouse_pos = .{ -10000.0, -10000.0 };
    const active_queue = if (editor_enabled) queue else &disabled_queue;

    const emoji_label = "😀";
    const emoji_width = button_height;
    const emoji_rect = draw_context.Rect.fromMinSize(.{ rect.min[0], row_y }, .{ emoji_width, button_height });

    if (!editor_enabled) {
        editor.focused = false;
        editor.dragging = false;
    }

    // If the emoji picker is open, clicks within the picker should not move the caret in the
    // underlying text editor (prevent click-through).
    var saved_mouse_pos: [16]struct { idx: usize, pos: [2]f32 } = undefined;
    var saved_mouse_pos_len: usize = 0;
    if (emoji_open and editor_enabled) {
        const picker_rect = computeEmojiPickerRect(t, emoji_rect);
        for (active_queue.events.items, 0..) |*evt, i| {
            switch (evt.*) {
                .mouse_down => |md| {
                    if (md.button == .left and picker_rect.contains(md.pos)) {
                        if (saved_mouse_pos_len < saved_mouse_pos.len) {
                            saved_mouse_pos[saved_mouse_pos_len] = .{ .idx = i, .pos = md.pos };
                            saved_mouse_pos_len += 1;
                            evt.* = .{ .mouse_down = .{ .button = md.button, .pos = .{ -10000.0, -10000.0 } } };
                        }
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left and picker_rect.contains(mu.pos)) {
                        if (saved_mouse_pos_len < saved_mouse_pos.len) {
                            saved_mouse_pos[saved_mouse_pos_len] = .{ .idx = i, .pos = mu.pos };
                            saved_mouse_pos_len += 1;
                            evt.* = .{ .mouse_up = .{ .button = mu.button, .pos = .{ -10000.0, -10000.0 } } };
                        }
                    }
                },
                else => {},
            }
        }
    }

    const action = editor.draw(allocator, ctx, editor_rect, active_queue, .{ .submit_on_enter = true });

    // Restore masked mouse event positions so the picker can still handle the click.
    if (saved_mouse_pos_len > 0) {
        var j: usize = 0;
        while (j < saved_mouse_pos_len) : (j += 1) {
            const entry = saved_mouse_pos[j];
            if (entry.idx < active_queue.events.items.len) {
                const evt = &active_queue.events.items[entry.idx];
                switch (evt.*) {
                    .mouse_down => |md| {
                        evt.* = .{ .mouse_down = .{ .button = md.button, .pos = entry.pos } };
                    },
                    .mouse_up => |mu| {
                        evt.* = .{ .mouse_up = .{ .button = mu.button, .pos = entry.pos } };
                    },
                    else => {},
                }
            }
        }
    }

    if (editor.focused) {
        const sys = ui_systems.get();
        sys.keyboard.setFocus("chat_input");
    }

    if (!editor.focused and editor.isEmpty()) {
        const pos = .{ editor_rect.min[0] + t.spacing.sm, editor_rect.min[1] + t.spacing.xs };
        ctx.drawText(hint, pos, .{ .color = t.colors.text_secondary });
    }

    var send = action.send;
    if (widgets.button.draw(ctx, emoji_rect, emoji_label, active_queue, .{
        .variant = .ghost,
        .disabled = !editor_enabled,
        .radius = t.radius.sm,
    })) {
        emoji_open = !emoji_open;
    }
    if (!editor_enabled) {
        emoji_open = false;
    }

    const send_label = "Send";
    const send_width = ctx.measureText(send_label, 0.0)[0] + t.spacing.md * 2.0;
    const send_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - send_width, row_y },
        .{ send_width, button_height },
    );
    if (widgets.button.draw(ctx, send_rect, send_label, active_queue, .{
        .variant = .primary,
        .disabled = !editor_enabled or !send_enabled,
        .radius = t.radius.sm,
    })) {
        send = true;
    }

    if (emoji_open and editor_enabled) {
        drawEmojiPicker(allocator, ctx, active_queue, emoji_rect, editor);
    }

    if (!send_enabled) send = false;
    if (!send or !editor_enabled) return null;
    return editor.takeText(allocator);
}

fn drawEmojiPicker(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    anchor: draw_context.Rect,
    editor: *text_editor.TextEditor,
) void {
    const t = ctx.theme;
    const emojis = [_][]const u8{
        "😀", "😁",   "😂", "🤣", "😊", "😍",    "😎", "🤔", "🙌", "👍", "🔥", "🎉",
        "✅",  "⚠️", "❌",  "💡", "🧪", "🛠️", "📌", "📎", "📝", "🚀", "🐛", "🧠",
    };
    const cols: usize = 6;
    const rows: usize = (emojis.len + cols - 1) / cols;
    const cell = anchor.size()[1];
    const gap = t.spacing.xs;
    const padding = t.spacing.xs;
    const picker_w = @as(f32, @floatFromInt(cols)) * cell + @as(f32, @floatFromInt(cols - 1)) * gap + padding * 2.0;
    const picker_h = @as(f32, @floatFromInt(rows)) * cell + @as(f32, @floatFromInt(rows - 1)) * gap + padding * 2.0;

    var picker_min = .{ anchor.min[0], anchor.min[1] - picker_h - gap };
    if (picker_min[1] < 0.0) {
        picker_min[1] = anchor.max[1] + gap;
    }
    const picker_rect = draw_context.Rect.fromMinSize(picker_min, .{ picker_w, picker_h });

    var clicked_outside = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and !picker_rect.contains(md.pos) and !anchor.contains(md.pos)) {
                    clicked_outside = true;
                }
            },
            else => {},
        }
    }
    if (clicked_outside) {
        emoji_open = false;
        return;
    }

    ctx.drawRoundedRect(picker_rect, t.radius.sm, .{
        .fill = t.colors.surface,
        .stroke = t.colors.border,
        .thickness = 1.0,
    });

    var index: usize = 0;
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            if (index >= emojis.len) break;
            const x = picker_min[0] + padding + @as(f32, @floatFromInt(col)) * (cell + gap);
            const y = picker_min[1] + padding + @as(f32, @floatFromInt(row)) * (cell + gap);
            const cell_rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ cell, cell });
            if (widgets.button.draw(ctx, cell_rect, emojis[index], queue, .{
                .variant = .ghost,
                .radius = t.radius.sm,
            })) {
                editor.insertText(allocator, emojis[index]);
                emoji_open = false;
            }
            index += 1;
        }
    }
}
