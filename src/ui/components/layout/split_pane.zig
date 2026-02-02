const std = @import("std");
const zgui = @import("zgui");
const theme = @import("../../theme.zig");

pub const Axis = enum { horizontal, vertical };

pub const Args = struct {
    id: []const u8,
    axis: Axis = .vertical,
    primary_size: f32 = 240.0,
    min_primary: f32 = 140.0,
    min_secondary: f32 = 140.0,
    border: bool = true,
    padded: bool = true,
};

pub const SplitState = struct {
    size: f32,
    dragging: bool = false,
};

pub fn begin(args: Args, state: *SplitState) void {
    const t = theme.activeTheme();
    state.size = clampSize(args, state.size);

    const padding = if (args.padded)
        .{ t.spacing.sm, t.spacing.sm }
    else
        .{ t.spacing.xs, t.spacing.xs };
    const border_size: f32 = if (args.border) 1.0 else 0.0;
    const label_z = zgui.formatZ("##split_{s}", .{args.id});

    zgui.beginGroup();
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = padding });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = t.radius.md });
    zgui.pushStyleVar1f(.{ .idx = .child_border_size, .v = border_size });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = t.colors.surface });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = t.colors.border });

    _ = zgui.beginChild(label_z, .{ .child_flags = .{ .border = args.border } });
}

pub fn end() void {
    zgui.endChild();
    zgui.popStyleColor(.{ .count = 2 });
    zgui.popStyleVar(.{ .count = 3 });
    zgui.endGroup();
}

pub fn beginPrimary(args: Args, state: *SplitState) bool {
    state.size = clampSize(args, state.size);
    const size = paneSize(args, state.size);
    const label = zgui.formatZ("##split_primary_{s}", .{args.id});
    return zgui.beginChild(label, .{ .w = size[0], .h = size[1], .child_flags = .{ .border = false } });
}

pub fn endPrimary() void {
    zgui.endChild();
}

pub fn beginSecondary(args: Args, state: *SplitState) bool {
    const size = secondarySize(args, state.size);
    const label = zgui.formatZ("##split_secondary_{s}", .{args.id});
    return zgui.beginChild(label, .{ .w = size[0], .h = size[1], .child_flags = .{ .border = false } });
}

pub fn endSecondary() void {
    zgui.endChild();
}

pub fn handleSplitter(args: Args, state: *SplitState) void {
    const t = theme.activeTheme();
    const thickness: f32 = 6.0;
    const cursor = zgui.getCursorScreenPos();
    const avail = zgui.getContentRegionAvail();
    const splitter_size: [2]f32 = switch (args.axis) {
        .vertical => .{ thickness, avail[1] },
        .horizontal => .{ avail[0], thickness },
    };
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = cursor,
        .pmax = .{ cursor[0] + splitter_size[0], cursor[1] + splitter_size[1] },
        .col = zgui.colorConvertFloat4ToU32(t.colors.divider),
    });

    _ = zgui.invisibleButton("##splitter", .{ .w = splitter_size[0], .h = splitter_size[1] });
    const active = zgui.isItemActive();
    const hovered = zgui.isItemHovered(.{});
    if (active) {
        const drag = zgui.getMouseDragDelta(.left, .{ .lock_threshold = 0.0 });
        const delta = if (args.axis == .vertical) drag[0] else drag[1];
        state.size = clampSize(args, state.size + delta);
        zgui.resetMouseDragDelta(.left);
        state.dragging = true;
    } else if (!hovered) {
        state.dragging = false;
    }

    zgui.sameLine(.{ .spacing = 0.0 });
}

fn paneSize(args: Args, primary: f32) [2]f32 {
    const avail = zgui.getContentRegionAvail();
    return switch (args.axis) {
        .vertical => .{ primary, avail[1] },
        .horizontal => .{ avail[0], primary },
    };
}

fn secondarySize(args: Args, primary: f32) [2]f32 {
    const avail = zgui.getContentRegionAvail();
    const thickness: f32 = 6.0;
    return switch (args.axis) {
        .vertical => .{ avail[0] - primary - thickness, avail[1] },
        .horizontal => .{ avail[0], avail[1] - primary - thickness },
    };
}

fn clampSize(args: Args, size: f32) f32 {
    const avail = zgui.getContentRegionAvail();
    const total = if (args.axis == .vertical) avail[0] else avail[1];
    const thickness: f32 = 6.0;
    const max_primary = @max(args.min_primary, total - args.min_secondary - thickness);
    return std.math.clamp(size, args.min_primary, max_primary);
}
