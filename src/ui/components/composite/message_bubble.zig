const std = @import("std");
const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");
const markdown_basic = @import("../../markdown_basic.zig");

pub const Args = struct {
    id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp_ms: ?i64 = null,
    now_ms: i64,
    align_right: bool = false,
    use_markdown: bool = true,
};

pub fn draw(args: Args) void {
    const t = theme.activeTheme();
    const avail = zgui.getContentRegionAvail();
    const bubble_width = bubbleWidth(avail[0]);
    const cursor_start = zgui.getCursorPos();

    if (args.align_right and avail[0] > bubble_width) {
        zgui.setCursorPosX(cursor_start[0] + (avail[0] - bubble_width));
    }

    const base = roleBaseColor(args.role, t);
    const bg = colors.withAlpha(base, 0.12);
    const border = colors.withAlpha(base, 0.32);

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ t.spacing.sm, t.spacing.xs } });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = t.radius.md });
    zgui.pushStyleVar1f(.{ .idx = .child_border_size, .v = 1.0 });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = bg });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = border });

    const id_z = zgui.formatZ("##bubble_{s}", .{args.id});
    if (zgui.beginChild(id_z, .{
        .w = bubble_width,
        .h = 0.0,
        .child_flags = .{ .border = true, .auto_resize_y = true, .always_use_window_padding = true },
    })) {
        theme.push(.heading);
        zgui.textColored(roleAccentColor(args.role, t), "{s}", .{roleLabel(args.role)});
        theme.pop();
        if (args.timestamp_ms) |ts| {
            var time_buf: [32]u8 = undefined;
            const label = formatRelativeTime(args.now_ms, ts, &time_buf);
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            zgui.textDisabled("{s}", .{label});
        }
        if (args.use_markdown) {
            markdown_basic.draw(.{ .text = args.content });
        } else {
            zgui.textWrapped("{s}", .{args.content});
        }
    }
    zgui.endChild();

    zgui.popStyleColor(.{ .count = 2 });
    zgui.popStyleVar(.{ .count = 3 });

    zgui.setCursorPosX(cursor_start[0]);
}

fn bubbleWidth(avail: f32) f32 {
    return @min(560.0, avail * 0.82);
}

fn roleLabel(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "assistant")) return "Assistant";
    if (std.mem.eql(u8, role, "user")) return "You";
    if (std.mem.eql(u8, role, "system")) return "System";
    if (std.mem.startsWith(u8, role, "tool")) return "Tool";
    return role;
}

fn roleBaseColor(role: []const u8, t: *const theme.Theme) colors.Color {
    if (std.mem.eql(u8, role, "assistant")) return t.colors.primary;
    if (std.mem.eql(u8, role, "user")) return t.colors.success;
    if (std.mem.eql(u8, role, "system")) return t.colors.warning;
    return t.colors.divider;
}

fn roleAccentColor(role: []const u8, t: *const theme.Theme) colors.Color {
    if (std.mem.eql(u8, role, "assistant")) return t.colors.primary;
    if (std.mem.eql(u8, role, "user")) return t.colors.success;
    if (std.mem.eql(u8, role, "system")) return t.colors.warning;
    return t.colors.text_secondary;
}

fn formatRelativeTime(now_ms: i64, ts_ms: i64, buf: []u8) []const u8 {
    const delta_ms = if (now_ms > ts_ms) now_ms - ts_ms else 0;
    const seconds = @as(u64, @intCast(@divTrunc(delta_ms, 1000)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;
    if (seconds < 60) {
        return std.fmt.bufPrint(buf, "{d}s ago", .{seconds}) catch "now";
    }
    if (minutes < 60) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "now";
    }
    if (hours < 24) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "today";
    }
    return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "days ago";
}
