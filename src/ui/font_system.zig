const std = @import("std");
const builtin = @import("builtin");

const theme = @import("theme.zig");

const font_body_data = @embedFile("../assets/fonts/space_grotesk/SpaceGrotesk-Regular.ttf");
const font_heading_data = @embedFile("../assets/fonts/space_grotesk/SpaceGrotesk-SemiBold.ttf");
const emoji_font_data = @embedFile("../assets/fonts/noto/NotoColorEmoji.ttf");
const emoji_font_windows_data = @embedFile("../assets/fonts/noto/NotoColorEmoji_WindowsCompatible.ttf");
const emoji_mono_data = @embedFile("../assets/fonts/noto/NotoSansSymbols2-Regular.ttf");

var initialized = false;
var current_role: theme.FontRole = .body;
var current_scale: f32 = 1.0;
var current_theme: ?*const theme.Theme = null;

var role_stack: [16]struct { role: theme.FontRole, scale: f32, theme: ?*const theme.Theme } = undefined;
var role_stack_len: usize = 0;

pub fn init(_: std.mem.Allocator) void {
    if (initialized) return;
    initialized = true;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn isReady() bool {
    // Font rasterization happens in the WGPU renderer via freetype, so there is no async readiness.
    return true;
}

pub fn currentRole() theme.FontRole {
    return current_role;
}

pub fn currentScale() f32 {
    return current_scale;
}

pub fn setCurrentTheme(t: *const theme.Theme) void {
    current_theme = t;
}

pub fn currentTheme() ?*const theme.Theme {
    return current_theme;
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

pub fn applyTypography(_: f32, _: f32, _: f32, scale: f32) void {
    current_role = .body;
    current_scale = scale;
    role_stack_len = 0;
}

pub fn push(role: theme.FontRole, scale: f32, t: *const theme.Theme) void {
    if (role_stack_len < role_stack.len) {
        role_stack[role_stack_len] = .{ .role = current_role, .scale = current_scale, .theme = current_theme };
        role_stack_len += 1;
    }
    current_role = role;
    current_scale = scale;
    current_theme = t;
}

pub fn pop() void {
    if (role_stack_len == 0) return;
    role_stack_len -= 1;
    const entry = role_stack[role_stack_len];
    current_role = entry.role;
    current_scale = entry.scale;
    current_theme = entry.theme;
}
