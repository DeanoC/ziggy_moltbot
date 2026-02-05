const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");
const command_queue = @import("../ui/render/command_queue.zig");
const ui_wgpu_renderer = @import("../ui/render/wgpu_renderer.zig");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    ui_renderer: ui_wgpu_renderer.Renderer,
    framebuffer_width: u32 = 1,
    framebuffer_height: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !Renderer {
        const window_provider = zgpu.WindowProvider{
            .window = window,
            .fn_getTime = &glfwGetTime,
            .fn_getFramebufferSize = &glfwGetFramebufferSize,
            .fn_getWin32Window = &glfwGetWin32Window,
            .fn_getX11Display = &glfwGetX11Display,
            .fn_getX11Window = &glfwGetX11Window,
            .fn_getWaylandDisplay = null,
            .fn_getWaylandSurface = null,
            .fn_getCocoaWindow = &glfwGetCocoaWindow,
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

fn glfwGetTime() f64 {
    return zglfw.getTime();
}

fn glfwGetFramebufferSize(window_ptr: *const anyopaque) [2]u32 {
    const win: *zglfw.Window = @ptrCast(@alignCast(@constCast(window_ptr)));
    const size = win.getFramebufferSize();
    const w: u32 = @intCast(if (size[0] > 0) size[0] else 1);
    const h: u32 = @intCast(if (size[1] > 0) size[1] else 1);
    return .{ w, h };
}

fn glfwGetWin32Window(_: *const anyopaque) callconv(.c) *anyopaque {
    @panic("Win32 window handle unavailable on wasm");
}

fn glfwGetX11Display() callconv(.c) *anyopaque {
    @panic("X11 display unavailable on wasm");
}

fn glfwGetX11Window(_: *const anyopaque) callconv(.c) u32 {
    @panic("X11 window unavailable on wasm");
}

fn glfwGetCocoaWindow(_: *const anyopaque) callconv(.c) ?*anyopaque {
    return null;
}
