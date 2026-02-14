const std = @import("std");
const zgpu = @import("zgpu");

const zui = @import("ziggy-ui");
const command_list = zui.ui.render.command_list;
const ui_wgpu_renderer = zui.ui.render.wgpu_renderer;
const sdl = zui.zsc.platform.sdl3.c;
const profiler = @import("../utils/profiler.zig");

pub const Shared = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    ui_renderer: ui_wgpu_renderer.Renderer,

    pub fn init(allocator: std.mem.Allocator, window: *sdl.SDL_Window) !Shared {
        cachePlatformHandlesFromWindow(window);
        const window_provider = windowProviderForSdl(window);
        const gctx = try zgpu.GraphicsContext.create(allocator, window_provider, .{});
        const ui_renderer = try ui_wgpu_renderer.Renderer.init(allocator, gctx);
        return .{ .allocator = allocator, .gctx = gctx, .ui_renderer = ui_renderer };
    }

    pub fn deinit(self: *Shared) void {
        self.ui_renderer.deinit();
        zgpu.GraphicsContext.destroy(self.gctx, self.allocator);
    }
};

pub const WindowSwapchain = struct {
    // If `kind == .main`, this swapchain is owned by `Shared.gctx` and must not be released here.
    kind: enum { main, owned },
    window: *sdl.SDL_Window,

    // Owned window resources.
    surface: ?zgpu.wgpu.Surface = null,
    swapchain: ?zgpu.wgpu.SwapChain = null,
    desc: ?zgpu.wgpu.SwapChainDescriptor = null,

    pub fn initMain(shared: *Shared, window: *sdl.SDL_Window) WindowSwapchain {
        _ = shared;
        return .{
            .kind = .main,
            .window = window,
            .surface = null,
            .swapchain = null,
            .desc = null,
        };
    }

    pub fn initOwned(shared: *Shared, window: *sdl.SDL_Window) !WindowSwapchain {
        const surface = createSurfaceForWindow(shared.gctx.instance, window);
        errdefer surface.release();

        const fb = sdlGetFramebufferSize(@ptrCast(window));
        const desc = zgpu.wgpu.SwapChainDescriptor{
            .label = "zsc.swapchain",
            .usage = .{ .render_attachment = true },
            .format = shared.gctx.swapchain_descriptor.format,
            .width = fb[0],
            .height = fb[1],
            .present_mode = shared.gctx.swapchain_descriptor.present_mode,
        };
        const sc = shared.gctx.device.createSwapChain(surface, desc);
        errdefer sc.release();

        return .{
            .kind = .owned,
            .window = window,
            .surface = surface,
            .swapchain = sc,
            .desc = desc,
        };
    }

    pub fn deinit(self: *WindowSwapchain) void {
        if (self.kind == .owned) {
            if (self.swapchain) |sc| sc.release();
            if (self.surface) |surf| surf.release();
        }
        self.* = undefined;
    }

    pub fn beginFrame(self: *WindowSwapchain, shared: *Shared, framebuffer_width: u32, framebuffer_height: u32) void {
        const gctx = shared.gctx;
        switch (self.kind) {
            .main => {
                if (framebuffer_width > 0 and framebuffer_height > 0) {
                    if (gctx.swapchain_descriptor.width != framebuffer_width or
                        gctx.swapchain_descriptor.height != framebuffer_height)
                    {
                        gctx.swapchain_descriptor.width = framebuffer_width;
                        gctx.swapchain_descriptor.height = framebuffer_height;
                        gctx.swapchain.release();
                        gctx.swapchain = gctx.device.createSwapChain(gctx.surface, gctx.swapchain_descriptor);
                    }
                }
            },
            .owned => {
                var d = self.desc orelse return;
                if (framebuffer_width > 0 and framebuffer_height > 0) {
                    if (d.width != framebuffer_width or d.height != framebuffer_height) {
                        d.width = framebuffer_width;
                        d.height = framebuffer_height;
                        if (self.swapchain) |sc| sc.release();
                        self.swapchain = shared.gctx.device.createSwapChain(self.surface.?, d);
                        self.desc = d;
                    }
                }
            },
        }
    }

    pub fn render(self: *WindowSwapchain, shared: *Shared, list: *command_list.CommandList) void {
        const zone = profiler.zone(@src(), "multi_renderer.render_window");
        defer zone.end();

        const gctx = shared.gctx;
        if (!gctx.canRender()) {
            gctx.device.tick();
            return;
        }

        const back_view = self.currentTextureViewMaybe(shared) orelse return;
        defer back_view.release();

        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

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
        shared.ui_renderer.record(list);
        shared.ui_renderer.render(pass);
        pass.end();

        const cmd = encoder.finish(null);
        defer cmd.release();
        gctx.queue.submit(&.{cmd});

        self.present(shared);
    }

    fn present(self: *WindowSwapchain, shared: *Shared) void {
        switch (self.kind) {
            .main => shared.gctx.swapchain.present(),
            .owned => self.swapchain.?.present(),
        }
    }

    fn currentTextureViewMaybe(self: *WindowSwapchain, shared: *Shared) ?zgpu.wgpu.TextureView {
        const view = switch (self.kind) {
            .main => shared.gctx.swapchain.getCurrentTextureView(),
            .owned => self.swapchain.?.getCurrentTextureView(),
        };
        return switch (comptime @typeInfo(@TypeOf(view))) {
            .optional => view,
            else => view,
        };
    }
};

