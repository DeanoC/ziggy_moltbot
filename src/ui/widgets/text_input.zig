const std = @import("std");
const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const text_editor = @import("text_editor.zig");
const theme = @import("../theme.zig");
const theme_runtime = @import("../theme_engine/runtime.zig");
const style_sheet = @import("../theme_engine/style_sheet.zig");

pub const Options = struct {
    placeholder: ?[]const u8 = null,
    read_only: bool = false,
    mask_char: ?u8 = null,
};

pub fn defaultHeight(t: *const theme.Theme, line_height: f32) f32 {
    const profile = theme_runtime.getProfile();
    const base = line_height + t.spacing.xs * 2.0;
    return @max(base, profile.hit_target_min_px);
}

pub fn draw(
    editor: *text_editor.TextEditor,
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    opts: Options,
) text_editor.Action {
    const t = ctx.theme;
    const ss = theme_runtime.getStyleSheet();
    const ti = ss.text_input;

    const action = editor.draw(allocator, ctx, rect, queue, .{
        .submit_on_enter = false,
        .read_only = opts.read_only,
        .single_line = true,
        .mask_char = opts.mask_char,
    });

    if (!editor.focused and editor.isEmpty()) {
        if (opts.placeholder) |placeholder| {
            const pos = .{ rect.min[0] + t.spacing.sm, rect.min[1] + t.spacing.xs };
            var placeholder_color = ti.placeholder orelse t.colors.text_secondary;

            const allow_hover = theme_runtime.allowHover(queue);
            const inside = rect.contains(queue.state.mouse_pos);
            const hovered = allow_hover and inside;
            const pressed = inside and queue.state.mouse_down_left and queue.state.pointer_kind != .nav;
            const focused = false;
            const st = blk: {
                if (opts.read_only) break :blk ti.states.read_only;
                if (focused) break :blk ti.states.focused;
                if (pressed) break :blk ti.states.pressed;
                if (hovered) break :blk ti.states.hover;
                break :blk style_sheet.TextInputStateStyle{};
            };
            if (st.placeholder) |v| placeholder_color = v;
            ctx.drawText(placeholder, pos, .{ .color = placeholder_color });
        }
    }

    return action;
}
