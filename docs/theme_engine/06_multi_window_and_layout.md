# Multi-Window and Layout

The requested theme engine needs to support:
- Desktop: optional multi-window (arbitrary windows, multiple windows)
- Winamp-style skins: multiple small windows are part of the identity
- Phone/tablet/fullscreen: single window, but different layout strategies

## Current State

- One SDL window is created per app entrypoint:
  - `src/main_native.zig`
  - `src/main_wasm.zig`
  - `src/main_android_wgpu.zig`

- UI renders into a single host rect with safe insets:
  - `src/ui/main_window.zig`

- UI draw recording is global per frame:
  - `src/ui/render/command_queue.zig` sets a global command list via `draw_context.setGlobalCommandList()`.

Multi-window will require de-globalizing at least the command list (and likely input routing) so each window can render independently.

## Desktop Strategy

![Desktop Layouts](images/desktop_layouts.svg)

### Capabilities
Multi-window should be allowed only if all of these are true:
- platform supports multiple SDL windows
- renderer can present to multiple surfaces/swapchains
- input routing can be per-window

Expose this as a `PlatformCaps.supports_multi_window` boolean.

### Window model
Introduce a window manager with per-window state:

```zig
pub const UiWindowId = u32;

pub const UiWindow = struct {
    id: UiWindowId,
    title: []const u8,

    // Platform
    sdl_window: *sdl.SDL_Window,

    // Rendering
    renderer: client.Renderer, // or per-window surface + shared device
    command_list: ui.render.CommandList,

    // Input
    input_queue: ui.input.InputQueue,

    // Theme/profile
    theme_ctx: *const ThemeContext,

    // Root view
    root: union(enum) { workspace, playlist_like, inspector, fullscreen },
};
```

### How themes use it
A theme package may optionally provide `windows.json` describing:
- window templates (sizes, titles, docking policy)
- which root view each window hosts
- whether a window uses pixel-snapping (Winamp-like) or smooth vector UI

The theme engine should not create windows directly. It should:
- provide templates
- and the app decides whether to apply them.

### Detachable panels
A clean desktop theme can allow:
- “tear off” a panel into a new window
- keep one authoritative workspace state
- store detached window metadata in the workspace file

## Phone Strategy

![Phone Layout](images/phone_layout.svg)

- Single window.
- Layout is stacked navigation.
- Theme profile enforces:
  - large hit targets
  - reduced density
  - safe insets

## Tablet Strategy

![Tablet Layout](images/tablet_layout.svg)

- Single window.
- Layout is adaptive split panes.
- Allow floating palettes (pen toolbars).

## Fullscreen Strategy

![Fullscreen UI](images/fullscreen_ui.svg)

- Single window.
- Focus is exclusive.
- UI is card-based with overlays.
- The theme can provide motion + transitions.

