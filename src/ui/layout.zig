const std = @import("std");
const zgui = @import("zgui");
const ui_state = @import("state.zig");

pub const LayoutMetrics = struct {
    avail_width: f32,
    usable_height: f32,
    spacing_x: f32,
    spacing_y: f32,
    splitter: f32,
    compact_layout: bool,
    left_width: f32,
    right_width: f32,
    center_width: f32,
    sessions_height: f32,
    chat_height: f32,
    settings_height: f32,
};

pub fn compute(
    state: *ui_state.UiState,
    avail_width: f32,
    usable_height: f32,
    spacing_x: f32,
    spacing_y: f32,
) LayoutMetrics {
    const splitter = state.splitter_thickness;
    const total_gap = splitter * 2.0 + spacing_x * 2.0;

    const compact_layout = avail_width <
        state.min_left_width + state.min_right_width + state.min_center_width + total_gap;

    var left_width = state.left_width;
    var right_width = state.right_width;
    var center_width: f32 = avail_width;
    var sessions_height = state.compact_sessions_height;
    var settings_height = state.compact_settings_height;
    var chat_height = usable_height;

    if (!compact_layout) {
        const max_left = @max(
            state.min_left_width,
            avail_width - right_width - state.min_center_width - total_gap,
        );
        left_width = std.math.clamp(left_width, state.min_left_width, max_left);
        const max_right = @max(
            state.min_right_width,
            avail_width - left_width - state.min_center_width - total_gap,
        );
        right_width = std.math.clamp(right_width, state.min_right_width, max_right);
        center_width = @max(1.0, avail_width - left_width - right_width - total_gap);

        state.left_width = left_width;
        state.right_width = right_width;
    } else {
        const total_gap_y = splitter * 2.0 + spacing_y * 2.0;
        const max_sessions = @max(
            state.min_sessions_height,
            usable_height - state.min_chat_height - state.min_settings_height - total_gap_y,
        );
        sessions_height = std.math.clamp(
            sessions_height,
            state.min_sessions_height,
            max_sessions,
        );
        const max_settings = @max(
            state.min_settings_height,
            usable_height - sessions_height - state.min_chat_height - total_gap_y,
        );
        settings_height = std.math.clamp(
            settings_height,
            state.min_settings_height,
            max_settings,
        );
        chat_height = @max(1.0, usable_height - sessions_height - settings_height - total_gap_y);

        state.compact_sessions_height = sessions_height;
        state.compact_settings_height = settings_height;
    }

    return .{
        .avail_width = avail_width,
        .usable_height = usable_height,
        .spacing_x = spacing_x,
        .spacing_y = spacing_y,
        .splitter = splitter,
        .compact_layout = compact_layout,
        .left_width = left_width,
        .right_width = right_width,
        .center_width = center_width,
        .sessions_height = sessions_height,
        .chat_height = chat_height,
        .settings_height = settings_height,
    };
}

pub fn splitterVertical(
    id: []const u8,
    height: f32,
    thickness: f32,
    width: *f32,
    min_width: f32,
    max_width: f32,
    delta_sign: f32,
) bool {
    var changed = false;
    zgui.pushStrId(id);
    _ = zgui.invisibleButton("splitter", .{ .w = thickness, .h = height });
    if (zgui.isItemHovered(.{})) {
        zgui.setMouseCursor(.resize_ew);
    }
    if (zgui.isItemActive()) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        if (delta[0] != 0.0) {
            width.* = std.math.clamp(width.* + delta[0] * delta_sign, min_width, max_width);
            zgui.resetMouseDragDelta(.left);
            changed = true;
        }
    }
    zgui.popId();
    return changed;
}

pub fn splitterHorizontal(
    id: []const u8,
    width: f32,
    thickness: f32,
    height: *f32,
    min_height: f32,
    max_height: f32,
    delta_sign: f32,
) bool {
    var changed = false;
    zgui.pushStrId(id);
    _ = zgui.invisibleButton("splitter", .{ .w = width, .h = thickness });
    if (zgui.isItemHovered(.{})) {
        zgui.setMouseCursor(.resize_ns);
    }
    if (zgui.isItemActive()) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        if (delta[1] != 0.0) {
            height.* = std.math.clamp(height.* + delta[1] * delta_sign, min_height, max_height);
            zgui.resetMouseDragDelta(.left);
            changed = true;
        }
    }
    zgui.popId();
    return changed;
}
