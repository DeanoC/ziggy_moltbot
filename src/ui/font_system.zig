const std = @import("std");
const builtin = @import("builtin");
const ui_build = @import("ui_build.zig");
const use_imgui = ui_build.use_imgui;
const zgui = if (use_imgui) @import("zgui") else struct {};
const theme = @import("theme.zig");

const font_body_data = @embedFile("../assets/fonts/space_grotesk/SpaceGrotesk-Regular.ttf");
const font_heading_data = @embedFile("../assets/fonts/space_grotesk/SpaceGrotesk-SemiBold.ttf");
const emoji_font_data = @embedFile("../assets/fonts/noto/NotoColorEmoji.ttf");
const emoji_font_windows_data = @embedFile("../assets/fonts/noto/NotoColorEmoji_WindowsCompatible.ttf");
const emoji_mono_data = @embedFile("../assets/fonts/noto/NotoSansSymbols2-Regular.ttf");

const EmojiWchar = if (use_imgui) zgui.Wchar else u16;
const emoji_ranges = [_]EmojiWchar{
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

var initialized = false;
const FontHandle = if (use_imgui) zgui.Font else u8;
const FontConfig = if (use_imgui)
    zgui.FontConfig
else
    struct {
        pub fn init() FontConfig {
            return .{};
        }
    };
var font_body: ?FontHandle = null;
var font_heading: ?FontHandle = null;
var font_title: ?FontHandle = null;
var current_role: theme.FontRole = .body;
var current_scale: f32 = 1.0;
var role_stack: [16]struct { role: theme.FontRole, scale: f32 } = undefined;
var role_stack_len: usize = 0;

pub fn init(_: std.mem.Allocator) void {
    if (initialized) return;
    initialized = true;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn isReady() bool {
    return !use_imgui or font_body != null;
}

pub fn currentRole() theme.FontRole {
    return current_role;
}

pub fn currentScale() f32 {
    return current_scale;
}

pub fn currentFontSize(t: *const theme.Theme) f32 {
    return switch (current_role) {
        .body => t.typography.body_size * current_scale,
        .heading => t.typography.heading_size * current_scale,
        .title => t.typography.title_size * current_scale,
    };
}

pub fn fontDataFor(role: theme.FontRole) []const u8 {
    return switch (role) {
        .body => font_body_data,
        .heading, .title => font_heading_data,
    };
}

pub fn emojiFontData() []const u8 {
    return if (builtin.os.tag == .windows) emoji_font_windows_data else emoji_font_data;
}

pub fn emojiMonoFontData() []const u8 {
    return emoji_mono_data;
}

fn tryAddEmojiFontFromFile(path: [:0]const u8, size: f32, cfg: FontConfig) bool {
    if (!use_imgui) return false;
    const path_ptr: [*:0]const u8 = @ptrCast(path.ptr);
    if (std.fs.accessAbsoluteZ(path_ptr, .{})) |_| {} else |_| return false;
    const font: ?zgui.Font = zgui.io.addFontFromFileWithConfig(path, size, cfg, &emoji_ranges);
    return font != null;
}

fn addEmojiFontFromMemory(size: f32, cfg: FontConfig) void {
    if (!use_imgui) return;
    _ = zgui.io.addFontFromMemoryWithConfig(emoji_font_data, size, cfg, &emoji_ranges);
}

fn addEmojiFont(size: f32, cfg: FontConfig) void {
    if (!use_imgui) return;
    if (builtin.abi.isAndroid() or builtin.cpu.arch == .wasm32) {
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

pub fn applyTypography(body_size: f32, heading_size: f32, title_size: f32, scale: f32) void {
    current_role = .body;
    current_scale = scale;
    role_stack_len = 0;
    if (!use_imgui) return;
    var cfg = FontConfig.init();
    cfg.font_data_owned_by_atlas = false;
    cfg.pixel_snap_h = true;
    cfg.oversample_h = 2;
    cfg.oversample_v = 2;

    font_body = zgui.io.addFontFromMemoryWithConfig(font_body_data, body_size, cfg, null);

    var emoji_cfg = FontConfig.init();
    emoji_cfg.merge_mode = true;
    emoji_cfg.font_data_owned_by_atlas = false;
    emoji_cfg.pixel_snap_h = true;
    if (use_imgui) {
        emoji_cfg.font_loader_flags = @as(c_uint, @bitCast(zgui.FreeTypeLoaderFlags{ .load_color = true }));
    }
    addEmojiFont(body_size, emoji_cfg);

    font_heading = zgui.io.addFontFromMemoryWithConfig(font_heading_data, heading_size, cfg, null);
    addEmojiFont(heading_size, emoji_cfg);

    font_title = zgui.io.addFontFromMemoryWithConfig(font_heading_data, title_size, cfg, null);
    addEmojiFont(title_size, emoji_cfg);

    if (font_body) |body| {
        zgui.io.setDefaultFont(body);
    }
}

pub fn push(role: theme.FontRole, scale: f32, t: *const theme.Theme) void {
    if (role_stack_len < role_stack.len) {
        role_stack[role_stack_len] = .{ .role = current_role, .scale = current_scale };
        role_stack_len += 1;
    }
    current_role = role;
    current_scale = scale;
    if (!use_imgui) return;
    switch (role) {
        .body => zgui.pushFont(font_body, t.typography.body_size * scale),
        .heading => zgui.pushFont(font_heading, t.typography.heading_size * scale),
        .title => zgui.pushFont(font_title, t.typography.title_size * scale),
    }
}

pub fn pop() void {
    if (role_stack_len > 0) {
        role_stack_len -= 1;
        const entry = role_stack[role_stack_len];
        current_role = entry.role;
        current_scale = entry.scale;
    }
    if (!use_imgui) return;
    zgui.popFont();
}
