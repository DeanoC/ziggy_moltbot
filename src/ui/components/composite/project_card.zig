const std = @import("std");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const draw_context = @import("../../draw_context.zig");
const artifact_row = @import("artifact_row.zig");

pub const BadgeVariant = enum {
    neutral,
    primary,
    success,
    warning,
    danger,
};

pub const Category = struct {
    name: []const u8,
    variant: BadgeVariant = .neutral,
};

pub const Artifact = struct {
    name: []const u8,
    file_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const Args = struct {
    id: []const u8 = "project_card",
    name: []const u8,
    description: ?[]const u8 = null,
    categories: []const Category = &[_]Category{},
    recent_artifacts: []const Artifact = &[_]Artifact{},
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
    const padding = t.spacing.md;
    theme.push(.heading);
    const heading_height = dc.lineHeight();
    theme.pop();
    const content_width = width - padding * 2.0;

    var height = padding + heading_height;
    if (args.description) |desc| {
        height += t.spacing.sm;
        height += measureWrappedTextHeight(allocator, dc, desc, content_width);
    }
    if (args.categories.len > 0) {
        height += t.spacing.sm;
        height += badgeRowsHeight(dc, args.categories, content_width, t);
    }
    if (args.recent_artifacts.len > 0) {
        height += t.spacing.sm;
        height += 1.0 + t.spacing.sm;
        height += heading_height + t.spacing.xs;
        const row_height = artifact_row.rowHeight(dc, t);
        if (args.recent_artifacts.len > 0) {
            height += @as(f32, @floatFromInt(args.recent_artifacts.len)) * row_height;
            height += t.spacing.xs * @as(f32, @floatFromInt(args.recent_artifacts.len - 1));
        }
    }
    height += padding;
    return height;
}

pub fn draw(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    args: Args,
) void {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    theme.push(.heading);
    const heading_height = dc.lineHeight();
    theme.pop();
    const content_width = rect.size()[0] - padding * 2.0;

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
    const accent_height: f32 = 48.0;
    const accent_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + 1.0, rect.min[1] + 1.0 },
        .{ rect.size()[0] - 2.0, accent_height },
    );
    dc.drawRoundedRect(accent_rect, t.radius.md, .{ .fill = colors.withAlpha(t.colors.primary, 0.14) });

    var cursor_y = rect.min[1] + padding;
    theme.push(.heading);
    dc.drawText(args.name, .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();
    cursor_y += heading_height;

    if (args.description) |desc| {
        cursor_y += t.spacing.sm;
        cursor_y += drawWrappedText(allocator, dc, desc, .{ rect.min[0] + padding, cursor_y }, content_width, t.colors.text_secondary);
    }

    if (args.categories.len > 0) {
        cursor_y += t.spacing.sm;
        cursor_y += drawBadges(dc, .{ rect.min[0] + padding, cursor_y }, content_width, args.categories, t);
    }

    if (args.recent_artifacts.len > 0) {
        cursor_y += t.spacing.sm;
        dc.drawRect(
            draw_context.Rect.fromMinSize(.{ rect.min[0] + padding, cursor_y }, .{ content_width, 1.0 }),
            .{ .fill = t.colors.divider },
        );
        cursor_y += t.spacing.sm;
        dc.drawText("Recent artifacts", .{ rect.min[0] + padding, cursor_y }, .{ .color = t.colors.text_primary });
        cursor_y += heading_height + t.spacing.xs;
        const row_height = artifact_row.rowHeight(dc, t);
        for (args.recent_artifacts) |artifact| {
            const row_rect = draw_context.Rect.fromMinSize(
                .{ rect.min[0] + padding, cursor_y },
                .{ content_width, row_height },
            );
            artifact_row.draw(dc, row_rect, .{
                .name = artifact.name,
                .file_type = artifact.file_type,
                .status = artifact.status,
            });
            cursor_y += row_height + t.spacing.xs;
        }
    }
}

fn badgeRowsHeight(
    dc: *draw_context.DrawContext,
    categories: []const Category,
    max_width: f32,
    t: *const theme.Theme,
) f32 {
    const badge_height = badgeSize(dc, "Temp", t)[1];
    var rows: usize = 1;
    var cursor_x: f32 = 0.0;
    for (categories) |category| {
        const size = badgeSize(dc, category.name, t);
        if (cursor_x > 0.0 and cursor_x + size[0] > max_width) {
            rows += 1;
            cursor_x = 0.0;
        }
        cursor_x += size[0] + t.spacing.xs;
    }
    return @as(f32, @floatFromInt(rows)) * badge_height + t.spacing.xs * @as(f32, @floatFromInt(rows - 1));
}

fn drawBadges(
    dc: *draw_context.DrawContext,
    pos: [2]f32,
    max_width: f32,
    categories: []const Category,
    t: *const theme.Theme,
) f32 {
    const badge_height = badgeSize(dc, "Temp", t)[1];
    var cursor_x: f32 = 0.0;
    var cursor_y: f32 = pos[1];
    var rows: usize = 1;
    for (categories) |category| {
        const size = badgeSize(dc, category.name, t);
        if (cursor_x > 0.0 and cursor_x + size[0] > max_width) {
            rows += 1;
            cursor_x = 0.0;
            cursor_y += badge_height + t.spacing.xs;
        }
        const badge_rect = draw_context.Rect.fromMinSize(
            .{ pos[0] + cursor_x, cursor_y },
            size,
        );
        drawBadge(dc, badge_rect, category.name, category.variant);
        cursor_x += size[0] + t.spacing.xs;
    }
    return @as(f32, @floatFromInt(rows)) * badge_height + t.spacing.xs * @as(f32, @floatFromInt(rows - 1));
}

fn badgeSize(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) [2]f32 {
    const text_size = dc.measureText(label, 0.0);
    return .{ text_size[0] + t.spacing.xs * 2.0, text_size[1] + t.spacing.xs };
}

fn drawBadge(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    label: []const u8,
    variant: BadgeVariant,
) void {
    const t = theme.activeTheme();
    const base = badgeColor(t, variant);
    const bg = colors.withAlpha(base, 0.18);
    const border = colors.withAlpha(base, 0.4);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs * 0.5 }, .{ .color = base });
}

fn badgeColor(t: *const theme.Theme, variant: BadgeVariant) colors.Color {
    return switch (variant) {
        .neutral => t.colors.text_secondary,
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
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
