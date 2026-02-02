const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");

pub const Elevation = enum { flat, raised, floating };

pub const Args = struct {
    title: ?[]const u8 = null,
    elevation: Elevation = .flat,
    padded: bool = true,
    id: ?[]const u8 = null,
};

fn shadowColor(level: Elevation) colors.Color {
    return switch (level) {
        .flat => colors.withAlpha(colors.rgba(0, 0, 0, 255), 0.0),
        .raised => colors.withAlpha(colors.rgba(0, 0, 0, 255), 0.12),
        .floating => colors.withAlpha(colors.rgba(0, 0, 0, 255), 0.18),
    };
}

pub fn begin(args: Args) bool {
    const t = theme.activeTheme();
    const radius = t.radius.lg;
    const padding = if (args.padded)
        .{ t.spacing.md, t.spacing.md }
    else
        .{ t.spacing.sm, t.spacing.sm };
    const label_z = if (args.id) |id|
        zgui.formatZ("##card_{s}", .{id})
    else
        zgui.formatZ("##card", .{});

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = padding });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = radius });
    zgui.pushStyleVar1f(.{ .idx = .child_border_size, .v = 1.0 });

    zgui.pushStyleColor(.child_bg, t.colors.surface);
    zgui.pushStyleColor(.border, t.colors.border);

    const opened = zgui.beginChild(label_z, .{ .h = 0.0, .child_flags = .{ .border = true } });

    if (opened) {
        if (args.title) |title| {
            theme.push(.heading);
            zgui.text("{s}", .{title});
            theme.pop();
            zgui.separator();
        }

        if (args.elevation != .flat) {
            const draw_list = zgui.getWindowDrawList();
            const pos = zgui.getWindowPos();
            const size = zgui.getWindowSize();
            const shadow = shadowColor(args.elevation);
            draw_list.addRectFilled(.{
                .pmin = .{ pos[0] + 1.0, pos[1] + 2.0 },
                .pmax = .{ pos[0] + size[0] + 1.0, pos[1] + size[1] + 2.0 },
                .col = zgui.colorConvertFloat4ToU32(shadow),
                .rounding = radius,
            });
        }
    }

    return opened;
}

pub fn end() void {
    zgui.endChild();
    zgui.popStyleColor(2);
    zgui.popStyleVar(.{ .count = 3 });
}
