# ZiggyStarClaw – UI v2 Implementation Guide
## Panel Data Models & Minimal v2 Milestone

This document is intended to be handed directly to **Codex** as an implementation brief.
Target stack:
- Zig
- ImGui (with Docking)
- WebGPU backend

---

## 1. Mental Model

ZiggyStarClaw is **not a chat UI**.

It is an **AI-controlled project workspace** where:
- Chat is one panel among many
- The AI opens, updates, and focuses panels
- UI state is persistent and replayable

The UI renders **workspace state**, not conversation text.

---

## 2. Core Architecture

### 2.1 Workspace (Authoritative UI State)

```zig
const Workspace = struct {
    panels: std.ArrayList(Panel),
    layout: DockLayout,
    focused_panel_id: ?PanelId,
    active_project: ProjectId,
};
```

Notes:
- Serializable
- Restored on startup
- Mutated by user actions or AI-issued UI commands

---

### 2.2 Panel (UI Atom)

```zig
const Panel = struct {
    id: PanelId,
    kind: PanelKind,
    title: []const u8,
    data: PanelData,
    state: PanelState,
};
```

---

### 2.3 PanelKind

Closed enum – new kinds require explicit support.

```zig
const PanelKind = enum {
    Chat,
    CodeEditor,
    Canvas,
    Document,
    FileExplorer,
    Diff,
    ToolOutput,
    Inspector,
};
```

---

### 2.4 PanelState (UI-only)

```zig
const PanelState = struct {
    dock_node: DockNodeId,
    is_focused: bool,
    is_dirty: bool,
};
```

- Never sent to the AI
- Purely visual / interaction state

---

### 2.5 PanelData (Semantic Payload)

```zig
const PanelData = union(enum) {
    Chat: ChatPanel,
    CodeEditor: CodeEditorPanel,
    Canvas: CanvasPanel,
    Document: DocumentPanel,
    ToolOutput: ToolOutputPanel,
};
```

This is the **AI-relevant data**.

---

## 3. Panel Payload Examples

### 3.1 Code Editor Panel

```zig
const CodeEditorPanel = struct {
    file_id: FileId,
    language: Language,
    content: []u8,

    last_modified_by: enum { user, ai },
    version: u32,
};
```

Key idea:
- AI edits data, not widgets
- UI renders data

---

### 3.2 Canvas Panel

```zig
const CanvasPanel = struct {
    canvas_id: CanvasId,
    elements: []CanvasElement,
    coordinate_space: enum { screen, world },
};
```

Supports:
- Diagrams
- Whiteboards
- AI sketches

---

### 3.3 Tool Output Panel

```zig
const ToolOutputPanel = struct {
    tool_name: []const u8,
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
};
```

Typically short-lived panels spawned by AI actions.

---

## 4. Panel Lifecycle Rules

- Panels have stable identity
- AI should reuse existing panels where possible
- Workspace reload restores panels and layout

Examples:
- AI edits an open file → reuse CodeEditor panel
- AI runs a tool → spawn ToolOutput panel
- User closes panel → panel destroyed

---

## 5. AI → UI Command Interface

The AI **never directly manipulates UI widgets**.

Instead it emits deterministic UI commands.

```zig
const UiCommand = union(enum) {
    OpenPanel: OpenPanelCmd,
    UpdatePanel: UpdatePanelCmd,
    FocusPanel: PanelId,
    ClosePanel: PanelId,
};
```

Example JSON payload:

```json
{
  "type": "OpenPanel",
  "kind": "CodeEditor",
  "file": "ui.zig"
}
```

All UI mutations go through:

```zig
fn applyUiCommand(cmd: UiCommand) void;
```

This is the AI ↔ UI seam.

---

## 6. Minimal v2 UI Milestone

### 6.1 Goals

v2 must move ZiggyStarClaw from:
> Chat app → AI workspace desktop

---

### 6.2 Required Features

1. ImGui Docking workspace
2. Persistent workspace layout
3. Panel system with identity
4. AI-driven panel creation
5. Workspace serialization

---

### 6.3 Required Panel Types

- Chat
- Code Editor
- Tool Output

Everything else is out-of-scope for v2.

---

### 6.4 Suggested Default Layout

```
┌──────────────────────────────┐
│ Project ▾   Quick Bar       │
├───────────┬──────────────────┤
│ Explorer  │ Code Editor      │
│           │                  │
├───────────┴───────┬──────────┤
│ Chat              │ Tool Out │
└───────────────────┴──────────┘
```

---

## 7. Recommended Implementation Order

1. Panel + PanelManager types
2. Enable ImGui docking
3. Workspace serialization
4. UiCommand handling
5. Replace chat-only flow with panel spawning

---

## 8. Success Criteria

v2 is successful when:

- AI opens files into editors
- AI spawns tool output panels
- Workspace restores after restart
- Chat is no longer the primary UI surface

At this point ZiggyStarClaw becomes an **AI workstation**, not an AI chat client.
