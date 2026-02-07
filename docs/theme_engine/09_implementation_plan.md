# Implementation Plan (Phased)

This plan is meant to be actionable by Codex CLI against this codebase.

## Phase 0: Prep and Refactors (low risk)

1. Introduce an explicit `ThemeContext` type (even if it just wraps the existing tokens).
2. Start migrating widgets from `theme.activeTheme()` to `dc.theme` / `ThemeContext`.
   - Goal: per-window theme becomes possible.
3. Add a profile concept (desktop/phone/tablet/fullscreen) and select it at runtime.

Acceptance:
- No visual regressions.
- All targets still build.

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

## Phase 4: Multi-Window (Desktop Only)

1. Remove global single command list assumption (`command_queue.zig`).
2. Introduce per-window command lists and per-window input routing.
3. Create a window manager that can spawn additional windows.
4. Add a theme capability `supports_multi_window` and a theme package option `windows.json`.

Acceptance:
- Two windows render correctly at once.
- Each window has independent theme/profile/scale.

## Phase 5: Winamp Skin Import

1. Add zip support (library or minimal reader).
2. Implement `.wsz` importer and mapping.
3. Add bitmap rendering helpers:
   - nine-slice
   - pixel snapping
   - nearest sampling

Acceptance:
- A sample `.wsz` can be imported into a ZSC theme pack and rendered.

## Phase 6: Controller Navigation + Fullscreen Polish

1. Add gamepad events into the UI input queue.
2. Implement focus graph navigation.
3. Add fullscreen profile UI (card navigation).

Acceptance:
- Full app can be driven with controller input.

