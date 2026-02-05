# ZiggyStarClaw Long-Term UI Refactor Plan

**Owner:** UI/Client Team  
**Date:** 2026-02-02  
**Time Horizon:** 12–24 months  
**Strategy:** ImGui-first (zgui), with selective direct-rendering for specific high-performance components

## Purpose
This document lays out a comprehensive, long-term plan to implement the new ZiggyStarClaw UI design and refactor the existing UI system into a cohesive, maintainable component architecture. It synthesizes the guidance from `docs/How to Build UI Design for ZiggyStarClaw Project/*`, the UI visual guide, and current repo structure. The plan is phased to minimize risk while delivering meaningful visual and usability improvements early.

## Goals (Success Criteria)
- Implement the light theme and design system specified in `ZiggyStarClaw_UI_Visual_Guide_v2.pdf`.
- Provide a reusable component library with consistent styling and behavior.
- Align all primary views (chat, operator, settings, workspace) with the new design.
- Introduce robust editor and markdown components that are performant on large files.
- Separate data models from UI views for higher-level systems (chat history, node graph, media).
- Maintain cross-platform parity (native, Windows, WASM, Android) for each milestone.

## Non-Goals
- Full rewrite of the UI to direct rendering.
- Feature expansion outside of UI scope (protocol, backend, or network changes).
- Pixel-perfect reproduction of external references beyond the provided visual guide.

## Guiding Principles
- **ImGui-first:** Use `zgui` for most UI to maximize cross-platform stability.
- **Component-driven:** Build reusable, themed components in `src/ui/components`.
- **Design system:** Centralize color, typography, spacing, radius, and shadows.
- **Data vs View:** Keep UI code stateless and render from data models.
- **Incremental migration:** Keep existing panels functional while rolling out new UI.

## Current State Summary
- UI is largely immediate-mode with panels in `src/ui/panels/*`.
- Theming exists but is primarily dark-theme oriented.
- Panels include chat, settings, control, sessions, tool output, etc.
- Editor components exist but are limited and not fully aligned with the new design.

## Target Architecture Overview
### 1) Theme System
Introduce a unified theme system with light/dark themes and design tokens:
- `src/ui/theme/colors.zig`
- `src/ui/theme/typography.zig`
- `src/ui/theme/spacing.zig`
- `src/ui/theme/theme.zig`

### 2) Component Library
Adopt the architecture in `ZiggyStarClaw UI Component Architecture.md`:
- `src/ui/components/core/*` (Button, Badge, TextLabel, Separator)
- `src/ui/components/layout/*` (Card, Sidebar, HeaderBar, SplitPane, ScrollArea)
- `src/ui/components/navigation/*` (TabBar, NavItem, Breadcrumb)
- `src/ui/components/data/*` (FileRow, ProgressStep, AgentStatus)
- `src/ui/components/feedback/*` (ApprovalCard, Toast)
- `src/ui/components/composite/*` (ProjectCard, SourceBrowser)

### 3) Editor & Markdown Stack
Follow `Code Editor and Markdown Component Architecture.md`:
- `src/ui/editors/code_editor/*`
- `src/ui/editors/markdown/*`
- Shared `Document`, `TextBuffer`, `Cursor`, `Highlighter` models

### 4) Higher-Level UI Systems
Follow `Building Higher-Level UI Components in ZiggyStarClaw.md`:
- `NodeGraph` data model + canvas
- Advanced chat history with virtualization
- Media viewer and gallery (image cache integration)

## Phased Roadmap

### Phase 0 — Planning & Baseline (Month 0–1)
Status: [ ] Not started
**Objectives**
- Confirm scope and rollout strategy.
- Build a baseline inventory of existing UI panels and their target counterparts.
- Add the long-term plan doc and align team expectations.

**Deliverables**
- This plan document.
- Migration inventory (panel-to-view mapping).

**Acceptance Criteria**
- Clear migration order and dependency map.

---

### Phase 1 — Design System Foundation (Month 1–3)
Status: [ ] Not started
**Objectives**
- Implement the theme system with light + dark themes.
- Add design tokens for color, spacing, typography, radius, and shadows.
- Provide helper APIs to apply themes across components.

**Deliverables**
- Theme module under `src/ui/theme/`.
- Theme switching API (runtime toggle).
- Baseline application of theme to existing UI.

