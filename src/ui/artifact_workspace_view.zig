const std = @import("std");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const clipboard = @import("clipboard.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const text_editor = @import("widgets/text_editor.zig");
const ui_systems = @import("ui_systems.zig");
const undo_redo = @import("systems/undo_redo.zig");
const systems = @import("systems/systems.zig");

const ArtifactTab = enum {
    preview,
    edit,
};

var active_tab: ArtifactTab = .preview;
var preview_scroll_y: f32 = 0.0;
var preview_scroll_max: f32 = 0.0;

var editor_state: ?text_editor.TextEditor = null;
var edit_initialized = false;
var undo_stack: ?undo_redo.UndoRedoStack(EditState) = null;

const EditState = struct {
    len: usize,
    buf: [4096]u8,
};

const ToolbarIcon = enum {
    copy,
    undo,
    redo,
    expand,
};

const Line = struct {
    start: usize,
    end: usize,
};

pub fn deinit(allocator: std.mem.Allocator) void {
    _ = allocator;
    if (editor_state) |*editor| editor.deinit(std.heap.page_allocator);
    editor_state = null;
    edit_initialized = false;
    if (undo_stack) |*stack| stack.deinit();
    undo_stack = null;
    preview_scroll_y = 0.0;
    preview_scroll_max = 0.0;
}

pub fn draw(rect_override: ?draw_context.Rect) void {
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return;
    var dc = draw_context.DrawContext.init(std.heap.page_allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();

    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&dc, panel_rect);
    const tabs_height = drawTabs(&dc, panel_rect, header.height, queue);

    const toolbar_height = toolbarHeight(t);
    const toolbar_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], panel_rect.max[1] - toolbar_height },
        .{ panel_rect.size()[0], toolbar_height },
    );

    const content_top = panel_rect.min[1] + header.height + tabs_height + t.spacing.sm;
    const content_bottom = toolbar_rect.min[1] - t.spacing.sm;
    const content_height = content_bottom - content_top;
    if (content_height <= 0.0) {
        drawToolbar(&dc, toolbar_rect, queue);
        return;
    }

    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], content_height },
    );

    switch (active_tab) {
        .preview => drawPreview(&dc, content_rect, queue),
        .edit => drawEditor(&dc, content_rect, queue),
    }

    drawToolbar(&dc, toolbar_rect, queue);
}

fn drawHeader(dc: *draw_context.DrawContext, rect: draw_context.Rect) struct { height: f32 } {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Artifact Workspace", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Preview & Edit", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    const height = top_pad + title_height + gap + subtitle_height + top_pad;
    return .{ .height = height };
}

fn drawTabs(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    header_height: f32,
    queue: *input_state.InputQueue,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const tab_height = line_height + t.spacing.xs * 2.0;

    const y = rect.min[1] + header_height + t.spacing.sm;
    var cursor_x = rect.min[0] + t.spacing.md;

    const preview_label = "Preview";
    const preview_width = tabWidth(dc, preview_label, t);
    const preview_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ preview_width, tab_height });
    if (drawTab(dc, preview_rect, preview_label, active_tab == .preview, queue)) {
        active_tab = .preview;
    }
    cursor_x += preview_width + t.spacing.sm;

    const edit_label = "Edit";
    const edit_width = tabWidth(dc, edit_label, t);
    const edit_rect = draw_context.Rect.fromMinSize(.{ cursor_x, y }, .{ edit_width, tab_height });
    if (drawTab(dc, edit_rect, edit_label, active_tab == .edit, queue)) {
        active_tab = .edit;
    }

    return tab_height;
}

fn drawPreview(dc: *draw_context.DrawContext, rect: draw_context.Rect, queue: *input_state.InputQueue) void {
    const t = theme.activeTheme();
    handleWheelScroll(queue, rect, &preview_scroll_y, preview_scroll_max, 36.0);

    dc.pushClip(rect);
    var y = rect.min[1] + t.spacing.md - preview_scroll_y;
    const x = rect.min[0] + t.spacing.md;
    const width = rect.size()[0] - t.spacing.md * 2.0;

    y += drawSummaryCard(dc, .{ x, y }, width) + t.spacing.md;
    y += drawInsightsCard(dc, .{ x, y }, width) + t.spacing.md;
    y += drawChartCard(dc, .{ x, y }, width) + t.spacing.md;

    dc.popClip();

    const content_height = (y + preview_scroll_y) - rect.min[1];
    preview_scroll_max = @max(0.0, content_height - rect.size()[1]);
    if (preview_scroll_y > preview_scroll_max) preview_scroll_y = preview_scroll_max;
    if (preview_scroll_y < 0.0) preview_scroll_y = 0.0;
}

