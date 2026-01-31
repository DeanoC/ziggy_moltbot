const std = @import("std");
const zgui = @import("zgui");
const glfw = @import("zglfw");
const theme = @import("theme.zig");

pub fn init(
    allocator: std.mem.Allocator,
    window: *glfw.Window,
    device: *const anyopaque,
    swapchain_format: u32,
    depth_format: u32,
) void {
    zgui.init(allocator);
    zgui.io.setConfigFlags(.{ .dock_enable = true });
    zgui.io.setIniFilename(null);
    theme.apply();
    zgui.backend.init(
        @ptrCast(window),
        device,
        swapchain_format,
        depth_format,
    );
}

pub fn beginFrame(framebuffer_width: u32, framebuffer_height: u32) void {
    zgui.backend.newFrame(framebuffer_width, framebuffer_height);
}

pub fn render(pass: *const anyopaque) void {
    zgui.backend.draw(pass);
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
