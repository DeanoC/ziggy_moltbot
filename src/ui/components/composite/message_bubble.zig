const std = @import("std");
const theme = @import("../../theme.zig");
const colors = @import("../../theme/colors.zig");

pub const Args = struct {
    id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp_ms: ?i64 = null,
    now_ms: i64,
    align_right: bool = false,
    use_markdown: bool = true,
};

pub const bubble_fill_ratio: f32 = 0.82;
pub const min_bubble_width: f32 = 300.0;

pub const BubbleColors = struct {
    bg: colors.Color,
    border: colors.Color,
    accent: colors.Color,
};

pub fn bubbleWidth(avail: f32) f32 {
    const target = @max(min_bubble_width, avail * bubble_fill_ratio);
    return @min(target, avail);
}

pub fn minPanelWidth() f32 {
    return min_bubble_width / bubble_fill_ratio;
}

pub fn roleLabel(role: []const u8) []const u8 {
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

pub fn formatRelativeTime(now_ms: i64, ts_ms: i64, buf: []u8) []const u8 {
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

pub fn bubbleColors(role: []const u8, t: *const theme.Theme) BubbleColors {
    const base = roleBaseColor(role, t);
    return .{
        .bg = colors.withAlpha(base, 0.12),
        .border = colors.withAlpha(base, 0.32),
        .accent = roleAccentColor(role, t),
    };
}
