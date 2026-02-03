const std = @import("std");
const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const components = @import("../components.zig");

pub const Decision = enum {
    none,
    allow_once,
    allow_always,
    deny,
};

pub const Args = struct {
    id: []const u8,
    summary: ?[]const u8 = null,
    requested_at_ms: ?i64 = null,
    payload_json: []const u8,
    can_resolve: bool = true,
};

pub fn draw(args: Args) Decision {
    var decision: Decision = .none;
    var title_buf: [128:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "Request {s}", .{args.id}) catch args.id;

    if (components.layout.card.begin(.{ .title = title, .id = args.id, .elevation = .raised })) {
        if (args.summary) |summary| {
            zgui.textWrapped("Summary: {s}", .{summary});
        }
        if (args.requested_at_ms) |ts| {
            zgui.textWrapped("Requested At: {d}", .{ts});
        }
        zgui.separator();
        zgui.textWrapped("{s}", .{args.payload_json});

        if (args.can_resolve) {
            zgui.separator();
            if (components.core.button.draw("Allow Once", .{ .variant = .primary, .size = .small })) {
                decision = .allow_once;
            }
            zgui.sameLine(.{ .spacing = theme.activeTheme().spacing.sm });
            if (components.core.button.draw("Allow Always", .{ .variant = .secondary, .size = .small })) {
                decision = .allow_always;
            }
            zgui.sameLine(.{ .spacing = theme.activeTheme().spacing.sm });
            if (components.core.button.draw("Deny", .{ .variant = .danger, .size = .small })) {
                decision = .deny;
            }
        } else {
            zgui.textWrapped("Missing approval id in payload.", .{});
        }
    }
    components.layout.card.end();
    return decision;
}
