# Architecture

![Theme Engine Architecture](images/theme_engine_architecture.svg)

## Current State In Repo (Baseline)

- Tokens: `src/ui/theme/colors.zig`, `src/ui/theme/spacing.zig`, `src/ui/theme/typography.zig`, `src/ui/theme/theme.zig`
- Global theme mode switch: `src/ui/theme.zig`
- Draw API: `src/ui/draw_context.zig`
- Recorded rendering: `src/ui/render/command_list.zig` + `src/ui/render/command_queue.zig`
- WGPU renderer: `src/ui/render/wgpu_renderer.zig`

This is already a good foundation: theme is data, draw is recorded, rendering is centralized.

## Target Theme Engine (What We Add)

### Responsibilities
1. **Load + validate** theme packages (folder/zip/assets)
2. Provide a **ThemeContext** to UI code (tokens + styles + materials)
3. Resolve and apply a **Profile** (desktop/phone/tablet/fullscreen) based on:
   - platform capabilities
   - window size/aspect
   - input modality
   - user selection
4. Manage **GPU resources** (textures, shader modules) needed by materials
5. Support **fallback** and optional **hot reload**

### Non-responsibilities
- It does not decide widget logic.
- It does not own the render loop.
- It does not do layout itself; it feeds layout presets and sizing rules.

## Proposed Module Layout (New)

Suggested new folder (names are flexible):

- `src/ui/theme_engine/theme_engine.zig`
- `src/ui/theme_engine/theme_package.zig`
- `src/ui/theme_engine/schema.zig` (parse/validate)
- `src/ui/theme_engine/profile.zig` (profile resolver)
- `src/ui/theme_engine/style_sheet.zig` (component styles)
- `src/ui/theme_engine/materials.zig` (GPU material registry)
- `src/ui/theme_engine/assets.zig` (file loading + caching; per-platform backends)

The existing token structs in `src/ui/theme/*` can be reused as the “built-in” baseline.

## Key Types (Data Model)

### Platform capabilities
The theme engine should explicitly ask the platform what is possible:

```zig
pub const PlatformCaps = struct {
    supports_filesystem_read: bool,
    supports_filesystem_write: bool,
    supports_multi_window: bool,
    supports_shader_hot_reload: bool,
    supports_pointer_hover: bool,
    supports_touch: bool,
    supports_pen: bool,
    supports_gamepad: bool,
};
```

### Profiles
Profiles are usage models:

```zig
pub const ProfileId = enum { desktop, phone, tablet, fullscreen };

pub const Profile = struct {
    id: ProfileId,

    // Sizing
    density: enum { compact, medium, large, huge },
    hit_target_min_px: f32,
    ui_scale: f32,

    // Input model
    modality: enum { pointer_keyboard, touch, touch_pen, controller },

    // Feature toggles
    allow_multi_window: bool,
    allow_hover_states: bool,
};
```

### ThemeContext
A resolved theme for a single UI root (window):

```zig
pub const ThemeContext = struct {
    tokens: ThemeTokens,
    styles: StyleSheet,
    materials: MaterialRegistry,
    profile: Profile,
};
```

Where:
- `ThemeTokens` may reuse the current `src/ui/theme/theme.zig` struct layout.
- `StyleSheet` is per-component styles.
- `MaterialRegistry` holds GPU material definitions.

## How UI Code Consumes It

### Short-term (minimal disruption)
- Keep `src/ui/theme.zig` as a compatibility layer.
- Theme engine sets the active theme, and widgets continue calling `theme.activeTheme()`.

### Long-term (required for multi-window)
- Stop reading theme from a global.
- Ensure all widgets prefer `dc.theme` / `ThemeContext` passed down from the window.

A pragmatic migration path:
1. Introduce `dc.theme_ctx: *const ThemeContext` alongside `dc.theme` (or replace `dc.theme`).
2. Update widgets incrementally to read from `ThemeContext.styles.*` rather than ad-hoc math.

## How Renderer Consumes It

The renderer should not parse theme packs. It needs:
- texture handles
- material ids and parameters

A minimal interface:

```zig
pub const MaterialId = u32;

pub const MaterialDraw = struct {
    id: MaterialId,
    params_offset: u32,
    params_len: u32,
};
```

DrawContext records:
- `Command.material_quad` (rect + material draw)

Renderer maps `MaterialId` to:
- pipeline
- bind group layouts
- shader modules

Details: `docs/theme_engine/05_rendering_and_effects.md`.

