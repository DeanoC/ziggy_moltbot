const std = @import("std");
const workspace = @import("../workspace.zig");
const draw_context = @import("../draw_context.zig");
const theme = @import("../theme.zig");
const input_router = @import("../input/input_router.zig");
const text_editor = @import("../widgets/text_editor.zig");

pub fn draw(panel: *workspace.Panel, allocator: std.mem.Allocator, rect_override: ?draw_context.Rect) void {
    if (panel.kind != .ToolOutput) return;
    const output = &panel.data.ToolOutput;
    const t = theme.activeTheme();

    const panel_rect = rect_override orelse return;
    var ctx = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer ctx.deinit();
    ctx.drawRect(panel_rect, .{ .fill = t.colors.background });

    const header_height = drawHeader(&ctx, panel_rect, output);
    const content_gap = t.spacing.sm;
    const content_top = panel_rect.min[1] + header_height + content_gap;
    const content_height = panel_rect.max[1] - content_top;
    if (content_height <= 0.0) return;

    const label_height = ctx.lineHeight();
    const section_gap = t.spacing.sm;
    const available = content_height - label_height * 2.0 - section_gap * 3.0;
    var editor_height: f32 = if (available > 0.0) available / 2.0 else 0.0;
    const min_editor_height: f32 = 80.0;
    if (available >= min_editor_height * 2.0) {
        editor_height = @max(editor_height, min_editor_height);
    }
    const editor_width = @max(0.0, panel_rect.size()[0] - t.spacing.md * 2.0);
    const label_x = panel_rect.min[0] + t.spacing.md;
    if (editor_height <= 0.0 or editor_width <= 0.0) return;

    const queue = input_router.getQueue();
    ensureEditorState(allocator, output);

    var cursor_y = content_top;
    ctx.drawText("stdout", .{ label_x, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += label_height + t.spacing.xs;
    const stdout_rect = draw_context.Rect.fromMinSize(.{ label_x, cursor_y }, .{ editor_width, editor_height });
    _ = output.stdout_editor.?.draw(allocator, &ctx, stdout_rect, queue, .{ .read_only = true });
    cursor_y = stdout_rect.max[1] + section_gap;

    ctx.drawText("stderr", .{ label_x, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += label_height + t.spacing.xs;
    const stderr_rect = draw_context.Rect.fromMinSize(.{ label_x, cursor_y }, .{ editor_width, editor_height });
    _ = output.stderr_editor.?.draw(allocator, &ctx, stderr_rect, queue, .{ .read_only = true });
}

fn drawHeader(
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    output: *workspace.ToolOutputPanel,
) f32 {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = ctx.lineHeight();
    ctx.drawText(output.tool_name, .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    var subtitle_buf: [32]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&subtitle_buf, "exit {d}", .{output.exit_code}) catch "exit ?";
    cursor_y += title_height + gap;
    const subtitle_height = ctx.lineHeight();
    ctx.drawText(subtitle, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    return top_pad + title_height + gap + subtitle_height + top_pad;
}

fn ensureEditorState(allocator: std.mem.Allocator, output: *workspace.ToolOutputPanel) void {
    if (output.stdout_editor == null) {
        output.stdout_editor = text_editor.TextEditor.init(allocator) catch null;
    }
    if (output.stderr_editor == null) {
        output.stderr_editor = text_editor.TextEditor.init(allocator) catch null;
    }
    const stdout_text = output.stdout.slice();
    const stderr_text = output.stderr.slice();
    const stdout_hash = std.hash.Wyhash.hash(0, stdout_text);
    const stderr_hash = std.hash.Wyhash.hash(0, stderr_text);
    if (stdout_hash != output.stdout_hash) {
        if (output.stdout_editor) |*editor| {
            editor.setText(allocator, stdout_text);
        }
        output.stdout_hash = stdout_hash;
    }
    if (stderr_hash != output.stderr_hash) {
        if (output.stderr_editor) |*editor| {
            editor.setText(allocator, stderr_text);
        }
        output.stderr_hash = stderr_hash;
    }
}
