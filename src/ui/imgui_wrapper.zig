const std = @import("std");
const zgui = @import("zgui");
const glfw = @import("zglfw");
const theme = @import("theme.zig");

pub fn init(allocator: std.mem.Allocator, window: *glfw.Window) void {
    zgui.init(allocator);
    zgui.io.setConfigFlags(.{ .dock_enable = true });
    zgui.io.setIniFilename(null);
    theme.apply();
    zgui.backend.init(window);
}

pub fn initWithGlslVersion(
    allocator: std.mem.Allocator,
    window: *glfw.Window,
    glsl_version: [:0]const u8,
) void {
    zgui.init(allocator);
    zgui.io.setConfigFlags(.{ .dock_enable = true });
    zgui.io.setIniFilename(null);
    theme.apply();
    zgui.backend.initWithGlSlVersion(window, glsl_version);
}

pub fn beginFrame(
    window_width: u32,
    window_height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
) void {
    const win_w_u32: u32 = if (window_width > 0) window_width else framebuffer_width;
    const win_h_u32: u32 = if (window_height > 0) window_height else framebuffer_height;
    const win_w: f32 = @floatFromInt(win_w_u32);
    const win_h: f32 = @floatFromInt(win_h_u32);
    zgui.backend.newFrame(win_w_u32, win_h_u32);

    var scale_x: f32 = 1.0;
    var scale_y: f32 = 1.0;
    if (window_width > 0 and window_height > 0) {
        scale_x = @as(f32, @floatFromInt(framebuffer_width)) / win_w;
        scale_y = @as(f32, @floatFromInt(framebuffer_height)) / win_h;
    }
    zgui.io.setDisplayFramebufferScale(scale_x, scale_y);
}

pub fn endFrame() void {
    zgui.backend.draw();
}

pub fn deinit() void {
    zgui.backend.deinit();
    zgui.deinit();
}

pub fn applyDpiScale(scale: f32) void {
    const resolved_scale: f32 = if (scale > 0.0) scale else 1.0;
    theme.apply();
    theme.applyTypography(resolved_scale);
    if (resolved_scale == 1.0) return;
    const style = zgui.getStyle();
    style.scaleAllSizes(resolved_scale);
}
