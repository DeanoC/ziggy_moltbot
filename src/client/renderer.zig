const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");
const imgui = @import("../ui/imgui_wrapper_wgpu.zig");

pub const depth_format_undefined: u32 = @intFromEnum(zgpu.wgpu.TextureFormat.undef);

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !Renderer {
        const window_provider = zgpu.WindowProvider{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        };

        const gctx = try zgpu.GraphicsContext.create(allocator, window_provider, .{});

        return .{
            .allocator = allocator,
            .gctx = gctx,
        };
    }

    pub fn deinit(self: *Renderer) void {
        zgpu.GraphicsContext.destroy(self.gctx, self.allocator);
    }

    pub fn beginFrame(self: *Renderer, framebuffer_width: u32, framebuffer_height: u32) void {
        _ = self;
        imgui.beginFrame(framebuffer_width, framebuffer_height);
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

        imgui.render(@ptrCast(pass));
        pass.end();

        const cmd = encoder.finish(null);
        gctx.submit(&.{cmd});
        cmd.release();

        _ = gctx.present();
    }
};
