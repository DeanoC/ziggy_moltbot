const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const components = @import("../components.zig");

pub const Category = struct {
    name: []const u8,
    variant: components.core.badge.Variant = .neutral,
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

pub fn draw(args: Args) void {
    const t = theme.activeTheme();

    if (components.layout.card.begin(.{
        .id = args.id,
        .elevation = .raised,
    })) {
        const draw_list = zgui.getWindowDrawList();
        const pos = zgui.getWindowPos();
        const size = zgui.getWindowSize();
        const accent_height = 56.0;
        const top = colors.withAlpha(t.colors.primary, 0.18);
        const bottom = colors.withAlpha(colors.blend(t.colors.primary, t.colors.surface, 0.65), 0.0);
        draw_list.addRectFilledMultiColor(.{
            .pmin = .{ pos[0] + 1.0, pos[1] + 1.0 },
            .pmax = .{ pos[0] + size[0] - 1.0, pos[1] + accent_height },
            .col_upr_left = zgui.colorConvertFloat4ToU32(top),
            .col_upr_right = zgui.colorConvertFloat4ToU32(top),
            .col_bot_right = zgui.colorConvertFloat4ToU32(bottom),
            .col_bot_left = zgui.colorConvertFloat4ToU32(bottom),
        });

        theme.push(.heading);
        zgui.text("{s}", .{args.name});
        theme.pop();

        if (args.description) |desc| {
            zgui.textWrapped("{s}", .{desc});
        }

        if (args.categories.len > 0) {
            const spacing = t.spacing.xs;
            for (args.categories, 0..) |category, idx| {
                if (idx > 0) {
                    zgui.sameLine(.{ .spacing = spacing });
                }
                components.core.badge.draw(category.name, .{
                    .variant = category.variant,
                    .filled = false,
                    .size = .small,
                });
            }
        }

        if (args.recent_artifacts.len > 0) {
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
            zgui.separator();
            zgui.text("Recent artifacts", .{});
            for (args.recent_artifacts, 0..) |artifact, idx| {
                zgui.pushIntId(@intCast(idx));
                defer zgui.popId();
                components.composite.artifact_row.draw(.{
                    .name = artifact.name,
                    .file_type = artifact.file_type,
                    .status = artifact.status,
                });
            }
        }
    }
    components.layout.card.end();
}
