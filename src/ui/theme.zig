const std = @import("std");
const ui_build = @import("ui_build.zig");
const use_imgui = ui_build.use_imgui;
const zgui = if (use_imgui) @import("zgui") else struct {};

const theme_tokens = @import("theme/theme.zig");
const colors = @import("theme/colors.zig");

const font_system = @import("font_system.zig");

pub const FontRole = enum {
    body,
    heading,
    title,
};

pub const Mode = theme_tokens.Mode;
pub const Theme = theme_tokens.Theme;

var active_mode: Mode = .light;

var last_scale: f32 = 0.0;
var last_body_size: f32 = 0.0;
var last_heading_size: f32 = 0.0;
var last_title_size: f32 = 0.0;

pub fn setMode(mode: Mode) void {
    active_mode = mode;
}

pub fn getMode() Mode {
    return active_mode;
}

pub fn toggleMode() void {
    active_mode = if (active_mode == .light) .dark else .light;
}

pub fn modeFromLabel(label: ?[]const u8) Mode {
    if (label) |value| {
        if (std.ascii.eqlIgnoreCase(value, "dark")) return .dark;
        if (std.ascii.eqlIgnoreCase(value, "light")) return .light;
    }
    return .light;
}

pub fn labelForMode(mode: Mode) []const u8 {
    return switch (mode) {
        .light => "light",
        .dark => "dark",
    };
}

pub fn activeTheme() *const Theme {
    return theme_tokens.get(active_mode);
}

fn tone(base: colors.Color, amount: f32) colors.Color {
    const target = if (active_mode == .light)
        colors.rgba(0, 0, 0, 255)
    else
        colors.rgba(255, 255, 255, 255);
    return colors.blend(base, target, amount);
}

