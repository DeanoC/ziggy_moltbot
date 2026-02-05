const std = @import("std");
const zgpu = @import("zgpu");
const command_queue = @import("../ui/render/command_queue.zig");
const ui_wgpu_renderer = @import("../ui/render/wgpu_renderer.zig");
const sdl = @import("../platform/sdl3.zig").c;
const profiler = @import("../utils/profiler.zig");

pub const depth_format_undefined: u32 = @intFromEnum(zgpu.wgpu.TextureFormat.undef);

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    ui_renderer: ui_wgpu_renderer.Renderer,
    framebuffer_width: u32 = 1,
    framebuffer_height: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, window: *sdl.SDL_Window) !Renderer {
        cachePlatformHandles(window);
        const window_provider = zgpu.WindowProvider{
            .window = window,
            .fn_getTime = &sdlGetTime,
            .fn_getFramebufferSize = &sdlGetFramebufferSize,
            .fn_getWin32Window = &sdlGetWin32Window,
            .fn_getX11Display = &sdlGetX11Display,
            .fn_getX11Window = &sdlGetX11Window,
            .fn_getWaylandDisplay = if (g_wayland_display != null) &sdlGetWaylandDisplay else null,
            .fn_getWaylandSurface = if (g_wayland_display != null) &sdlGetWaylandSurface else null,
            .fn_getCocoaWindow = &sdlGetCocoaWindow,
        };

        const gctx = try zgpu.GraphicsContext.create(allocator, window_provider, .{});
        const ui_renderer = try ui_wgpu_renderer.Renderer.init(allocator, gctx);

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .ui_renderer = ui_renderer,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.ui_renderer.deinit();
        zgpu.GraphicsContext.destroy(self.gctx, self.allocator);
    }

    pub fn beginFrame(self: *Renderer, framebuffer_width: u32, framebuffer_height: u32) void {
        const zone = profiler.zone("renderer.beginFrame");
        defer zone.end();
        self.framebuffer_width = framebuffer_width;
        self.framebuffer_height = framebuffer_height;
        if (framebuffer_width > 0 and framebuffer_height > 0) {
            if (self.gctx.swapchain_descriptor.width != framebuffer_width or
                self.gctx.swapchain_descriptor.height != framebuffer_height)
            {
                self.gctx.swapchain_descriptor.width = framebuffer_width;
                self.gctx.swapchain_descriptor.height = framebuffer_height;
                self.gctx.swapchain.release();
                self.gctx.swapchain = self.gctx.device.createSwapChain(
                    self.gctx.surface,
                    self.gctx.swapchain_descriptor,
                );
            }
        }
        self.ui_renderer.beginFrame(framebuffer_width, framebuffer_height);
    }

    pub fn render(self: *Renderer) void {
        const zone = profiler.zone("renderer.render");
        defer zone.end();
        const gctx = self.gctx;
        const back_view = gctx.swapchain.getCurrentTextureView();
        defer back_view.release();

        const encoder = gctx.device.createCommandEncoder(null);

        var color_attachments = [_]zgpu.wgpu.RenderPassColorAttachment{.{
            .view = back_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.08, .g = 0.08, .b = 0.1, .a = 1.0 },
        }};

        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        });

        if (command_queue.get()) |list| {
            const record_zone = profiler.zone("renderer.record");
            defer record_zone.end();
            self.ui_renderer.record(list);
            self.ui_renderer.render(pass);
        }
        pass.end();

        const cmd = encoder.finish(null);
        gctx.submit(&.{cmd});
        cmd.release();

        _ = gctx.present();
    }
};

var g_x11_display: ?*anyopaque = null;
var g_wayland_display: ?*anyopaque = null;

fn cachePlatformHandles(window: *sdl.SDL_Window) void {
    const props = sdl.SDL_GetWindowProperties(window);
    g_x11_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null);
    g_wayland_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
}

fn sdlGetTime() f64 {
    const ticks = sdl.SDL_GetTicks();
    return @as(f64, @floatFromInt(ticks)) / 1000.0;
}

fn sdlGetFramebufferSize(window_ptr: *const anyopaque) [2]u32 {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(@constCast(@ptrCast(window_ptr)), &w, &h);
    const w_u32: u32 = @intCast(if (w > 0) w else 1);
    const h_u32: u32 = @intCast(if (h > 0) h else 1);
    return .{ w_u32, h_u32 };
}

fn sdlGetWin32Window(window_ptr: *const anyopaque) callconv(.c) *anyopaque {
    const props = sdl.SDL_GetWindowProperties(@constCast(@ptrCast(window_ptr)));
    return sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) orelse unreachable;
}

fn sdlGetX11Display() callconv(.c) *anyopaque {
    return g_x11_display orelse unreachable;
}

fn sdlGetX11Window(window_ptr: *const anyopaque) callconv(.c) u32 {
    const props = sdl.SDL_GetWindowProperties(@constCast(@ptrCast(window_ptr)));
    const value = sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    return @intCast(value);
}

fn sdlGetWaylandDisplay() callconv(.c) *anyopaque {
    return g_wayland_display orelse unreachable;
}

fn sdlGetWaylandSurface(window_ptr: *const anyopaque) callconv(.c) *anyopaque {
    const props = sdl.SDL_GetWindowProperties(@constCast(@ptrCast(window_ptr)));
    return sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse unreachable;
}

fn sdlGetCocoaWindow(window_ptr: *const anyopaque) callconv(.c) ?*anyopaque {
    const props = sdl.SDL_GetWindowProperties(@constCast(@ptrCast(window_ptr)));
    return sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
}
