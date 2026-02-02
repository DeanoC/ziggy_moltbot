const zgui = @import("zgui");
const theme = @import("../../theme.zig");

pub const Args = struct {
    id: []const u8,
    height: f32 = 0.0,
    border: bool = true,
    padded: bool = true,
};

pub fn begin(args: Args) bool {
    const t = theme.activeTheme();
    const padding = if (args.padded)
        .{ t.spacing.sm, t.spacing.sm }
    else
        .{ t.spacing.xs, t.spacing.xs };
    const label_z = zgui.formatZ("##scroll_{s}", .{args.id});
    const border_size: f32 = if (args.border) 1.0 else 0.0;

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = padding });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = t.radius.md });
    zgui.pushStyleVar1f(.{ .idx = .child_border_size, .v = border_size });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = t.colors.surface });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = t.colors.border });

    return zgui.beginChild(label_z, .{ .h = args.height, .child_flags = .{ .border = args.border } });
}

pub fn end() void {
    zgui.endChild();
    zgui.popStyleColor(.{ .count = 2 });
    zgui.popStyleVar(.{ .count = 3 });
}