fn drawEditor(dc: *draw_context.DrawContext, rect: draw_context.Rect, queue: *input_state.InputQueue) void {
    const t = theme.activeTheme();

    if (editor_state == null) {
        editor_state = text_editor.TextEditor.init(std.heap.page_allocator) catch null;
    }
    if (editor_state == null) return;
    const editor = &editor_state.?;

    if (!edit_initialized) {
        const seed =
            "## Report Summary\n\n" ++
            "Write a concise summary of the report findings.\n\n" ++
            "## Key Insights\n\n" ++
            "- Insight 1\n" ++
            "- Insight 2\n\n" ++
            "## Action Items\n\n" ++
            "- Follow up with sales leadership\n";
        editor.setText(std.heap.page_allocator, seed);
        ensureUndoStack();
        edit_initialized = true;
    }

    const editor_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.md, rect.min[1] + t.spacing.md },
        .{ rect.size()[0] - t.spacing.md * 2.0, rect.size()[1] - t.spacing.md * 2.0 },
    );

    const before = captureState(editor);
    _ = editor.draw(std.heap.page_allocator, dc, editor_rect, queue, .{ .submit_on_enter = false });

    if (editor.focused) {
        const sys = ui_systems.get();
        sys.keyboard.setFocus("artifact_editor");
        registerShortcuts(sys);
    }

    const after = captureState(editor);
    if (!statesEqual(before, after)) {
        ensureUndoStack();
        if (undo_stack) |*stack| {
            _ = stack.execute(.{
                .name = "edit",
                .state_before = before,
                .state_after = after,
            }) catch {};
        }
    }

    if (!editor.focused and editor.isEmpty()) {
        const padding = .{ t.spacing.sm, t.spacing.xs };
        const pos = .{ editor_rect.min[0] + padding[0], editor_rect.min[1] + padding[1] };
        dc.drawText("Start typing...", pos, .{ .color = t.colors.text_secondary });
    }
}

fn drawToolbar(dc: *draw_context.DrawContext, rect: draw_context.Rect, queue: *input_state.InputQueue) void {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const icon_size = toolbarIconSize(t);

    dc.drawRect(rect, .{ .fill = t.colors.background });
    dc.drawRect(draw_context.Rect.fromMinSize(.{ rect.min[0], rect.min[1] }, .{ rect.size()[0], 1.0 }), .{ .fill = t.colors.divider });

    var cursor_x = rect.min[0] + padding;
    const y = rect.min[1] + (rect.size()[1] - icon_size) * 0.5;

    if (drawToolbarIcon(dc, .{ cursor_x, y }, icon_size, .copy, queue)) {
        if (editor_state) |editor| {
                if (editor.slice().len > 0) {
                    if (std.heap.page_allocator.dupeZ(u8, editor.slice()) catch null) |ztext| {
                        defer std.heap.page_allocator.free(ztext);
                        clipboard.setTextZ(ztext);
                    }
                }
            }
        }
    cursor_x += icon_size + t.spacing.sm;

    if (drawToolbarIcon(dc, .{ cursor_x, y }, icon_size, .undo, queue)) {
        applyUndo();
    }
    cursor_x += icon_size + t.spacing.sm;

    if (drawToolbarIcon(dc, .{ cursor_x, y }, icon_size, .redo, queue)) {
        applyRedo();
    }
    cursor_x += icon_size + t.spacing.sm;

    _ = drawToolbarIcon(dc, .{ cursor_x, y }, icon_size, .expand, queue);
}

fn drawSummaryCard(dc: *draw_context.DrawContext, pos: [2]f32, width: f32) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    theme.push(.heading);
    const title_height = dc.lineHeight();
    theme.pop();
    const text = "This report summarizes sales performance, highlights key insights, and links supporting artifacts collected during the run.";
    const body_height = measureWrappedTextHeight(std.heap.page_allocator, dc, text, width - padding * 2.0);
    const card_height = padding * 2.0 + title_height + t.spacing.sm + body_height;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Report Summary", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height + t.spacing.sm;

    _ = drawWrappedText(std.heap.page_allocator, dc, text, .{ rect.min[0] + padding, cursor_y }, width - padding * 2.0, t.colors.text_secondary);

    return card_height;
}