pub fn apply() void {
    if (!font_system.isInitialized()) {
        font_system.init(std.heap.page_allocator);
    }
    if (!use_imgui) return;
    const style = zgui.getStyle();
    switch (active_mode) {
        .light => zgui.styleColorsLight(style),
        .dark => zgui.styleColorsDark(style),
    }

    const t = activeTheme();
    const c = t.colors;

    style.alpha = 1.0;
    style.disabled_alpha = 0.5;
    style.window_padding = .{ t.spacing.md, t.spacing.md };
    style.frame_padding = .{ t.spacing.sm, t.spacing.xs };
    style.item_spacing = .{ t.spacing.sm, t.spacing.sm };
    style.item_inner_spacing = .{ t.spacing.xs, t.spacing.xs };
    style.cell_padding = .{ t.spacing.sm, t.spacing.xs };
    style.indent_spacing = t.spacing.lg;
    style.scrollbar_size = 12.0;
    style.grab_min_size = 12.0;
    style.window_rounding = t.radius.md;
    style.child_rounding = t.radius.md;
    style.popup_rounding = t.radius.md;
    style.frame_rounding = t.radius.sm;
    style.scrollbar_rounding = t.radius.lg;
    style.grab_rounding = t.radius.sm;
    style.tab_rounding = t.radius.sm;
    style.window_border_size = 1.0;
    style.child_border_size = 1.0;
    style.popup_border_size = 1.0;
    style.frame_border_size = 1.0;
    style.tab_border_size = 0.0;
    style.tab_bar_border_size = 0.0;
    style.separator_text_border_size = 1.0;
    style.separator_text_padding = .{ t.spacing.sm, t.spacing.xs };
    style.display_safe_area_padding = .{ t.spacing.sm, t.spacing.sm };

    const accent = c.primary;
    const accent_soft = colors.withAlpha(accent, 0.6);
    const accent_light = tone(accent, 0.2);

    const surface = c.surface;
    const surface_hover = tone(surface, 0.06);
    const surface_active = tone(surface, 0.12);
    const surface_selected = tone(surface, 0.18);
    const background_alt = tone(c.background, 0.04);

    style.setColor(.text, c.text_primary);
    style.setColor(.text_disabled, colors.withAlpha(c.text_secondary, 0.7));
    style.setColor(.window_bg, c.background);
    style.setColor(.child_bg, c.background);
    style.setColor(.popup_bg, c.surface);
    style.setColor(.border, c.border);
    style.setColor(.border_shadow, colors.rgba(0, 0, 0, 0));
    style.setColor(.frame_bg, surface);
    style.setColor(.frame_bg_hovered, surface_hover);
    style.setColor(.frame_bg_active, surface_active);
    style.setColor(.title_bg, c.background);
    style.setColor(.title_bg_active, background_alt);
    style.setColor(.title_bg_collapsed, c.background);
    style.setColor(.menu_bar_bg, background_alt);
    style.setColor(.scrollbar_bg, c.background);
    style.setColor(.scrollbar_grab, surface_active);
    style.setColor(.scrollbar_grab_hovered, surface_selected);
    style.setColor(.scrollbar_grab_active, tone(surface_selected, 0.08));
    style.setColor(.check_mark, accent);
    style.setColor(.slider_grab, accent);
    style.setColor(.slider_grab_active, accent_light);
    style.setColor(.button, surface);
    style.setColor(.button_hovered, surface_hover);
    style.setColor(.button_active, surface_active);
    style.setColor(.header, surface);
    style.setColor(.header_hovered, surface_hover);
    style.setColor(.header_active, surface_active);
    style.setColor(.separator, c.divider);
    style.setColor(.separator_hovered, accent);
    style.setColor(.separator_active, accent_light);
    style.setColor(.resize_grip, colors.withAlpha(accent, 0.25));
    style.setColor(.resize_grip_hovered, accent_soft);
    style.setColor(.resize_grip_active, accent_light);
    style.setColor(.input_text_cursor, accent);
    style.setColor(.tab_hovered, surface_hover);
    style.setColor(.tab, background_alt);
    style.setColor(.tab_selected, surface);
    style.setColor(.tab_selected_overline, accent);
    style.setColor(.tab_dimmed, background_alt);
    style.setColor(.tab_dimmed_selected, surface);
    style.setColor(.tab_dimmed_selected_overline, colors.withAlpha(accent, 0.5));
    style.setColor(.docking_preview, colors.withAlpha(accent, 0.27));
    style.setColor(.docking_empty_bg, c.background);
    style.setColor(.plot_lines, accent);
    style.setColor(.plot_lines_hovered, accent_light);
    style.setColor(.plot_histogram, c.success);
    style.setColor(.plot_histogram_hovered, accent_light);
    style.setColor(.table_header_bg, surface);
    style.setColor(.table_border_strong, c.border);
    style.setColor(.table_border_light, c.divider);
    style.setColor(.table_row_bg, c.background);
    style.setColor(.table_row_bg_alt, background_alt);
    style.setColor(.text_link, accent);
    style.setColor(.text_selected_bg, colors.withAlpha(accent, 0.25));
    style.setColor(.tree_lines, c.divider);
    style.setColor(.drag_drop_target, colors.withAlpha(accent, 0.85));
    style.setColor(.nav_cursor, colors.withAlpha(accent, 0.8));
    style.setColor(.nav_windowing_highlight, colors.withAlpha(accent, 0.65));
    style.setColor(.nav_windowing_dim_bg, colors.withAlpha(colors.rgba(0, 0, 0, 255), 0.35));
    style.setColor(.modal_window_dim_bg, colors.withAlpha(colors.rgba(0, 0, 0, 255), 0.45));
}

pub fn applyTypography(scale: f32) void {
    if (scale <= 0.0) return;
    const t = activeTheme();
    const body_size = t.typography.body_size * scale;
    const heading_size = t.typography.heading_size * scale;
    const title_size = t.typography.title_size * scale;

    if (last_scale == scale and last_body_size == body_size and last_heading_size == heading_size and last_title_size == title_size and font_system.isReady()) return;

    last_scale = scale;
    last_body_size = body_size;
    last_heading_size = heading_size;
    last_title_size = title_size;

    font_system.applyTypography(body_size, heading_size, title_size, scale);
}

pub fn push(role: FontRole) void {
    const t = activeTheme();
    const scale = if (last_scale > 0.0) last_scale else 1.0;
    font_system.push(role, scale, t);
}

pub fn pop() void {
    font_system.pop();
}
