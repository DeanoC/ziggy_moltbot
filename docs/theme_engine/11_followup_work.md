# Theme Engine Follow-up Work (Post-Merge)

This branch intentionally focuses on landing the core Theme Engine infrastructure (theme packs, asset loading, multi-window, runtime reload, Winamp-style packs).
There are still a handful of improvements that are worth doing, but they can be safely done in a follow-up branch after this work lands in `main`.

## Theme Model / UX

- Theme-pack capability flags
  - Allow packs to opt out of the app-wide light/dark toggle (example: brushed metal is inherently a light theme; forcing dark mode breaks text contrast).
  - Proposed: `pack.capabilities.supports_light_dark = true|false` (default true for existing packs).
  - UI: if false, hide/disable the light/dark toggle while the pack is active and show a short hint.

- Layout inset for 9-slice chrome
  - Some frame assets include a visible border that should not be “content”.
  - Add a theme token (or per-surface style) like `content_inset { l, t, r, b }` so layout can place widgets inside the border.
  - Use this for: card frames, panel frames, possibly window chrome.

- Menu sizing and text measurement polish
  - Ensure menu item width accounts for full label text in all profiles.
  - Verify the menu background/chrome uses the themed surface where intended (tabs, status bar, custom menu bar).

## Rendering / Visual Fidelity

- Brushed metal lighting as an overlay/shader
  - Use a flat tileable brushed metal base for 9-slice + center fill.
  - Add a separate lighting overlay pass (image or GPU shader) so the “highlight band” stays centered independent of tiling.
  - This avoids non-tileable “center highlight” textures fighting the 9-slice tiler.

- More brush primitives (if we want classic macOS or game-UI looks)
  - Linear gradients (multi-stop).
  - Inner-shadow / bevel helpers.
  - Optional noise overlay.

## Theme Pack Distribution

- User packs vs shipped packs
  - Desktop: support user-downloaded packs under a stable user directory (and optionally keep `themes/` next to exe for portable mode).
  - Android: ship packs in APK + optionally allow user-provided packs in app storage.
  - WASM: shipped-only packs, plus editor-driven packs (if we decide to support upload/import in the browser).

- Theme pack browser filtering
  - When listing packs, only show directories that contain `theme_pack.json` (hide subfolders like `assets/`, `layouts/`).

## Stability / Testing

- Add coverage for:
  - Theme-pack JSON validation errors (missing fields, unknown fields).
  - Theme reload while windows are open (multi-window correctness).
  - Asset path resolution for local file assets vs http(s) URLs (cross-platform).

## Explicitly Deferred

- Importing non-Winamp skin formats
  - We can keep supporting “Winamp-style pack authoring” without implementing full external format imports.