fn drawInsightsCard(dc: *draw_context.DrawContext, pos: [2]f32, width: f32) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    theme.push(.heading);
    const title_height = dc.lineHeight();
    theme.pop();
    const bullet_height = dc.lineHeight();
    const bullets = [_][]const u8{
        "North America revenue is trending up 12% month-over-month.",
        "Top competitor share declined after feature launch.",
        "Pipeline risk concentrated in two enterprise accounts.",
    };
    const body_height = @as(f32, @floatFromInt(bullets.len)) * (bullet_height + t.spacing.xs);
    const card_height = padding * 2.0 + title_height + t.spacing.sm + body_height;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Key Insights", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height + t.spacing.sm;

    for (bullets) |item| {
        drawBullet(dc, .{ rect.min[0] + padding, cursor_y }, item);
        cursor_y += bullet_height + t.spacing.xs;
    }

    return card_height;
}

fn drawChartCard(dc: *draw_context.DrawContext, pos: [2]f32, width: f32) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    theme.push(.heading);
    const title_height = dc.lineHeight();
    theme.pop();
    const chart_height: f32 = 160.0;
    const tabs_height = dc.lineHeight() + t.spacing.xs * 2.0;
    const card_height = padding * 2.0 + title_height + t.spacing.sm + chart_height + t.spacing.md + tabs_height;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, card_height });
    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText("Sales Performance (Chart)", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += title_height + t.spacing.sm;

    const chart_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, cursor_y },
        .{ width - padding * 2.0, chart_height },
    );
    drawChart(dc, chart_rect);
    cursor_y += chart_height + t.spacing.md;

    dc.drawText("Competitor Analysis", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    const tab_y = cursor_y + t.spacing.xs;
    var x = rect.min[0] + padding + dc.measureText("Competitor Analysis", 0.0)[0] + t.spacing.md;
    const tab_h = tabs_height;

    const tabs = [_][]const u8{ "Sales", "Dow", "Proclues", "Pemble" };
    for (tabs, 0..) |label, idx| {
        const tab_w = tabWidth(dc, label, t);
        const tab_rect = draw_context.Rect.fromMinSize(.{ x, tab_y }, .{ tab_w, tab_h });
        _ = drawTab(dc, tab_rect, label, idx == 0, input_router.getQueue());
        x += tab_w + t.spacing.xs;
    }

    return card_height;
}

fn drawChart(dc: *draw_context.DrawContext, rect: draw_context.Rect) void {
    const t = theme.activeTheme();
    const bars = [_]f32{ 0.4, 0.6, 0.3, 0.8, 0.5, 0.7 };
    const bar_width: f32 = 18.0;
    const gap: f32 = 10.0;
    const base_y = rect.max[1];
    var x = rect.min[0];

    for (bars) |ratio| {
        const bar_h = rect.size()[1] * ratio;
        const bar_rect = draw_context.Rect.fromMinSize(.{ x, base_y - bar_h }, .{ bar_width, bar_h });
        dc.drawRoundedRect(bar_rect, 3.0, .{ .fill = t.colors.primary });
        x += bar_width + gap;
    }

    dc.drawLine(.{ rect.min[0], base_y }, .{ rect.max[0], base_y }, 1.0, t.colors.border);
    dc.drawLine(.{ rect.min[0], rect.min[1] }, .{ rect.min[0], base_y }, 1.0, t.colors.border);
    dc.drawText("Week", .{ rect.max[0] - 36.0, base_y + 4.0 }, .{ .color = t.colors.text_secondary });
    dc.drawText("Sales", .{ rect.min[0] + 4.0, rect.min[1] - 16.0 }, .{ .color = t.colors.text_secondary });
}

