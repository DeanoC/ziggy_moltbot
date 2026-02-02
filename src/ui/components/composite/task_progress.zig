const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const components = @import("../components.zig");

pub const Step = struct {
    label: []const u8,
    state: components.data.progress_step.State = .pending,
};

pub const Args = struct {
    title: ?[]const u8 = "Task Progress",
    steps: []const Step = &[_]Step{},
    detail: ?[]const u8 = null,
    show_logs_button: bool = false,
};

pub const Action = enum {
    none,
    view_logs,
};

pub fn draw(args: Args) Action {
    const t = theme.activeTheme();
    var action: Action = .none;

    if (args.title) |title| {
        if (title.len > 0) {
            theme.push(.heading);
            zgui.text("{s}", .{title});
            theme.pop();
            zgui.separator();
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
        }
    }

    if (args.steps.len > 0) {
        const step_spacing = t.spacing.sm;
        for (args.steps, 0..) |step, idx| {
            if (idx > 0) {
                zgui.sameLine(.{ .spacing = step_spacing });
            }
            components.data.progress_step.draw(.{
                .label = step.label,
                .state = step.state,
            });
        }
    } else {
        zgui.textDisabled("No steps available.", .{});
    }

    if (args.detail) |detail| {
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
        zgui.textDisabled("Details", .{});
        zgui.textWrapped("{s}", .{detail});
    }

    if (args.show_logs_button) {
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
        if (components.core.button.draw("View Logs", .{ .variant = .secondary, .size = .small })) {
            action = .view_logs;
        }
    }

    return action;
}
