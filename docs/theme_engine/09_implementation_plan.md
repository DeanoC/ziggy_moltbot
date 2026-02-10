# Implementation Plan (Phased)

This plan is meant to be actionable by Codex CLI against this codebase.

Status note (feature/theme_engine branch):
- Phases 0-4: Implemented (with some follow-on polish still worthwhile)
- Phase 5 (Winamp import): Deprioritized for now (not required to ship Winamp-style packs)
- Phase 6: Partially implemented (nav system exists; needs UX polish + more coverage)

## Phase 0: Prep and Refactors (low risk)

1. Introduce an explicit `ThemeContext` type (even if it just wraps the existing tokens).
2. Start migrating widgets from `theme.activeTheme()` to `dc.theme` / `ThemeContext`.
   - Goal: per-window theme becomes possible.
3. Add a profile concept (desktop/phone/tablet/fullscreen) and select it at runtime.

Acceptance:
- No visual regressions.
- All targets still build.

Implementation status:
- Implemented: `ThemeContext` style usage (widgets read from `dc.theme`), profile resolver, per-profile overrides.
- Implemented: config/profile selector + runtime plumbing (see `src/ui/theme_engine/runtime.zig`, `src/ui/theme_engine/profile.zig`).

## Phase 1: Style Sheet (reduce ad-hoc styling)

1. Add `StyleSheet` structs for core widgets:
   - button
   - checkbox
   - text input
   - panels
   - focus ring
2. Migrate widgets to use `StyleSheet` values.

Acceptance:
- Theme changes become centralized.

Implementation status:
- Implemented: `StyleSheet` + JSON parsing (see `src/ui/theme_engine/style_sheet.zig`).
- Implemented: Button/Checkbox/TextInput/Panel/FocusRing all read style sheet (see `src/ui/widgets/*`, `src/ui/panel_chrome.zig`, `src/ui/surface_chrome.zig`).
- Remaining polish:
  - Add explicit state styles (hover/pressed/disabled/focused) so packs can fully control interaction visuals.
  - Extend style sheet coverage to more UI components (menus, tabs, list rows, scrollbars, status bar, etc).

## Phase 2: Theme Packages (data loading)

1. Define JSON schema + versioning:
   - `manifest.json`, token files, style files.
2. Implement loader that can read from a directory.
   - Desktop first.
3. Add capability-gated support for other platforms:
   - Android assets
   - WASM fetch

Acceptance:
- Can switch between a built-in theme and a directory theme pack.
- Invalid theme pack falls back safely.

Implementation status:
- Implemented: dir + zip packs, manifest/tokens/styles/profiles/layouts/windows loading, safe fallback status reporting.
- Implemented: Android writable install of embedded packs under `themes/<id>`.
- Implemented: WASM fetch-based pipeline.

## Phase 3: GPU Materials and New Draw Commands

1. Decide on approach:
   - direct new commands (gradient/nine-slice/shadow)
   - or material system from day 1
2. Implement minimum effect set needed for:
   - clean desktop shadows
   - fullscreen focus ring glow
3. Integrate style sheet references to materials.

Acceptance:
- Effects render correctly on native + wasm + android.

Implementation status:
- Implemented: gradients, image paints (stretch/tile), nine-slice (incl. tile modes), SDF shadow/glow.
- Implemented: “materials” are currently expressed as style sheet `Paint` and existing renderer pipelines.
- Remaining polish:
  - Optional: explicit material/shader extension point for theme packs that require custom shaders.

## Phase 4: Multi-Window (Desktop Only)

1. Remove global single command list assumption (`command_queue.zig`).
2. Introduce per-window command lists and per-window input routing.
3. Create a window manager that can spawn additional windows.
4. Add a theme capability `supports_multi_window` and a theme package option `windows.json`.

Acceptance:
- Two windows render correctly at once.
- Each window has independent theme/profile/scale.

Implementation status:
- Implemented: multi-window, tear-off panels, per-window theme-pack overrides, pack switching at draw-time.

## Phase 5: Winamp Skin Import

1. Add zip support (library or minimal reader).
2. Implement `.wsz` importer and mapping.
3. Add bitmap rendering helpers:
   - nine-slice
   - pixel snapping
   - nearest sampling

Acceptance:
- A sample `.wsz` can be imported into a ZSC theme pack and rendered.

Implementation status:
- Deprioritized for now.
- Note: “Winamp-style” theme packs are supported without importing `.wsz` (see `themes/zsc_winamp*`).

## Phase 6: Controller Navigation + Fullscreen Polish

1. Add gamepad events into the UI input queue.
2. Implement focus graph navigation.
3. Add fullscreen profile UI (card navigation).

Acceptance:
- Full app can be driven with controller input.

Implementation status:
- Partially implemented: nav system exists (`src/ui/input/nav.zig`, `src/ui/input/nav_router.zig`) and is used in key views/widgets.
- Remaining: consistent focus order, default focus targets, controller-first UX polish in all panels, and fullscreen-specific layouts.