fn drawBullet(dc: *draw_context.DrawContext, pos: [2]f32, text: []const u8) void {
    const t = theme.activeTheme();
    const radius: f32 = 3.0;
    const bullet_center = .{ pos[0] + radius, pos[1] + radius + 3.0 };
    dc.drawRoundedRect(
        draw_context.Rect.fromMinSize(.{ bullet_center[0] - radius, bullet_center[1] - radius }, .{ radius * 2.0, radius * 2.0 }),
        radius,
        .{ .fill = t.colors.text_secondary },
    );
    dc.drawText(text, .{ pos[0] + radius * 2.0 + t.spacing.xs, pos[1] }, .{ .color = t.colors.text_secondary });
}

fn drawTab(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    active: bool,
    queue: *input_state.InputQueue,
) bool {
    const t = theme.activeTheme();
    const hovered = rect.contains(queue.state.mouse_pos);
    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    clicked = true;
                }
            },
            else => {},
        }
    }

    const base = if (active) t.colors.primary else t.colors.surface;
    const alpha: f32 = if (active) 0.18 else if (hovered) 0.1 else 0.0;
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = colors.withAlpha(base, alpha), .stroke = colors.withAlpha(t.colors.border, 0.3), .thickness = 1.0 });

    const text_color = if (active) t.colors.primary else t.colors.text_secondary;
    const text_size = dc.measureText(label, 0.0);
    dc.drawText(label, .{ rect.min[0] + (rect.size()[0] - text_size[0]) * 0.5, rect.min[1] + (rect.size()[1] - text_size[1]) * 0.5 }, .{ .color = text_color });

    return clicked;
}

fn drawToolbarIcon(
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    size: f32,
    icon: ToolbarIcon,
    queue: *input_state.InputQueue,
) bool {
    const t = theme.activeTheme();
    const rect = draw_context.Rect.fromMinSize(pos, .{ size, size });
    const hovered = rect.contains(queue.state.mouse_pos);
    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    clicked = true;
                }
            },
            else => {},
        }
    }

    const bg = if (hovered) colors.withAlpha(t.colors.primary, 0.12) else t.colors.surface;
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = bg, .stroke = colors.withAlpha(t.colors.border, 0.7), .thickness = 1.0 });

    const center = .{ pos[0] + size * 0.5, pos[1] + size * 0.5 };
    const icon_color = t.colors.text_primary;
    switch (icon) {
        .copy => {
            const rect_size: f32 = size * 0.35;
            dc.drawRoundedRect(
                draw_context.Rect.fromMinSize(
                    .{ center[0] - rect_size, center[1] - rect_size },
                    .{ rect_size * 1.4, rect_size * 1.4 },
                ),
                2.0,
                .{ .stroke = icon_color, .thickness = 1.5 },
            );
        },
        .undo => {
            const left = center[0] - size * 0.18;
            const right = center[0] + size * 0.18;
            dc.drawLine(.{ right, center[1] }, .{ left, center[1] }, 2.0, icon_color);
            dc.drawLine(.{ left, center[1] }, .{ left + size * 0.1, center[1] - size * 0.1 }, 2.0, icon_color);
            dc.drawLine(.{ left, center[1] }, .{ left + size * 0.1, center[1] + size * 0.1 }, 2.0, icon_color);
        },
        .redo => {
            const left = center[0] - size * 0.18;
            const right = center[0] + size * 0.18;
            dc.drawLine(.{ left, center[1] }, .{ right, center[1] }, 2.0, icon_color);
            dc.drawLine(.{ right, center[1] }, .{ right - size * 0.1, center[1] - size * 0.1 }, 2.0, icon_color);
            dc.drawLine(.{ right, center[1] }, .{ right - size * 0.1, center[1] + size * 0.1 }, 2.0, icon_color);
        },
        .expand => {
            const offset = size * 0.18;
            dc.drawLine(.{ center[0] - offset, center[1] - offset }, .{ center[0] - offset, center[1] - size * 0.3 }, 2.0, icon_color);
            dc.drawLine(.{ center[0] - offset, center[1] - offset }, .{ center[0] - size * 0.3, center[1] - offset }, 2.0, icon_color);
            dc.drawLine(.{ center[0] + offset, center[1] + offset }, .{ center[0] + offset, center[1] + size * 0.3 }, 2.0, icon_color);
            dc.drawLine(.{ center[0] + offset, center[1] + offset }, .{ center[0] + size * 0.3, center[1] + offset }, 2.0, icon_color);
        },
    }

    return clicked;
}

fn toolbarIconSize(t: *const theme.Theme) f32 {
    return t.spacing.lg + t.spacing.sm;
}

