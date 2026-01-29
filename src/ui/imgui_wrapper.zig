const std = @import("std");
const zgui = @import("zgui");
const glfw = @import("zglfw");

pub fn init(allocator: std.mem.Allocator, window: *glfw.Window) void {
    zgui.init(allocator);
    zgui.styleColorsDark(zgui.getStyle());
    zgui.backend.init(window);
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
    if (scale <= 0.0 or scale == 1.0) return;

    var cfg = zgui.FontConfig.init();
    cfg.size_pixels = 16.0 * scale;
    const font = zgui.io.addFontDefault(cfg);
    zgui.io.setDefaultFont(font);

    const style = zgui.getStyle();
    style.scaleAllSizes(scale);
}
