const std = @import("std");

const theme_tokens = @import("theme/theme.zig");

const font_system = @import("font_system.zig");

pub const FontRole = enum {
    body,
    heading,
    title,
};

pub const Mode = theme_tokens.Mode;
pub const Theme = theme_tokens.Theme;

var active_mode: Mode = .light;

// Optional runtime theme overrides (owned by ThemeEngine).
var runtime_light: ?*const Theme = null;
var runtime_dark: ?*const Theme = null;

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
    const runtime = switch (active_mode) {
        .light => runtime_light,
        .dark => runtime_dark,
    };
    return runtime orelse theme_tokens.get(active_mode);
}

/// Set a runtime theme pointer for a mode. Ownership is external (ThemeEngine must keep it alive).
pub fn setRuntimeTheme(mode: Mode, theme_ptr: ?*const Theme) void {
    switch (mode) {
        .light => runtime_light = theme_ptr,
        .dark => runtime_dark = theme_ptr,
    }
}

pub fn apply() void {
    if (!font_system.isInitialized()) {
        font_system.init(std.heap.page_allocator);
    }
}

pub fn applyTypography(scale: f32) void {
    applyTypographyFor(activeTheme(), scale);
}

pub fn applyTypographyFor(t: *const Theme, scale: f32) void {
    if (scale <= 0.0) return;
    // Keep font sizing/theme-aware metrics consistent with the DrawContext theme.
    font_system.setCurrentTheme(t);
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
    pushFor(activeTheme(), role);
}

pub fn pushFor(t: *const Theme, role: FontRole) void {
    const scale = if (last_scale > 0.0) last_scale else 1.0;
    font_system.push(role, scale, t);
}

pub fn pop() void {
    font_system.pop();
}