fn toolbarHeight(t: *const theme.Theme) f32 {
    const icon = toolbarIconSize(t);
    return icon + t.spacing.md;
}

fn tabWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn buttonWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn handleWheelScroll(
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    scroll_y: *f32,
    max_scroll: f32,
    step: f32,
) void {
    if (max_scroll <= 0.0) {
        scroll_y.* = 0.0;
        return;
    }
    if (!rect.contains(queue.state.mouse_pos)) return;
    for (queue.events.items) |evt| {
        if (evt == .mouse_wheel) {
            const delta = evt.mouse_wheel.delta[1];
            scroll_y.* -= delta * step;
        }
    }
    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
    if (scroll_y.* > max_scroll) scroll_y.* = max_scroll;
}

fn ensureUndoStack() void {
    if (undo_stack == null) {
        undo_stack = undo_redo.UndoRedoStack(EditState).init(std.heap.page_allocator, 64, null);
    }
}

fn captureState(editor: *text_editor.TextEditor) EditState {
    var state = EditState{ .len = 0, .buf = [_]u8{0} ** 4096 };
    const text = editor.slice();
    const len = @min(text.len, state.buf.len);
    state.len = len;
    std.mem.copyForwards(u8, state.buf[0..len], text[0..len]);
    return state;
}

fn applyState(state: EditState) void {
    if (editor_state) |*editor| {
        editor.setText(std.heap.page_allocator, state.buf[0..state.len]);
    }
}

fn statesEqual(a: EditState, b: EditState) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a.buf[0..a.len], b.buf[0..b.len]);
}

fn applyUndo() void {
    if (undo_stack) |*stack| {
        if (stack.undo()) |state| {
            applyState(state);
        }
    }
}

fn applyRedo() void {
    if (undo_stack) |*stack| {
        if (stack.redo()) |state| {
            applyState(state);
        }
    }
}

fn registerShortcuts(sys: *systems.Systems) void {
    sys.keyboard.register(.{
        .id = "artifact.undo",
        .key = .z,
        .ctrl = true,
        .scope = .focused,
        .focus_id = "artifact_editor",
        .action = onUndoShortcut,
    }) catch {};
    sys.keyboard.register(.{
        .id = "artifact.redo",
        .key = .y,
        .ctrl = true,
        .scope = .focused,
        .focus_id = "artifact_editor",
        .action = onRedoShortcut,
    }) catch {};
    sys.keyboard.register(.{
        .id = "artifact.redo_shift",
        .key = .z,
        .ctrl = true,
        .shift = true,
        .scope = .focused,
        .focus_id = "artifact_editor",
        .action = onRedoShortcut,
    }) catch {};
}

fn onUndoShortcut(_: ?*anyopaque) void {
    applyUndo();
}

fn onRedoShortcut(_: ?*anyopaque) void {
    applyRedo();
}

fn drawWrappedText(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    pos: [2]f32,
    wrap_width: f32,
    color: colors.Color,
) f32 {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, wrap_width, &lines);

    var y = pos[1];
    const line_height = dc.lineHeight();
    for (lines.items) |line| {
        const slice = text[line.start..line.end];
        if (slice.len > 0) {
            dc.drawText(slice, .{ pos[0], y }, .{ .color = color });
        }
        y += line_height;
    }
    return y - pos[1];
}

fn measureWrappedTextHeight(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
) f32 {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    buildLinesInto(allocator, dc, text, wrap_width, &lines);
    return @as(f32, @floatFromInt(lines.items.len)) * dc.lineHeight();
}

fn buildLinesInto(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    text: []const u8,
    wrap_width: f32,
    lines: *std.ArrayList(Line),
) void {
    lines.clearRetainingCapacity();
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
        const char_w = dc.measureText(slice, 0.0)[0];

        if (ch == ' ' or ch == '\t') {
            last_space = next;
        }

        if (line_width + char_w > effective_wrap and line_width > 0.0) {
            if (last_space != null and last_space.? > line_start) {
                _ = lines.append(allocator, .{ .start = line_start, .end = last_space.? - 1 }) catch {};
                index = last_space.?;
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

fn nextCharIndex(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const first = text[index];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const next = index + @as(usize, len);
    return if (next > text.len) text.len else next;
}
