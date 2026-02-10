# Codex CLI Workflow

This document is a “do the work” checklist for implementing the theme engine in this repo.

## Ground Rules

- Always keep the app runnable.
- Capability-gate anything platform-specific.
- Prefer incremental changes that preserve the current UI behavior.

## Build/Validation Commands

This repo uses the pinned Zig toolchain at `./.tools/zig-0.15.2/zig`.

Run all builds during theme engine work:

```bash
./.tools/zig-0.15.2/zig build
./.tools/zig-0.15.2/zig build -Dtarget=x86_64-windows-gnu
source ./scripts/emsdk-env.sh && ./.tools/zig-0.15.2/zig build -Dwasm=true
./.tools/zig-0.15.2/zig build -Dandroid=true
```

## Suggested Implementation Order

1. Add `ThemeContext` and thread it through UI root(s).
2. Create `StyleSheet` and migrate 2-3 widgets.
3. Implement profile resolver (desktop/phone/tablet/fullscreen) and wire it to config.
4. Implement theme package folder loader for desktop.
5. Add materials/effects needed for:
   - focus ring glow
   - shadows
6. Add multi-window support (desktop only).
7. Add winamp importer.

## What Files Usually Change

- `src/ui/draw_context.zig`
  - new draw calls for effects
- `src/ui/render/command_list.zig`
  - new commands for effects/materials
- `src/ui/render/wgpu_renderer.zig`
  - pipelines/material registry
- `src/ui/theme.zig` and `src/ui/theme/*`
  - keep built-ins as safe fallback
- `src/ui/widgets/*`
  - migrate to StyleSheet
- `src/client/config.zig`
  - add config fields: active theme pack id/path, active profile

## Minimal Theme Pack for Testing

Use the example theme pack in this repo as a starting point:
- `docs/theme_engine/examples/zsc_clean/manifest.json`
- `docs/theme_engine/examples/zsc_clean/tokens/base.json`
- `docs/theme_engine/examples/zsc_clean/styles/components.json`
- `docs/theme_engine/examples/zsc_showcase/manifest.json` (recommended for testing new features)

### Android Note (Writable Themes Folder)

On Android, ZiggyStarClaw changes the process working directory to the SDL pref path (app-writable).
Theme packs referenced as `themes/<id>` therefore live under that pref directory.

The app also embeds the built-in example packs and will auto-install them into `themes/zsc_clean` and
`themes/zsc_showcase` if the user selects them and they are missing.

### Web (WASM) Note (Fetch-Based Theme Packs)

On the web build, theme packs are loaded by fetching files from a URL (or a path relative to the page origin).

Examples:
- `ui_theme_pack: "themes/zsc_showcase"` (served alongside `ziggystarclaw-client.html`)
- `ui_theme_pack: "https://example.com/my_theme_pack"`

Add config fields (proposal):

```json
{
  "ui_theme_pack": "themes/zsc_clean",
  "ui_profile": "desktop"
}
```

Then implement:
- load pack at startup
- fallback to built-in theme if load fails

## Acceptance Criteria Per Milestone

- Phase 1 (StyleSheet):
  - only one place to tweak padding/colors for a component

- Phase 2 (Theme Packs):
  - theme can be swapped without recompiling
  - missing files do not crash

- Phase 3 (Effects):
  - gradients/shadows/focus glow available as materials
  - stable frame time at desktop density

- Phase 4 (Multi-window):
  - multiple windows render simultaneously
  - independent command lists and input

- Phase 6 (Fullscreen + controller):
  - app is usable with controller only

## Winamp Skin Extraction (WIP)

ZiggyStarClaw includes a minimal `.wsz` (Winamp skin) extractor in the CLI to support the
Winamp import pipeline.

```bash
./zig-out/bin/ziggystarclaw-cli --extract-wsz path/to/skin.wsz --extract-dest themes/imported/my_skin
```
