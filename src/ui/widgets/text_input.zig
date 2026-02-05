const std = @import("std");
const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const text_editor = @import("text_editor.zig");
const theme = @import("../theme.zig");

pub const Options = struct {
    placeholder: ?[]const u8 = null,
    read_only: bool = false,
    mask_char: ?u8 = null,
};

pub fn defaultHeight(line_height: f32) f32 {
    const t = theme.activeTheme();
    return line_height + t.spacing.xs * 2.0;
}

pub fn draw(
    editor: *text_editor.TextEditor,
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    opts: Options,
) text_editor.Action {
    const action = editor.draw(allocator, ctx, rect, queue, .{
        .submit_on_enter = false,
        .read_only = opts.read_only,
        .single_line = true,
        .mask_char = opts.mask_char,
    });

    if (!editor.focused and editor.isEmpty()) {
        if (opts.placeholder) |placeholder| {
            const t = theme.activeTheme();
            const pos = .{ rect.min[0] + t.spacing.sm, rect.min[1] + t.spacing.xs };
            ctx.drawText(placeholder, pos, .{ .color = t.colors.text_secondary });
        }
    }

    return action;
}
