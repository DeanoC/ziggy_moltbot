# Goals and Non-Goals

## Goals

1. **Four usage models (profiles)**
   - Desktop: pointer + keyboard, dense panels, optional multi-window.
   - Phone: touch-first, large hit targets, safe inset aware.
   - Tablet: hybrid touch + pen, adaptive split layouts.
   - Fullscreen: game-like UI, controller navigation, strong focus system.

2. **Theme packages (runtime-loadable)**
   - Support a “developer folder” form (uncompressed directory) and an optional distributable archive form (zip).
   - Packages include tokens, component styles, assets, and optional layouts.

3. **GPU-first theming**
   - Themes can use real GPU effects: gradients, noise, glows, shadows/blur, signed-distance vector shapes, animated backgrounds.
   - The theme engine feeds IDs/parameters into the draw pipeline; the renderer does the batching.

4. **Desktop multi-window**
   - When supported by the platform/renderer, allow multiple native windows.
   - Support “Winamp-style” themes that want separate windows and aggressive bitmap skinning.

5. **Predictable fallback + safety**
   - If a theme pack is invalid or missing assets, fall back to a known-safe built-in theme.
   - Theme packs must be treated as data: no arbitrary code execution.

6. **Works across all current targets**
   - Native (Linux/macOS/Windows cross build), WASM, Android.
   - Capability-gated features (multi-window and file-system loading are not uniform).

## Non-Goals (For v1)

- A full CSS engine.
- User-authored scripting inside themes.
- Perfect pixel-for-pixel Winamp compatibility on day 1.
- Replacing the UI architecture (widgets/components) before the theme system exists.

## Constraints From Current Code

- Tokens exist and are compile-time constants today: `src/ui/theme/theme.zig`.
- Most widgets pull theme via the global accessor `theme.activeTheme()`.
  - For per-window themes and multi-window, the long-term target is: widgets should read from `dc.theme` (the DrawContext theme reference).
- Render features currently implemented in `CommandList` are:
  - rect, rounded rect, line, text, image, clip.
- WGPU renderer currently has two pipelines:
  - shape (solid color) and textured (images + font atlas).

The theme engine design below intentionally aligns with this pipeline instead of fighting it.

