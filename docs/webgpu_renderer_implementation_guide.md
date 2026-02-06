# WebGPU Renderer Implementation Guide for ZiggyStarClaw

**Author**: Manus AI
**Date**: January 31, 2026

## 1. Introduction

This document provides a comprehensive guide for implementing a cross-platform WebGPU renderer for the ZiggyStarClaw project. The target audience for this guide is the `codex-cli` AI code generation tool, and the implementation will be in Zig, leveraging the `zgpu` library for WebGPU bindings. The new renderer will replace the existing OpenGL implementation and integrate seamlessly with the project's ImGui-based user interface.

WebGPU is a modern graphics API that provides low-level, high-performance access to GPU hardware. It is designed to be cross-platform, with native implementations like Google's Dawn mapping to DirectX 12 on Windows, Metal on macOS, and Vulkan on Linux and Android. This makes it an ideal choice for the ZiggyStarClaw project, which targets a wide range of platforms.

The `zgpu` library provides idiomatic Zig bindings for Dawn, offering a high-level, handle-based resource management system, uniform buffer pooling, and asynchronous shader compilation. By using `zgpu`, we can significantly simplify the process of writing a WebGPU renderer in Zig.

## 2. Prerequisites

Before starting the implementation, ensure the following prerequisites are met:

- The ZiggyStarClaw project is cloned and the build environment is set up as described in `AGENTS.md`.
- The `zgpu` library will be added as a dependency in the `build.zig.zon` file.
- The existing `zglfw` dependency will be used for windowing and input.

## 3. Project Setup

To integrate `zgpu` into the ZiggyStarClaw project, the following changes need to be made to the build system.

### 3.1. Add `zgpu` Dependency

First, add `zgpu` as a dependency in the `build.zig.zon` file.

In this repo we vendor our `zgpu` fork (for the newer Emscripten WebGPU API surface) under `deps/zgpu` and reference it via a `.path` dependency.

```zon
.{
    .name = "ziggystarclaw",
    .version = "0.1.3",
    .dependencies = .{
        // ... other dependencies
        .zgpu = .{
            .path = "deps/zgpu",
        },
    },
}
```

### 3.2. Update `build.zig`

Next, update the `build.zig` file to link against `zgpu` and its dependencies. The following table summarizes the necessary changes:

| Action | Code Snippet |
| :--- | :--- |
| **Import `zgpu`** | `const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });` |
| **Add `zgpu` module** | `exe.root_module.addImport("zgpu", zgpu.module("root"));` |
| **Link `zgpu` libraries** | `@import("zgpu").addLibraryPathsTo(exe);` |
| **Link Dawn** | `if (target.result.os.tag != .emscripten) { exe.linkLibrary(zgpu.artifact("zdawn")); }` |

These changes should be applied to the native, Android, and WASM build configurations in `build.zig`.

## 4. Renderer Architecture

The new WebGPU renderer will be integrated into the existing application structure. A new `Renderer` struct will be created to encapsulate all WebGPU-related state and logic. This struct will be responsible for:

- Initializing the WebGPU context.
- Managing the swap chain.
- Creating and managing render pipelines.
- Handling ImGui rendering.
- Submitting command buffers to the GPU.

The `Renderer` will be initialized in `main_native.zig` (and the other entry points) and will be passed to the main loop. The existing OpenGL-related code in `opengl_loader.c` and `main_native.zig` will be removed.

The following table outlines the key components of the renderer architecture:

| Component | Description |
| :--- | :--- |
| **`Renderer` struct** | Manages all WebGPU state, including the device, queue, and swap chain. |
| **`GraphicsContext`** | The main `zgpu` object that provides access to the WebGPU API. |
| **`WindowProvider`** | An interface that provides the necessary windowing information to `zgpu`, implemented using `zglfw`. |
| **Render Pipeline** | A `GPURenderPipeline` that defines the shaders and vertex layout for rendering. |
| **ImGui Backend** | The `zgui` library will be configured to use the WebGPU renderer. |


## 5. Implementation Steps

This section provides a detailed, step-by-step guide to implementing the WebGPU renderer. The code snippets provided are intended to be used by `codex-cli` to modify the ZiggyStarClaw codebase.

### 5.1. Renderer Initialization

The first step is to create a `Renderer` struct and initialize the `zgpu.GraphicsContext`. This will involve creating a window with `zglfw`, creating a `WindowProvider` for `zgpu`, and then creating the `GraphicsContext`.

A new file, `src/client/renderer.zig`, will be created to house the `Renderer` struct and its associated functions.

**`src/client/renderer.zig`**
```zig
const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    swap_chain: zgpu.SwapChain,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !*Renderer {
        const self = try allocator.create(Renderer);
        self.* = .{
            .allocator = allocator,
            .gctx = undefined,
            .swap_chain = undefined,
        };

        const window_provider = zgpu.DefaultWindowProvider.init(window, zglfw.Window.getFramebufferSize, zglfw.getTime);

        const gctx = try zgpu.GraphicsContext.create(allocator, window_provider.any(), .{});
        self.gctx = gctx;

        const surface = gctx.getSurface();
        const preferred_format = gctx.getSurfacePreferredFormat(surface);

        self.swap_chain = try gctx.createSwapChain(surface, .{
            .format = preferred_format,
            .present_mode = .fifo, // VSync
        });

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.gctx.destroy();
        self.allocator.destroy(self);
    }
};
```

