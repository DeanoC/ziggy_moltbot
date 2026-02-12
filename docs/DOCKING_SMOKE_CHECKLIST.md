# Docking and Multi-Window Smoke Checklist

Use this checklist to verify docking behavior after UI/layout changes.

## Scope
- Drag/drop docking within a window (center + left/right/top/bottom).
- Dragging tabs/groups into new windows and back into existing windows.
- Split resizing behavior.
- Contextual window chrome behavior (menu and status bar differences by window role).

## Setup
- Build and run native desktop app:
  - `./.tools/zig-0.15.2/zig build`
  - `./zig-out/bin/ziggystarclaw-client`
- Open at least 3 panels (for example: `Control`, `Chat`, `Sessions`) so docking actions are visible.
- Keep the main window visible while creating at least one detached window.

Optional diagnostics:
- Set `ZSC_DOCK_DEBUG=1` before launching to emit docking attach/detach and workspace save/load traces.
- Example: `ZSC_DOCK_DEBUG=1 ./zig-out/bin/ziggystarclaw-client`

## A. In-Window Docking Targets
- [ ] Drag a tab and hover a target group center.
Expected: center drop highlight appears with center marker; drop merges into target tabs.
- [ ] Drag a tab and hover target left zone.
Expected: left drop highlight appears with directional marker; drop creates left split.
- [ ] Drag a tab and hover target right zone.
Expected: right drop highlight appears with directional marker; drop creates right split.
- [ ] Drag a tab and hover target top zone.
Expected: top drop highlight appears with directional marker; drop creates top split.
- [ ] Drag a tab and hover target bottom zone.
Expected: bottom drop highlight appears with directional marker; drop creates bottom split.
- [ ] Repeat side/center drops with source and destination in non-root groups.
Expected: layout updates correctly without losing tabs or creating empty ghost groups.
- [ ] While hovering one drop zone, visually inspect the same target group.
Expected: sibling drop zones for that same group are shown in a lighter preview state.
- [ ] Drag outside the dock content area.
Expected: drag label indicates detaching to a new window.

## B. Tear-Off and Cross-Window Attach
- [ ] Drag a tab far enough away from all drop targets and release.
Expected: a new detached window opens containing that panel.
- [ ] From detached window, drag its tab over main window and release on center.
Expected: panel reattaches into main window tabs (no extra new window).
- [ ] From detached window, drag over main window side zones and release.
Expected: panel attaches as split on the selected side.
- [ ] Drag from main window tab over an existing detached window and release.
Expected: panel attaches to hovered detached window using hovered drop zone.
- [ ] Perform cross-window attach without changing keyboard focus first.
Expected: target is selected by mouse-hovered window, not stale focused window.

## C. Splitter Resize
- [ ] Drag vertical split handle left/right.
Expected: split ratio updates continuously and panels resize smoothly.
- [ ] Drag horizontal split handle up/down.
Expected: split ratio updates continuously and panels resize smoothly.
- [ ] Resize window after changing split ratios.
Expected: relative proportions are preserved.

## D. Menu and Status Bar Behavior
- [ ] Main workspace window: verify top menu bar is visible.
Expected: full workspace menu is shown.
- [ ] Main workspace window: verify status bar is visible.
Expected: status bar renders at bottom.
- [ ] Detached panel/group window: verify top menu bar is visible.
Expected: compact/contextual menu is shown.
- [ ] Detached panel/group window: verify status bar visibility.
Expected: status bar is hidden by default.

## E. Persistence and Restore
- [ ] Save workspace and quit app.
- [ ] Relaunch app and restore workspace.
Expected: dock groups, tab membership, and detached windows restore.
- [ ] Verify detached windows keep contextual chrome after restore.
Expected: detached windows still use compact menu and hidden status bar by default.
- [ ] Collapse one group to each side rail, save, quit, and relaunch.
Expected: collapsed rail items restore on the same side and remain interactive.

## F. Keyboard Docking (Quick Smoke)
- [ ] `Ctrl+Tab` and `Ctrl+Shift+Tab`.
Expected: cycles tabs within focused group.
- [ ] `Ctrl+PageUp` and `Ctrl+PageDown`.
Expected: cycles focus across dock groups.
- [ ] `Alt+Shift+Left/Right`.
Expected: reorders active tab within current group.
- [ ] `Ctrl+Alt+Arrow`.
Expected: docks focused tab toward nearest group in that direction.
- [ ] `Ctrl+Alt+Enter`.
Expected: merges focused tab into nearest group center.
- [ ] `Ctrl+Shift+Left/Right`.
Expected: collapses focused group to left/right rail.
- [ ] `Ctrl+Shift+Up`.
Expected: opens flyout preview from rail, and toggles pin when flyout is already open.
- [ ] `Ctrl+Shift+Down`.
Expected: closes flyout preview.
- [ ] `Ctrl+Shift+Enter`.
Expected: expands flyout/collapsed group back into dock layout.

## G. Collapsed Rails and Flyouts
- [ ] Collapse a dock group with the header collapse button.
Expected: group is removed from main dock area and appears as a rail icon button.
- [ ] Hover a rail icon without clicking.
Expected: temporary flyout preview appears; moving pointer away from both rail and flyout closes it.
- [ ] Click a rail icon.
Expected: flyout opens in pinned mode and stays open until explicitly closed or expanded.
- [ ] Click flyout expand control.
Expected: flyout closes and group returns to normal dock layout.
- [ ] Collapse or expand a side rail while watching the content area edge.
Expected: rail width transitions smoothly instead of popping instantly.

## Failure Notes Template
- Build/commit:
- OS and window system (X11/Wayland/Win/macOS):
- Repro steps:
- Expected:
- Actual:
- Screenshots or recording:
