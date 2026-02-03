const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");

pub const Args = struct {
    text: []const u8,
    max_lines: ?usize = null,
};

pub fn draw(args: Args) void {
    const t = theme.activeTheme();
    var it = std.mem.splitScalar(u8, args.text, '\n');
    var line_count: usize = 0;
    var in_code_block = false;
    while (it.next()) |line| {
        if (args.max_lines) |max_lines| {
            if (line_count >= max_lines) break;
        }
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code_block = !in_code_block;
            line_count += 1;
            continue;
        }
        if (trimmed.len == 0) {
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
            line_count += 1;
            continue;
        }
        if (in_code_block) {
            zgui.textDisabled("{s}", .{trimmed});
            line_count += 1;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) {
            theme.push(.heading);
            zgui.text("{s}", .{std.mem.trim(u8, trimmed, "# ")});
            theme.pop();
        } else if (std.mem.startsWith(u8, trimmed, "> ")) {
            zgui.textDisabled("{s}", .{trimmed[2..]});
        } else if (std.mem.startsWith(u8, trimmed, "- ") or
            std.mem.startsWith(u8, trimmed, "* ") or
            std.mem.startsWith(u8, trimmed, "+ "))
        {
            zgui.bulletText("{s}", .{trimmed[2..]});
        } else {
            zgui.textWrapped("{s}", .{trimmed});
        }
        line_count += 1;
    }
    if (args.max_lines) |max_lines| {
        if (line_count >= max_lines) {
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
            zgui.textDisabled("Preview truncated.", .{});
        }
    }
}
