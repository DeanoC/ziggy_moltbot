const std = @import("std");
const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const input_events = @import("../input/input_events.zig");
const text_input_backend = @import("../input/text_input_backend.zig");
const clipboard = @import("../clipboard.zig");
const theme = @import("../theme.zig");

pub const Options = struct {
    submit_on_enter: bool = true,
    read_only: bool = false,
    single_line: bool = false,
    mask_char: ?u8 = null,
};

pub const Action = struct {
    send: bool = false,
    changed: bool = false,
};

const Line = struct {
    start: usize,
    end: usize,
};

const Mask = struct {
    ch: u8,
    width: f32,
};

pub const TextEditor = struct {
    buffer: std.ArrayList(u8),
    cursor: usize = 0,
    selection_anchor: ?usize = null,
    scroll_y: f32 = 0.0,
    scroll_x: f32 = 0.0,
    focused: bool = false,
    dragging: bool = false,

    pub fn init(allocator: std.mem.Allocator) !TextEditor {
        _ = allocator;
        return .{ .buffer = std.ArrayList(u8).empty };
    }

    pub fn deinit(self: *TextEditor, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    pub fn isEmpty(self: *const TextEditor) bool {
        return self.buffer.items.len == 0;
    }

    pub fn slice(self: *const TextEditor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *TextEditor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.selection_anchor = null;
        self.scroll_y = 0.0;
        self.scroll_x = 0.0;
    }

    pub fn takeText(self: *TextEditor, allocator: std.mem.Allocator) ?[]u8 {
        if (self.buffer.items.len == 0) return null;
        const owned = allocator.dupe(u8, self.buffer.items) catch return null;
        self.clear();
        return owned;
    }

    pub fn setText(self: *TextEditor, allocator: std.mem.Allocator, text: []const u8) void {
        self.buffer.clearRetainingCapacity();
        if (text.len > 0) {
            self.buffer.appendSlice(allocator, text) catch {};
        }
        self.cursor = self.buffer.items.len;
        self.selection_anchor = null;
        self.scroll_y = 0.0;
        self.scroll_x = 0.0;
    }

    pub fn insertText(self: *TextEditor, allocator: std.mem.Allocator, text: []const u8) void {
        insertTextInternal(self, allocator, text);
    }

    pub fn hasSelection(self: *const TextEditor) bool {
        return self.selectionRange() != null;
    }

    pub fn copySelectionToClipboard(self: *TextEditor, allocator: std.mem.Allocator) bool {
        return copySelection(self, allocator);
    }

    pub fn draw(
        self: *TextEditor,
        allocator: std.mem.Allocator,
        ctx: *draw_context.DrawContext,
        rect: draw_context.Rect,
        queue: *input_state.InputQueue,
        opts: Options,
    ) Action {
        var action = Action{};
        const t = theme.activeTheme();
        const padding = .{ t.spacing.sm, t.spacing.xs };

        const text_min = .{ rect.min[0] + padding[0], rect.min[1] + padding[1] };
        const text_max = .{ rect.max[0] - padding[0], rect.max[1] - padding[1] };
        const text_rect = draw_context.Rect{ .min = text_min, .max = text_max };
        const wrap_width = if (opts.single_line) 10_000.0 else @max(4.0, text_rect.size()[0]);
        const line_height = ctx.lineHeight();
        const mask = if (opts.mask_char) |ch| Mask{
            .ch = ch,
            .width = ctx.measureText(&[1]u8{ch}, 0.0)[0],
        } else null;

        var lines = buildLines(ctx, allocator, self.buffer.items, wrap_width, opts.single_line, mask);
        defer lines.deinit(allocator);

        handleMouse(self, ctx, queue, rect, text_rect, &lines, opts.single_line, line_height, mask);
        const text_changed = handleInput(self, allocator, queue, &lines, opts, &action);
        action.changed = text_changed;

        if (text_changed) {
            lines.clearRetainingCapacity();
            buildLinesInto(ctx, allocator, self.buffer.items, wrap_width, &lines, opts.single_line, mask);
        }

        const view_height = text_rect.size()[1];
        const view_width = text_rect.size()[0];
        const content_height = @as(f32, @floatFromInt(lines.items.len)) * line_height;
        const max_scroll = if (opts.single_line) 0.0 else @max(0.0, content_height - view_height);
        if (!opts.single_line) {
            if (self.scroll_y < 0.0) self.scroll_y = 0.0;
            if (self.scroll_y > max_scroll) self.scroll_y = max_scroll;
        } else {
            self.scroll_y = 0.0;
        }

        const caret_pos = caretPosition(self.buffer.items, &lines, self.cursor, line_height, ctx, mask);
        if (opts.single_line) {
            const content_width = textWidth(ctx, self.buffer.items, mask);
            const max_scroll_x = @max(0.0, content_width - view_width);
            ensureCaretVisibleX(self, caret_pos[0], view_width, max_scroll_x);
        } else {
            self.scroll_x = 0.0;
            ensureCaretVisible(self, caret_pos[1], line_height, view_height, max_scroll);
        }

        drawBackground(ctx, rect, t);
        ctx.pushClip(rect);
        defer ctx.popClip();

        drawSelection(ctx, text_rect, &lines, self.buffer.items, self.selectionRange(), line_height, self.scroll_y, self.scroll_x, t, mask);
        drawText(ctx, text_rect, &lines, self.buffer.items, line_height, self.scroll_y, self.scroll_x, t, mask);
        if (self.focused) {
            drawCaret(ctx, text_rect, caret_pos, line_height, self.scroll_y, self.scroll_x, t);
        }

        if (self.focused and !opts.read_only) {
            const ime_pos = .{
                text_rect.min[0] + caret_pos[0] - self.scroll_x,
                text_rect.min[1] + caret_pos[1] - self.scroll_y,
            };
            text_input_backend.setActive(true);
            text_input_backend.setImeRect(ime_pos, line_height, true);
        } else {
            text_input_backend.setActive(false);
        }

        return action;
    }

    fn selectionRange(self: *const TextEditor) ?[2]usize {
        if (self.selection_anchor) |anchor| {
            if (anchor == self.cursor) return null;
            if (anchor < self.cursor) return .{ anchor, self.cursor };
            return .{ self.cursor, anchor };
        }
        return null;
    }
};

fn drawBackground(ctx: *draw_context.DrawContext, rect: draw_context.Rect, t: *const theme.Theme) void {
    ctx.drawRoundedRect(rect, t.radius.md, .{
        .fill = t.colors.surface,
        .stroke = t.colors.border,
        .thickness = 1.0,
    });
}

fn drawText(
    ctx: *draw_context.DrawContext,
    text_rect: draw_context.Rect,
    lines: *std.ArrayList(Line),
    text: []const u8,
    line_height: f32,
    scroll_y: f32,
    scroll_x: f32,
    t: *const theme.Theme,
    mask: ?Mask,
) void {
    for (lines.items, 0..) |line, idx| {
        const y = text_rect.min[1] + @as(f32, @floatFromInt(idx)) * line_height - scroll_y;
        if (y + line_height < text_rect.min[1] or y > text_rect.max[1]) continue;
        if (mask) |mask_info| {
            const count = countChars(text[line.start..line.end]);
            drawMaskedLine(ctx, .{ text_rect.min[0] - scroll_x, y }, count, mask_info, t.colors.text_primary);
        } else {
            const slice = text[line.start..line.end];
            ctx.drawText(slice, .{ text_rect.min[0] - scroll_x, y }, .{ .color = t.colors.text_primary });
        }
    }
}

fn drawSelection(
    ctx: *draw_context.DrawContext,
    text_rect: draw_context.Rect,
    lines: *std.ArrayList(Line),
    text: []const u8,
    selection: ?[2]usize,
    line_height: f32,
    scroll_y: f32,
    scroll_x: f32,
    t: *const theme.Theme,
    mask: ?Mask,
) void {
    if (selection == null) return;
    const sel = selection.?;
    const highlight = .{ t.colors.primary[0], t.colors.primary[1], t.colors.primary[2], 0.25 };
    for (lines.items, 0..) |line, idx| {
        if (sel[1] <= line.start or sel[0] >= line.end) continue;
        const line_sel_start = if (sel[0] > line.start) sel[0] else line.start;
        const line_sel_end = if (sel[1] < line.end) sel[1] else line.end;
        const left = textWidth(ctx, text[line.start..line_sel_start], mask);
        const right = textWidth(ctx, text[line.start..line_sel_end], mask);
        const y = text_rect.min[1] + @as(f32, @floatFromInt(idx)) * line_height - scroll_y;
        const rect = draw_context.Rect{
            .min = .{ text_rect.min[0] + left - scroll_x, y },
            .max = .{ text_rect.min[0] + right - scroll_x, y + line_height },
        };
        ctx.drawRect(rect, .{ .fill = highlight });
    }
}

fn drawCaret(
    ctx: *draw_context.DrawContext,
    text_rect: draw_context.Rect,
    caret_pos: [2]f32,
    line_height: f32,
    scroll_y: f32,
    scroll_x: f32,
    t: *const theme.Theme,
) void {
    const x = text_rect.min[0] + caret_pos[0] - scroll_x;
    const y = text_rect.min[1] + caret_pos[1] - scroll_y;
    const rect = draw_context.Rect{
        .min = .{ x, y },
        .max = .{ x + 1.5, y + line_height },
    };
    ctx.drawRect(rect, .{ .fill = t.colors.text_primary });
}

fn handleMouse(
    editor: *TextEditor,
    ctx: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    text_rect: draw_context.Rect,
    lines: *std.ArrayList(Line),
    single_line: bool,
    line_height: f32,
    mask: ?Mask,
) void {
    const mouse = queue.state.mouse_pos;
    const inside = rect.contains(mouse);
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button != .left) continue;
                if (inside) {
                    editor.focused = true;
                    editor.dragging = true;
                    const local = .{ mouse[0] - text_rect.min[0] + editor.scroll_x, mouse[1] - text_rect.min[1] };
                    editor.cursor = cursorFromPosition(ctx, editor.buffer.items, lines, local, editor.scroll_y, editor.scroll_x, line_height, mask);
                    editor.selection_anchor = editor.cursor;
                } else {
                    editor.focused = false;
                    editor.dragging = false;
                    editor.selection_anchor = null;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    editor.dragging = false;
                }
            },
            .mouse_wheel => |mw| {
                if (inside and !single_line) {
                    editor.scroll_y -= mw.delta[1] * 24.0;
                }
            },
            else => {},
        }
    }

    if (editor.dragging) {
        if (inside) {
            const local = .{ mouse[0] - text_rect.min[0] + editor.scroll_x, mouse[1] - text_rect.min[1] };
            editor.cursor = cursorFromPosition(ctx, editor.buffer.items, lines, local, editor.scroll_y, editor.scroll_x, line_height, mask);
        }
    }
}

