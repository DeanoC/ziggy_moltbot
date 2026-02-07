const std = @import("std");
const builtin = @import("builtin");

pub const ProfileId = enum {
    desktop,
    phone,
    tablet,
    fullscreen,
};

pub const InputModality = enum {
    pointer_keyboard,
    touch,
    touch_pen,
    controller,
};

pub const Density = enum {
    compact,
    medium,
    large,
    huge,
};

pub const PlatformCaps = struct {
    supports_filesystem_read: bool,
    supports_filesystem_write: bool,
    supports_multi_window: bool,
    supports_shader_hot_reload: bool,
    supports_pointer_hover: bool,
    supports_touch: bool,
    supports_pen: bool,
    supports_gamepad: bool,

    pub fn defaultForTarget() PlatformCaps {
        const is_wasm = builtin.cpu.arch == .wasm32;
        const is_android = builtin.abi.isAndroid();

        return .{
            .supports_filesystem_read = !is_wasm,
            .supports_filesystem_write = !is_wasm,
            .supports_multi_window = !is_wasm and !is_android,
            .supports_shader_hot_reload = !is_wasm,
            .supports_pointer_hover = !is_android and !is_wasm,
            .supports_touch = is_android or is_wasm,
            .supports_pen = is_android, // conservative default; can be refined by platform probes later
            .supports_gamepad = true, // SDL initializes GAMEPAD already; event wiring may still be TODO
        };
    }
};

pub const Profile = struct {
    id: ProfileId,
    density: Density,
    hit_target_min_px: f32,
    ui_scale: f32,
    modality: InputModality,
    allow_multi_window: bool,
    allow_hover_states: bool,
};

pub fn profileFromLabel(label: ?[]const u8) ?ProfileId {
    const value = label orelse return null;
    if (std.ascii.eqlIgnoreCase(value, "desktop")) return .desktop;
    if (std.ascii.eqlIgnoreCase(value, "phone")) return .phone;
    if (std.ascii.eqlIgnoreCase(value, "tablet")) return .tablet;
    if (std.ascii.eqlIgnoreCase(value, "fullscreen")) return .fullscreen;
    return null;
}

pub fn labelForProfile(id: ProfileId) []const u8 {
    return switch (id) {
        .desktop => "desktop",
        .phone => "phone",
        .tablet => "tablet",
        .fullscreen => "fullscreen",
    };
}

/// Heuristic resolver used until we have richer signals (touch events, gamepad activity, etc.).
pub fn resolveProfile(
    caps: PlatformCaps,
    framebuffer_width: u32,
    framebuffer_height: u32,
    requested: ?ProfileId,
) Profile {
    if (requested) |id| return defaultsFor(id, caps);

    // Conservative defaults:
    // - Android: phone/tablet based on shortest dimension
    // - WASM: desktop-ish unless narrow
    // - Desktop OS: desktop
    const w = @as(f32, @floatFromInt(if (framebuffer_width > 0) framebuffer_width else 1));
    const h = @as(f32, @floatFromInt(if (framebuffer_height > 0) framebuffer_height else 1));
    const short = @min(w, h);

    if (builtin.abi.isAndroid()) {
        if (short < 900.0) return defaultsFor(.phone, caps);
        return defaultsFor(.tablet, caps);
    }
    if (builtin.cpu.arch == .wasm32) {
        if (short < 800.0) return defaultsFor(.phone, caps);
        return defaultsFor(.desktop, caps);
    }
    return defaultsFor(.desktop, caps);
}

pub fn defaultsFor(id: ProfileId, caps: PlatformCaps) Profile {
    return switch (id) {
        .desktop => .{
            .id = .desktop,
            .density = .compact,
            .hit_target_min_px = 32.0,
            .ui_scale = 1.0,
            .modality = .pointer_keyboard,
            .allow_multi_window = caps.supports_multi_window,
            .allow_hover_states = caps.supports_pointer_hover,
        },
        .phone => .{
            .id = .phone,
            .density = .large,
            .hit_target_min_px = 48.0,
            .ui_scale = 1.15,
            .modality = .touch,
            .allow_multi_window = false,
            .allow_hover_states = false,
        },
        .tablet => .{
            .id = .tablet,
            .density = .medium,
            .hit_target_min_px = 44.0,
            .ui_scale = 1.1,
            .modality = .touch_pen,
            .allow_multi_window = false,
            .allow_hover_states = caps.supports_pointer_hover,
        },
        .fullscreen => .{
            .id = .fullscreen,
            .density = .huge,
            .hit_target_min_px = 56.0,
            .ui_scale = 1.25,
            .modality = .controller,
            .allow_multi_window = false,
            .allow_hover_states = false,
        },
    };
}