In `main_native.zig`, the `Renderer` will be initialized after the GLFW window is created, and the existing OpenGL context creation will be removed.

### 5.2. ImGui Integration

With the `GraphicsContext` initialized, the next step is to set up the ImGui backend for WebGPU. `zgui` already has support for this, so it's a matter of calling the correct initialization functions.

An `initImGui` function will be added to the `Renderer` struct.

**`src/client/renderer.zig` (continued)**
```zig
// ... inside Renderer struct
const imgui = @import("ui/imgui_wrapper.zig");

// ...

    pub fn initImGui(self: *Renderer) !void {
        const gctx = self.gctx;
        const device = gctx.getDevice();

        try imgui.impl.wgpu.init(device, gctx.getSwapChainFormat(self.swap_chain));
    }

    pub fn deinitImGui(self: *Renderer) void {
        imgui.impl.wgpu.shutdown();
    }
```

This function will be called after the `Renderer` is initialized in `main_native.zig`.

### 5.3. Main Render Loop

The main render loop in `main_native.zig` will be updated to use the new `Renderer`. The loop will now perform the following steps:

1.  Begin a new ImGui frame.
2.  Get the current swap chain texture view.
3.  Create a command encoder.
4.  Begin a render pass.
5.  Render the ImGui draw data.
6.  End the render pass.
7.  Submit the command buffer.
8.  Present the swap chain.

A `render` function will be added to the `Renderer` struct to encapsulate this logic.

**`src/client/renderer.zig` (continued)**
```zig
// ... inside Renderer struct

    pub fn render(self: *Renderer) !void {
        const gctx = self.gctx;

        // New ImGui frame
        imgui.impl.wgpu.newFrame();
        imgui.impl.glfw.newFrame();
        imgui.newFrame();

        // Build UI (this will be called from main_native.zig)
        // ui.draw(ctx);

        // Get next swap chain texture
        const frame = gctx.getSwapChainCurrentTextureView(self.swap_chain) orelse return;
        defer gctx.textureViewRelease(frame.texture_view);

        const encoder = gctx.createCommandEncoder(null);

        const render_pass = gctx.beginRenderPass(encoder, .{
            .color_attachments = &[_]zgpu.wgpu.RenderPassColorAttachment{
                {
                    .view = frame.texture_view,
                    .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 },
                    .load_op = .clear,
                    .store_op = .store,
                },
            },
        });

        // Render ImGui
        imgui.render();
        imgui.impl.wgpu.renderDrawData(imgui.getDrawData(), render_pass);

        gctx.renderPassEnd(render_pass);

        const cmd = gctx.finishCommandEncoder(encoder);
        gctx.submit(&.{cmd});

        gctx.present(self.swap_chain);
    }
```

### 5.4. Shader (WGSL)

While the initial implementation will only render the ImGui interface, this section provides a basic WGSL shader for rendering a triangle, which can be used as a starting point for future rendering tasks.

**`src/shaders/triangle.wgsl`**
```wgsl
@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> @builtin(position) vec4<f32> {
    var pos = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 0.5),
        vec2<f32>(-0.5, -0.5),
        vec2<f32>(0.5, -0.5)
    );

    return vec4<f32>(pos[in_vertex_index], 0.0, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0, 0.0, 0.0, 1.0); // Red
}
```

To use this shader, a `GPURenderPipeline` would be created using `gctx.createRenderPipeline()`, and the shader module would be created from the WGSL source using `gctx.createShaderModule()`. The pipeline would then be used in the render pass before drawing.

### 5.5. Cleanup

Proper cleanup is essential to avoid resource leaks. The `deinit` functions in the `Renderer` struct will be called from `main_native.zig` before the application exits.

## 6. Cross-Platform Considerations

The `zgpu` library and Dawn handle most of the platform-specific details. However, there are a few things to keep in mind:

- **Android**: The Android implementation will require a `SurfaceView` to be passed to the `WindowProvider`.
- **WASM**: The WASM build will use the browser's native WebGPU implementation. The main loop will need to be driven by `emscripten_set_main_loop`.
- **macOS**: The Metal backend requires that the view is layer-backed. `zglfw` handles this automatically.

## 7. Conclusion

This guide provides a clear path for implementing a modern, cross-platform WebGPU renderer in the ZiggyStarClaw project. By leveraging `zgpu` and Dawn, the new renderer will be performant, maintainable, and ready for future expansion.

## 8. References

- [1] [WebGPU API - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API)
- [2] [DeanoC/zgpu - GitHub](https://github.com/DeanoC/zgpu)
- [3] [google/dawn - GitHub](https://github.com/google/dawn)
- [4] [Learn WebGPU for C++](https://eliemichel.github.io/LearnWebGPU/)
- [5] [Build an app with WebGPU - Chrome for Developers](https://developer.chrome.com/docs/web-platform/webgpu/build-app)
