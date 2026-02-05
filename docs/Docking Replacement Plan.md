# Docking Replacement Plan (Custom Layout Manager)

## Goal
Move off ImGui DockSpace to a custom layout manager while keeping the UI functional throughout the transition.

## Principles
- Keep the app usable at all times.
- Migrate in slices: layout first, interactions later.
- Allow ImGui panels to be hosted inside custom layout rects during transition.
- Persist layout state early so we can iterate without losing work.

## Phase A — Static Custom Layout (No Drag)
**Purpose:** Stand up a custom layout manager that can render panels at fixed positions and sizes.

**Deliverables:**
- `src/ui/layout/custom_layout.zig`
  - `LayoutNode` tree types: `Split`, `Tabs`, `Leaf`.
  - `computeRects(viewport) -> []PanelRect` for deterministic panel placement.
- `src/ui/layout/panel_host.zig`
  - `renderPanelInRect(panel_kind, rect)`
  - For custom panels: call custom draw directly.
  - For legacy ImGui panels: call ImGui wrapper using `SetNextWindowPos/Size + Begin/End`.
- `src/ui/main_window.zig`
  - Add `use_custom_layout` toggle (default OFF).
  - If ON, bypass DockSpace; render panels via `custom_layout` and `panel_host`.

**Exit Criteria:**
- App runs with custom layout enabled.
- Panels render correctly in fixed positions.
- ImGui panels can be hosted inside custom layout rects.

## Phase B — Tabbing + Show/Hide (No Drag)
**Purpose:** Make custom layout usable day-to-day before adding docking drag behavior.

**Deliverables:**
- `LayoutNode.Tabs` with active index and tab strip rendering (custom draw + input).
- Show/Hide panels via existing Window menu and panel manager, mapped into custom layout.
- Persist layout tree and active tabs to workspace JSON.

**Exit Criteria:**
- Tabs switch correctly.
- Panel visibility toggles work.
- Layout persists across sessions.

## Phase C — Docking Interactions
**Purpose:** Replace DockSpace behaviors with custom interaction logic.

**Deliverables:**
- Drag overlays and docking targets.
- Split resizing handles.
- Layout tree updates on drop.
- Persistence for all changes.

**Exit Criteria:**
- DockSpace no longer required.
- Custom docking matches current functionality.
- All layouts persist reliably.

## Risks / Notes
- IMGUI-hosted panels in Phase A/B must respect rect sizes to avoid zero-size assertions.
- Avoid deep coupling between layout and panel rendering to keep migration flexible.
- Long-term goal: full custom renderer/input for all panels.
