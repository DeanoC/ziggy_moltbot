const std = @import("std");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const draw_context = @import("../../draw_context.zig");
const input_state = @import("../../input/input_state.zig");
const widgets = @import("../../widgets/widgets.zig");

pub const Step = struct {
    label: []const u8,
    state: State = .pending,
};

pub const State = enum {
    pending,
    active,
    complete,
    failed,
};

pub const Args = struct {
    title: ?[]const u8 = "Task Progress",
    steps: []const Step = &[_]Step{},
    detail: ?[]const u8 = null,
    show_logs_button: bool = false,
};

pub const Action = enum {
    none,
    view_logs,
};

const Line = struct {
    start: usize,
    end: usize,
};

pub fn measureHeight(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    args: Args,
    width: f32,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    theme.push(.heading);
    const heading_height = dc.lineHeight();
    theme.pop();
    var height: f32 = 0.0;

    if (args.title) |title| {
        if (title.len > 0) {
            height += heading_height + t.spacing.xs + 1.0 + t.spacing.xs;
        }
    }

    if (args.steps.len > 0) {
        height += pillsHeight(dc, args.steps, width, t);
    } else {
        height += line_height;
    }

    if (args.detail) |detail| {
        height += t.spacing.sm;
        height += line_height;
        height += t.spacing.xs;
        height += measureWrappedTextHeight(allocator, dc, detail, width);
    }

    if (args.show_logs_button) {
        height += t.spacing.sm;
        height += line_height + t.spacing.xs * 2.0;
    }

    return height;
}

pub fn draw(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    args: Args,
) Action {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    theme.push(.heading);
    const heading_height = dc.lineHeight();
    theme.pop();
    var cursor_y = rect.min[1];
    var action: Action = .none;

    if (args.title) |title| {
        if (title.len > 0) {
            theme.push(.heading);
            dc.drawText(title, .{ rect.min[0], cursor_y }, .{ .color = t.colors.text_primary });
            theme.pop();
            cursor_y += heading_height + t.spacing.xs;
            dc.drawRect(draw_context.Rect.fromMinSize(.{ rect.min[0], cursor_y }, .{ rect.size()[0], 1.0 }), .{ .fill = t.colors.divider });
            cursor_y += 1.0 + t.spacing.xs;
        }
    }

    if (args.steps.len > 0) {
        cursor_y += drawPills(dc, .{ rect.min[0], cursor_y }, rect.size()[0], args.steps, t);
    } else {
        dc.drawText("No steps available.", .{ rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height;
    }

    if (args.detail) |detail| {
        cursor_y += t.spacing.sm;
        dc.drawText("Details", .{ rect.min[0], cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
        cursor_y += drawWrappedText(allocator, dc, detail, .{ rect.min[0], cursor_y }, rect.size()[0], t.colors.text_secondary);
    }

    if (args.show_logs_button) {
        cursor_y += t.spacing.sm;
        const button_height = line_height + t.spacing.xs * 2.0;
        const button_rect = draw_context.Rect.fromMinSize(
            .{ rect.min[0], cursor_y },
            .{ buttonWidth(dc, "View Logs", t), button_height },
        );
        if (widgets.button.draw(dc, button_rect, "View Logs", queue, .{ .variant = .secondary })) {
            action = .view_logs;
        }
    }

    return action;
}

fn pillsHeight(
    dc: *draw_context.DrawContext,
    steps: []const Step,
    max_width: f32,
    t: *const theme.Theme,
) f32 {
    const pill_height = pillSize(dc, "Temp", t)[1];
    var rows: usize = 1;
    var cursor_x: f32 = 0.0;
    for (steps) |step| {
        const size = pillSize(dc, step.label, t);
        if (cursor_x > 0.0 and cursor_x + size[0] > max_width) {
            rows += 1;
            cursor_x = 0.0;
        }
        cursor_x += size[0] + t.spacing.sm;
    }
    return @as(f32, @floatFromInt(rows)) * pill_height + t.spacing.xs * @as(f32, @floatFromInt(rows - 1));
}

fn drawPills(
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    max_width: f32,
    steps: []const Step,
    t: *const theme.Theme,
) f32 {
    const pill_height = pillSize(dc, "Temp", t)[1];
    var cursor_x: f32 = 0.0;
    var cursor_y: f32 = pos[1];
    var rows: usize = 1;
    for (steps) |step| {
        const size = pillSize(dc, step.label, t);
        if (cursor_x > 0.0 and cursor_x + size[0] > max_width) {
            rows += 1;
            cursor_x = 0.0;
            cursor_y += pill_height + t.spacing.xs;
        }
        const pill_rect = draw_context.Rect.fromMinSize(.{ pos[0] + cursor_x, cursor_y }, size);
        drawPill(dc, pill_rect, step, t);
        cursor_x += size[0] + t.spacing.sm;
    }
    return @as(f32, @floatFromInt(rows)) * pill_height + t.spacing.xs * @as(f32, @floatFromInt(rows - 1));
}

fn pillSize(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) [2]f32 {
    const text_size = dc.measureText(label, 0.0);
    return .{ text_size[0] + t.spacing.sm * 1.5, text_size[1] + t.spacing.xs };
}

fn drawPill(dc: *draw_context.DrawContext, rect: draw_context.Rect, step: Step, t: *const theme.Theme) void {
    const base = stateColor(t, step.state);
    const filled = step.state != .pending;
    const bg = if (filled) colors.withAlpha(base, 0.2) else colors.withAlpha(t.colors.border, 0.2);
    const border = colors.withAlpha(base, if (filled) 0.6 else 0.35);
    const text_color = if (filled) base else t.colors.text_secondary;

    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(step.label, .{ rect.min[0] + t.spacing.sm * 0.75, rect.min[1] + t.spacing.xs * 0.5 }, .{ .color = text_color });
}

fn stateColor(t: *const theme.Theme, state: State) colors.Color {
    return switch (state) {
        .pending => t.colors.text_secondary,
        .active => t.colors.primary,
        .complete => t.colors.success,
        .failed => t.colors.danger,
    };
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

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}