**Acceptance Criteria**
- Light theme renders without regressions to layout or readability.
- Existing UI panels can run under both themes.

---

### Phase 2 — Core Component Library (Month 3–6)
Status: [ ] Not started
**Objectives**
- Implement core and layout components using `zgui`.
- Establish consistent styling and API for components.
- Provide basic navigation components.

**Deliverables**
- `Button`, `Badge`, `TextLabel`, `Separator`.
- `Card`, `Sidebar`, `HeaderBar`, `SplitPane`, `ScrollArea`.
- `TabBar`, `NavItem`, `Breadcrumb`.

**Acceptance Criteria**
- Components match the visual guide within practical ImGui limits.
- Components are used in at least one migrated panel.

---

### Phase 3 — Core Views Migration (Month 6–10)
Status: [ ] Not started
**Objectives**
- Refactor main views to use the new component library.
- Migrate chat, operator, settings, and workspace layouts.
- Introduce UI layout management improvements (dock/panel manager).

**Deliverables**
- Updated `src/ui/main_window.zig` and panel rendering.
- Migrated `chat_panel`, `settings_panel`, `control_panel`.
- Consistent styling and spacing across all main panels.

**Acceptance Criteria**
- Core workflows (chat, operator, settings) are fully functional with new UI.
- No regressions in cross-platform builds.

---

### Phase 4 — Editor & Markdown System (Month 10–14)
Status: [ ] Not started
**Objectives**
- Implement `Document` and `TextBuffer` (gap buffer Stage 1).
- Add syntax highlighting and tokenization.
- Build Markdown parser + viewer, with split mode editor.

**Deliverables**
- `src/ui/editors/code_editor/*`
- `src/ui/editors/markdown/*`
- `src/ui/data/document.zig`

**Acceptance Criteria**
- Code editor supports UTF-8, selection, undo/redo, and line numbers.
- Markdown editor supports source/preview/split with live updates.
- Large documents remain responsive.

---

### Phase 5 — Advanced Components (Month 14–18)
Status: [ ] Not started
**Objectives**
- Add higher-level UI systems: node graph, media viewer, advanced chat.
- Implement shared systems: undo/redo, drag-and-drop, focus management.

**Deliverables**
- `NodeGraph` data model + canvas rendering.
- `MediaCollection` + image viewer and gallery.
- Advanced chat history with virtualization.

**Acceptance Criteria**
- Node graph interactions are stable (pan/zoom/link).
- Media gallery is performant with large collections.
- Chat history renders efficiently at scale.

---

### Phase 6 — Optimization & Optional Direct Rendering (Month 18–24)
Status: [ ] Not started
**Objectives**
- Profile and optimize UI performance (virtualization, caching).
- Implement direct-rendered widgets where necessary.
- Final polish and UI consistency sweep.

**Deliverables**
- Optional `direct_renderer.zig` with selective adoption.
- Performance regression tests and profiling benchmarks.

**Acceptance Criteria**
- UI meets target framerate on all supported platforms.
- No significant regressions in responsiveness or memory usage.

## Testing Strategy
- **Unit Tests:** TextBuffer, cursor movement, UTF-8 ops, tokenizer correctness.
- **Integration Tests:** Editor rendering + Markdown preview flow.
- **Performance Tests:** Long chat histories, large documents, media galleries.
- **Cross-Platform Builds:** Native, Windows, WASM, Android for each milestone.

## Risks & Mitigations
- **Scope creep:** lock milestones and enforce non-goals.
- **Performance regressions:** introduce virtualization early in chat/media.
- **Styling drift:** enforce component usage instead of ad hoc zgui calls.
- **Dependency bloat:** add only essential libs (e.g., MD4C when needed).

## Migration & Rollout Plan
- Incremental migration by panel/view.
- Feature flags or config toggles for old vs new UI.
- Keep existing panels functional until replacements are stable.

## Assumptions
- Light theme is the primary target; dark theme remains available.
- Existing zgui/ImGui system remains the base renderer.
- Direct rendering is only introduced for targeted high-value components.

## Milestone Checklist (High-Level)
- [ ] Theme system (light/dark) complete
- [ ] Core components implemented and adopted
- [ ] Main views migrated to new UI
- [ ] Editor + Markdown stack functional
- [ ] Advanced systems implemented (node graph, media, advanced chat)
- [ ] Optimization phase complete
