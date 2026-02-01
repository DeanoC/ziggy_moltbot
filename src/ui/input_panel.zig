const std = @import("std");
const zgui = @import("zgui");

// Leave headroom for multiline messages.
var input_buf: [4096:0]u8 = [_:0]u8{0} ** 4096;

const hint_z: [:0]const u8 = "Message (⏎ to send, Shift+⏎ for line breaks, paste images)";

pub fn draw(allocator: std.mem.Allocator, avail_w: f32, max_h: f32) ?[]u8 {
    var send = false;

    const style = zgui.getStyle();
    const min_h: f32 = 56.0;
    const max_h_clamped: f32 = @max(min_h, @min(180.0, max_h));

    const text = std.mem.sliceTo(&input_buf, 0);
    const wrap_w = @max(40.0, avail_w - style.frame_padding[0] * 2.0);
    const text_size = if (text.len > 0)
        zgui.calcTextSize(text, .{ .wrap_width = wrap_w })
    else
        zgui.calcTextSize(hint_z, .{ .wrap_width = wrap_w });

    var input_h = text_size[1] + style.frame_padding[1] * 2.0 + 8.0;
    input_h = @max(min_h, @min(max_h_clamped, input_h));

    const changed = zgui.inputTextMultiline("##message_input", .{
        .buf = input_buf[0.. :0],
        .w = avail_w,
        .h = input_h,
        .flags = .{
            .allow_tab_input = true,
            // Avoid horizontal scrolling; wrap instead.
            .no_horizontal_scroll = true,
        },
    });

    // Placeholder/hint overlay for multiline
    if (!zgui.isItemActive() and text.len == 0) {
        const min = zgui.getItemRectMin();
        const col = zgui.colorConvertFloat4ToU32(.{ 0.55, 0.55, 0.55, 1.0 });
        const pos = .{ min[0] + style.frame_padding[0], min[1] + style.frame_padding[1] };
        const dl = zgui.getWindowDrawList();
        dl.addTextExtendedUnformatted(pos, col, hint_z, .{ .font = null, .font_size = 0, .wrap_width = wrap_w });
    }

    // Enter to send, Shift+Enter for newline.
    if (zgui.isItemActive()) {
        const shift_down = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift);
        if (zgui.isKeyPressed(.enter, false) and !shift_down) {
            send = true;
            // inputTextMultiline may have inserted a newline already; strip trailing newlines.
            if (changed) {
                var buf = std.mem.sliceTo(&input_buf, 0);
                while (buf.len > 0 and (buf[buf.len - 1] == '\n' or buf[buf.len - 1] == '\r')) {
                    input_buf[buf.len - 1] = 0;
                    buf = std.mem.sliceTo(&input_buf, 0);
                }
            }
        }
    }

    // Button (kept for discoverability)
    if (zgui.button("Send", .{})) {
        send = true;
    }

    if (!send) return null;

    const final_text = std.mem.sliceTo(&input_buf, 0);
    if (final_text.len == 0) return null;

    const owned = allocator.dupe(u8, final_text) catch return null;
    input_buf[0] = 0;
    return owned;
}
