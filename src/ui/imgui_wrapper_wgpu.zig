const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const sdl = @import("../platform/sdl3.zig").c;

extern fn zsc_imgui_use_freetype() void;
extern fn ImGui_ImplSDL3_InitForOther(window: *const anyopaque) bool;
extern fn ImGui_ImplSDL3_ProcessEvent(event: *const anyopaque) bool;
extern fn ImGui_ImplSDL3_NewFrame() void;
extern fn ImGui_ImplSDL3_Shutdown() void;
extern fn ImGui_ImplWGPU_Init(init_info: *ImGui_ImplWGPU_InitInfo) bool;
extern fn ImGui_ImplWGPU_NewFrame() void;
extern fn ImGui_ImplWGPU_RenderDrawData(draw_data: *const anyopaque, pass_encoder: *const anyopaque) void;
extern fn ImGui_ImplWGPU_Shutdown() void;

pub fn init(
    allocator: std.mem.Allocator,
    window: *sdl.SDL_Window,
    device: *const anyopaque,
    swapchain_format: u32,
    depth_format: u32,
) void {
    zgui.init(allocator);
    zsc_imgui_use_freetype();
    zgui.io.setConfigFlags(.{ .dock_enable = true });
    zgui.io.setIniFilename(null);
    theme.apply();
    if (!ImGui_ImplSDL3_InitForOther(window)) {
        unreachable;
    }
    var info = ImGui_ImplWGPU_InitInfo{
        .device = device,
        .num_frames_in_flight = 1,
        .rt_format = swapchain_format,
        .depth_format = depth_format,
        .pipeline_multisample_state = .{},
    };
    if (!ImGui_ImplWGPU_Init(&info)) {
        unreachable;
    }
}

pub fn processEvent(event: *const sdl.SDL_Event) bool {
    return ImGui_ImplSDL3_ProcessEvent(event);
}

pub fn beginFrame(framebuffer_width: u32, framebuffer_height: u32) void {
    ImGui_ImplWGPU_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    zgui.io.setDisplaySize(@floatFromInt(framebuffer_width), @floatFromInt(framebuffer_height));
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);
    zgui.newFrame();
}

pub fn render(pass: *const anyopaque) void {
    zgui.render();
    ImGui_ImplWGPU_RenderDrawData(zgui.getDrawData(), pass);
}

pub fn deinit() void {
    ImGui_ImplWGPU_Shutdown();
    ImGui_ImplSDL3_Shutdown();
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

const ImGui_ImplWGPU_InitInfo = extern struct {
    device: *const anyopaque,
    num_frames_in_flight: u32 = 1,
    rt_format: u32,
    depth_format: u32,
    pipeline_multisample_state: extern struct {
        next_in_chain: ?*const anyopaque = null,
        count: u32 = 1,
        mask: u32 = @bitCast(@as(i32, -1)),
        alpha_to_coverage_enabled: bool = false,
    },
};