fn handleInput(
    editor: *TextEditor,
    allocator: std.mem.Allocator,
    queue: *input_state.InputQueue,
    lines: *std.ArrayList(Line),
    opts: Options,
    action: *Action,
) bool {
    if (!editor.focused) return false;
    var changed = false;
    const read_only = opts.read_only;
    const single_line = opts.single_line;
    for (queue.events.items) |evt| {
        switch (evt) {
            .text_input => |ti| {
                if (!read_only) {
                    if (single_line) {
                        if (insertTextSingleLine(editor, allocator, ti.text)) {
                            changed = true;
                        }
                    } else {
                        insertTextInternal(editor, allocator, ti.text);
                        changed = true;
                    }
                }
            },
            .key_down => |key_evt| {
                const mods = key_evt.mods;
                const shift = mods.shift;
                const ctrl = mods.ctrl;
                switch (key_evt.key) {
                    .left_arrow => moveCursor(editor, lines, .left, shift),
                    .right_arrow => moveCursor(editor, lines, .right, shift),
                    .up_arrow => moveCursor(editor, lines, .up, shift),
                    .down_arrow => moveCursor(editor, lines, .down, shift),
                    .home => moveCursor(editor, lines, .line_start, shift),
                    .end => moveCursor(editor, lines, .line_end, shift),
                    .back_space => {
                        if (!read_only) {
                            if (deleteSelection(editor)) {
                                changed = true;
                            } else if (editor.cursor > 0) {
                                const prev = prevCharIndex(editor.buffer.items, editor.cursor);
                                removeRange(editor, prev, editor.cursor);
                                changed = true;
                            }
                        }
                    },
                    .delete => {
                        if (!read_only) {
                            if (deleteSelection(editor)) {
                                changed = true;
                            } else if (editor.cursor < editor.buffer.items.len) {
                                const next = nextCharIndex(editor.buffer.items, editor.cursor);
                                removeRange(editor, editor.cursor, next);
                                changed = true;
                            }
                        }
                    },
                    .enter, .keypad_enter => {
                        if (!read_only) {
                            if (opts.submit_on_enter and !shift) {
                                action.send = true;
                            } else if (!single_line) {
                                insertTextInternal(editor, allocator, "\n");
                                changed = true;
                            }
                        }
                    },
                    .a => if (ctrl) {
                        editor.selection_anchor = 0;
                        editor.cursor = editor.buffer.items.len;
                    },
                    .c => if (ctrl) {
                        _ = copySelection(editor, allocator);
                    },
                    .x => if (ctrl) {
                        if (!read_only) {
                            if (copySelection(editor, allocator)) {
                                _ = deleteSelection(editor);
                                changed = true;
                            }
                        }
                    },
                    .v => if (ctrl) {
                        if (!read_only) {
                            if (single_line) {
                                pasteClipboardSingleLine(editor, allocator);
                            } else {
                                pasteClipboard(editor, allocator);
                            }
                            changed = true;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    return changed;
}

fn insertTextInternal(editor: *TextEditor, allocator: std.mem.Allocator, text: []const u8) void {
    if (text.len == 0) return;
    _ = deleteSelection(editor);
    editor.buffer.insertSlice(allocator, editor.cursor, text) catch return;
    editor.cursor += text.len;
    editor.selection_anchor = null;
}

fn insertTextSingleLine(editor: *TextEditor, allocator: std.mem.Allocator, text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.indexOfAny(u8, text, "\r\n") == null) {
        insertTextInternal(editor, allocator, text);
        return true;
    }
    var filtered = std.ArrayList(u8).empty;
    defer filtered.deinit(allocator);
    for (text) |ch| {
        if (ch == '\n' or ch == '\r') continue;
        filtered.append(allocator, ch) catch {};
    }
    if (filtered.items.len == 0) return false;
    insertTextInternal(editor, allocator, filtered.items);
    return true;
}

fn deleteSelection(editor: *TextEditor) bool {
    const range = editor.selectionRange() orelse return false;
    removeRange(editor, range[0], range[1]);
    editor.selection_anchor = null;
    return true;
}

fn removeRange(editor: *TextEditor, start: usize, end: usize) void {
    if (end <= start) return;
    const len = editor.buffer.items.len;
    if (start >= len) return;
    const clamped_end = if (end > len) len else end;
    const tail_len = len - clamped_end;
    if (tail_len > 0) {
        std.mem.copyForwards(u8, editor.buffer.items[start..], editor.buffer.items[clamped_end..]);
    }
    editor.buffer.items.len = len - (clamped_end - start);
    editor.cursor = start;
}

fn copySelection(editor: *TextEditor, allocator: std.mem.Allocator) bool {
    const range = editor.selectionRange() orelse return false;
    const slice = editor.buffer.items[range[0]..range[1]];
    if (slice.len == 0) return false;
    const buf = allocator.alloc(u8, slice.len + 1) catch return false;
    defer allocator.free(buf);
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    clipboard.setTextZ(buf[0.. :0]);
    return true;
}

fn pasteClipboard(editor: *TextEditor, allocator: std.mem.Allocator) void {
    const text_z = clipboard.getTextZ();
    const text = std.mem.sliceTo(text_z, 0);
    if (text.len == 0) return;
    insertTextInternal(editor, allocator, text);
}

fn pasteClipboardSingleLine(editor: *TextEditor, allocator: std.mem.Allocator) void {
    const text_z = clipboard.getTextZ();
    const text = std.mem.sliceTo(text_z, 0);
    if (text.len == 0) return;
    _ = insertTextSingleLine(editor, allocator, text);
}

const MoveDir = enum { left, right, up, down, line_start, line_end };

fn moveCursor(editor: *TextEditor, lines: *std.ArrayList(Line), dir: MoveDir, shift: bool) void {
    const old_cursor = editor.cursor;
    if (!shift) editor.selection_anchor = null;
    switch (dir) {
        .left => {
            if (editor.cursor > 0) editor.cursor = prevCharIndex(editor.buffer.items, editor.cursor);
        },
        .right => {
            if (editor.cursor < editor.buffer.items.len) editor.cursor = nextCharIndex(editor.buffer.items, editor.cursor);
        },
        .line_start => {
            if (lineForIndex(lines, editor.cursor)) |info| {
                editor.cursor = info.line.start;
            } else {
                editor.cursor = 0;
            }
        },
        .line_end => {
            if (lineForIndex(lines, editor.cursor)) |info| {
                editor.cursor = info.line.end;
            } else {
                editor.cursor = editor.buffer.items.len;
            }
        },
        .up => moveVertical(editor, lines, -1),
        .down => moveVertical(editor, lines, 1),
    }
    if (shift and editor.selection_anchor == null) {
        editor.selection_anchor = old_cursor;
    }
}

fn moveVertical(editor: *TextEditor, lines: *std.ArrayList(Line), delta: i32) void {
    if (lineForIndex(lines, editor.cursor)) |info| {
        const next_line_index = @as(i32, @intCast(info.index)) + delta;
        if (next_line_index < 0 or next_line_index >= @as(i32, @intCast(lines.items.len))) return;
        const target = lines.items[@intCast(next_line_index)];
        const offset = editor.cursor - info.line.start;
        const target_len = target.end - target.start;
        const clamped = if (offset > target_len) target_len else offset;
        editor.cursor = target.start + clamped;
    }
}

fn lineForIndex(lines: *std.ArrayList(Line), index: usize) ?struct { line: Line, index: usize } {
    for (lines.items, 0..) |line, idx| {
        if (index >= line.start and index <= line.end) {
            return .{ .line = line, .index = idx };
        }
    }
    return null;
}

fn caretPosition(text: []const u8, lines: *std.ArrayList(Line), cursor: usize, line_height: f32, ctx: *draw_context.DrawContext, mask: ?Mask) [2]f32 {
    if (lines.items.len == 0) return .{ 0.0, 0.0 };
    if (lineForIndex(lines, cursor)) |info| {
        const slice = text[info.line.start..cursor];
        const width = textWidth(ctx, slice, mask);
        return .{ width, @as(f32, @floatFromInt(info.index)) * line_height };
    }
    const last_idx = lines.items.len - 1;
    const last_line = lines.items[last_idx];
    const width = textWidth(ctx, text[last_line.start..last_line.end], mask);
    return .{ width, @as(f32, @floatFromInt(last_idx)) * line_height };
}

fn ensureCaretVisible(editor: *TextEditor, caret_y: f32, line_height: f32, view_height: f32, max_scroll: f32) void {
    if (caret_y < editor.scroll_y) {
        editor.scroll_y = caret_y;
    } else if (caret_y + line_height > editor.scroll_y + view_height) {
        editor.scroll_y = caret_y + line_height - view_height;
    }
    if (editor.scroll_y < 0.0) editor.scroll_y = 0.0;
    if (editor.scroll_y > max_scroll) editor.scroll_y = max_scroll;
}

fn ensureCaretVisibleX(editor: *TextEditor, caret_x: f32, view_width: f32, max_scroll: f32) void {
    if (caret_x < editor.scroll_x) {
        editor.scroll_x = caret_x;
    } else if (caret_x > editor.scroll_x + view_width) {
        editor.scroll_x = caret_x - view_width;
    }
    if (editor.scroll_x < 0.0) editor.scroll_x = 0.0;
    if (editor.scroll_x > max_scroll) editor.scroll_x = max_scroll;
}

fn cursorFromPosition(
    ctx: *draw_context.DrawContext,
    text: []const u8,
    lines: *std.ArrayList(Line),
    local_pos: [2]f32,
    scroll_y: f32,
    scroll_x: f32,
    line_height: f32,
    mask: ?Mask,
) usize {
    _ = scroll_x;
    const y = local_pos[1] + scroll_y;
    var line_index = @as(i32, @intFromFloat(@floor(y / line_height)));
    if (line_index < 0) line_index = 0;
    if (line_index >= @as(i32, @intCast(lines.items.len))) {
        if (lines.items.len == 0) return 0;
        line_index = @as(i32, @intCast(lines.items.len - 1));
    }
    const line = lines.items[@intCast(line_index)];
    const x = if (local_pos[0] < 0.0) 0.0 else local_pos[0];
    return indexAtX(ctx, text, line, x, mask);
}

fn indexAtX(ctx: *draw_context.DrawContext, text: []const u8, line: Line, x: f32, mask: ?Mask) usize {
    var idx = line.start;
    var cur_x: f32 = 0.0;
    while (idx < line.end) {
        const next = nextCharIndex(text, idx);
        const slice = text[idx..next];
        const char_w = charWidth(ctx, slice, mask);
        if (cur_x + char_w * 0.5 >= x) break;
        cur_x += char_w;
        idx = next;
    }
    return idx;
}

fn drawMaskedLine(
    ctx: *draw_context.DrawContext,
    pos: [2]f32,
    count: usize,
    mask: Mask,
    color: draw_context.Color,
) void {
    if (count == 0) return;
    var buf: [128]u8 = undefined;
    var remaining = count;
    var x = pos[0];
    while (remaining > 0) {
        const chunk = if (remaining > buf.len) buf.len else remaining;
        @memset(buf[0..chunk], mask.ch);
        ctx.drawText(buf[0..chunk], .{ x, pos[1] }, .{ .color = color });
        x += mask.width * @as(f32, @floatFromInt(chunk));
        remaining -= chunk;
    }
}

fn countChars(text: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (idx < text.len) {
        idx = nextCharIndex(text, idx);
        count += 1;
    }
    return count;
}

fn charWidth(ctx: *draw_context.DrawContext, slice: []const u8, mask: ?Mask) f32 {
    if (mask) |mask_info| {
        return mask_info.width;
    }
    return ctx.measureText(slice, 0.0)[0];
}

fn textWidth(ctx: *draw_context.DrawContext, text: []const u8, mask: ?Mask) f32 {
    if (mask) |mask_info| {
        return @as(f32, @floatFromInt(countChars(text))) * mask_info.width;
    }
    return ctx.measureText(text, 0.0)[0];
}

fn nextCharIndex(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const first = text[index];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const next = index + @as(usize, len);
    return if (next > text.len) text.len else next;
}

fn prevCharIndex(text: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var i = index - 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return i;
}

fn buildLines(
    ctx: *draw_context.DrawContext,
    allocator: std.mem.Allocator,
    text: []const u8,
    wrap_width: f32,
    single_line: bool,
    mask: ?Mask,
) std.ArrayList(Line) {
    var lines = std.ArrayList(Line).empty;
    buildLinesInto(ctx, allocator, text, wrap_width, &lines, single_line, mask);
    return lines;
}

fn buildLinesInto(
    ctx: *draw_context.DrawContext,
    allocator: std.mem.Allocator,
    text: []const u8,
    wrap_width: f32,
    lines: *std.ArrayList(Line),
    single_line: bool,
    mask: ?Mask,
) void {
    lines.clearRetainingCapacity();
    if (single_line) {
        _ = lines.append(allocator, .{ .start = 0, .end = text.len }) catch {};
        return;
    }
    const effective_wrap = if (wrap_width <= 1.0) 10_000.0 else wrap_width;
    var line_start: usize = 0;
    var line_width: f32 = 0.0;
    var last_space: ?usize = null;
    var index: usize = 0;

    while (index < text.len) {
        const ch = text[index];
        if (ch == '\n') {
            _ = lines.append(allocator, .{ .start = line_start, .end = index }) catch {};
            index += 1;
            line_start = index;
            line_width = 0.0;
            last_space = null;
            continue;
        }

        const next = nextCharIndex(text, index);
        const slice = text[index..next];
        const char_w = charWidth(ctx, slice, mask);

        if (ch == ' ' or ch == '\t') {
            last_space = next;
        }

        if (line_width + char_w > effective_wrap and line_width > 0.0) {
            if (last_space != null and last_space.? > line_start) {
                _ = lines.append(allocator, .{ .start = line_start, .end = last_space.? - 1 }) catch {};
                index = last_space.?; // continue from char after space
            } else {
                _ = lines.append(allocator, .{ .start = line_start, .end = index }) catch {};
            }
            line_start = index;
            line_width = 0.0;
            last_space = null;
            continue;
        }

        line_width += char_w;
        index = next;
    }

    _ = lines.append(allocator, .{ .start = line_start, .end = text.len }) catch {};
}
