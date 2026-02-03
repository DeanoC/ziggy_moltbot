const zgui = @import("zgui");
const theme = @import("../../theme.zig");

pub const Args = struct {
    id: []const u8,
    width: f32 = 240.0,
    height: f32 = 0.0,
    border: bool = true,
    padded: bool = true,
    collapsible: bool = false,
    collapsed: ?*bool = null,
    collapsed_width: f32 = 56.0,
    collapsed_label: ?[]const u8 = null,
};

pub fn begin(args: Args) bool {
    const t = theme.activeTheme();
    const is_collapsed = args.collapsible and args.collapsed != null and args.collapsed.?.*;
    const padding = if (args.padded and !is_collapsed)
        .{ t.spacing.sm, t.spacing.sm }
    else
        .{ t.spacing.xs, t.spacing.xs };
    const label_z = zgui.formatZ("##sidebar_{s}", .{args.id});
    const border_size: f32 = if (args.border) 1.0 else 0.0;
    const width = if (is_collapsed) args.collapsed_width else args.width;

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = padding });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = t.radius.md });
    zgui.pushStyleVar1f(.{ .idx = .child_border_size, .v = border_size });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = t.colors.surface });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = t.colors.border });

    const opened = zgui.beginChild(label_z, .{
        .w = width,
        .h = args.height,
        .child_flags = .{ .border = args.border },
    });
    if (opened and args.collapsible and args.collapsed != null) {
        const cursor = zgui.getCursorPos();
        const button_size = zgui.getFrameHeight();
        const avail = zgui.getContentRegionAvail();
        const x = if (avail[0] > button_size) cursor[0] + (avail[0] - button_size) else cursor[0];
        zgui.setCursorPos(.{ x, cursor[1] });
        const label = if (is_collapsed) ">>" else "<<";
        if (zgui.smallButton(label)) {
            args.collapsed.?.* = !is_collapsed;
        }
        zgui.setCursorPos(.{ cursor[0], cursor[1] + button_size + t.spacing.xs });
        if (!is_collapsed) {
            zgui.separator();
        }
    }
    if (opened and is_collapsed) {
        if (args.collapsed_label) |label| {
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
            zgui.pushTextWrapPos(0.0);
            zgui.textDisabled("{s}", .{label});
            zgui.popTextWrapPos();
        }
    }
    return opened;
}

pub fn end() void {
    zgui.endChild();
    zgui.popStyleColor(.{ .count = 2 });
    zgui.popStyleVar(.{ .count = 3 });
}
