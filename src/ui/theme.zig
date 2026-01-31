const std = @import("std");
const zgui = @import("zgui");
const builtin = @import("builtin");

const font_body_data = @embedFile("../assets/fonts/space_grotesk/SpaceGrotesk-Regular.ttf");
const font_heading_data = @embedFile("../assets/fonts/space_grotesk/SpaceGrotesk-SemiBold.ttf");
const emoji_font_data = @embedFile("../assets/fonts/noto/NotoColorEmoji.ttf");

const emoji_ranges = [_]zgui.Wchar{
    0x0020, 0x00FF,
    0x2000, 0x206F,
    0x2600, 0x27BF,
    0x1F100, 0x1F1FF,
    0x1F300, 0x1F5FF,
    0x1F600, 0x1F64F,
    0x1F680, 0x1F6FF,
    0x1F900, 0x1F9FF,
    0x1FA70, 0x1FAFF,
    0,
};

pub const FontRole = enum {
    body,
    heading,
    title,
};

var font_body: ?zgui.Font = null;
var font_heading: ?zgui.Font = null;
var font_title: ?zgui.Font = null;
var last_scale: f32 = 0.0;

fn rgba(r: u8, g: u8, b: u8, a: u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

pub fn apply() void {
    const style = zgui.getStyle();
    zgui.styleColorsDark(style);

    style.alpha = 1.0;
    style.disabled_alpha = 0.5;
    style.window_padding = .{ 16.0, 14.0 };
    style.frame_padding = .{ 10.0, 6.0 };
    style.item_spacing = .{ 10.0, 8.0 };
    style.item_inner_spacing = .{ 8.0, 6.0 };
    style.cell_padding = .{ 8.0, 6.0 };
    style.indent_spacing = 20.0;
    style.scrollbar_size = 12.0;
    style.grab_min_size = 12.0;
    style.window_rounding = 8.0;
    style.child_rounding = 8.0;
    style.popup_rounding = 8.0;
    style.frame_rounding = 6.0;
    style.scrollbar_rounding = 10.0;
    style.grab_rounding = 6.0;
    style.tab_rounding = 6.0;
    style.window_border_size = 1.0;
    style.child_border_size = 1.0;
    style.popup_border_size = 1.0;
    style.frame_border_size = 1.0;
    style.tab_border_size = 0.0;
    style.tab_bar_border_size = 0.0;
    style.separator_text_border_size = 1.0;
    style.separator_text_padding = .{ 8.0, 6.0 };
    style.display_safe_area_padding = .{ 6.0, 6.0 };

    const accent = rgba(229, 148, 59, 255);
    const accent_soft = rgba(229, 148, 59, 170);
    const accent_light = rgba(240, 176, 92, 255);

    style.setColor(.text, rgba(230, 233, 237, 255));
    style.setColor(.text_disabled, rgba(154, 162, 172, 255));
    style.setColor(.window_bg, rgba(20, 23, 26, 255));
    style.setColor(.child_bg, rgba(20, 23, 26, 255));
    style.setColor(.popup_bg, rgba(27, 31, 37, 248));
    style.setColor(.border, rgba(43, 49, 58, 255));
    style.setColor(.border_shadow, rgba(0, 0, 0, 0));
    style.setColor(.frame_bg, rgba(30, 35, 43, 255));
    style.setColor(.frame_bg_hovered, rgba(36, 42, 51, 255));
    style.setColor(.frame_bg_active, rgba(42, 49, 59, 255));
    style.setColor(.title_bg, rgba(17, 20, 24, 255));
    style.setColor(.title_bg_active, rgba(27, 32, 39, 255));
    style.setColor(.title_bg_collapsed, rgba(17, 20, 24, 255));
    style.setColor(.menu_bar_bg, rgba(25, 29, 35, 255));
    style.setColor(.scrollbar_bg, rgba(17, 20, 24, 255));
    style.setColor(.scrollbar_grab, rgba(42, 49, 59, 255));
    style.setColor(.scrollbar_grab_hovered, rgba(51, 59, 70, 255));
    style.setColor(.scrollbar_grab_active, rgba(59, 69, 82, 255));
    style.setColor(.check_mark, accent);
    style.setColor(.slider_grab, accent);
    style.setColor(.slider_grab_active, accent_light);
    style.setColor(.button, rgba(35, 42, 51, 255));
    style.setColor(.button_hovered, rgba(42, 50, 61, 255));
    style.setColor(.button_active, rgba(50, 59, 71, 255));
    style.setColor(.header, rgba(35, 42, 51, 255));
    style.setColor(.header_hovered, rgba(42, 50, 61, 255));
    style.setColor(.header_active, rgba(50, 59, 71, 255));
    style.setColor(.separator, rgba(43, 49, 58, 255));
    style.setColor(.separator_hovered, accent);
    style.setColor(.separator_active, accent_light);
    style.setColor(.resize_grip, rgba(229, 148, 59, 64));
    style.setColor(.resize_grip_hovered, accent_soft);
    style.setColor(.resize_grip_active, accent_light);
    style.setColor(.input_text_cursor, accent);
    style.setColor(.tab_hovered, rgba(42, 50, 61, 255));
    style.setColor(.tab, rgba(32, 38, 47, 255));
    style.setColor(.tab_selected, rgba(45, 53, 65, 255));
    style.setColor(.tab_selected_overline, accent);
    style.setColor(.tab_dimmed, rgba(26, 31, 38, 255));
    style.setColor(.tab_dimmed_selected, rgba(36, 43, 53, 255));
    style.setColor(.tab_dimmed_selected_overline, rgba(229, 148, 59, 128));
    style.setColor(.docking_preview, rgba(229, 148, 59, 70));
    style.setColor(.docking_empty_bg, rgba(20, 23, 26, 255));
    style.setColor(.plot_lines, rgba(144, 187, 214, 255));
    style.setColor(.plot_lines_hovered, accent_light);
    style.setColor(.plot_histogram, rgba(111, 176, 138, 255));
    style.setColor(.plot_histogram_hovered, accent_light);
    style.setColor(.table_header_bg, rgba(30, 36, 44, 255));
    style.setColor(.table_border_strong, rgba(43, 49, 58, 255));
    style.setColor(.table_border_light, rgba(33, 39, 48, 255));
    style.setColor(.table_row_bg, rgba(22, 26, 31, 255));
    style.setColor(.table_row_bg_alt, rgba(26, 31, 38, 255));
    style.setColor(.text_link, accent);
    style.setColor(.text_selected_bg, rgba(229, 148, 59, 70));
    style.setColor(.tree_lines, rgba(43, 49, 58, 255));
    style.setColor(.drag_drop_target, rgba(229, 148, 59, 220));
    style.setColor(.nav_cursor, rgba(229, 148, 59, 200));
    style.setColor(.nav_windowing_highlight, rgba(229, 148, 59, 170));
    style.setColor(.nav_windowing_dim_bg, rgba(0, 0, 0, 80));
    style.setColor(.modal_window_dim_bg, rgba(0, 0, 0, 110));
}

fn tryAddEmojiFontFromFile(path: [:0]const u8, size: f32, cfg: zgui.FontConfig) bool {
    const path_ptr: [*:0]const u8 = @ptrCast(path.ptr);
    if (std.fs.accessAbsoluteZ(path_ptr, .{})) |_| {} else |_| return false;
    const font: ?zgui.Font = zgui.io.addFontFromFileWithConfig(path, size, cfg, &emoji_ranges);
    return font != null;
}

fn addEmojiFontFromMemory(size: f32, cfg: zgui.FontConfig) void {
    _ = zgui.io.addFontFromMemoryWithConfig(emoji_font_data, size, cfg, &emoji_ranges);
}

fn addEmojiFont(size: f32, cfg: zgui.FontConfig) void {
    if (builtin.abi == .android or builtin.cpu.arch == .wasm32) {
        addEmojiFontFromMemory(size, cfg);
        return;
    }
    if (builtin.os.tag == .windows) {
        if (!tryAddEmojiFontFromFile("C:\\\\Windows\\\\Fonts\\\\seguiemj.ttf", size, cfg)) {
            addEmojiFontFromMemory(size, cfg);
        }
        return;
    }
    if (builtin.os.tag == .macos) {
        if (!tryAddEmojiFontFromFile("/System/Library/Fonts/Apple Color Emoji.ttc", size, cfg)) {
            addEmojiFontFromMemory(size, cfg);
        }
        return;
    }

    const linux_paths = [_][:0]const u8{
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/noto/NotoColorEmoji.ttf",
    };
    for (linux_paths) |path| {
        if (tryAddEmojiFontFromFile(path, size, cfg)) return;
    }
    addEmojiFontFromMemory(size, cfg);
}

pub fn applyTypography(scale: f32) void {
    if (scale <= 0.0) return;
    if (last_scale == scale and font_body != null) return;
    last_scale = scale;

    const body_size = 16.0 * scale;
    const heading_size = 18.0 * scale;
    const title_size = 22.0 * scale;

    var cfg = zgui.FontConfig.init();
    cfg.font_data_owned_by_atlas = false;
    cfg.pixel_snap_h = true;
    cfg.oversample_h = 2;
    cfg.oversample_v = 2;

    font_body = zgui.io.addFontFromMemoryWithConfig(font_body_data, body_size, cfg, null);

    var emoji_cfg = zgui.FontConfig.init();
    emoji_cfg.merge_mode = true;
    emoji_cfg.font_data_owned_by_atlas = false;
    emoji_cfg.pixel_snap_h = true;
    emoji_cfg.font_loader_flags = @as(c_uint, @bitCast(zgui.FreeTypeLoaderFlags{ .load_color = true }));
    addEmojiFont(body_size, emoji_cfg);

    font_heading = zgui.io.addFontFromMemoryWithConfig(font_heading_data, heading_size, cfg, null);
    addEmojiFont(heading_size, emoji_cfg);

    font_title = zgui.io.addFontFromMemoryWithConfig(font_heading_data, title_size, cfg, null);
    addEmojiFont(title_size, emoji_cfg);

    if (font_body) |body| {
        zgui.io.setDefaultFont(body);
    }
}

pub fn push(role: FontRole) void {
    const scale = if (last_scale > 0.0) last_scale else 1.0;
    switch (role) {
        .body => zgui.pushFont(font_body, 16.0 * scale),
        .heading => zgui.pushFont(font_heading, 18.0 * scale),
        .title => zgui.pushFont(font_title, 22.0 * scale),
    }
}

pub fn pop() void {
    zgui.popFont();
}
