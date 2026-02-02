const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const components = @import("../components.zig");

pub const Args = struct {
    name: []const u8,
    file_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub fn draw(args: Args) void {
    const t = theme.activeTheme();
    zgui.text("{s}", .{args.name});
    var has_badge = false;
    if (args.file_type) |file_type| {
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        components.core.badge.draw(file_type, .{
            .variant = .neutral,
            .filled = false,
            .size = .small,
        });
        has_badge = true;
    }
    if (args.status) |status| {
        zgui.sameLine(.{ .spacing = if (has_badge) t.spacing.xs else t.spacing.sm });
        components.core.badge.draw(status, .{
            .variant = .primary,
            .filled = false,
            .size = .small,
        });
    }
}