// SDL window provider glue. This mirrors the setup used in `src/client/renderer.zig`,
// but allows multiple swapchains to share one WebGPU device.

var g_x11_display: ?*anyopaque = null;
var g_wayland_display: ?*anyopaque = null;

pub fn cachePlatformHandlesFromWindow(window: *sdl.SDL_Window) void {
    const props = sdl.SDL_GetWindowProperties(window);
    g_x11_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null);
    g_wayland_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
}

fn windowProviderForSdl(window: *sdl.SDL_Window) zgpu.WindowProvider {
    return .{
        .window = window,
        .fn_getTime = &sdlGetTime,
        .fn_getFramebufferSize = &sdlGetFramebufferSize,
        .fn_getWin32Window = &sdlGetWin32Window,
        .fn_getX11Display = &sdlGetX11Display,
        .fn_getX11Window = &sdlGetX11Window,
        .fn_getWaylandDisplay = if (g_wayland_display != null) &sdlGetWaylandDisplay else null,
        .fn_getWaylandSurface = if (g_wayland_display != null) &sdlGetWaylandSurface else null,
        .fn_getCocoaWindow = &sdlGetCocoaWindow,
        .fn_getAndroidNativeWindow = &sdlGetAndroidNativeWindow,
    };
}

fn sdlGetTime() f64 {
    const ticks = sdl.SDL_GetTicks();
    return @as(f64, @floatFromInt(ticks)) / 1000.0;
}

fn sdlGetFramebufferSize(window_ptr: *const anyopaque) [2]u32 {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(@ptrCast(@constCast(window_ptr)), &w, &h);
    const w_u32: u32 = @intCast(if (w > 0) w else 1);
    const h_u32: u32 = @intCast(if (h > 0) h else 1);
    return .{ w_u32, h_u32 };
}

fn sdlGetWin32Window(window_ptr: *const anyopaque) callconv(.c) *anyopaque {
    const props = sdl.SDL_GetWindowProperties(@ptrCast(@constCast(window_ptr)));
    return sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) orelse unreachable;
}

fn sdlGetX11Display() callconv(.c) *anyopaque {
    return g_x11_display orelse unreachable;
}

fn sdlGetX11Window(window_ptr: *const anyopaque) callconv(.c) u32 {
    const props = sdl.SDL_GetWindowProperties(@ptrCast(@constCast(window_ptr)));
    const value = sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    return @intCast(value);
}

fn sdlGetWaylandDisplay() callconv(.c) *anyopaque {
    return g_wayland_display orelse unreachable;
}

fn sdlGetWaylandSurface(window_ptr: *const anyopaque) callconv(.c) *anyopaque {
    const props = sdl.SDL_GetWindowProperties(@ptrCast(@constCast(window_ptr)));
    return sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse unreachable;
}

fn sdlGetCocoaWindow(window_ptr: *const anyopaque) callconv(.c) ?*anyopaque {
    const props = sdl.SDL_GetWindowProperties(@ptrCast(@constCast(window_ptr)));
    return sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
}

fn sdlGetAndroidNativeWindow(window_ptr: *const anyopaque) callconv(.c) *anyopaque {
    const props = sdl.SDL_GetWindowProperties(@ptrCast(@constCast(window_ptr)));
    return sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER, null) orelse unreachable;
}

fn createSurfaceForWindow(instance: zgpu.wgpu.Instance, window: *sdl.SDL_Window) zgpu.wgpu.Surface {
    const builtin = @import("builtin");
    const os_tag = builtin.target.os.tag;

    if (os_tag == .windows) {
        const hwnd = sdlGetWin32Window(@ptrCast(window));
        var desc: zgpu.wgpu.SurfaceDescriptorFromWindowsHWND = undefined;
        desc.chain.next = null;
        desc.chain.struct_type = .surface_descriptor_from_windows_hwnd;
        desc.hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?;
        desc.hwnd = hwnd;
        return instance.createSurface(.{
            .next_in_chain = @ptrCast(&desc),
            .label = "zsc surface",
        });
    }

    if (os_tag == .macos) {
        // Copied from zgpu: attach a CAMetalLayer to the window's content view.
        const ns_window = sdlGetCocoaWindow(@ptrCast(window)).?;
        const ns_view = msgSend(ns_window, "contentView", .{}, *anyopaque);
        msgSend(ns_view, "setWantsLayer:", .{true}, void);
        const layer = msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque) orelse
            @panic("failed to create Metal layer");
        msgSend(ns_view, "setLayer:", .{layer}, void);

        const scale_factor = msgSend(ns_window, "backingScaleFactor", .{}, f64);
        msgSend(layer, "setContentsScale:", .{scale_factor}, void);

        var sdesc: zgpu.wgpu.SurfaceDescriptorFromMetalLayer = undefined;
        sdesc.chain.next = null;
        sdesc.chain.struct_type = .surface_descriptor_from_metal_layer;
        sdesc.layer = layer;
        return instance.createSurface(.{
            .next_in_chain = @ptrCast(&sdesc),
            .label = "zsc surface",
        });
    }

    // Linux desktop (X11/Wayland).
    if (g_wayland_display) |wl_display| {
        var desc: zgpu.wgpu.SurfaceDescriptorFromWaylandSurface = undefined;
        desc.chain.next = null;
        desc.chain.struct_type = .surface_descriptor_from_wayland_surface;
        desc.display = wl_display;
        desc.surface = sdlGetWaylandSurface(@ptrCast(window));
        return instance.createSurface(.{
            .next_in_chain = @ptrCast(&desc),
            .label = "zsc surface",
        });
    } else {
        var desc: zgpu.wgpu.SurfaceDescriptorFromXlibWindow = undefined;
        desc.chain.next = null;
        desc.chain.struct_type = .surface_descriptor_from_xlib_window;
        desc.display = sdlGetX11Display();
        desc.window = sdlGetX11Window(@ptrCast(window));
        return instance.createSurface(.{
            .next_in_chain = @ptrCast(&desc),
            .label = "zsc surface",
        });
    }
}

const objc = struct {
    const SEL = ?*opaque {};
    const Class = ?*opaque {};
    extern fn sel_getUid(str: [*:0]const u8) SEL;
    extern fn objc_getClass(name: [*:0]const u8) Class;
    extern fn objc_msgSend() void;
};

fn msgSend(obj: anytype, sel_name: [:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
    const args_meta = @typeInfo(@TypeOf(args)).@"struct".fields;
    const FnType = switch (args_meta.len) {
        0 => *const fn (@TypeOf(obj), objc.SEL) callconv(.c) ReturnType,
        1 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type) callconv(.c) ReturnType,
        else => @compileError("msgSend arity not supported in this file"),
    };
    const func: FnType = @ptrCast(&objc.objc_msgSend);
    const sel = objc.sel_getUid(sel_name);
    return switch (args_meta.len) {
        0 => func(obj, sel),
        1 => func(obj, sel, @field(args, args_meta[0].name)),
        else => unreachable,
    };
}
